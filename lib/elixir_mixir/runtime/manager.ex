defmodule ElixirMixir.Runtime.Manager do
  @moduledoc """
  Serializes kernel mutations and owns the in-memory request ledger and generation.

  No generated behavior or network transport is executed here. Kernel operations
  must validate and preflight their staged changes before committing. The internal
  mutation callback is trusted kernel code, never an external callback.
  """

  use GenServer

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.RequestLedger
  alias ElixirMixir.Runtime.Values

  @type result :: {:ok, map()} | {:error, Error.t()}

  @doc "Starts a manager with optional name, downward limit overrides and monotonic clock."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the empty runtime status. Arguments must currently be an empty map."
  @spec inspect_runtime(map(), GenServer.server()) :: result()
  def inspect_runtime(args, server \\ __MODULE__) do
    GenServer.call(server, {:inspect, args})
  end

  @doc """
  Runs a trusted kernel operation once per request ID and validated argument hash.

  This internal coordination interface is not a runtime tool. The callback receives
  the next generation and returns a staged result; only success advances generation.
  It must be finite, kernel-owned, and free of generated code. It must preflight any
  domain changes; the coordinator preflights the result before recording completion.
  Duplicate callers queue behind the operation and replay its exact outcome.
  """
  @spec mutate(GenServer.server(), String.t(), map(), (non_neg_integer() -> result())) :: result()
  def mutate(server, operation, args, callback) do
    GenServer.call(
      server,
      {:mutate, operation, args, callback},
      Limits.defaults().operation_timeout_ms
    )
  end

  @impl true
  def init(opts) do
    limits =
      Limits.new(Keyword.get(opts, :limits, Application.get_env(:elixir_mixir, :limits, %{})))

    {:ok,
     %{
       limits: limits,
       ledger: RequestLedger.new(limits),
       generation: 0,
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_call({:inspect, args}, _from, state) do
    result =
      if args == %{} do
        {:ok,
         envelope(
           %{
             "health" => "ok",
             "workers" => [],
             "topology" => [],
             "limits" => Map.new(state.limits, fn {k, v} -> {Atom.to_string(k), v} end),
             "ledger" => %{
               "capacity" => state.limits.ledger_entries,
               "retention_ms" => state.limits.ledger_retention_ms
             }
           },
           state.generation
         )}
      else
        {:error, envelope(Error.new("INVALID_ARGUMENT"), state.generation)}
      end

    {:reply, bounded(result, state), state}
  end

  def handle_call({:mutate, operation, args, callback}, _from, state) do
    case mutation_arguments(args, state.limits) do
      :ok ->
        hash = Values.request_hash(operation, args)
        {result, state} = run(args["request_id"], hash, callback, state)
        {:reply, result, state}

      {:error, error} ->
        id = if is_map(args) and Values.valid_id?(args["request_id"]), do: args["request_id"]
        {:reply, failure(error, id, state), state}
    end
  end

  defp mutation_arguments(args, limits) when is_map(args) do
    if Values.valid_id?(args["request_id"]) do
      Values.validate(args, :reply, %{limits | reply_bytes: limits.body_bytes})
    else
      {:error, Error.new("INVALID_ARGUMENT")}
    end
  end

  defp mutation_arguments(_args, _limits), do: {:error, Error.new("INVALID_ARGUMENT")}

  defp run(id, hash, callback, state) do
    case RequestLedger.admit(state.ledger, id, hash, state.clock.()) do
      {:admitted, ledger} -> execute(id, callback, %{state | ledger: ledger})
      {:replay, result, ledger} -> {result, %{state | ledger: ledger}}
      {:error, error, ledger} -> {failure(error, id, state), %{state | ledger: ledger}}
    end
  end

  defp execute(id, callback, state) do
    result = callback.(state.generation + 1)
    generation = if elem(result, 0) == :ok, do: state.generation + 1, else: state.generation
    {status, data} = result
    result = bounded({status, data |> envelope(generation) |> Map.put("request_id", id)}, state)
    generation = if elem(result, 0) == :ok, do: generation, else: state.generation
    {:ok, ledger} = RequestLedger.complete(state.ledger, id, result, state.clock.())
    {result, %{state | ledger: ledger, generation: generation}}
  end

  defp bounded({status, data}, state) do
    limits = %{state.limits | reply_bytes: state.limits.response_bytes}

    case Values.validate(data, :reply, limits) do
      :ok -> {status, data}
      {:error, _error} -> failure(Error.new("LIMIT_EXCEEDED"), data["request_id"], state)
    end
  end

  defp failure(error, id, state) do
    error = envelope(error, state.generation)
    {:error, if(id, do: Map.put(error, "request_id", id), else: error)}
  end

  defp envelope(data, generation),
    do: Map.merge(data, %{"api_version" => "1", "generation" => generation})
end
