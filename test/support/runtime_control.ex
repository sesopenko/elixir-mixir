defmodule ElixirMixir.TestSupport.RuntimeControl do
  @moduledoc "Test-only stdin controls for inspecting an independent BEAM without production testing tools."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.TestSupport.CallbackBarrier
  alias ElixirMixir.TestSupport.StoreProxy

  @doc "Handles bounded JSON control lines until the owning port closes stdin."
  @spec run() :: no_return()
  def run do
    case IO.gets("") do
      :eof ->
        System.halt(0)

      "stop\n" ->
        System.halt(0)

      line ->
        response = line |> Jason.decode!() |> request()
        IO.puts("MIXIR_CONTROL:" <> JSON.encode!(response))
        run()
    end
  end

  @doc "Runs an explicit read/control operation in the fixture; never evaluates submitted code."
  @spec request(map()) :: map()
  def request(%{"op" => "store_fault", "mode" => mode}) do
    mode =
      case mode do
        "raise_before_commit" -> :raise_before_commit
        "timeout_after_commit" -> :timeout_after_commit
      end

    {:ok, proxy} = StoreProxy.start(Store, mode)
    :sys.replace_state(Manager, &%{&1 | store: proxy})
    %{"armed" => true}
  end

  def request(%{"op" => "runtime_status"}),
    do: %{"ready" => Manager.ready?(), "manager_alive" => is_pid(Process.whereis(Manager))}

  def request(%{"op" => "restoration_barrier"}) do
    hook = &restore_with_barrier/1
    :sys.replace_state(Manager, &%{&1 | restore_host: hook})
    %{"enabled" => true}
  end

  def request(%{"op" => "durability_barrier", "phase" => phase}) do
    hook = fn reached ->
      if Atom.to_string(reached) == phase, do: CallbackBarrier.wait(phase)
      :ok
    end

    :sys.replace_state(Manager, &%{&1 | durability_barrier: hook})
    %{"phase" => phase}
  end

  def request(%{"op" => "durable_records"}) do
    records = Store.snapshot(Store)

    %{
      "artifacts" =>
        for({{:artifact, id}, record} <- records, do: %{"id" => id, "record" => record}),
      "requests" =>
        for({{:request, id}, record} <- records, do: %{"id" => id, "record" => record}),
      "workers" => for({{:worker, id}, record} <- records, do: %{"id" => id, "record" => record}),
      "states" => for({{:state, id}, record} <- records, do: %{"id" => id, "record" => record}),
      "effects" => for({{:effect, id}, record} <- records, do: %{"id" => id, "record" => record}),
      "meta" => records[:meta]
    }
  end

  def request(%{"op" => "publication_barrier", "enabled" => enabled}) do
    hook = if enabled, do: fn -> CallbackBarrier.wait("publication") end, else: fn -> :ok end
    :sys.replace_state(Manager, &%{&1 | before_publish: hook})
    %{"enabled" => enabled}
  end

  def request(%{"op" => "host_state", "id" => id}) do
    [{_manager, host}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, id)
    {:ok, snapshot} = ProcessHost.snapshot(host)

    %{
      "state" => snapshot.data,
      "worker_revision" => snapshot.worker_revision,
      "state_revision" => snapshot.state_revision,
      "artifact_id" => snapshot.artifact.id
    }
  end

  def request(%{"op" => "store_commit", "value" => value}) do
    store = Store
    records = store.snapshot(store)

    {:ok, outcome} =
      store.commit(store, records[:meta]["generation"], %{
        puts: %{{:audit, 0} => value, {:audit, 1} => %{"paired" => true}},
        deletes: [],
        outcome: %{"saved" => true},
        operation_id: "fixture",
        advance: true
      })

    outcome
  end

  def request(%{"op" => "store_snapshot"}) do
    records = Store.snapshot(Store)
    %{"meta" => records[:meta], "first" => records[{:audit, 0}], "second" => records[{:audit, 1}]}
  end

  def request(%{"op" => "registry_status"}), do: ArtifactRegistry.status()
  def request(%{"op" => "events"} = args), do: EventLog.events(Map.get(args, "args", %{}))

  def request(%{"op" => "artifact", "id" => id}) do
    case ArtifactRegistry.fetch(id) do
      {:ok, artifact} ->
        %{
          "id" => artifact.id,
          "module" => Atom.to_string(artifact.module),
          "source_hash" => artifact.source_hash,
          "source" => artifact.source,
          "revision" => artifact.revision,
          "state_schema" => artifact.state_schema,
          "beam_bytes" => byte_size(artifact.beam),
          "compiler_helpers" => artifact.compiler_helpers
        }

      {:error, error} ->
        error
    end
  end

  def request(%{"op" => "barrier_status", "key" => key}), do: CallbackBarrier.status(key)
  def request(%{"op" => "release_barrier", "key" => key}), do: CallbackBarrier.release(key)

  def request(%{"op" => "worker_membership", "id" => id}) do
    case Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, id) do
      [{_, pid}] ->
        supervised =
          Enum.any?(DynamicSupervisor.which_children(ElixirMixir.Runtime.WorkerSupervisor), fn {_,
                                                                                                child,
                                                                                                _,
                                                                                                _} ->
            child == pid
          end)

        %{"registered" => Process.alive?(pid), "supervised" => supervised, "pid" => inspect(pid)}

      [] ->
        %{"registered" => false, "supervised" => false}
    end
  end

  def request(%{"op" => "dispatcher_status"}) do
    EffectDispatcher.snapshot(
      EffectDispatcher,
      Process.whereis(Manager)
    )
  end

  def request(%{"op" => "recovery_failure", "enabled" => enabled}) when is_boolean(enabled) do
    Application.put_env(:elixir_mixir, :test_recovery_failure, enabled)

    if :sys.get_state(Manager).storage.mode == :durable do
      restore = restorer(enabled)
      :sys.replace_state(Manager, &%{&1 | restore_host: restore})
    end

    %{"enabled" => enabled}
  end

  def request(%{"op" => "kill_host", "id" => id}) do
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> %{"killed" => true, "pid" => inspect(pid)}
    after
      1_000 -> %{"killed" => false}
    end
  end

  def request(%{"op" => "restart_application"}) do
    :ok = Application.stop(:elixir_mixir)
    {:ok, _} = Application.ensure_all_started(:elixir_mixir)
    {:ok, {_ip, port}} = ElixirMixir.MCP.Supervisor.address()
    %{"port" => port}
  end

  def request(%{"op" => "kill_registry"}), do: kill_authority(ArtifactRegistry)
  def request(%{"op" => "kill_store"}), do: kill_authority(Store)

  defp restore_with_barrier(opts) do
    unless Process.get(:test_restoration_released) do
      CallbackBarrier.wait("restoration")
      Process.put(:test_restoration_released, true)
    end

    DynamicSupervisor.start_child(ElixirMixir.Runtime.WorkerSupervisor, {ProcessHost, opts})
  end

  defp restorer(true), do: fn _opts -> {:error, :injected} end

  defp restorer(false),
    do: fn opts ->
      DynamicSupervisor.start_child(ElixirMixir.Runtime.WorkerSupervisor, {ProcessHost, opts})
    end

  defp kill_authority(authority) do
    ref = Process.monitor(Process.whereis(ElixirMixir.Supervisor))
    Process.exit(Process.whereis(authority), :kill)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} ->
        %{
          "kernel_down" => true,
          "manager_alive" => is_pid(Process.whereis(ElixirMixir.Runtime.Manager))
        }
    after
      3_000 -> %{"kernel_down" => false}
    end
  end
end
