defmodule ElixirMixir.Runtime.DurableLifecycle do
  @moduledoc "Prepares durable starts and stops without changing live routing before commit."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.DurableOperations
  alias ElixirMixir.Runtime.DurableWorkers
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Values
  alias ElixirMixir.Runtime.WorkerRecovery
  alias ElixirMixir.Runtime.Workers

  @doc "Validates public lifecycle shapes before reserving a durable request."
  @spec validate(:start | :stop, map(), Limits.t()) :: :ok | {:error, Error.t()}
  def validate(operation, args, limits) do
    expected =
      if operation == :start,
        do: ~w(worker_id artifact_id config request_id),
        else: ~w(worker_id request_id)

    with true <- Enum.sort(Map.keys(args)) == Enum.sort(expected),
         true <- Values.valid_id?(args["worker_id"]) do
      if operation == :start, do: validate_start(args, limits), else: :ok
    else
      _invalid -> {:error, Error.new("INVALID_ARGUMENT")}
    end
  end

  @doc "Commits lifecycle records and exact outcomes before routing or termination."
  @spec execute(:start | :stop, map(), map()) :: {{:ok | :error, map()}, map()}
  def execute(operation, args, state) do
    DurableOperations.execute(Atom.to_string(operation), args, state, fn records, entry ->
      prepare(operation, args, records, entry, state)
    end)
  end

  defp validate_start(args, limits) do
    if is_binary(args["artifact_id"]),
      do: Values.validate(args["config"], :config, limits),
      else: {:error, Error.new("INVALID_ARGUMENT")}
  end

  defp prepare(:start, args, _records, entry, state) do
    previous = state.workers[args["worker_id"]]

    with :ok <- available(previous, state),
         :ok <- retained(previous, args),
         true <- Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, args["worker_id"]) == [],
         {:ok, artifact} <- ArtifactRegistry.fetch(args["artifact_id"]),
         worker = DurableWorkers.candidate(args, artifact, state),
         {:ok, worker} <- DurableWorkers.start_candidate(worker, false, state) do
      puts = %{
        {:worker, worker.worker_id} => DurableWorkers.record(worker),
        {:state, worker.worker_id} =>
          DurableWorkers.checkpoint(worker, entry["operation_id"], state.wall_clock.())
      }

      {:ok,
       %{
         data: Workers.summary(worker),
         puts: puts,
         deletes: [],
         changed: true,
         abort: fn -> DurableWorkers.close(worker) end,
         publish: fn state ->
           worker = DurableWorkers.activate(worker)
           %{state | workers: Map.put(state.workers, worker.worker_id, worker)}
         end
       }}
    else
      false -> {:error, Error.new("WORKER_EXISTS")}
      error -> error
    end
  end

  defp prepare(:stop, args, records, _entry, state) do
    with {:ok, worker} <- Workers.find(state.workers, args["worker_id"]) do
      changed = worker.status != "stopped"

      next = %{
        worker
        | desired_status: "stopped",
          status: "stopped",
          pid: nil,
          monitor: nil,
          worker_revision: worker.worker_revision + if(changed, do: 1, else: 0),
          request_id: args["request_id"]
      }

      data = %{
        "worker_id" => next.worker_id,
        "worker_revision" => next.worker_revision,
        "status" => "stopped",
        "definition_retained" => true
      }

      deletes =
        for {{:effect, _} = key, effect} <- records, effect["source"] == worker.worker_id, do: key

      {:ok,
       %{
         data: data,
         puts:
           if(changed, do: %{{:worker, next.worker_id} => DurableWorkers.record(next)}, else: %{}),
         deletes: deletes,
         changed: changed,
         abort: fn -> :ok end,
         publish: fn state ->
           next = WorkerRecovery.cancel(next)
           Registry.unregister(ElixirMixir.Runtime.ProcessRegistry, worker.worker_id)
           if worker.monitor, do: Process.demonitor(worker.monitor, [:flush])
           DurableWorkers.close(worker)
           %{state | workers: Map.put(state.workers, next.worker_id, next)}
         end
       }}
    end
  end

  defp available(%{status: status}, _state) when status in ["running", "restarting"],
    do: {:error, Error.new("WORKER_EXISTS")}

  defp available(nil, state) when map_size(state.workers) >= state.limits.workers,
    do: {:error, Error.new("LIMIT_EXCEEDED")}

  defp available(_worker, _state), do: :ok

  defp retained(%{status: status} = worker, args) when status in ["failed", "quarantined"] do
    if worker.artifact.id == args["artifact_id"] and worker.config == args["config"],
      do: :ok,
      else:
        {:error,
         Map.put(Error.new("INVALID_ARGUMENT"), "details", %{
           "hint" => "Stop the worker before changing its artifact or config."
         })}
  end

  defp retained(_worker, _args), do: :ok
end
