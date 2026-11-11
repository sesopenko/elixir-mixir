defmodule ElixirMixir.Runtime.DurableRecovery do
  @moduledoc "Rebuilds committed logical hosts and persists incarnation-safe lifecycle retries without running init."

  alias ElixirMixir.Runtime.DurableOperations
  alias ElixirMixir.Runtime.DurableWorkers
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.RecoveryDiagnostics
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.Runtime.WorkerRecovery

  @doc "Restores desired hosts in logical order while readiness stays closed, then publishes healthy routes."
  @spec restore(map(), map()) :: {:ok, map(), map()} | {:error, Error.t()}
  def restore(records, state) do
    retained = for {{:worker, id}, record} <- records, do: {id, record}

    if length(retained) <= state.limits.workers do
      workers =
        retained
        |> Enum.sort()
        |> Map.new(fn {id, record} ->
          worker = DurableWorkers.decode(id, record, records[{:state, id}], state)
          {id, restore_worker(worker, state)}
        end)

      workers =
        Map.new(workers, fn {id, worker} ->
          {id, if(worker.pid, do: DurableWorkers.activate(worker), else: worker)}
        end)

      quarantines =
        for {id, %{status: "quarantined"}} <- workers,
            do:
              RecoveryDiagnostics.entry(
                "worker",
                id,
                "INVALID_ARGUMENT",
                workers[id].quarantine_reason
              )

      {:ok, workers,
       %{
         :quarantines => quarantines,
         "workers" => length(retained),
         "workers_failed" => Enum.count(workers, fn {_, worker} -> worker.status == "failed" end),
         "workers_restored" => Enum.count(workers, fn {_, worker} -> worker.pid != nil end),
         "workers_quarantined" => length(quarantines),
         "worker_diagnostics" =>
           Enum.take(
             Enum.map(quarantines, &Map.put(&1, "worker_id", &1["id"])),
             state.limits.diagnostics
           )
       }}
    else
      {:error, Error.new("LIMIT_EXCEEDED")}
    end
  end

  @doc "Records matching host loss before changing routes or arming a fresh retry token."
  @spec down(map(), reference(), term()) :: map()
  def down(state, ref, reason) do
    case Enum.find(state.workers, fn {_, worker} ->
           worker.monitor == ref and worker.status == "running"
         end) do
      nil ->
        state

      {id, worker} ->
        next =
          %{
            worker
            | pid: nil,
              monitor: nil,
              status: "restarting",
              worker_revision: worker.worker_revision + 1,
              restarts: recent(worker, state)
          }
          |> exhaustion()

        state = persist(next, state, "worker_crashed", %{"reason" => reason_text(reason)})
        Registry.unregister(ElixirMixir.Runtime.ProcessRegistry, id)
        next = schedule(next, state)
        %{state | workers: Map.put(state.workers, id, next)}
    end
  end

  @doc "Restores one matching retry from committed state, preserving its state revision and durable budget."
  @spec retry(map(), String.t(), reference()) :: map()
  def retry(state, id, token) do
    case state.workers[id] do
      %{status: "restarting", restart_token: ^token} = worker ->
        worker = %{
          WorkerRecovery.cancel(worker)
          | worker_revision: worker.worker_revision + 1,
            restarts: recent(worker, state) ++ [state.wall_clock.()]
        }

        candidate =
          case DurableWorkers.start_candidate(worker, true, state) do
            {:ok, candidate} -> %{candidate | status: "running"}
            {:error, _} -> exhaustion(worker)
          end

        type = if candidate.pid, do: "worker_restarted", else: "worker_restart_failed"
        state = persist(candidate, state, type, %{"attempt" => length(candidate.restarts)})

        next =
          if candidate.pid,
            do: DurableWorkers.activate(candidate),
            else: schedule(candidate, state)

        %{state | workers: Map.put(state.workers, id, next)}

      _stale ->
        state
    end
  end

  defp restore_worker(%{status: "running"} = worker, state) do
    case DurableWorkers.start_candidate(worker, true, state) do
      {:ok, candidate} -> candidate
      {:error, _} -> %{worker | status: "quarantined", quarantine_reason: "HOST_RESTORE_FAILED"}
    end
  end

  defp restore_worker(worker, _state), do: worker

  defp persist(worker, state, type, metadata) do
    records = Store.snapshot(state.store)
    sequence = records[:meta]["next_audit_sequence"]
    operation_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    audit = %{
      "operation_id" => operation_id,
      "operation" => type,
      "worker_id" => worker.worker_id,
      "outcome" => worker.status
    }

    deletes =
      for {{:audit, prior} = key, _} <- records,
          prior <= sequence - state.limits.history_records,
          do: key

    DurableOperations.commit!(
      state,
      %{
        {:worker, worker.worker_id} => DurableWorkers.record(worker),
        {:audit, sequence} => audit
      },
      deletes,
      true,
      operation_id,
      %{}
    )

    EventLog.append(%{
      "type" => type,
      "worker_id" => worker.worker_id,
      "logical_id" => worker.worker_id,
      "artifact_revision" => worker.artifact.revision,
      "request_id" => worker.request_id,
      "outcome" => worker.status,
      "metadata" => metadata
    })

    %{state | generation: state.generation + 1}
  end

  defp schedule(%{status: "restarting"} = worker, state) do
    token = make_ref()
    timer = state.restart_timer.({:restart_worker, worker.worker_id, token})
    %{worker | restart_token: token, restart_timer: timer}
  end

  defp schedule(worker, _state), do: worker

  defp exhaustion(%{restarts: restarts} = worker) when length(restarts) >= 3,
    do: %{worker | status: "failed"}

  defp exhaustion(worker), do: worker

  defp recent(worker, state),
    do: Enum.filter(worker.restarts, &(&1 > state.wall_clock.() - 10_000))

  defp reason_text(:killed), do: "killed"
  defp reason_text(:normal), do: "normal"
  defp reason_text(_reason), do: "abnormal"
end
