defmodule ElixirMixir.Runtime.WorkerStartTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.Runtime.Execution
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures

  setup_all do
    {:ok, manager} = Manager.start_link(name: nil)

    {:ok, artifact} =
      Manager.define(
        %{
          "source" => Fixtures.worker_source(),
          "logical_name" => "startup-fixture",
          "expected_behavior" => "elixir_mixir.behavior.v1",
          "request_id" => "startup-fixture"
        },
        manager
      )

    GenServer.stop(manager)
    %{artifact: artifact["artifact_id"]}
  end

  setup do
    manager = start_supervised!({Manager, name: nil})

    on_exit(fn ->
      for {_, pid, _, _} <- children() do
        DynamicSupervisor.terminate_child(ElixirMixir.Runtime.WorkerSupervisor, pid)
      end
    end)

    %{manager: manager, worker: unique()}
  end

  test "init state, logical Registry routing and DynamicSupervisor membership agree", ctx do
    args = start_args(ctx, %{"count" => 7})
    assert {:ok, result} = Manager.start_worker(args, ctx.manager)
    assert result["worker_revision"] == 1
    assert result["state_revision"] == 1
    assert result["generation"] == 1
    assert result["status"] == "running"
    [{manager, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    assert manager == ctx.manager
    assert inspect(pid) == result["pid"]
    assert Enum.any?(children(), fn {_, child, _, _} -> child == pid end)
    assert {:ok, inspected} = inspect_worker(ctx)
    assert inspected["state"] == %{"count" => 7}
    assert inspected["pid"] == result["pid"]

    assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
             GenServer.call(pid, {:invoke, %{"increment" => 1}})

    assert {:error, %{"code" => "INVALID_ARGUMENT"}} = ProcessHost.stop(pid)
    assert {:ok, snapshot} = ProcessHost.snapshot(pid)
    assert snapshot.data == %{"count" => 7}
  end

  @tag :route_collision
  test "a conflicting logical route rejects the candidate without losing either Manager", ctx do
    other = start_supervised!({Manager, name: nil}, id: :other_manager)
    args = start_args(ctx, %{})
    assert {:ok, started} = Manager.start_worker(args, ctx.manager)
    assert {:error, %{"code" => "WORKER_EXISTS"}} = Manager.start_worker(args, other)
    assert Process.alive?(other)
    assert length(children()) == 1
    manager = ctx.manager
    assert [{^manager, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    assert inspect(pid) == started["pid"]
  end

  test "start replay cannot create another host and payload reuse conflicts", ctx do
    args = start_args(ctx, %{})
    assert {:ok, result} = Manager.start_worker(args, ctx.manager)
    assert {:ok, ^result} = Manager.start_worker(args, ctx.manager)
    assert length(children()) == 1

    assert {:error, %{"code" => "REQUEST_ID_CONFLICT"}} =
             Manager.start_worker(%{args | "config" => %{"other" => 1}}, ctx.manager)

    assert {:error, %{"code" => "WORKER_EXISTS"}} =
             Manager.start_worker(%{args | "request_id" => unique()}, ctx.manager)
  end

  test "stop retains identity, repeated stop is a no-op, and restart advances revisions", ctx do
    {:ok, first} = Manager.start_worker(start_args(ctx, %{"count" => 1}), ctx.manager)
    assert {:ok, stopped} = Manager.stop_worker(stop_args(ctx), ctx.manager)
    assert stopped["definition_retained"]
    assert stopped["worker_revision"] == 2
    assert stopped["generation"] == 2
    assert children() == []
    assert Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker) == []

    assert {:error, %{"code" => "CALLBACK_FAILED", "generation" => 2}} =
             Manager.start_worker(start_args(ctx, %{"mode" => "error"}), ctx.manager)

    assert {:ok, %{"status" => "stopped", "worker_revision" => 2}} = inspect_worker(ctx)
    assert {:ok, again} = Manager.stop_worker(stop_args(ctx), ctx.manager)
    assert again["generation"] == 2
    assert again["worker_revision"] == 2
    {:ok, next} = Manager.start_worker(start_args(ctx, %{"count" => 9}), ctx.manager)
    assert next["worker_revision"] == 3
    assert next["state_revision"] == 2
    refute next["pid"] == first["pid"]
    assert {:ok, %{"state" => %{"count" => 9}}} = inspect_worker(ctx)
  end

  test "a completed stop has released logical routing even while death cleanup is delayed", ctx do
    {:ok, _} = Manager.start_worker(start_args(ctx, %{}), ctx.manager)

    [{_id, partition, _type, _modules}] =
      Supervisor.which_children(ElixirMixir.Runtime.ProcessRegistry)

    :sys.suspend(partition)
    pending = Task.async(fn -> Manager.stop_worker(stop_args(ctx), ctx.manager) end)

    outcome =
      try do
        case Task.yield(pending, 100) do
          {:ok, {:ok, _stopped}} = completed ->
            assert Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker) == []
            completed

          nil ->
            nil
        end
      after
        :sys.resume(partition)
      end

    if is_nil(outcome), do: assert({:ok, _} = Task.await(pending))
    assert Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker) == []
  end

  test "unknown references and malformed arguments do not create definitions", ctx do
    assert {:error, %{"code" => "WORKER_NOT_FOUND"}} =
             Manager.stop_worker(stop_args(ctx), ctx.manager)

    args = start_args(ctx, %{})

    assert {:error, %{"code" => "ARTIFACT_NOT_FOUND"}} =
             Manager.start_worker(%{args | "artifact_id" => "missing"}, ctx.manager)

    for altered <- [
          Map.delete(args, "config"),
          Map.put(args, "other", true),
          Map.put(args, "config", []),
          Map.put(args, "worker_id", "bad id")
        ] do
      assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
               Manager.start_worker(Map.put(altered, "request_id", unique()), ctx.manager)
    end

    assert {:ok, %{"workers" => [], "generation" => 0}} =
             Manager.inspect_runtime(%{}, ctx.manager)
  end

  test "failed initialization leaves neither live routing nor a half-created definition", ctx do
    for {mode, code} <- [
          {"error", "CALLBACK_FAILED"},
          {"raise", "CALLBACK_FAILED"},
          {"exit", "CALLBACK_FAILED"},
          {"timeout", "CALLBACK_TIMEOUT"},
          {"non_json", "INVALID_TRANSITION"},
          {"invalid_root", "INVALID_TRANSITION"},
          {"invalid_shape", "CALLBACK_FAILED"},
          {"heap", "CALLBACK_FAILED"}
        ] do
      assert {:error, %{"code" => ^code, "generation" => 0}} =
               Manager.start_worker(start_args(ctx, %{"mode" => mode}), ctx.manager)

      assert children() == []
      assert {:ok, %{"workers" => []}} = Manager.inspect_runtime(%{}, ctx.manager)
    end
  end

  test "capacity includes stopped definitions but permits explicit reinitialization", ctx do
    manager = start_supervised!({Manager, name: nil, limits: %{workers: 1}}, id: :small_manager)
    ctx = %{ctx | manager: manager}
    {:ok, _} = Manager.start_worker(start_args(ctx, %{}), manager)
    {:ok, _} = Manager.stop_worker(stop_args(ctx), manager)

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             Manager.start_worker(start_args(%{ctx | worker: unique()}, %{}), manager)

    assert {:ok, _} = Manager.start_worker(start_args(ctx, %{}), manager)
  end

  test "config/state exact byte bounds and invalid state do not change existing workers", ctx do
    assert {:ok, _} =
             Manager.start_worker(
               start_args(ctx, %{"mode" => "payload", "bytes" => 16_376}),
               ctx.manager
             )

    assert {:ok, inspected} = inspect_worker(ctx)
    assert byte_size(Jason.encode!(inspected["state"])) == 16_384
    other = %{ctx | worker: unique()}

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             Manager.start_worker(
               start_args(other, %{"mode" => "payload", "bytes" => 16_377}),
               ctx.manager
             )

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             Manager.start_worker(
               start_args(other, %{"huge" => String.duplicate("x", 16_384)}),
               ctx.manager
             )

    assert {:ok, ^inspected} = inspect_worker(ctx)
  end

  test "valid config/state at depth sixteen survives protocol response envelopes", ctx do
    config = Enum.reduce(1..16, %{}, fn _, child -> %{"nested" => child} end)
    assert {:ok, _} = Manager.start_worker(start_args(ctx, config), ctx.manager)
    assert {:ok, %{"state" => ^config}} = inspect_worker(ctx)
  end

  test "a killed host recovers without restarting Manager or its healthy peer", ctx do
    {:ok, first} = Manager.start_worker(start_args(ctx, %{"count" => 1}), ctx.manager)
    peer = %{ctx | worker: unique()}
    {:ok, healthy} = Manager.start_worker(start_args(peer, %{"count" => 2}), ctx.manager)
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    restarted = await_running(ctx, first["pid"], 100)
    refute restarted["pid"] == first["pid"]
    assert restarted["worker_revision"] > first["worker_revision"]
    assert restarted["state"] == %{"count" => 1}
    assert {:ok, %{"pid" => peer_pid, "state" => %{"count" => 2}}} = inspect_worker(peer)
    assert peer_pid == healthy["pid"]
    assert Process.alive?(ctx.manager)
    assert restarted["state_revision"] == first["state_revision"] + 1
  end

  test "callback tasks and helpers are cleaned up if their host/caller dies" do
    parent = self()

    work = fn ->
      helper = spawn(fn -> Process.sleep(:infinity) end)
      send(parent, {:execution_started, self(), helper})
      Process.sleep(:infinity)
    end

    caller =
      spawn(fn ->
        Execution.run(ElixirMixir.CallbackTasks, work, 200, Limits.defaults().callback_heap_words)
      end)

    assert_receive {:execution_started, callback, helper}

    on_exit(fn ->
      Process.exit(callback, :kill)
      Process.exit(helper, :kill)
    end)

    callback_ref = Process.monitor(callback)
    helper_ref = Process.monitor(helper)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^callback_ref, :process, ^callback, _reason}, 1_000
    assert_receive {:DOWN, ^helper_ref, :process, ^helper, _reason}, 1_000
  end

  defp await_running(ctx, _old_pid, 0),
    do: flunk("host failure was not observed: #{inspect(inspect_worker(ctx))}")

  defp await_running(ctx, old_pid, remaining) do
    {:ok, state} = inspect_worker(ctx)

    if state["status"] == "running" and state["pid"] != old_pid,
      do: state,
      else:
        (
          Process.sleep(5)
          await_running(ctx, old_pid, remaining - 1)
        )
  end

  defp inspect_worker(ctx),
    do: Manager.inspect_runtime(%{"worker_id" => ctx.worker, "detail" => "state"}, ctx.manager)

  defp start_args(ctx, config),
    do: %{
      "worker_id" => ctx.worker,
      "artifact_id" => ctx.artifact,
      "config" => config,
      "request_id" => unique()
    }

  defp stop_args(ctx), do: %{"worker_id" => ctx.worker, "request_id" => unique()}
  defp unique, do: "worker_#{System.unique_integer([:positive])}"
  defp children, do: DynamicSupervisor.which_children(ElixirMixir.Runtime.WorkerSupervisor)
end
