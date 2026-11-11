defmodule ElixirMixir.Runtime.DurableTransitionsTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures

  setup ctx do
    dir = Path.join(System.tmp_dir!(), "mixir-transitions-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    store = start_supervised!({Store, data_dir: dir})

    manager =
      start_supervised!(
        {Manager,
         name: nil,
         store: store,
         limits: Map.get(ctx, :limits, %{}),
         storage: [mode: :durable, data_dir: dir]}
      )

    await(fn -> :sys.get_state(manager).recovery["status"] == "ready" end)

    {:ok, artifact} =
      Manager.define(
        %{
          "logical_name" => unique(),
          "source" => Fixtures.counter_source(),
          "request_id" => unique(),
          "expected_behavior" => "elixir_mixir.behavior.v1"
        },
        manager
      )

    worker = unique()

    {:ok, _} =
      Manager.start_worker(
        %{
          "worker_id" => worker,
          "artifact_id" => artifact["artifact_id"],
          "config" => %{"initial" => 0},
          "request_id" => unique()
        },
        manager
      )

    %{manager: manager, store: store, worker: worker}
  end

  test "committed event state, revisions and exact outcome stay atomic and replay once", ctx do
    args = args(ctx, %{"amount" => 7})
    assert {:ok, result} = Manager.invoke(args, ctx.manager)
    assert result["reply"] == 7
    assert {:ok, ^result} = Manager.invoke(args, ctx.manager)
    records = Store.snapshot(ctx.store)
    assert records[:meta]["generation"] == result["generation"]
    assert records[{:state, ctx.worker}]["data"] == %{"count" => 7}
    assert records[{:state, ctx.worker}]["state_revision"] == 2
    entry = records[{:request, args["request_id"]}]
    assert entry["outcome"]["data"] == result
    assert records[{:state, ctx.worker}]["last_operation_id"] == entry["operation_id"]

    assert {:error, %{"code" => "REQUEST_ID_CONFLICT"}} =
             Manager.invoke(%{args | "event" => %{"amount" => 8}}, ctx.manager)

    assert snapshot(ctx)["state"] == %{"count" => 7}
  end

  test "callback errors, deadlines and invalid/oversized state retain committed data and generation",
       ctx do
    before = Store.snapshot(ctx.store)[{:state, ctx.worker}]

    for mode <-
          ~w(error raise exit timeout malformed reply_non_json state_non_json invalid_state heap) do
      args = args(ctx, %{"mode" => mode})
      assert {:error, failure} = Manager.invoke(args, ctx.manager)
      assert {:error, ^failure} = Manager.invoke(args, ctx.manager)
      assert Store.snapshot(ctx.store)[{:state, ctx.worker}] == before
      assert Store.snapshot(ctx.store)[:meta]["generation"] == 2
    end

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             Manager.invoke(
               args(ctx, %{"mode" => "state_payload", "bytes" => 16_377}),
               ctx.manager
             )

    assert Store.snapshot(ctx.store)[{:state, ctx.worker}] == before
    assert {:ok, %{"reply" => 1}} = Manager.invoke(args(ctx, %{}), ctx.manager)
  end

  test "latest event state restores after host death without another state revision", ctx do
    {:ok, accepted} = Manager.invoke(args(ctx, %{"amount" => 11}), ctx.manager)
    [{_, host}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    Process.exit(host, :kill)

    await(fn ->
      data = snapshot(ctx)
      data["status"] == "running" and data["pid"] != inspect(host)
    end)

    restored = snapshot(ctx)
    assert restored["state"] == %{"count" => 11}
    assert restored["state_revision"] == accepted["state_revision"]

    assert Store.snapshot(ctx.store)[{:state, ctx.worker}]["state_revision"] ==
             accepted["state_revision"]

    assert {:ok, %{"reply" => 12}} = Manager.invoke(args(ctx, %{}), ctx.manager)
  end

  test "nonempty effects never reserve, dispatch or mutate durable state", ctx do
    {:ok, artifact} =
      Manager.define(
        %{
          "logical_name" => unique(),
          "source" => Fixtures.effects_source(),
          "request_id" => unique(),
          "expected_behavior" => "elixir_mixir.behavior.v1"
        },
        ctx.manager
      )

    worker = unique()

    {:ok, _} =
      Manager.start_worker(
        %{
          "worker_id" => worker,
          "artifact_id" => artifact["artifact_id"],
          "config" => %{},
          "request_id" => unique()
        },
        ctx.manager
      )

    ctx = %{ctx | worker: worker}
    before = Store.snapshot(ctx.store)[{:state, worker}]

    for effect <- [
          %{"type" => "emit", "to" => "peer", "event" => %{}},
          %{"type" => "schedule", "to" => "peer", "event" => %{}, "delay_ms" => 1},
          %{
            "type" => "log",
            "level" => "info",
            "message" => "must not dispatch",
            "metadata" => %{}
          }
        ] do
      args = args(ctx, %{"effects" => [effect]})

      assert {:error, %{"code" => "DURABILITY_UNAVAILABLE"} = failure} =
               Manager.invoke(args, ctx.manager)

      assert {:error, ^failure} = Manager.invoke(args, ctx.manager)
      assert Store.snapshot(ctx.store)[{:state, worker}] == before
    end

    stats = EffectDispatcher.snapshot(EffectDispatcher, ctx.manager)
    assert stats["pending"] == 0
    assert stats["reserved"] == 0
    assert {:ok, _} = Manager.invoke(args(ctx, %{}), ctx.manager)
  end

  @tag limits: %{response_bytes: 2_048}
  test "a large reply fails wire preflight before state or durable outcome success", ctx do
    before = Store.snapshot(ctx.store)[{:state, ctx.worker}]
    args = args(ctx, %{"mode" => "reply_payload", "bytes" => 1_500})
    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} = Manager.invoke(args, ctx.manager)
    assert Store.snapshot(ctx.store)[{:state, ctx.worker}] == before
    assert snapshot(ctx)["state"] == %{"count" => 0}
  end

  defp args(ctx, event),
    do: %{"worker_id" => ctx.worker, "event" => event, "request_id" => unique()}

  defp snapshot(ctx) do
    {:ok, data} =
      Manager.inspect_runtime(%{"worker_id" => ctx.worker, "detail" => "state"}, ctx.manager)

    data
  end

  defp unique, do: "event-#{System.unique_integer([:positive])}"
  defp await(check, attempts \\ 300)
  defp await(_check, 0), do: flunk("durable transition did not settle")

  defp await(check, attempts) do
    unless check.() do
      Process.sleep(5)
      await(check, attempts - 1)
    end
  end
end
