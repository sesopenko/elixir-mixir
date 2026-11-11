defmodule ElixirMixir.Runtime.Manager do
  @moduledoc """
  Serializes kernel mutations and owns the in-memory request ledger and generation.

  No generated behavior or network transport is executed here. Kernel operations
  must validate and preflight their staged changes before committing. The internal
  mutation callback is trusted kernel code, never an external callback.
  """

  use GenServer

  alias ElixirMixir.Runtime.Definition
  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.Inspection
  alias ElixirMixir.Runtime.Inspector
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.RequestLedger
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.StorageConfig
  alias ElixirMixir.Runtime.Values
  alias ElixirMixir.Runtime.WorkerRecovery
  alias ElixirMixir.Runtime.Workers

  @type result :: {:ok, map()} | {:error, Error.t()}

  @doc "Starts a manager with optional name, downward limits, monotonic clock and kernel restart timer."
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

  @doc "Commits one bounded worker event at most once per validated request identity."
  @spec invoke(map(), GenServer.server()) :: result()
  def invoke(args, server \\ __MODULE__),
    do: GenServer.call(server, {:worker, :invoke, args}, Limits.defaults().operation_timeout_ms)

  @doc "Replaces a live worker implementation with expected revision checks and explicit schema migration."
  @spec replace(map(), GenServer.server()) :: result()
  def replace(args, server \\ __MODULE__),
    do: GenServer.call(server, {:worker, :replace, args}, Limits.defaults().operation_timeout_ms)

  @doc "Returns bounded read-only worker and relationship pages tied to the current generation."
  @spec inspect_runtime(map(), GenServer.server()) :: result()
  def inspect_runtime(args, server \\ __MODULE__) do
    GenServer.call(server, {:inspect, args}, Limits.defaults().operation_timeout_ms)
  end

  @doc "Returns bounded correlated event history after an exclusive sequence cursor."
  @spec events(map(), GenServer.server()) :: result()
  def events(args, server \\ __MODULE__),
    do: GenServer.call(server, {:events, args}, Limits.defaults().operation_timeout_ms)

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
       storage:
         StorageConfig.new(
           Keyword.get(opts, :storage, Application.get_env(:elixir_mixir, :storage, []))
         ),
       limits: limits,
       ledger: RequestLedger.new(limits),
       generation: 0,
       workers: %{},
       before_publish: Keyword.get(opts, :before_publish, fn -> :ok end),
       event_log: Keyword.get(opts, :event_log, EventLog),
       inspection_id: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
       dispatcher: GenServer.whereis(Keyword.get(opts, :dispatcher, EffectDispatcher)),
       restart_timer:
         Keyword.get(opts, :restart_timer, fn message ->
           Process.send_after(self(), message, 100)
         end),
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_call({:inspect, args}, _from, state) do
    result =
      case Inspection.validate(args, state.limits) do
        :ok -> read_result(Inspector.inspect_runtime(args, state), state)
        {:error, error} -> {:error, envelope(error, state.generation)}
      end

    {:reply, bounded(result, state), state}
  end

  def handle_call({:events, args}, _from, state) do
    result = with :ok <- Inspection.events(args, state.limits), do: Inspector.events(args, state)
    {:reply, bounded(read_result(result, state), state), state}
  end

  def handle_call(message, _from, %{storage: %{mode: :durable}} = state)
      when elem(message, 0) in [:define, :worker, :mutate] do
    {:reply, failure(Error.new("DURABILITY_UNAVAILABLE"), nil, state), state}
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
    do: Workers.start(args, state.workers, state.limits, generation, state.dispatcher)

  defp worker_operation(:stop, args, state, generation),
    do: Workers.stop(args, state.workers, state.limits, generation)

  defp worker_operation(:invoke, args, state, generation),
    do:
      Workers.invoke(args, state.workers, state.limits, generation, %{
        before_publish: state.before_publish
      })

  defp worker_operation(:replace, args, state, generation),
    do:
      Workers.replace(args, state.workers, state.limits, generation, %{
        before_publish: state.before_publish
      })

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
    {workers, changed} = WorkerRecovery.down(state.workers, ref, reason, recovery_policy(state))

    {:noreply,
     %{state | workers: workers, generation: state.generation + if(changed, do: 1, else: 0)}}
  end

  def handle_info({:restart_worker, id, token}, state) do
    {workers, changed} = WorkerRecovery.retry(state.workers, id, token, recovery_policy(state))

    {:noreply,
     %{state | workers: workers, generation: state.generation + if(changed, do: 1, else: 0)}}
  end

  def handle_info({:effect_delivery, dispatcher, id}, %{dispatcher: dispatcher} = state) do
    case EffectDispatcher.claim(dispatcher, id) do
      {:ok, item} ->
        args = %{
          "worker_id" => item.effect["to"],
          "event" => item.effect["event"],
          "request_id" => id
        }

        inherited = %{
          correlation_id: item.correlation_id,
          path: item.path,
          remaining_hops: item.remaining_hops - 1
        }

        callback = fn generation ->
          Workers.invoke(args, state.workers, state.limits, generation, inherited)
        end

        {result, next} = run(id, Values.request_hash("effect_delivery", args), callback, state)
        EffectDispatcher.complete(dispatcher, id, result)
        {:noreply, next}

      :cancelled ->
        {:noreply, state}
    end
  end

  defp recovery_policy(state), do: %{clock: state.clock, timer: state.restart_timer}

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

  defp read_result({status, data}, state), do: {status, envelope(data, state.generation)}

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
