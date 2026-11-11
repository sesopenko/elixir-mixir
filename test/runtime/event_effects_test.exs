defmodule ElixirMixir.Runtime.EventEffectsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures

  setup_all do
    {:ok, manager} = Manager.start_link(name: nil)

    {:ok, artifact} =
      Manager.define(
        %{
          "source" => Fixtures.effects_source(),
          "logical_name" => "effects",
          "expected_behavior" => "elixir_mixir.behavior.v1",
          "request_id" => "effects"
        },
        manager
      )

    GenServer.stop(manager)
    %{artifact: artifact["artifact_id"]}
  end

  setup ctx do
    parent = self()

    timer =
      if ctx[:manual_timer],
        do: fn message, delay ->
          send(parent, {:timer, message, delay})
          nil
        end,
        else: &Process.send_after(self(), &1, &2)

    dispatcher =
      start_supervised!(
        {EffectDispatcher,
         name: nil,
         timer: timer,
         reservation_timeout_ms: if(ctx[:reservation_expiry], do: 30, else: 7_000)}
      )

    manager =
      start_supervised!(
        {Manager, name: nil, dispatcher: dispatcher, limits: Map.get(ctx, :limits, %{})}
      )

    on_exit(fn ->
      for {_, pid, _, _} <-
            DynamicSupervisor.which_children(ElixirMixir.Runtime.WorkerSupervisor),
          do: DynamicSupervisor.terminate_child(ElixirMixir.Runtime.WorkerSupervisor, pid)
    end)

    %{manager: manager, dispatcher: dispatcher, source: unique(), target: unique()}
  end

  test "counter forwards exact totals and replay has one downstream delivery", ctx do
    start(ctx, ctx.target)
    start(ctx, ctx.source, %{"forward" => ctx.target})
    args = invoke_args(ctx.source, %{"amount" => 5})
    assert {:ok, result} = Manager.invoke(args, ctx.manager)
    assert [%{"effect_id" => id, "status" => "accepted"}] = result["effects"]
    assert byte_size(id) == 64
    await(fn -> state(ctx, ctx.target)["total"] == 5 end)
    assert {:ok, ^result} = Manager.invoke(args, ctx.manager)
    await(fn -> stats(ctx)["pending"] == 0 end)
    assert state(ctx, ctx.source)["count"] == 1
    assert state(ctx, ctx.target)["count"] == 1
    assert stats(ctx)["topology"] == [%{"from" => ctx.source, "to" => ctx.target, "count" => 1}]

    assert Enum.any?(
             events(),
             &(&1["effect_id"] == id and &1["request_id"] == args["request_id"])
           )
  end

  @tag manual_timer: true
  test "zero and maximum delays wait for their timer and stop invalidates fired messages", ctx do
    start(ctx, ctx.target)
    start(ctx, ctx.source)

    for delay <- [0, 60_000] do
      assert {:ok, _} =
               invoke(ctx, [
                 %{
                   "type" => "schedule",
                   "to" => ctx.target,
                   "delay_ms" => delay,
                   "event" => %{"amount" => 4}
                 }
               ])

      assert_receive {:timer, message, ^delay}
      before = state(ctx, ctx.target)["count"]
      assert stats(ctx)["timers"] == 1
      send(ctx.dispatcher, message)
      await(fn -> state(ctx, ctx.target)["count"] == before + 1 end)
      await(fn -> stats(ctx)["pending"] == 0 end)
    end

    assert {:ok, _} =
             invoke(ctx, [
               %{"type" => "schedule", "to" => ctx.target, "delay_ms" => 10, "event" => %{}}
             ])

    assert_receive {:timer, stale, 10}

    assert {:ok, _} =
             Manager.stop_worker(
               %{"worker_id" => ctx.source, "request_id" => unique()},
               ctx.manager
             )

    send(ctx.dispatcher, stale)
    assert stats(ctx)["pending"] == 0
    assert state(ctx, ctx.target)["count"] == 2
  end

  test "bounded structured logs enter Logger and correlated history", ctx do
    start(ctx, ctx.source)

    log =
      capture_log(fn ->
        assert {:ok, _} =
                 invoke(ctx, [
                   %{
                     "type" => "log",
                     "level" => "warning",
                     "message" => "effect-marker",
                     "metadata" => %{"value" => 7}
                   }
                 ])
      end)

    assert log =~ "effect-marker"

    assert Enum.any?(
             events(),
             &(&1["type"] == "effect_log" and &1["metadata"]["metadata"] == %{"value" => 7})
           )

    assert stats(ctx)["pending"] == 0
  end

  test "batch validation and rejected state preserve source and emit nothing", ctx do
    start(ctx, ctx.source)
    start(ctx, ctx.target)
    valid = %{"type" => "emit", "to" => ctx.target, "event" => %{}}
    before = state(ctx, ctx.source)

    for bad <- [
          Map.put(valid, "extra", true),
          %{valid | "to" => "bad id"},
          %{valid | "event" => []},
          %{"type" => "unknown"},
          %{"type" => "log", "level" => "fatal", "message" => "x", "metadata" => %{}},
          %{"type" => "schedule", "to" => ctx.target, "event" => %{}, "delay_ms" => -1}
        ] do
      assert {:error, %{"code" => "INVALID_TRANSITION"}} = invoke(ctx, [valid, bad])
      assert state(ctx, ctx.source) == before
      assert stats(ctx)["reserved"] == 0
    end

    for event <- [
          %{"effects" => [valid], "invalid_state" => true},
          %{"effects" => [valid], "failure" => true}
        ] do
      assert {:error, _} = Manager.invoke(invoke_args(ctx.source, event), ctx.manager)
      assert state(ctx, ctx.source) == before
    end

    assert state(ctx, ctx.target)["count"] == 0
    assert stats(ctx)["pending"] == 0
  end

  @tag manual_timer: true, limits: %{pending_effects: 1}
  test "queue reservations reject entire transitions before source state changes", ctx do
    start(ctx, ctx.source)
    start(ctx, ctx.target)
    effect = %{"type" => "schedule", "to" => ctx.target, "event" => %{}, "delay_ms" => 60_000}
    assert {:ok, _} = invoke(ctx, [effect])
    before = state(ctx, ctx.source)
    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} = invoke(ctx, [effect])
    assert state(ctx, ctx.source) == before
    assert stats(ctx)["pending"] == 1
    assert stats(ctx)["reserved"] == 0
    assert {:ok, _} = invoke(ctx, [])
  end

  test "effect count, event, delay, message and metadata limits reject without dispatch", ctx do
    start(ctx, ctx.source)
    effect = %{"type" => "emit", "to" => ctx.target, "event" => %{}}

    for batch <- [
          List.duplicate(effect, 17),
          [%{effect | "event" => %{"large" => String.duplicate("x", 16_384)}}],
          [%{"type" => "schedule", "to" => ctx.target, "event" => %{}, "delay_ms" => 60_001}],
          [
            %{
              "type" => "log",
              "level" => "info",
              "message" => String.duplicate("x", 2_049),
              "metadata" => %{}
            }
          ],
          [
            %{
              "type" => "log",
              "level" => "info",
              "message" => "x",
              "metadata" => %{"large" => String.duplicate("x", 2_048)}
            }
          ]
        ] do
      assert {:error, %{"code" => "LIMIT_EXCEEDED"}} = invoke(ctx, batch)
    end

    assert state(ctx, ctx.source)["count"] == 0
    assert stats(ctx)["pending"] == 0
  end

  test "missing and stopped destinations fail observably after source acceptance", ctx do
    start(ctx, ctx.source)
    start(ctx, ctx.target)
    Manager.stop_worker(%{"worker_id" => ctx.target, "request_id" => unique()}, ctx.manager)

    assert {:ok, result} =
             invoke(
               ctx,
               Enum.map([ctx.target, "missing"], &%{"type" => "emit", "to" => &1, "event" => %{}})
             )

    ids = Enum.map(result["effects"], & &1["effect_id"])
    await(fn -> stats(ctx)["pending"] == 0 end)
    failed = Enum.filter(events(), &(&1["type"] == "effect_failed" and &1["effect_id"] in ids))

    assert Enum.sort(Enum.map(failed, & &1["metadata"]["code"])) == [
             "WORKER_NOT_FOUND",
             "WORKER_NOT_RUNNING"
           ]

    assert state(ctx, ctx.source)["count"] == 1
  end

  test "cyclic workers exhaust the inherited sixteen-hop budget", ctx do
    start(ctx, ctx.source, %{"forward" => ctx.target})
    start(ctx, ctx.target, %{"forward" => ctx.source})
    assert {:ok, _} = Manager.invoke(invoke_args(ctx.source, %{}), ctx.manager)
    await(fn -> stats(ctx)["pending"] == 0 end)
    assert state(ctx, ctx.source)["count"] + state(ctx, ctx.target)["count"] == 17

    assert Enum.any?(
             events(),
             &(&1["type"] == "effect_failed" and &1["metadata"]["code"] == "HOP_LIMIT")
           )
  end

  @tag manual_timer: true
  test "a delayed event resolves a restarted destination by logical ID", ctx do
    first = start(ctx, ctx.target)
    start(ctx, ctx.source)

    assert {:ok, _} =
             invoke(ctx, [
               %{
                 "type" => "schedule",
                 "to" => ctx.target,
                 "delay_ms" => 100,
                 "event" => %{"amount" => 8}
               }
             ])

    assert_receive {:timer, message, 100}
    [{pid, _}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.target)
    Process.exit(pid, :kill)

    await(fn ->
      {:ok, current} = Manager.inspect_runtime(%{"worker_id" => ctx.target}, ctx.manager)
      current["status"] == "running" and current["pid"] != first["pid"]
    end)

    send(ctx.dispatcher, message)
    await(fn -> state(ctx, ctx.target)["total"] == 8 end)
    assert state(ctx, ctx.target)["count"] == 1
  end

  @tag limits: %{response_bytes: 1_024}
  test "wire rejection releases the reservation and retains source state", ctx do
    start(ctx, ctx.source)
    start(ctx, ctx.target)
    batch = List.duplicate(%{"type" => "emit", "to" => ctx.target, "event" => %{}}, 16)
    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} = invoke(ctx, batch)
    assert state(ctx, ctx.source)["count"] == 0
    assert state(ctx, ctx.target)["count"] == 0
    assert stats(ctx)["reserved"] == 0
    assert stats(ctx)["pending"] == 0
  end

  @tag reservation_expiry: true
  test "uncommitted reservations release on owner death and expiry, and commit consumes once",
       ctx do
    limits = Limits.defaults()

    context = %{
      correlation_id: unique(),
      source: ctx.source,
      path: [],
      manager: self(),
      remaining_hops: 16
    }

    effects = [%{"type" => "emit", "to" => ctx.target, "event" => %{}}]
    parent = self()

    owner =
      spawn(fn ->
        {:ok, token, _} = EffectDispatcher.reserve_batch(ctx.dispatcher, effects, context, limits)
        send(parent, {:reserved, token})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:reserved, token}
    Process.exit(owner, :kill)
    await(fn -> EffectDispatcher.snapshot(ctx.dispatcher)["reserved"] == 0 end)
    assert :ok = EffectDispatcher.release(ctx.dispatcher, token)
    {:ok, expired, _} = EffectDispatcher.reserve_batch(ctx.dispatcher, effects, context, limits)
    await(fn -> EffectDispatcher.snapshot(ctx.dispatcher)["reserved"] == 0 end)
    assert {:error, _} = EffectDispatcher.commit_batch(ctx.dispatcher, expired)
    {:ok, committed, _} = EffectDispatcher.reserve_batch(ctx.dispatcher, effects, context, limits)
    assert :ok = EffectDispatcher.commit_batch(ctx.dispatcher, committed)
    assert {:error, _} = EffectDispatcher.commit_batch(ctx.dispatcher, committed)
    assert :ok = EffectDispatcher.cancel_source(ctx.dispatcher, ctx.source)
  end

  test "default capacity admits exactly 256 reserved deliveries and releases every slot", ctx do
    limits = Limits.defaults()
    effect = %{"type" => "emit", "to" => ctx.target, "event" => %{}}

    context = %{
      correlation_id: unique(),
      source: ctx.source,
      path: [],
      manager: self(),
      remaining_hops: 16
    }

    tokens =
      for index <- 1..16 do
        {:ok, token, accepted} =
          EffectDispatcher.reserve_batch(
            ctx.dispatcher,
            List.duplicate(effect, 16),
            %{context | correlation_id: "capacity-#{index}"},
            limits
          )

        assert length(accepted) == 16
        token
      end

    assert EffectDispatcher.snapshot(ctx.dispatcher)["reserved"] == 256

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             EffectDispatcher.reserve_batch(ctx.dispatcher, [effect], context, limits)

    for token <- tokens, do: EffectDispatcher.release(ctx.dispatcher, token)
    assert EffectDispatcher.snapshot(ctx.dispatcher)["reserved"] == 0
    {:ok, token, _} = EffectDispatcher.reserve_batch(ctx.dispatcher, [effect], context, limits)
    wrong_owner = Task.async(fn -> EffectDispatcher.commit_batch(ctx.dispatcher, token) end)
    assert {:error, %{"code" => "INTERNAL_ERROR"}} = Task.await(wrong_owner)
    assert EffectDispatcher.snapshot(ctx.dispatcher)["reserved"] == 1
    EffectDispatcher.release(ctx.dispatcher, token)
  end

  @tag manual_timer: true
  test "an unclaimed delivery expires without unbounded pending resources", ctx do
    limits = Limits.new(%{operation_timeout_ms: 20})

    context = %{
      correlation_id: unique(),
      source: ctx.source,
      path: [],
      manager: self(),
      remaining_hops: 16
    }

    effect = %{"type" => "emit", "to" => ctx.target, "event" => %{}}

    {:ok, token, [%{"effect_id" => id}]} =
      EffectDispatcher.reserve_batch(ctx.dispatcher, [effect], context, limits)

    :ok = EffectDispatcher.commit_batch(ctx.dispatcher, token)
    assert_receive {:timer, fire, 0}
    send(ctx.dispatcher, fire)
    assert_receive {:effect_delivery, dispatcher, ^id}
    assert dispatcher == ctx.dispatcher
    await(fn -> EffectDispatcher.snapshot(ctx.dispatcher)["pending"] == 0 end)

    assert Enum.any?(
             events(),
             &(&1["effect_id"] == id and &1["metadata"]["code"] == "DELIVERY_TIMEOUT")
           )
  end

  defp start(ctx, id, config \\ %{}) do
    {:ok, result} =
      Manager.start_worker(
        %{
          "worker_id" => id,
          "artifact_id" => ctx.artifact,
          "config" => config,
          "request_id" => unique()
        },
        ctx.manager
      )

    result
  end

  defp invoke(ctx, effects),
    do: Manager.invoke(invoke_args(ctx.source, %{"effects" => effects}), ctx.manager)

  defp invoke_args(id, event),
    do: %{"worker_id" => id, "event" => event, "request_id" => unique()}

  defp state(ctx, id) do
    {:ok, result} =
      Manager.inspect_runtime(%{"worker_id" => id, "detail" => "state"}, ctx.manager)

    result["state"]
  end

  defp stats(ctx), do: EffectDispatcher.snapshot(ctx.dispatcher, ctx.manager)

  defp events(after_sequence \\ 0) do
    page = EventLog.events(%{"after" => after_sequence, "limit" => 100})

    case page["events"] do
      [] -> []
      records -> records ++ events(page["next_cursor"])
    end
  end

  defp unique, do: "effect_#{System.unique_integer([:positive])}"
  defp await(check, attempts \\ 500)
  defp await(_check, 0), do: flunk("effect did not settle")

  defp await(check, attempts) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(1)
          await(check, attempts - 1)
        )
  end
end
