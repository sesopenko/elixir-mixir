defmodule ElixirMixir.Runtime.ArtifactRegistry do
  @moduledoc """
  Append-only in-memory artifacts and non-reusable BEAM-lifetime module slots.

  The fixed atom pool is allocated when this module is compiled. The slot counter
  survives application restarts in persistent_term; artifact metadata does not.
  """

  use GenServer

  alias ElixirMixir.Runtime.Error

  @modules (for index <- 1..128 do
              Module.concat([
                ElixirMixir.Generated,
                "Slot" <> String.pad_leading(Integer.to_string(index), 3, "0")
              ])
            end)
  @counter_key {__MODULE__, :lifetime_counter}

  @type reservation :: %{slot: pos_integer(), module: module(), token: reference()}
  @type artifact :: %{atom() => term()}

  @doc "Starts the unique artifact registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Consumes one lifetime slot before parsing, without reusing failed attempts."
  @spec reserve(pos_integer()) :: {:ok, reservation()} | {:error, Error.t()}
  def reserve(limit), do: GenServer.call(__MODULE__, {:reserve, min(limit, 128)})

  @doc "Returns the next successful revision for a logical name; Manager serializes registration."
  @spec next_revision(String.t()) :: pos_integer()
  def next_revision(name), do: GenServer.call(__MODULE__, {:next_revision, name})

  @doc "Registers a preflighted artifact exactly once using its reservation."
  @spec register(reservation(), artifact()) :: :ok | {:error, Error.t()}
  def register(reservation, artifact),
    do: GenServer.call(__MODULE__, {:register, reservation, artifact})

  @doc "Fetches immutable internal source, bytecode and metadata by opaque artifact ID."
  @spec fetch(String.t()) :: {:ok, artifact()} | {:error, Error.t()}
  def fetch(id), do: GenServer.call(__MODULE__, {:fetch, id})

  @doc "Returns bounded counts, including all successful and failed lifetime reservations."
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts) do
    counter =
      case :persistent_term.get(@counter_key, nil) do
        nil ->
          counter = :atomics.new(1, [])
          :persistent_term.put(@counter_key, counter)
          counter

        counter ->
          counter
      end

    {:ok, %{counter: counter, reservations: %{}, artifacts: %{}, revisions: %{}}}
  end

  @impl true
  def handle_call({:reserve, limit}, _from, state) do
    if :atomics.get(state.counter, 1) < limit do
      slot = :atomics.add_get(state.counter, 1, 1)
      reservation = %{slot: slot, module: Enum.at(@modules, slot - 1), token: make_ref()}
      {:reply, {:ok, reservation}, put_in(state.reservations[slot], reservation)}
    else
      {:reply, {:error, Error.new("LIMIT_EXCEEDED")}, state}
    end
  end

  def handle_call({:next_revision, name}, _from, state),
    do: {:reply, Map.get(state.revisions, name, 0) + 1, state}

  def handle_call({:register, reservation, artifact}, _from, state) do
    valid =
      Map.get(state.reservations, reservation.slot) == reservation and
        artifact.module == reservation.module and not Map.has_key?(state.artifacts, artifact.id) and
        artifact.revision == Map.get(state.revisions, artifact.logical_name, 0) + 1

    if valid do
      state = %{
        state
        | artifacts: Map.put(state.artifacts, artifact.id, artifact),
          revisions: Map.put(state.revisions, artifact.logical_name, artifact.revision),
          reservations: Map.delete(state.reservations, reservation.slot)
      }

      {:reply, :ok, state}
    else
      {:reply, {:error, Error.new("INVALID_ARGUMENT")}, state}
    end
  end

  def handle_call({:fetch, id}, _from, state) do
    case Map.fetch(state.artifacts, id) do
      {:ok, artifact} -> {:reply, {:ok, artifact}, state}
      :error -> {:reply, {:error, Error.new("ARTIFACT_NOT_FOUND")}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{"attempts" => :atomics.get(state.counter, 1), "artifacts" => map_size(state.artifacts)},
     state}
  end
end
