defmodule ElixirMixir.TestSupport.RuntimeControl do
  @moduledoc "Test-only stdin controls for inspecting an independent BEAM without production testing tools."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.TestSupport.CallbackBarrier

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
  def request(%{"op" => "registry_status"}), do: ArtifactRegistry.status()
  def request(%{"op" => "events"} = args), do: EventLog.events(Map.get(args, "args", %{}))

  def request(%{"op" => "artifact", "id" => id}) do
    case ArtifactRegistry.fetch(id) do
      {:ok, artifact} ->
        %{
          "id" => artifact.id,
          "module" => Atom.to_string(artifact.module),
          "source_hash" => artifact.source_hash,
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
      [{pid, _}] ->
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
    %{"enabled" => enabled}
  end

  def request(%{"op" => "kill_host", "id" => id}) do
    [{pid, _}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, id)
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

  def request(%{"op" => "kill_registry"}) do
    ref = Process.monitor(Process.whereis(ElixirMixir.Supervisor))
    Process.exit(Process.whereis(ArtifactRegistry), :kill)

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
