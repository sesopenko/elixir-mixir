defmodule ElixirMixir.Runtime.Store do
  @moduledoc """
  Exclusive durable kernel authority. Only this module accesses CubDB.

  Commits compare generation and atomically apply validated record changes with
  their bounded outcome. Callers must treat process exits as uncertain writes and
  stop runtime availability; they must never continue from volatile state.
  """
  use GenServer

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.StoreRecords

  @type change :: %{
          required(:puts) => map(),
          required(:deletes) => list(),
          required(:outcome) => term(),
          required(:operation_id) => String.t(),
          required(:advance) => boolean()
        }

  @doc "Starts a synchronous store with exclusive same-VM directory ownership."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Reads a consistent record map including versioned global metadata."
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(store), do: GenServer.call(store, :snapshot)

  @doc "Atomically applies a prepared change if its base generation is current."
  @spec commit(GenServer.server(), non_neg_integer(), change()) ::
          {:ok, term()} | {:error, Error.t()}
  def commit(store, generation, change),
    do: GenServer.call(store, {:commit, generation, change})

  @impl true
  def init(opts) do
    dir = opts |> Keyword.fetch!(:data_dir) |> Path.expand()

    with :yes <- :global.register_name({__MODULE__, dir}, self()),
         :ok <- File.mkdir_p(dir),
         {:ok, db} <- CubDB.start_link(data_dir: dir, auto_file_sync: true, auto_compact: true) do
      records = Map.new(CubDB.select(db))

      case initialize(db, records) do
        :ok ->
          {:ok,
           %{
             db: db,
             limits:
               Limits.new(
                 Keyword.get(opts, :limits, Application.get_env(:elixir_mixir, :limits, %{}))
               )
           }}

        :error ->
          GenServer.stop(db)
          {:stop, :unsupported_store_format}
      end
    else
      :no -> {:stop, :directory_in_use}
      {:error, _reason} -> {:stop, :storage_unavailable}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.new(CubDB.select(state.db)), state}
  end

  def handle_call({:commit, generation, change}, _from, state) do
    result =
      CubDB.transaction(state.db, &transaction(&1, generation, change, state.limits))

    {:reply, result, state}
  end

  defp transaction(tx, generation, change, limits) do
    records = Map.new(CubDB.Tx.select(tx))

    with true <- records[:meta]["generation"] == generation,
         :ok <- StoreRecords.validate(records, change, limits) do
      tx = Enum.reduce(change.deletes, tx, &CubDB.Tx.delete(&2, &1))
      tx = Enum.reduce(change.puts, tx, fn {key, value}, tx -> CubDB.Tx.put(tx, key, value) end)
      meta = Map.update!(records[:meta], "generation", &(&1 + increment(change.advance)))
      tx = CubDB.Tx.put(tx, :meta, meta)
      {:commit, tx, {:ok, change.outcome}}
    else
      false -> {:cancel, {:error, Error.new("REVISION_CONFLICT")}}
      error -> {:cancel, error}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.db), do: GenServer.stop(state.db)
  end

  defp increment(true), do: 1
  defp increment(false), do: 0

  defp initialize(db, records) when map_size(records) == 0 do
    CubDB.put(db, :meta, %{
      "format_version" => 1,
      "lineage_id" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      "generation" => 0,
      "next_audit_sequence" => 0
    })
  end

  defp initialize(_db, %{meta: meta}) do
    if is_map(meta) and meta["format_version"] == 1 and
         is_binary(meta["lineage_id"]) and is_integer(meta["generation"]) and
         meta["generation"] >= 0 and is_integer(meta["next_audit_sequence"]) and
         meta["next_audit_sequence"] >= 0,
       do: :ok,
       else: :error
  end

  defp initialize(_db, _records), do: :error
end
