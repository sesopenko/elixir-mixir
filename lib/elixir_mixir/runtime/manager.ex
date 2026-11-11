defmodule ElixirMixir.Runtime.Manager do
  @moduledoc """
  Serializes kernel mutations and owns the in-memory request ledger and generation.

  No generated behavior or network transport is executed here. Kernel operations
  must validate and preflight their staged changes before committing. The internal
  mutation callback is trusted kernel code, never an external callback.
  """

  use GenServer

  alias ElixirMixir.Runtime.Definition
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Inspection
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.RequestLedger
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.Values
  alias ElixirMixir.Runtime.Workers

  @type result :: {:ok, map()} | {:error, Error.t()}

  @doc "Starts a manager with optional name, downward limit overrides and monotonic clock."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Compiles a bounded template into an immutable, inactive artifact using request replay semantics."
  @spec define(map(), GenServer.server()) :: result()
  def define(args, server \\ __MODULE__) do
    GenServer.call(server, {:define, args}, Limits.defaults().operation_timeout_ms)
  end

  @doc "Starts a logical worker using a defined artifact and bounded JSON configuration."
  @spec start_worker(map(), GenServer.server()) :: result()
  def start_worker(args, server \\ __MODULE__),
    do: GenServer.call(server, {:worker, :start, args}, Limits.defaults().operation_timeout_ms)

  @doc "Explicitly stops a worker while retaining its definition; repeat stops are idempotent."
  @spec stop_worker(map(), GenServer.server()) :: result()
  def stop_worker(args, server \\ __MODULE__),
    do: GenServer.call(server, {:worker, :stop, args}, Limits.defaults().operation_timeout_ms)

  @doc "Returns bounded runtime/worker snapshots using kernel-owned state; no cursor exists yet."
  @spec inspect_runtime(map(), GenServer.server()) :: result()
  def inspect_runtime(args, server \\ __MODULE__) do
    GenServer.call(server, {:inspect, args}, Limits.defaults().operation_timeout_ms)
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
       workers: %{},
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_call({:inspect, args}, _from, state) do
    result =
      case Inspection.validate(args, state.limits) do
        :ok -> inspect_workers(args, state)
        {:error, error} -> {:error, envelope(error, state.generation)}
      end

    {:reply, bounded(result, state), state}
  end

  def handle_call({:define, args}, _from, state) do
    case mutation_arguments(args, state.limits) do
      :ok ->
        hash = Values.request_hash("define", args)
        callback = fn generation -> Definition.define(args, generation, state.limits) end
        {result, state} = run(args["request_id"], hash, callback, state)
        {:reply, result, state}

      {:error, error} ->
        id = if is_map(args) and Values.valid_id?(args["request_id"]), do: args["request_id"]
        {:reply, failure(error, id, state), state}
    end
  end

  def handle_call({:worker, operation, args}, _from, state) do
    case mutation_arguments(args, state.limits) do
      :ok ->
        hash = Values.request_hash(Atom.to_string(operation), args)

        callback = fn generation ->
          worker_operation(operation, args, state, generation)
        end

        {result, state} = run(args["request_id"], hash, callback, state)
        {:reply, result, state}

      {:error, error} ->
        id = if is_map(args) and Values.valid_id?(args["request_id"]), do: args["request_id"]
        {:reply, failure(error, id, state), state}
    end
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

  defp worker_operation(:start, args, state, generation),
    do: Workers.start(args, state.workers, state.limits, generation)

  defp worker_operation(:stop, args, state, generation),
    do: Workers.stop(args, state.workers, state.limits, generation)

  defp mutation_arguments(args, limits) when is_map(args) do
    if Values.valid_id?(args["request_id"]) do
      Values.validate(args, :reply, %{
        limits
        | reply_bytes: limits.body_bytes,
          depth: limits.depth + 1
      })
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

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {workers, changed} = Workers.down(state.workers, ref, reason)

    {:noreply,
     %{state | workers: workers, generation: state.generation + if(changed, do: 1, else: 0)}}
  end

  defp execute(id, callback, state) do
    {result, next_state, changed} = staged(callback.(state.generation + 1), state)
    generation = state.generation + if(changed, do: 1, else: 0)
    {status, data} = result
    result = bounded({status, data |> envelope(generation) |> Map.put("request_id", id)}, state)
    generation = if elem(result, 0) == :ok, do: generation, else: state.generation
    next_state = if elem(result, 0) == :ok, do: next_state, else: state
    {:ok, ledger} = RequestLedger.complete(state.ledger, id, result, state.clock.())
    {result, %{next_state | ledger: ledger, generation: generation}}
  end

  defp staged({:commit, data, workers}, state),
    do: {{:ok, data}, %{state | workers: workers}, true}

  defp staged({:noop, data}, state), do: {{:ok, data}, state, false}
  defp staged({:ok, _data} = result, state), do: {result, state, true}
  defp staged({:error, _error} = result, state), do: {result, state, false}

  defp inspect_workers(%{"worker_id" => id} = args, state) do
    case Workers.find(state.workers, id) do
      {:ok, worker} ->
        {:ok,
         worker
         |> Workers.snapshot(Map.get(args, "detail", "summary"), state.limits)
         |> envelope(state.generation)}

      {:error, error} ->
        {:error, envelope(error, state.generation)}
    end
  end

  defp inspect_workers(args, state) do
    limit = Map.get(args, "limit", state.limits.page_default)

    workers =
      state.workers
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.take(limit)
      |> Enum.map(fn {_id, worker} -> Workers.snapshot(worker, "summary", state.limits) end)

    data = %{
      "health" => "ok",
      "workers" => workers,
      "topology" => [],
      "limits" => Map.new(state.limits, fn {key, value} -> {Atom.to_string(key), value} end),
      "ledger" => %{
        "capacity" => state.limits.ledger_entries,
        "retention_ms" => state.limits.ledger_retention_ms
      }
    }

    data = if map_size(state.workers) > limit, do: Map.put(data, "truncated", true), else: data
    {:ok, envelope(data, state.generation)}
  end

  defp bounded({status, data}, state) do
    limits = %{
      state.limits
      | reply_bytes: state.limits.response_bytes,
        depth: state.limits.depth + 4
    }

    case Values.validate(data, :reply, limits) do
      :ok ->
        if ResponseBudget.fits?(data, state.limits),
          do: {status, data},
          else: failure(Error.new("LIMIT_EXCEEDED"), data["request_id"], state)

      {:error, _error} ->
        failure(Error.new("LIMIT_EXCEEDED"), data["request_id"], state)
    end
  end

  defp failure(error, id, state) do
    error = envelope(error, state.generation)
    {:error, if(id, do: Map.put(error, "request_id", id), else: error)}
  end

  defp envelope(data, generation),
    do: Map.merge(data, %{"api_version" => "1", "generation" => generation})
end
