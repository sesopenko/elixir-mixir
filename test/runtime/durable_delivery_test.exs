defmodule ElixirMixir.Runtime.DurableDeliveryTest do
  use ExUnit.Case, async: false
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.TestSupport.DurableFixture, as: F

  setup_all do
    %{artifact: F.artifact()}
  end

  setup ctx do
    ctx = F.setup(ctx)
    F.start(ctx, ctx.source)
    F.start(ctx, ctx.target)
    ctx
  end

  @tag limits: %{pending_effects: 1, ledger_retention_ms: 100, ledger_entries: 3}
  test "consumption commits target, edge and child with parent capacity and ignores stale wakeups after expiry",
       ctx do
    child = emit(ctx.source, %{})

    {:ok, result} =
      F.invoke(ctx, ctx.source, %{"effects" => [emit(ctx.target, %{"effects" => [child]})]})

    [parent] = Enum.map(result["effects"], & &1["effect_id"])
    stale = F.fire(ctx)
    records = Store.snapshot(ctx.store)
    refute Map.has_key?(records, {:effect, parent})
    refute Map.has_key?(records, {:request, parent})
    assert F.data(ctx, ctx.target)["count"] == 1
    assert records[{:edge, ctx.source, ctx.target}] == %{"count" => 1}
    assert map_size(F.pending(ctx)) == 1
    assert [{_, record}] = Map.to_list(F.pending(ctx))
    assert record["path"] == [1, 1]
    assert record["remaining_hops"] == 15
    before = Store.snapshot(ctx.store)
    Agent.update(ctx.clock, &(&1 + 200))
    send(ctx.manager, stale)
    :sys.get_state(ctx.manager)
    assert Store.snapshot(ctx.store) == before
    F.fire(ctx)
    assert F.pending(ctx) == %{}
    assert F.data(ctx, ctx.source)["count"] == 2
    assert Store.snapshot(ctx.store)[{:edge, ctx.target, ctx.source}] == %{"count" => 1}
    {:ok, summary} = Manager.inspect_runtime(%{}, ctx.manager)
    assert summary["effects"]["dispatch"] == "enabled"
    assert summary["edge_count"] == 2
  end

  @tag limits: %{pending_effects: 1}
  test "a child batch exceeding reclaimed capacity fails atomically and consumes the parent",
       ctx do
    child = emit(ctx.source, %{})

    {:ok, _} =
      F.invoke(ctx, ctx.source, %{"effects" => [emit(ctx.target, %{"effects" => [child, child]})]})

    before = F.data(ctx, ctx.target)
    F.fire(ctx)
    assert F.pending(ctx) == %{}
    assert F.data(ctx, ctx.target) == before
    records = Store.snapshot(ctx.store)
    refute Map.has_key?(records, {:edge, ctx.source, ctx.target})

    assert Enum.any?(records, fn {key, record} ->
             match?({:audit, _}, key) and record["operation"] == "delivery" and
               record["outcome"] == "LIMIT_EXCEEDED"
           end)
  end

  test "missing, stopped, quarantined targets and invalid callbacks terminally consume without target state changes",
       ctx do
    {:ok, _} =
      Manager.stop_worker(%{"worker_id" => ctx.target, "request_id" => F.unique()}, ctx.manager)

    for target <- [ctx.target, "missing"] do
      assert {:ok, _} = F.invoke(ctx, ctx.source, %{"effects" => [emit(target, %{})]})
      F.fire(ctx)
      assert F.pending(ctx) == %{}
    end

    :sys.replace_state(ctx.manager, fn state ->
      put_in(state, [:workers, ctx.target, :status], "quarantined")
    end)

    assert {:ok, _} = F.invoke(ctx, ctx.source, %{"effects" => [emit(ctx.target, %{})]})
    F.fire(ctx)
    assert F.pending(ctx) == %{}
    # A fresh explicit start restores a valid target after stop.
    {:ok, _} =
      Manager.stop_worker(%{"worker_id" => ctx.target, "request_id" => F.unique()}, ctx.manager)

    F.start(ctx, ctx.target)
    before = F.data(ctx, ctx.target)

    for mode <- ~w(error invalid timeout) do
      {:ok, _} = F.invoke(ctx, ctx.source, %{"effects" => [emit(ctx.target, %{"mode" => mode})]})
      F.fire(ctx)
      assert F.pending(ctx) == %{}
      assert F.data(ctx, ctx.target) == before
    end

    audits =
      for {{:audit, _}, record} <- Store.snapshot(ctx.store),
          record["operation"] == "delivery",
          do: record

    assert length(audits) == 6
    assert Enum.all?(audits, &(&1["type"] == "effect_failed"))
  end

  test "transient restarting and BUSY retry after 100 ms without a durable mutation", ctx do
    {:ok, _} = F.invoke(ctx, ctx.source, %{"effects" => [emit(ctx.target, %{})]})

    :sys.replace_state(ctx.manager, fn state ->
      put_in(state, [:workers, ctx.target, :status], "restarting")
    end)

    before = Store.snapshot(ctx.store)
    F.fire(ctx)
    assert Store.snapshot(ctx.store) == before
    assert_receive {:armed, _, 100}
    F.fire(ctx)
    assert Store.snapshot(ctx.store) == before

    :sys.replace_state(ctx.manager, fn state ->
      put_in(state, [:workers, ctx.target, :status], "running")
    end)

    Agent.update(ctx.clock, &(&1 + 100))
    F.fire(ctx)
    assert F.pending(ctx) == %{}
    assert F.data(ctx, ctx.target)["count"] == 1
  end

  test "a queued wakeup ahead of the target DOWN message retains work for restoration", ctx do
    {:ok, _} = F.invoke(ctx, ctx.source, %{"effects" => [emit(ctx.target, %{})]})
    state = :sys.get_state(ctx.manager)
    host = state.workers[ctx.target].pid
    %{id: id, nonce: nonce} = state.delivery_timer
    :sys.suspend(ctx.manager)
    send(ctx.manager, {:durable_delivery, id, nonce})
    ref = Process.monitor(host)
    Process.exit(host, :kill)
    assert_receive {:DOWN, ^ref, :process, ^host, :killed}
    :sys.resume(ctx.manager)
    F.await(fn -> :sys.get_state(ctx.manager).workers[ctx.target].status == "running" end)
    assert map_size(F.pending(ctx)) == 1
    Agent.update(ctx.clock, &(&1 + 100))
    F.fire(ctx)
    assert F.pending(ctx) == %{}
    assert F.data(ctx, ctx.target)["count"] == 1
  end

  test "a BUSY prepared target retains the parent until its candidate is aborted", ctx do
    {:ok, _} = F.invoke(ctx, ctx.source, %{"effects" => [emit(ctx.target, %{})]})
    parent = self()

    :sys.replace_state(ctx.manager, fn state ->
      worker = state.workers[ctx.target]
      context = %{request_id: "busy", operation_id: "busy", generation: state.generation + 1}

      {:ok, _, ticket} =
        ProcessHost.prepare_invoke(worker.pid, %{}, context, state.limits.operation_timeout_ms)

      send(parent, {:ticket, ticket})
      state
    end)

    assert_receive {:ticket, ticket}
    before = Store.snapshot(ctx.store)
    F.fire(ctx)
    assert Store.snapshot(ctx.store) == before
    assert_receive {:armed, _, 100}

    :sys.replace_state(ctx.manager, fn state ->
      :ok = ProcessHost.abort(state.workers[ctx.target].pid, ticket)
      state
    end)

    Agent.update(ctx.clock, &(&1 + 100))
    F.fire(ctx)
    assert F.pending(ctx) == %{}
    assert F.data(ctx, ctx.target)["count"] == 1
  end

  @tag limits: %{effect_hops: 2}
  test "hop exhaustion consumes the last child without an extra target transition", ctx do
    # Each target emits the next member of a bounded chain.
    third = emit(ctx.target, %{})
    second = emit(ctx.source, %{"effects" => [third]})
    first = emit(ctx.target, %{"effects" => [second]})
    {:ok, _} = F.invoke(ctx, ctx.source, %{"effects" => [first]})
    F.fire(ctx)
    F.fire(ctx)
    F.fire(ctx)
    assert F.pending(ctx) == %{}
    assert F.data(ctx, ctx.source)["count"] == 2
    assert F.data(ctx, ctx.target)["count"] == 1

    assert Enum.any?(Store.snapshot(ctx.store), fn {key, record} ->
             match?({:audit, _}, key) and record["outcome"] == "HOP_LIMIT"
           end)
  end

  defp emit(target, event), do: %{"type" => "emit", "to" => target, "event" => event}
end
