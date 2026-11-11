defmodule ElixirMixir.Runtime.DurableTransitions do
  @moduledoc "Commits effect-free prepared worker state and exact request results before live publication."

  alias ElixirMixir.Runtime.DurableOperations
  alias ElixirMixir.Runtime.DurableWorkers
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.Values
  alias ElixirMixir.Runtime.Workers

  @doc "Validates invocation shape and bounded events before durable admission."
  @spec validate(map(), Limits.t()) :: :ok | {:error, Error.t()}
  def validate(args, limits) do
    if Enum.sort(Map.keys(args)) == ~w(event request_id worker_id) and
         Values.valid_id?(args["worker_id"]),
       do: Values.validate(args["event"], :event, limits),
       else: {:error, Error.new("INVALID_ARGUMENT")}
  end

  @doc "Prepares and durably publishes one logical event, or replays its retained outcome."
  @spec execute(map(), map()) :: {{:ok | :error, map()}, map()}
  def execute(args, state) do
    DurableOperations.execute("invoke", args, state, fn _records, entry ->
      with {:ok, worker} <- Workers.find(state.workers, args["worker_id"]),
           :ok <- running(worker) do
        prepare(args, worker, entry, state)
      end
    end)
  end

  defp prepare(args, worker, entry, state) do
    context = %{
      request_id: args["request_id"],
      operation_id: entry["operation_id"],
      generation: state.generation + 1,
      correlation_id: args["request_id"],
      source: worker.worker_id,
      artifact_revision: worker.artifact.revision,
      manager: self(),
      path: [],
      remaining_hops: state.limits.effect_hops,
      effect_mode: :reject
    }

    with {:ok, data, ticket} <-
           ProcessHost.prepare_invoke(
             worker.pid,
             args["event"],
             context,
             state.limits.operation_timeout_ms
           ) do
      prepared_change(args, worker, entry, data, ticket, state)
    end
  end

  @doc "Builds one atomic state/selection change from an owner-bound prepared host checkpoint."
  @spec prepared_change(map(), map(), map(), map(), map(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepared_change(args, worker, entry, data, ticket, state) do
    case ProcessHost.prepared_snapshot(worker.pid, ticket) do
      {:ok, snapshot} ->
        candidate(args, worker, entry, data, ticket, snapshot, state)

      {:error, _error} = error ->
        ProcessHost.abort(worker.pid, ticket)
        error
    end
  end

  defp candidate(args, worker, entry, data, ticket, snapshot, state) do
    next = %{
      worker
      | artifact: snapshot.artifact,
        committed_data: snapshot.data,
        state_revision: snapshot.state_revision,
        worker_revision: snapshot.worker_revision,
        request_id: args["request_id"]
    }

    puts = %{
      {:worker, next.worker_id} => DurableWorkers.record(next),
      {:state, next.worker_id} =>
        DurableWorkers.checkpoint(next, entry["operation_id"], state.wall_clock.())
    }

    {:ok,
     %{
       data: data,
       puts: puts,
       deletes: [],
       changed: true,
       abort: fn -> ProcessHost.abort(worker.pid, ticket) end,
       publish: fn state ->
         {:ok, ^data, :none} = ProcessHost.publish(worker.pid, ticket)
         %{state | workers: Map.put(state.workers, next.worker_id, next)}
       end
     }}
  end

  defp running(%{status: "running"}), do: :ok
  defp running(_worker), do: {:error, Error.new("WORKER_NOT_RUNNING")}
end
