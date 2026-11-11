defmodule ElixirMixir.Runtime.WorkerRecovery do
  @moduledoc "Manager-owned per-worker rolling restart budgets and incarnation-safe retry scheduling."

  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.Workers

  @attempts 3
  @window_ms 10_000

  @doc "Schedules recovery for a matching current host monitor, ignoring stale incarnations."
  @spec down(Workers.definitions(), reference(), term(), map()) ::
          {Workers.definitions(), boolean()}
  def down(workers, ref, reason, policy) do
    case Enum.find(workers, fn {_id, worker} ->
           worker.monitor == ref and worker.status == "running"
         end) do
      nil ->
        {workers, false}

      {id, worker} ->
        Registry.unregister(ElixirMixir.Runtime.ProcessRegistry, id)

        next = %{
          worker
          | status: "restarting",
            pid: nil,
            monitor: nil,
            worker_revision: worker.worker_revision + 1
        }

        record("worker_crashed", next, %{"reason" => reason_text(reason)})
        next = schedule(next, policy)
        {Map.put(workers, id, next), true}
    end
  end

  @doc "Runs one eligible reinitialization attempt; the token guards stop and newer incarnations."
  @spec retry(Workers.definitions(), String.t(), reference(), map()) ::
          {Workers.definitions(), boolean()}
  def retry(workers, id, token, policy) do
    case Map.get(workers, id) do
      %{status: "restarting", restart_token: ^token} = worker ->
        next = attempt(worker, policy)
        {Map.put(workers, id, next), true}

      _stale ->
        {workers, false}
    end
  end

  @doc "Invalidates an outstanding retry and cancels its timer if still scheduled."
  @spec cancel(map()) :: map()
  def cancel(worker) do
    if is_reference(worker.restart_timer), do: Process.cancel_timer(worker.restart_timer)
    %{worker | restart_timer: nil, restart_token: nil}
  end

  defp attempt(worker, policy) do
    now = policy.clock.()

    worker = %{
      cancel(worker)
      | restarts: recent(worker, now) ++ [now],
        worker_revision: worker.worker_revision + 1
    }

    record("worker_restart_attempt", worker, %{"attempt" => length(worker.restarts)})
    opts = %{worker | state_revision: worker.state_revision + 1}

    case start_candidate(opts) do
      {:ok, pid} ->
        next = %{opts | status: "running", pid: pid, monitor: Process.monitor(pid)}
        record("worker_restarted", next, %{})
        next

      {:error, _reason} ->
        record("worker_restart_failed", worker, %{})
        schedule(worker, policy)
    end
  end

  defp start_candidate(opts) do
    with {:ok, pid} <-
           DynamicSupervisor.start_child(
             ElixirMixir.Runtime.WorkerSupervisor,
             {ProcessHost, opts}
           ) do
      case Registry.register(ElixirMixir.Runtime.ProcessRegistry, opts.worker_id, pid) do
        {:ok, _} ->
          {:ok, pid}

        {:error, _} = error ->
          ProcessHost.stop(pid)
          DynamicSupervisor.terminate_child(ElixirMixir.Runtime.WorkerSupervisor, pid)
          error
      end
    end
  end

  defp schedule(worker, policy) do
    worker = %{worker | restarts: recent(worker, policy.clock.())}

    if length(worker.restarts) < @attempts do
      token = make_ref()
      timer = policy.timer.({:restart_worker, worker.worker_id, token})
      %{worker | status: "restarting", restart_token: token, restart_timer: timer}
    else
      next = %{worker | status: "failed", restart_token: nil, restart_timer: nil}
      record("worker_restart_exhausted", next, %{"attempts" => length(worker.restarts)})
      next
    end
  end

  defp recent(worker, now), do: Enum.filter(worker.restarts, &(&1 > now - @window_ms))

  defp record(type, worker, metadata) do
    EventLog.append(%{
      "type" => type,
      "worker_id" => worker.worker_id,
      "logical_id" => worker.worker_id,
      "artifact_revision" => worker.artifact.revision,
      "request_id" => worker.request_id,
      "outcome" => worker.status,
      "metadata" => metadata
    })
  end

  defp reason_text(:killed), do: "killed"
  defp reason_text(:normal), do: "normal"
  defp reason_text(:shutdown), do: "shutdown"
  defp reason_text(_reason), do: "abnormal"
end
