defmodule ElixirMixir.Integration.Phase02DeliveryTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures
  alias ElixirMixir.TestSupport.MCPClient, as: Client
  alias ElixirMixir.TestSupport.RuntimeFixture

  for phase <- ~w(delivery_before_commit delivery_after_commit delivery_after_publish) do
    @tag phase: phase
    test "SIGKILL at #{phase} consumes parent, target state, edge and children once", %{
      phase: phase
    } do
      dir = directory()
      {fixture, client} = runtime(dir, :first)
      setup_workers(client)
      RuntimeFixture.control(fixture, %{"op" => "durability_barrier", "phase" => phase})
      child = emit("leaf", %{"amount" => 9})

      result =
        tool(
          client,
          "runtime_invoke",
          invoke_args([emit("peer", %{"amount" => 5, "effects" => [child]})])
        )

      parent = hd(result["effects"])["effect_id"]
      await_barrier(fixture, phase)
      before = records(fixture)
      committed = phase != "delivery_before_commit"
      assert state(before, "peer")["count"] == if(committed, do: 1, else: 0)
      assert Enum.any?(before["effects"], &(&1["id"] == parent)) == not committed
      assert length(before["effects"]) == 1

      if committed do
        assert hd(before["effects"])["record"]["path"] == [1, 1]

        assert before["edges"] == [
                 %{"source" => "sender", "target" => "peer", "record" => %{"count" => 1}}
               ]
      else
        assert before["edges"] == []
      end

      live = RuntimeFixture.control(fixture, %{"op" => "host_state", "id" => "peer"})
      assert live["state"]["count"] == if(phase == "delivery_after_publish", do: 1, else: 0)
      Client.disconnect(client)
      RuntimeFixture.kill(fixture)
      {restarted, fresh} = runtime(dir, :second, limits: %{ledger_retention_ms: 1})
      await(fn -> state(records(restarted), "leaf")["count"] == 1 end)
      after_boot = records(restarted)
      assert state(after_boot, "peer")["total"] == 5
      assert state(after_boot, "leaf")["total"] == 9
      assert after_boot["effects"] == []

      assert Enum.sort(after_boot["edges"]) ==
               Enum.sort([
                 %{"source" => "sender", "target" => "peer", "record" => %{"count" => 1}},
                 %{"source" => "peer", "target" => "leaf", "record" => %{"count" => 1}}
               ])

      # Even a corrupt volatile claim and duplicate wakeup cannot recreate a consumed ID.
      RuntimeFixture.control(restarted, %{"op" => "duplicate_delivery", "id" => parent})
      assert records(restarted) == after_boot
      summary = tool(fresh, "runtime_inspect", %{})
      assert summary["edge_count"] == 2
      assert summary["effects"]["pending"] == 0

      assert tool(fresh, "runtime_invoke", %{
               "worker_id" => "peer",
               "event" => %{"amount" => 2},
               "request_id" => "continued"
             })["reply"] == 2

      assert state(records(restarted), "peer")["total"] == 7
    end
  end

  test "future and overdue schedules recover without a client and retain UTC deadlines" do
    dir = directory()
    {fixture, client} = runtime(dir, :first, pause_delivery: true)
    setup_workers(client)

    effects = [
      %{"type" => "schedule", "to" => "peer", "event" => %{"amount" => 3}, "delay_ms" => 1},
      %{"type" => "schedule", "to" => "peer", "event" => %{"amount" => 7}, "delay_ms" => 60_000}
    ]

    tool(client, "runtime_invoke", invoke_args(effects))
    before = records(fixture)
    future = Enum.max_by(before["effects"], & &1["record"]["due_at"])
    Client.disconnect(client)
    RuntimeFixture.kill(fixture)
    restarted = start_supervised!({RuntimeFixture, data_dir: dir}, id: :second)
    RuntimeFixture.ready(restarted)
    await(fn -> RuntimeFixture.control(restarted, %{"op" => "runtime_status"})["ready"] end)
    await(fn -> state(records(restarted), "peer")["count"] == 1 end)
    assert records(restarted)["effects"] == [future]
    assert state(records(restarted), "peer")["total"] == 3

    RuntimeFixture.control(restarted, %{"op" => "delivery_clock_offset", "milliseconds" => 60_001})

    await(fn -> state(records(restarted), "peer")["count"] == 2 end)
    assert records(restarted)["effects"] == []
    assert state(records(restarted), "peer")["total"] == 10
  end

  test "a crash after log output but before completion repeats the external log intent" do
    dir = directory()
    {fixture, client} = runtime(dir, :first)
    setup_workers(client)

    RuntimeFixture.control(fixture, %{
      "op" => "durability_barrier",
      "phase" => "delivery_after_log"
    })

    log = %{
      "type" => "log",
      "level" => "warning",
      "message" => "at least once proof",
      "metadata" => %{}
    }

    result = tool(client, "runtime_invoke", invoke_args([log]))
    id = hd(result["effects"])["effect_id"]
    await_barrier(fixture, "delivery_after_log")
    assert length(records(fixture)["effects"]) == 1
    assert log_count(fixture, id) == 1
    Client.disconnect(client)
    RuntimeFixture.kill(fixture)
    {restarted, fresh} = runtime(dir, :second)
    await(fn -> records(restarted)["effects"] == [] end)
    assert log_count(restarted, id) == 1
    assert state(records(restarted), "sender")["count"] == 1
    assert tool(fresh, "runtime_invoke", invoke_args([log])) == result
    assert log_count(restarted, id) == 1
  end

  for mode <- ~w(raise_before_commit timeout_after_commit) do
    @tag fault: mode
    test "#{mode} during delivery closes authority and recovery reads the actual commit", %{
      fault: mode
    } do
      dir = directory()
      {fixture, client} = runtime(dir, :first, pause_delivery: true)
      setup_workers(client)
      tool(client, "runtime_invoke", invoke_args([emit("peer", %{"amount" => 4})]))
      RuntimeFixture.control(fixture, %{"op" => "store_fault", "mode" => mode})
      RuntimeFixture.control(fixture, %{"op" => "resume_delivery"})

      if mode == "timeout_after_commit" do
        await(fn -> state(records(fixture), "peer")["count"] == 1 end)
        assert records(fixture)["effects"] == []
      end

      await(
        fn ->
          not RuntimeFixture.control(fixture, %{"op" => "runtime_status"})["manager_alive"]
        end,
        1_600
      )

      Client.disconnect(client)
      RuntimeFixture.kill(fixture)
      {restarted, _fresh} = runtime(dir, :second)
      await(fn -> state(records(restarted), "peer")["count"] == 1 end)
      assert records(restarted)["effects"] == []
      assert state(records(restarted), "peer")["total"] == 4
      assert length(records(restarted)["edges"]) == 1
    end
  end

  defp setup_workers(client) do
    artifact =
      tool(client, "runtime_define", %{
        "logical_name" => "effects",
        "source" => Fixtures.effects_source(),
        "expected_behavior" => "elixir_mixir.behavior.v1",
        "request_id" => "define"
      })

    for id <- ~w(sender peer leaf),
        do:
          tool(client, "runtime_start", %{
            "worker_id" => id,
            "artifact_id" => artifact["artifact_id"],
            "config" => %{},
            "request_id" => "start-" <> id
          })
  end

  defp records(fixture), do: RuntimeFixture.control(fixture, %{"op" => "durable_records"})
  defp state(records, id), do: Enum.find(records["states"], &(&1["id"] == id))["record"]["data"]
  defp emit(target, event), do: %{"type" => "emit", "to" => target, "event" => event}

  defp invoke_args(effects),
    do: %{"worker_id" => "sender", "event" => %{"effects" => effects}, "request_id" => "origin"}

  defp log_count(fixture, id) do
    RuntimeFixture.control(fixture, %{"op" => "events"})["events"]
    |> Enum.count(&(&1["type"] == "effect_log" and &1["effect_id"] == id))
  end

  defp directory do
    dir =
      Path.join(System.tmp_dir!(), "mixir-delivery-http-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp runtime(dir, id, opts \\ []) do
    fixture = start_supervised!({RuntimeFixture, [data_dir: dir] ++ opts}, id: id)
    ready = RuntimeFixture.ready(fixture)
    client = Client.new(ready.port)
    on_exit(fn -> Client.close(%{client | session: nil}) end)
    await(fn -> Client.raw(client, :get, "/health").status == 200 end)
    {_init, _notification, client} = Client.initialize(client)
    {fixture, client}
  end

  defp tool(client, name, args) do
    {response, _} = Client.call(client, name, args)
    assert response.status == 200
    response.data["result"]["structuredContent"]
  end

  defp await_barrier(fixture, phase),
    do:
      await(fn ->
        RuntimeFixture.control(fixture, %{"op" => "barrier_status", "key" => phase})["waiting"]
      end)

  defp await(check, attempts \\ 400)
  defp await(_check, 0), do: flunk("durable event scenario did not settle")

  defp await(check, attempts) do
    unless check.() do
      Process.sleep(5)
      await(check, attempts - 1)
    end
  end
end
