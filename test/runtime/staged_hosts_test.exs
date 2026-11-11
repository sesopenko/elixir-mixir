defmodule ElixirMixir.Runtime.StagedHostsTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures

  setup_all do
    {:ok, manager} = Manager.start_link(name: nil)

    artifacts =
      for {id, source} <- [
            {"effects", Fixtures.effects_source()},
            {"counted",
             String.replace(
               Fixtures.effects_source(),
               "count = state",
               "send(Process.whereis(ElixirMixir.Runtime.StagedHostsTest), :generated_callback)\n      count = state"
             )},
            {"v1", Fixtures.replacement_source(1)},
            {"v2", Fixtures.replacement_source(2)},
            {"v3", Fixtures.replacement_source(3)}
          ],
          into: %{} do
        {:ok, result} =
          Manager.define(
            %{
              "logical_name" => "staged-#{id}",
              "source" => source,
              "expected_behavior" => "elixir_mixir.behavior.v1",
              "request_id" => "staged-#{id}"
            },
            manager
          )

        {:ok, artifact} = ArtifactRegistry.fetch(result["artifact_id"])
        {id, Map.take(artifact, [:id, :module, :revision, :state_schema])}
      end

    GenServer.stop(manager)
    %{artifacts: artifacts}
  end

  setup ctx do
    opts = %{
      worker_id: "unrouted",
      artifact: ctx.artifacts["effects"],
      config: %{},
      worker_revision: 1,
      state_revision: 1,
      limits: Limits.new(),
      manager: self(),
      dispatcher: EffectDispatcher
    }

    host = start_supervised!({ProcessHost, opts})

    context = %{
      request_id: "staged",
      operation_id: "operation",
      generation: 2,
      correlation_id: "staged",
      path: [],
      remaining_hops: 16,
      source: "unrouted",
      manager: self()
    }

    %{host: host, context: context, opts: opts}
  end

  test "prepare reserves without routing, dispatch or state publication; abort releases capacity",
       ctx do
    assert Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, "unrouted") == []
    {:ok, before} = ProcessHost.snapshot(ctx.host)
    event = effect_event()
    {:ok, outcome, ticket} = ProcessHost.prepare_invoke(ctx.host, event, ctx.context, 1_000)
    assert outcome["state_revision"] == 2
    assert {:ok, ^before} = ProcessHost.snapshot(ctx.host)
    assert EffectDispatcher.snapshot()["pending"] == 0
    assert EffectDispatcher.snapshot()["reserved"] > 0

    assert {:error, %{"code" => "BUSY"}} =
             ProcessHost.prepare_invoke(ctx.host, %{}, ctx.context, 1_000)

    assert :ok = ProcessHost.abort(ctx.host, ticket)
    assert :ok = ProcessHost.abort(ctx.host, ticket)
    assert EffectDispatcher.snapshot()["reserved"] == 0
    assert {:error, _} = ProcessHost.publish(ctx.host, ticket)
    assert {:ok, ^before} = ProcessHost.snapshot(ctx.host)
  end

  test "publication is owner-only, revision/incarnation-bound and repeatable", ctx do
    {:ok, before} = ProcessHost.snapshot(ctx.host)

    {:ok, outcome, ticket} =
      ProcessHost.prepare_invoke(ctx.host, %{"amount" => 4}, ctx.context, 1_000)

    assert {:error, _} =
             Task.async(fn -> ProcessHost.publish(ctx.host, ticket) end) |> Task.await()

    assert {:error, _} = ProcessHost.publish(ctx.host, %{ticket | state_revision: 99})
    assert {:error, _} = ProcessHost.publish(ctx.host, %{ticket | incarnation: make_ref()})
    assert {:ok, ^before} = ProcessHost.snapshot(ctx.host)
    assert {:ok, ^outcome, :none} = ProcessHost.publish(ctx.host, ticket)
    assert {:ok, ^outcome, :none} = ProcessHost.publish(ctx.host, ticket)
    assert {:ok, %{state_revision: 2}} = ProcessHost.snapshot(ctx.host)
    assert :ok = ProcessHost.abort(ctx.host, ticket)
    assert {:ok, %{state_revision: 2}} = ProcessHost.snapshot(ctx.host)
  end

  test "repeat publication does not execute generated code again", ctx do
    Process.register(self(), __MODULE__)

    host =
      start_supervised!({ProcessHost, %{ctx.opts | artifact: ctx.artifacts["counted"]}},
        id: :counted
      )

    {:ok, _, ticket} = ProcessHost.prepare_invoke(host, %{}, ctx.context, 1_000)
    assert_receive :generated_callback
    assert {:ok, _, :none} = ProcessHost.publish(host, ticket)
    assert {:ok, _, :none} = ProcessHost.publish(host, ticket)
    refute_receive :generated_callback
    assert {:ok, %{data: %{"count" => 1}}} = ProcessHost.snapshot(host)
  end

  test "candidate timeout releases capacity and invalidates late publication", ctx do
    opts = %{ctx.opts | limits: Limits.new(%{operation_timeout_ms: 30})}
    host = start_supervised!({ProcessHost, opts}, id: :expiring)
    {:ok, before} = ProcessHost.snapshot(host)
    {:ok, _, ticket} = ProcessHost.prepare_invoke(host, effect_event(), ctx.context, 1_000)
    Process.sleep(50)
    assert {:ok, ^before} = ProcessHost.snapshot(host)
    assert EffectDispatcher.snapshot()["reserved"] == 0
    assert {:error, _} = ProcessHost.publish(host, ticket)
    {:ok, _, newer} = ProcessHost.prepare_invoke(host, %{}, ctx.context, 1_000)
    assert {:error, _} = ProcessHost.publish(host, ticket)
    assert {:error, _} = ProcessHost.abort(host, ticket)
    assert {:ok, _, :none} = ProcessHost.publish(host, newer)
  end

  test "an expired dispatcher reservation cannot publish candidate state", ctx do
    dispatcher = start_supervised!({EffectDispatcher, name: nil, reservation_timeout_ms: 10})

    host =
      start_supervised!({ProcessHost, %{ctx.opts | dispatcher: dispatcher}}, id: :short_lease)

    {:ok, before} = ProcessHost.snapshot(host)
    {:ok, _, ticket} = ProcessHost.prepare_invoke(host, effect_event(), ctx.context, 1_000)
    Process.sleep(30)
    assert {:error, _} = ProcessHost.publish(host, ticket)
    assert {:ok, ^before} = ProcessHost.snapshot(host)
    assert EffectDispatcher.snapshot(dispatcher)["reserved"] == 0
  end

  test "owner or host death releases reserved capacity", ctx do
    parent = self()

    for death <- [:owner, :host] do
      {owner, owner_ref} =
        spawn_monitor(fn ->
          opts = %{ctx.opts | manager: self()}

          {:ok, host} =
            DynamicSupervisor.start_child(
              ElixirMixir.Runtime.WorkerSupervisor,
              {ProcessHost, opts}
            )

          context = %{ctx.context | manager: self()}
          {:ok, _, _} = ProcessHost.prepare_invoke(host, effect_event(), context, 1_000)
          send(parent, {:prepared, self(), host})

          receive do
            :finish -> :ok
          end
        end)

      assert_receive {:prepared, ^owner, host}
      assert EffectDispatcher.snapshot(EffectDispatcher, owner)["reserved"] == 1
      host_ref = Process.monitor(host)
      if death == :owner, do: send(owner, :finish), else: Process.exit(host, :kill)
      assert_receive {:DOWN, ^host_ref, :process, ^host, _}
      # Dispatcher monitor notification is independent of the host monitor.
      await_released(owner, 100)
      send(owner, :finish)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    end
  end

  test "replacement stays inactive until publish and stale revisions do not migrate", ctx do
    host =
      start_supervised!({ProcessHost, %{ctx.opts | artifact: ctx.artifacts["v1"]}},
        id: :replacement
      )

    {:ok, before} = ProcessHost.snapshot(host)

    {:ok, result, ticket} =
      ProcessHost.prepare_replace(host, ctx.artifacts["v2"], 1, ctx.context, 1_000)

    assert {:ok, ^before} = ProcessHost.snapshot(host)
    assert :ok = ProcessHost.abort(host, ticket)

    assert {:error, %{"code" => "REVISION_CONFLICT"}} =
             ProcessHost.prepare_replace(host, ctx.artifacts["v3"], 2, ctx.context, 1_000)

    {:ok, _, ticket} =
      ProcessHost.prepare_replace(host, ctx.artifacts["v2"], 1, ctx.context, 1_000)

    assert {:ok, ^result, :none} = ProcessHost.publish(host, ticket)
    assert {:ok, %{artifact: artifact, worker_revision: 2}} = ProcessHost.snapshot(host)
    assert artifact == ctx.artifacts["v2"]
    assert result["pid_before"] == result["pid_after"]
  end

  defp effect_event, do: %{"effects" => [%{"type" => "emit", "to" => "peer", "event" => %{}}]}

  defp await_released(_owner, 0), do: flunk("reserved capacity leaked")

  defp await_released(owner, attempts) do
    if EffectDispatcher.snapshot(EffectDispatcher, owner)["reserved"] == 0 do
      :ok
    else
      Process.sleep(5)
      await_released(owner, attempts - 1)
    end
  end
end
