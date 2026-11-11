defmodule ElixirMixir.Runtime.DurableTimersTest do
  use ExUnit.Case, async: false
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.TestSupport.DurableFixture, as: F
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures

  setup_all do
    %{artifact: F.artifact()}
  end

  setup ctx do
    ctx = F.setup(ctx)
    F.start(ctx, ctx.source)
    F.start(ctx, ctx.target)
    ctx
  end

  test "zero delay, backward and forward clock moves preserve fixed deadlines and recheck eligibility",
       ctx do
    {:ok, _} =
      F.invoke(ctx, ctx.source, %{
        "effects" => [schedule(ctx.target, 0), schedule(ctx.target, 500)]
      })

    F.fire(ctx)
    assert F.data(ctx, ctx.target)["count"] == 1
    remaining = F.pending(ctx)
    Agent.update(ctx.clock, &(&1 - 100))
    F.fire(ctx)
    assert F.pending(ctx) == remaining
    assert_receive {:armed, _, 600}
    Agent.update(ctx.clock, &(&1 + 1_000))
    F.fire(ctx)
    assert F.pending(ctx) == %{}
    assert F.data(ctx, ctx.target)["count"] == 2
  end

  test "eligible work follows UTC deadline then ID order and timer claims alone do not mutate",
       ctx do
    {:ok, _} =
      F.invoke(ctx, ctx.source, %{
        "effects" => [
          schedule(ctx.target, 50),
          schedule(ctx.target, 10),
          schedule(ctx.target, 10)
        ]
      })

    original = Store.snapshot(ctx.store)
    F.fire(ctx)
    assert Store.snapshot(ctx.store) == original
    Agent.update(ctx.clock, &(&1 + 100))

    ordered =
      F.pending(ctx) |> Enum.sort_by(fn {{:effect, id}, record} -> {record["due_at"], id} end)

    for {{:effect, id}, _record} <- ordered do
      assert :sys.get_state(ctx.manager).delivery_timer.id == id
      F.fire(ctx)
    end

    assert F.data(ctx, ctx.target)["count"] == 3
  end

  test "source replacement preserves schedule and source stop cancels a stale timer", ctx do
    {:ok, result} =
      F.invoke(ctx, ctx.source, %{
        "effects" => [schedule(ctx.target, 100), schedule(ctx.target, 200)]
      })

    original = F.pending(ctx)

    {:ok, replacement} =
      Manager.define(
        %{
          "logical_name" => F.unique(),
          "source" =>
            Fixtures.source(event: ~S|{:ok, Map.get(event, "reply", "changed"), state, []}|),
          "request_id" => F.unique(),
          "expected_behavior" => "elixir_mixir.behavior.v1"
        },
        ctx.manager
      )

    {:ok, _} =
      Manager.replace(
        %{
          "worker_id" => ctx.source,
          "artifact_id" => replacement["artifact_id"],
          "expected_revision" => result["worker_revision"],
          "request_id" => F.unique()
        },
        ctx.manager
      )

    assert {:ok, %{"reply" => "changed"}} = F.invoke(ctx, ctx.source, %{})
    assert F.pending(ctx) == original
    Agent.update(ctx.clock, &(&1 + 100))
    F.fire(ctx)
    assert F.data(ctx, ctx.target)["count"] == 1
    %{id: id, nonce: nonce} = :sys.get_state(ctx.manager).delivery_timer

    {:ok, _} =
      Manager.stop_worker(%{"worker_id" => ctx.source, "request_id" => F.unique()}, ctx.manager)

    Agent.update(ctx.clock, &(&1 + 100))
    send(ctx.manager, {:durable_delivery, id, nonce})
    :sys.get_state(ctx.manager)
    assert F.pending(ctx) == %{}
    assert F.data(ctx, ctx.target)["count"] == 1
  end

  test "large backward UTC jumps rearm within the timer ceiling without changing the deadline",
       ctx do
    {:ok, _} = F.invoke(ctx, ctx.source, %{"effects" => [schedule(ctx.target, 500)]})
    assert_receive {:armed, _, 500}
    original = F.pending(ctx)
    Agent.update(ctx.clock, &(&1 - 4_294_967_296))
    F.fire(ctx)
    assert_receive {:armed, _, delay}
    assert delay <= 60_000
    assert F.pending(ctx) == original
  end

  defp schedule(target, delay),
    do: %{"type" => "schedule", "to" => target, "event" => %{}, "delay_ms" => delay}
end
