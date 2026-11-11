defmodule ElixirMixir.Runtime.Execution do
  @moduledoc """
  Runs unlinked supervised work with an initial heap flag and a finite deadline.

  An independent supervised kernel coordinator monitors the caller and owns cleanup.
  Spawn tracing tracks temporary descendants so deadlines or caller death also kill
  helper processes. Tasks and tracing are resource controls, not security isolation.
  """

  @type outcome ::
          {:ok, term(), non_neg_integer()} | {:error, :timeout | :failed, non_neg_integer()}

  @doc "Runs work after installing heap/tracing controls, then joins its task and tracked helpers."
  @spec run(Supervisor.supervisor(), (-> term()), pos_integer(), pos_integer()) :: outcome()
  def run(supervisor, work, timeout, heap_words) do
    owner = self()

    coordinator =
      Task.Supervisor.async_nolink(supervisor, fn ->
        owner_ref = Process.monitor(owner)

        try do
          execute_group(supervisor, work, timeout, heap_words, owner_ref)
        after
          Process.demonitor(owner_ref, [:flush])
        end
      end)

    case Task.yield(coordinator, timeout + 1_000) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, :failed, 0}

      nil ->
        # The independent kernel coordinator keeps its cleanup duty even if its owner leaves.
        Process.demonitor(coordinator.ref, [:flush])
        {:error, :timeout, 0}
    end
  end

  defp execute_group(supervisor, work, timeout, heap_words, owner_ref) do
    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Process.flag(:max_heap_size, %{size: heap_words, kill: true, error_logger: false})

        receive do
          :execute ->
            try do
              {:ok, work.()}
            rescue
              _exception -> {:error, :failed}
            catch
              _kind, _reason -> {:error, :failed}
            end
        end
      end)

    :erlang.trace(task.pid, true, [:procs, :set_on_spawn])
    send(task.pid, :execute)
    deadline = System.monotonic_time(:millisecond) + timeout
    await(task, deadline, %{task.pid => true}, owner_ref)
  end

  defp await(task, deadline, processes, owner_ref) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        finish(result, task, processes)

      {:DOWN, ref, :process, _pid, _reason} when ref == task.ref ->
        finish({:error, :failed}, task, processes)

      {:DOWN, ^owner_ref, :process, _owner, _reason} ->
        finish({:error, :failed}, task, processes)

      {:trace, parent, :spawn, child, _mfa} when is_map_key(processes, parent) ->
        await(task, deadline, Map.put(processes, child, true), owner_ref)

      {:trace, pid, :spawned, _parent, _mfa} when is_map_key(processes, pid) ->
        await(task, deadline, processes, owner_ref)

      {:trace, pid, _event, _data} when is_map_key(processes, pid) ->
        await(task, deadline, processes, owner_ref)
    after
      remaining -> finish({:error, :timeout}, task, processes)
    end
  end

  defp finish(result, task, processes) do
    Task.shutdown(task, :brutal_kill)
    processes = cleanup(processes)
    count = map_size(processes) - 1

    case result do
      {:ok, value} -> {:ok, value, count}
      {:error, reason} -> {:error, reason, count}
    end
  end

  defp cleanup(processes) do
    Enum.each(Map.keys(processes), &kill_and_join/1)
    discovered = drain(processes)
    if map_size(discovered) == map_size(processes), do: discovered, else: cleanup(discovered)
  end

  defp drain(processes) do
    marker = :erlang.trace_delivered(:all)
    collect(processes, marker)
  end

  defp collect(processes, marker) do
    receive do
      {:trace_delivered, :all, ^marker} ->
        processes

      {:trace, parent, :spawn, child, _mfa} when is_map_key(processes, parent) ->
        collect(Map.put(processes, child, true), marker)

      {:trace, pid, :spawned, _parent, _mfa} when is_map_key(processes, pid) ->
        collect(processes, marker)

      {:trace, pid, _event, _data} when is_map_key(processes, pid) ->
        collect(processes, marker)
    end
  end

  defp kill_and_join(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end
end
