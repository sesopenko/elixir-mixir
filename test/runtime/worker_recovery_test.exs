defmodule ElixirMixir.Runtime.WorkerRecoveryTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures

  setup_all do
    {:ok, manager} = Manager.start_link(name: nil)

    source = Fixtures.recovery_source()

    {:ok, artifact} =
      Manager.define(
        %{
          "source" => source,
          "logical_name" => "recovery",
          "expected_behavior" => "elixir_mixir.behavior.v1",
          "request_id" => "recovery"
        },
        manager
      )

    GenServer.stop(manager)
    %{artifact: artifact["artifact_id"]}
  end

  setup do
    parent = self()
    clock = start_supervised!({Agent, fn -> 0 end})

    timer = fn message ->
      send(parent, {:scheduled, message})
      nil
    end

    manager =
      start_supervised!(
        {Manager, name: nil, clock: fn -> Agent.get(clock, & &1) end, restart_timer: timer}
      )

    on_exit(fn ->
      Application.delete_env(:elixir_mixir, :test_recovery_failure)

      for {_, pid, _, _} <-
            DynamicSupervisor.which_children(ElixirMixir.Runtime.WorkerSupervisor),
          do: DynamicSupervisor.terminate_child(ElixirMixir.Runtime.WorkerSupervisor, pid)
    end)

    %{manager: manager, clock: clock, worker: unique()}
  end

  test "real host death schedules recovery with new PID, reset state and stable logical identity",
       ctx do
    first = start(ctx)
    peer = %{ctx | worker: unique()}
    healthy = start(peer)

    {:ok, _} =
      Manager.invoke(
        %{"worker_id" => ctx.worker, "event" => %{"value" => 9}, "request_id" => unique()},
        ctx.manager
      )

    old = kill(ctx)
    assert_receive {:scheduled, message}
    assert snapshot(ctx)["status"] == "restarting"

    assert {:error, %{"code" => "WORKER_NOT_RUNNING"}} =
             Manager.invoke(
               %{"worker_id" => ctx.worker, "event" => %{}, "request_id" => unique()},
               ctx.manager
             )

    send(ctx.manager, message)
    next = snapshot(ctx)
    assert next["status"] == "running"
    refute next["pid"] == first["pid"]
    assert next["state"] == %{"value" => 7}
    assert next["state_revision"] == 3
    assert next["worker_revision"] > first["worker_revision"]
    assert next["restart_count"] == 1
    assert next["artifact_id"] == first["artifact_id"]
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    assert pid != old
    assert inspect(pid) == next["pid"]
    assert snapshot(peer)["pid"] == healthy["pid"]
    assert Process.alive?(ctx.manager)
  end

  test "three failed reinitializations exhaust budget, explicit start resets it", ctx do
    start(ctx)
    kill(ctx)
    Application.put_env(:elixir_mixir, :test_recovery_failure, true)

    for attempt <- 1..3 do
      assert_receive {:scheduled, message}
      send(ctx.manager, message)
      assert snapshot(ctx)["restart_count"] == attempt
    end

    assert snapshot(ctx)["status"] == "failed"
    refute_receive {:scheduled, _}, 20
    assert Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker) == []
    Application.delete_env(:elixir_mixir, :test_recovery_failure)
    assert start(ctx)["restart_count"] == 0
    kill(ctx)
    assert_receive {:scheduled, message}
    send(ctx.manager, message)
    assert snapshot(ctx)["restart_count"] == 1
  end

  test "a failed definition requires explicit stop before artifact or config changes", ctx do
    {:ok, candidate} =
      Manager.define(
        %{
          "source" => Fixtures.worker_source(),
          "logical_name" => unique(),
          "expected_behavior" => "elixir_mixir.behavior.v1",
          "request_id" => unique()
        },
        ctx.manager
      )

    start(ctx)
    kill(ctx)
    Application.put_env(:elixir_mixir, :test_recovery_failure, true)

    for attempt <- 1..3 do
      assert_receive {:scheduled, message}
      send(ctx.manager, message)
      assert snapshot(ctx)["restart_count"] == attempt
    end

    Application.delete_env(:elixir_mixir, :test_recovery_failure)
    before = snapshot(ctx)
    assert before["status"] == "failed"

    base = %{
      "worker_id" => ctx.worker,
      "artifact_id" => ctx.artifact,
      "config" => %{"value" => 7},
      "request_id" => unique()
    }

    for altered <- [
          %{base | "config" => %{"value" => 8}},
          %{base | "config" => %{"value" => 7.0}},
          %{base | "artifact_id" => candidate["artifact_id"]}
        ] do
      assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
               Manager.start_worker(Map.put(altered, "request_id", unique()), ctx.manager)

      assert snapshot(ctx) == before
    end

    {:ok, _} =
      Manager.stop_worker(%{"worker_id" => ctx.worker, "request_id" => unique()}, ctx.manager)

    assert {:ok, result} =
             Manager.start_worker(
               %{
                 base
                 | "artifact_id" => candidate["artifact_id"],
                   "config" => %{"value" => 8},
                   "request_id" => unique()
               },
               ctx.manager
             )

    assert result["restart_count"] == 0
    assert snapshot(ctx)["state"] == %{"value" => 8}
  end

  test "successful restarts share a rolling budget and peers have independent budgets", ctx do
    start(ctx)
    peer = %{ctx | worker: unique()}
    start(peer)

    for attempt <- 1..3 do
      kill(ctx)
      assert_receive {:scheduled, message}
      send(ctx.manager, message)
      assert snapshot(ctx)["restart_count"] == attempt
    end

    kill(ctx)
    assert snapshot(ctx)["status"] == "failed"
    refute_receive {:scheduled, _}, 20
    kill(peer)
    assert_receive {:scheduled, message}
    send(ctx.manager, message)
    assert snapshot(peer)["status"] == "running"
    assert snapshot(peer)["restart_count"] == 1
  end

  test "attempts age out at the ten second boundary", ctx do
    start(ctx)

    for attempt <- 1..3 do
      kill(ctx)
      assert_receive {:scheduled, message}
      send(ctx.manager, message)
      assert snapshot(ctx)["restart_count"] == attempt
    end

    Agent.update(ctx.clock, fn _ -> 10_000 end)
    kill(ctx)
    assert_receive {:scheduled, message}
    send(ctx.manager, message)
    assert snapshot(ctx)["status"] == "running"
    assert snapshot(ctx)["restart_count"] == 1
  end

  test "stop invalidates a pending retry and stale monitor/timer messages", ctx do
    start(ctx)
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    worker = :sys.get_state(ctx.manager).workers[ctx.worker]
    kill(ctx)
    assert_receive {:scheduled, message}

    assert {:ok, stopped} =
             Manager.stop_worker(
               %{"worker_id" => ctx.worker, "request_id" => unique()},
               ctx.manager
             )

    send(ctx.manager, message)
    send(ctx.manager, {:DOWN, worker.monitor, :process, pid, :killed})
    assert snapshot(ctx)["status"] == "stopped"
    assert snapshot(ctx)["generation"] == stopped["generation"]
    first = start(ctx)
    send(ctx.manager, message)
    send(ctx.manager, {:DOWN, worker.monitor, :process, pid, :killed})
    assert snapshot(ctx)["pid"] == first["pid"]
    assert snapshot(ctx)["generation"] == first["generation"]
  end

  defp start(ctx) do
    {:ok, result} =
      Manager.start_worker(
        %{
          "worker_id" => ctx.worker,
          "artifact_id" => ctx.artifact,
          "config" => %{"value" => 7},
          "request_id" => unique()
        },
        ctx.manager
      )

    result
  end

  defp kill(ctx) do
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    pid
  end

  defp snapshot(ctx) do
    {:ok, result} =
      Manager.inspect_runtime(%{"worker_id" => ctx.worker, "detail" => "state"}, ctx.manager)

    result
  end

  defp unique, do: "recovery_#{System.unique_integer([:positive])}"
end
