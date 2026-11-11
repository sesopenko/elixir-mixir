defmodule ElixirMixir.Runtime.DurableLifecycleTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.Runtime.DurableRecovery
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures

  setup ctx do
    dir = Path.join(System.tmp_dir!(), "mixir-lifecycle-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    store = start_supervised!({Store, data_dir: dir})
    parent = self()

    restore =
      if ctx[:restore_failure],
        do: fn _opts -> {:error, :injected} end,
        else: fn opts ->
          DynamicSupervisor.start_child(ElixirMixir.Runtime.WorkerSupervisor, {ProcessHost, opts})
        end

    manager =
      start_supervised!(
        {Manager,
         name: nil,
         store: store,
         storage: [mode: :durable, data_dir: dir],
         limits: Map.get(ctx, :limits, %{}),
         restore_host: restore,
         restart_timer: fn message ->
           send(parent, message)
           nil
         end}
      )

    await(fn -> :sys.get_state(manager).recovery["status"] == "ready" end)
    source = Fixtures.worker_source()

    {:ok, artifact} =
      Manager.define(
        %{
          "logical_name" => unique(),
          "request_id" => unique(),
          "source" => source,
          "expected_behavior" => "elixir_mixir.behavior.v1"
        },
        manager
      )

    %{manager: manager, store: store, artifact: artifact["artifact_id"], worker: unique()}
  end

  test "start and stop commit the whole definition, checkpoint and exact response before routing",
       ctx do
    args = start_args(ctx, %{"count" => 7})
    assert {:ok, first} = Manager.start_worker(args, ctx.manager)
    records = Store.snapshot(ctx.store)
    record = records[{:worker, ctx.worker}]
    assert record["desired_status"] == "running"
    assert record["config"] == %{"count" => 7}
    assert records[{:state, ctx.worker}]["data"] == %{"count" => 7}
    assert records[{:state, ctx.worker}]["state_revision"] == 1
    assert {:ok, ^first} = Manager.start_worker(args, ctx.manager)

    assert {:error, %{"code" => "WORKER_EXISTS"}} =
             Manager.start_worker(%{args | "request_id" => unique()}, ctx.manager)

    assert [{manager, host}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    assert manager == ctx.manager
    assert Process.alive?(host)
    stop = %{"worker_id" => ctx.worker, "request_id" => unique()}
    assert {:ok, stopped} = Manager.stop_worker(stop, ctx.manager)
    assert stopped["worker_revision"] == 2
    assert {:ok, ^stopped} = Manager.stop_worker(stop, ctx.manager)
    assert {:ok, noop} = Manager.stop_worker(%{stop | "request_id" => unique()}, ctx.manager)
    assert noop["generation"] == stopped["generation"]
    assert Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker) == []
    refute Process.alive?(host)
    assert snapshot(ctx)["state"] == %{"count" => 7}
    assert {:ok, restarted} = Manager.start_worker(start_args(ctx, %{"count" => 99}), ctx.manager)
    assert restarted["worker_revision"] == 3
    assert restarted["state_revision"] == 2
    assert snapshot(ctx)["state"] == %{"count" => 99}
  end

  test "invalid init and timeout retain no definition or route and replay one failure", ctx do
    for mode <- ["error", "timeout", "invalid_root", "non_json", "invalid_shape"] do
      args = start_args(ctx, %{"mode" => mode})
      assert {:error, error} = Manager.start_worker(args, ctx.manager)
      assert {:error, ^error} = Manager.start_worker(args, ctx.manager)
      refute Map.has_key?(Store.snapshot(ctx.store), {:worker, ctx.worker})
      assert Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker) == []
    end
  end

  @tag limits: %{response_bytes: 1_024}
  test "response preflight removes an initialized candidate before any definition commits", ctx do
    args = %{
      start_args(ctx, %{"count" => 4})
      | "worker_id" => String.duplicate("w", 64),
        "request_id" => String.duplicate("r", 64)
    }

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} = Manager.start_worker(args, ctx.manager)
    records = Store.snapshot(ctx.store)
    refute Map.has_key?(records, {:worker, args["worker_id"]})
    assert Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, args["worker_id"]) == []

    refute Enum.any?(
             DynamicSupervisor.which_children(ElixirMixir.Runtime.WorkerSupervisor),
             fn {_, pid, _, _} ->
               case ProcessHost.snapshot(pid) do
                 {:ok, snapshot} -> snapshot.worker_id == args["worker_id"]
                 _missing -> false
               end
             end
           )
  end

  test "the maximum state depth remains valid inside its durable checkpoint envelope", ctx do
    source =
      Fixtures.source(
        init: ~S|_ = config; {:ok, Enum.reduce(1..16, 0, fn _, acc -> %{"x" => acc} end)}|
      )

    {:ok, artifact} =
      Manager.define(
        %{
          "logical_name" => unique(),
          "request_id" => unique(),
          "source" => source,
          "expected_behavior" => "elixir_mixir.behavior.v1"
        },
        ctx.manager
      )

    args = %{start_args(ctx, %{}) | "artifact_id" => artifact["artifact_id"]}
    assert {:ok, _} = Manager.start_worker(args, ctx.manager)
    expected = Enum.reduce(1..16, 0, fn _, acc -> %{"x" => acc} end)
    assert Store.snapshot(ctx.store)[{:state, ctx.worker}]["data"] == expected
  end

  test "host loss restores the committed checkpoint and ignores stale retry and DOWN messages",
       ctx do
    {:ok, first} = Manager.start_worker(start_args(ctx, %{"count" => 8}), ctx.manager)
    [{_, host}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    Process.exit(host, :kill)
    assert_receive {:restart_worker, id, token}
    assert id == ctx.worker
    send(ctx.manager, {:restart_worker, id, make_ref()})
    assert Store.snapshot(ctx.store)[{:worker, id}]["observed_status"] == "restarting"
    send(ctx.manager, {:restart_worker, id, token})
    await(fn -> snapshot(ctx)["status"] == "running" end)
    restored = snapshot(ctx)
    assert restored["state"] == %{"count" => 8}
    assert restored["state_revision"] == first["state_revision"]
    assert restored["worker_revision"] == first["worker_revision"] + 2
    assert Store.snapshot(ctx.store)[{:worker, id}]["restarts"] != []
    send(ctx.manager, {:DOWN, make_ref(), :process, host, :killed})
    send(ctx.manager, {:restart_worker, id, token})
    assert snapshot(ctx) == restored
  end

  @tag restore_failure: true
  test "exhausted budget is persisted and changing a failed definition requires stop", ctx do
    {:ok, _} = Manager.start_worker(start_args(ctx, %{}), ctx.manager)
    [{_, host}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    Process.exit(host, :kill)

    for _ <- 1..3 do
      assert_receive {:restart_worker, id, token}
      send(ctx.manager, {:restart_worker, id, token})
      # Serialize with Manager after the retry, including its durable write.
      Manager.inspect_runtime(%{}, ctx.manager)
    end

    failed = snapshot(ctx)
    assert failed["status"] == "failed"
    record = Store.snapshot(ctx.store)[{:worker, ctx.worker}]
    assert record["observed_status"] == "failed"
    assert length(record["restarts"]) == 3
    assert Enum.all?(record["restarts"], &(&1 > 1_000_000_000_000))

    assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
             Manager.start_worker(start_args(ctx, %{"count" => 3}), ctx.manager)

    {:ok, restored, _summary} =
      DurableRecovery.restore(Store.snapshot(ctx.store), :sys.get_state(ctx.manager))

    assert restored[ctx.worker].status == "failed"
    assert restored[ctx.worker].pid == nil

    assert {:ok, _} =
             Manager.stop_worker(
               %{"worker_id" => ctx.worker, "request_id" => unique()},
               ctx.manager
             )

    assert {:ok, _} = Manager.start_worker(start_args(ctx, %{"count" => 3}), ctx.manager)
    assert snapshot(ctx)["restart_count"] == 0
  end

  defp start_args(ctx, config),
    do: %{
      "worker_id" => ctx.worker,
      "artifact_id" => ctx.artifact,
      "config" => config,
      "request_id" => unique()
    }

  defp snapshot(ctx) do
    {:ok, data} =
      Manager.inspect_runtime(%{"worker_id" => ctx.worker, "detail" => "state"}, ctx.manager)

    data
  end

  defp unique, do: "life-#{System.unique_integer([:positive])}"
  defp await(check, attempts \\ 200)
  defp await(_check, 0), do: flunk("lifecycle did not settle")

  defp await(check, attempts) do
    unless check.() do
      Process.sleep(5)
      await(check, attempts - 1)
    end
  end
end
