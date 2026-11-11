defmodule ElixirMixir.Runtime.DurableOutboxTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.DurableArtifacts
  alias ElixirMixir.Runtime.DurableOutbox
  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.Effects
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures
  alias ElixirMixir.TestSupport.RuntimeFixture

  setup_all do
    source =
      String.replace(
        Fixtures.effects_source(),
        "{:ok, count, next, effects}",
        "{:ok, Map.get(event, \"reply\", count), next, effects}"
      )

    {:ok, manager} = Manager.start_link(name: nil)

    {:ok, result} =
      Manager.define(
        %{
          "logical_name" => unique(),
          "source" => source,
          "request_id" => unique(),
          "expected_behavior" => "elixir_mixir.behavior.v1"
        },
        manager
      )

    GenServer.stop(manager)

    {:ok, artifact} = ArtifactRegistry.fetch(result["artifact_id"])
    %{artifact: artifact}
  end

  setup ctx do
    dir = RuntimeFixture.temp_path(unique())
    on_exit(fn -> File.rm_rf!(dir) end)
    limits = Map.merge(%{ledger_retention_ms: 100}, Map.get(ctx, :limits, %{}))
    store = start_supervised!({Store, data_dir: dir, limits: limits})
    clock = start_supervised!({Agent, fn -> 1_700_000_000_000 end})

    manager =
      start_supervised!(
        {Manager,
         name: nil,
         delivery_timer: fn _message, _delay -> make_ref() end,
         store: store,
         limits: limits,
         storage: [mode: :durable, data_dir: dir],
         wall_clock: fn -> Agent.get(clock, & &1) end}
      )

    await(fn -> :sys.get_state(manager).recovery["status"] == "ready" end)
    # Reuse one compiled fixture without consuming a new lifetime slot per test.
    {:ok, nil} =
      Store.commit(store, 0, %{
        puts: %{{:artifact, ctx.artifact.id} => DurableArtifacts.record(ctx.artifact)},
        deletes: [],
        outcome: nil,
        operation_id: "fixture",
        advance: false
      })

    worker = unique()

    {:ok, _} =
      Manager.start_worker(
        %{
          "worker_id" => worker,
          "artifact_id" => ctx.artifact.id,
          "config" => %{},
          "request_id" => unique()
        },
        manager
      )

    %{manager: manager, store: store, worker: worker, clock: clock, dir: dir}
  end

  test "entire batch and state commit once with serializable identities and fixed UTC deadlines",
       ctx do
    args = args(ctx, %{"effects" => batch()})
    assert {:ok, result} = Manager.invoke(args, ctx.manager)
    assert {:ok, ^result} = Manager.invoke(args, ctx.manager)
    records = Store.snapshot(ctx.store)
    effects = effects(ctx)
    assert map_size(effects) == 3
    operation = records[{:request, args["request_id"]}]["operation_id"]

    for {{:effect, id}, record} <- effects do
      assert id == Effects.identity(operation, record["path"])
      assert record["operation_id"] == operation
      assert record["correlation_id"] == args["request_id"]
      assert record["due_at"] == 1_700_000_000_000 + Map.get(record["effect"], "delay_ms", 0)
      assert record == record |> Jason.encode!() |> Jason.decode!()
    end

    assert records[{:state, ctx.worker}]["data"]["count"] == 1
    assert stats(ctx)["pending"] == 3
    assert stats(ctx)["timers"] == 1
    assert stats(ctx)["reserved"] == 0

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             DurableOutbox.validate_capacity(records, Limits.new(%{pending_effects: 2}))

    assert :ok = DurableOutbox.validate_capacity(records, Limits.new(%{pending_effects: 3}))
  end

  test "expired caller keys create fresh operations without colliding with old pending effects",
       ctx do
    args = args(ctx, %{"effects" => batch()})
    assert {:ok, _} = Manager.invoke(args, ctx.manager)
    first = effects(ctx)
    Agent.update(ctx.clock, &(&1 + 200))
    assert {:ok, _} = Manager.invoke(args, ctx.manager)
    second = effects(ctx)
    assert map_size(second) == 6
    assert Map.take(second, Map.keys(first)) == first

    assert second |> Map.values() |> Enum.map(& &1["operation_id"]) |> Enum.uniq() |> length() ==
             2

    assert stats(ctx)["pending"] == 6
  end

  @tag limits: %{pending_effects: 3}
  test "invalid and full batches leave state and pending work untouched", ctx do
    before = checkpoint(ctx)

    assert {:error, _} =
             Manager.invoke(
               args(ctx, %{"effects" => batch() ++ [%{"type" => "invalid"}]}),
               ctx.manager
             )

    assert checkpoint(ctx) == before
    assert effects(ctx) == %{}
    assert {:ok, _} = Manager.invoke(args(ctx, %{"effects" => batch()}), ctx.manager)
    retained = effects(ctx)
    before = checkpoint(ctx)

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             Manager.invoke(args(ctx, %{"effects" => batch()}), ctx.manager)

    assert checkpoint(ctx) == before
    assert effects(ctx) == retained
    assert stats(ctx)["reserved"] == 0
  end

  @tag limits: %{response_bytes: 2_048}
  test "state validation and response preflight release the complete reservation", ctx do
    before = checkpoint(ctx)

    for event <- [%{"invalid_state" => true}, %{"reply" => String.duplicate("x", 1_500)}] do
      assert {:error, _} =
               Manager.invoke(args(ctx, Map.put(event, "effects", batch())), ctx.manager)

      assert checkpoint(ctx) == before
      assert effects(ctx) == %{}
      assert stats(ctx)["reserved"] == 0
    end

    assert {:ok, _} = Manager.invoke(args(ctx, %{"effects" => batch()}), ctx.manager)
  end

  test "host crash and replacement preserve intents while explicit stop cancels them", ctx do
    assert {:ok, _} = Manager.invoke(args(ctx, %{"effects" => batch()}), ctx.manager)
    retained = effects(ctx)
    [{_, host}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    Process.exit(host, :kill)

    await(fn ->
      case Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker) do
        [{_, next}] -> next != host
        [] -> false
      end
    end)

    assert effects(ctx) == retained

    {:ok, worker} =
      Manager.inspect_runtime(%{"worker_id" => ctx.worker, "detail" => "state"}, ctx.manager)

    assert {:ok, _} =
             Manager.replace(
               %{
                 "worker_id" => ctx.worker,
                 "artifact_id" => ctx.artifact.id,
                 "expected_revision" => worker["worker_revision"],
                 "request_id" => unique()
               },
               ctx.manager
             )

    assert effects(ctx) == retained

    assert {:ok, _} =
             Manager.stop_worker(
               %{"worker_id" => ctx.worker, "request_id" => unique()},
               ctx.manager
             )

    assert effects(ctx) == %{}
    assert stats(ctx)["pending"] == 0
  end

  @tag capture_log: true
  test "lowering boot capacity fails recovery without rewriting retained intents", ctx do
    assert {:ok, _} = Manager.invoke(args(ctx, %{"effects" => batch()}), ctx.manager)
    records = Store.snapshot(ctx.store)
    stop_supervised!(Manager)

    spec =
      Supervisor.child_spec(
        {Manager,
         name: nil,
         store: ctx.store,
         storage: [mode: :durable, data_dir: ctx.dir],
         limits: %{pending_effects: 2}},
        restart: :temporary
      )

    manager = start_supervised!(spec)
    ref = Process.monitor(manager)
    assert_receive {:DOWN, ^ref, :process, ^manager, :recovery_failed}, 2_000
    assert Store.snapshot(ctx.store) == records
    assert EffectDispatcher.snapshot(EffectDispatcher, manager)["pending"] == 0
  end

  defp batch,
    do: [
      %{"type" => "emit", "to" => "peer", "event" => %{}},
      %{"type" => "schedule", "to" => "peer", "event" => %{}, "delay_ms" => 60_000},
      %{"type" => "log", "level" => "info", "message" => "durable intent", "metadata" => %{}}
    ]

  defp args(ctx, event),
    do: %{"worker_id" => ctx.worker, "event" => event, "request_id" => unique()}

  defp effects(ctx),
    do: Map.filter(Store.snapshot(ctx.store), fn {key, _} -> match?({:effect, _}, key) end)

  defp checkpoint(ctx), do: Store.snapshot(ctx.store)[{:state, ctx.worker}]
  defp stats(ctx), do: EffectDispatcher.snapshot(EffectDispatcher, ctx.manager)
  defp unique, do: "outbox-#{System.unique_integer([:positive])}"
  defp await(check, attempts \\ 400)
  defp await(_check, 0), do: flunk("outbox recovery did not settle")

  defp await(check, attempts) do
    unless check.() do
      Process.sleep(5)
      await(check, attempts - 1)
    end
  end
end
