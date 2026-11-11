defmodule ElixirMixir.Integration.Phase02OutboxTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures
  alias ElixirMixir.TestSupport.MCPClient, as: Client
  alias ElixirMixir.TestSupport.RuntimeFixture

  for phase <- ~w(before_commit after_commit before_response) do
    @tag phase: phase
    test "SIGKILL at #{phase} retains all intents with their state or neither", %{phase: phase} do
      dir = directory()
      {fixture, client} = runtime(dir, :first)
      setup_workers(client)
      RuntimeFixture.control(fixture, %{"op" => "durability_barrier", "phase" => phase})

      arguments = %{
        "worker_id" => "sender",
        "event" => %{"effects" => batch()},
        "request_id" => "batch"
      }

      pending = uncertain_call(client, "runtime_invoke", arguments)
      await_barrier(fixture, phase)
      records = RuntimeFixture.control(fixture, %{"op" => "durable_records"})
      committed = phase != "before_commit"
      assert length(records["effects"]) == if(committed, do: 3, else: 0)
      state = Enum.find(records["states"], &(&1["id"] == "sender"))["record"]["data"]
      assert state["count"] == if(committed, do: 1, else: 0)
      assert_paused(fixture)
      Client.disconnect(client)
      assert Task.await(pending) == :connection_closed
      RuntimeFixture.kill(fixture)
      {restarted, fresh} = runtime(dir, :second)
      recovered = RuntimeFixture.control(restarted, %{"op" => "durable_records"})
      assert recovered["effects"] == records["effects"]
      assert recovered["states"] == records["states"]
      stats = RuntimeFixture.control(restarted, %{"op" => "dispatcher_status"})
      assert stats["reserved"] == 0
      assert stats["pending"] == length(records["effects"])
      assert stats["timers"] == if(committed, do: 1, else: 0)
      assert tool(fresh, "runtime_inspect", %{})["effects"]["dispatch"] == "paused"
      result = tool(fresh, "runtime_invoke", arguments)

      if committed,
        do: assert(result["reply"] == 1),
        else: assert(result["code"] == "OPERATION_INTERRUPTED")

      assert RuntimeFixture.control(restarted, %{"op" => "durable_records"})["effects"] ==
               records["effects"]

      assert_paused(restarted)
    end

    @tag phase: phase
    test "SIGKILL at #{phase} makes source stop and cancellation atomic", %{phase: phase} do
      dir = directory()
      {fixture, client} = runtime(dir, :first)
      setup_workers(client)

      assert tool(client, "runtime_invoke", %{
               "worker_id" => "sender",
               "event" => %{"effects" => batch()},
               "request_id" => "batch"
             })["reply"] == 1

      original = RuntimeFixture.control(fixture, %{"op" => "durable_records"})["effects"]
      RuntimeFixture.control(fixture, %{"op" => "durability_barrier", "phase" => phase})

      pending =
        uncertain_call(client, "runtime_stop", %{"worker_id" => "sender", "request_id" => "stop"})

      await_barrier(fixture, phase)
      Client.disconnect(client)
      assert Task.await(pending) == :connection_closed
      RuntimeFixture.kill(fixture)
      {restarted, _fresh} = runtime(dir, :second)
      records = RuntimeFixture.control(restarted, %{"op" => "durable_records"})
      worker = Enum.find(records["workers"], &(&1["id"] == "sender"))["record"]

      if phase == "before_commit" do
        assert records["effects"] == original
        assert worker["desired_status"] == "running"
      else
        assert records["effects"] == []
        assert worker["desired_status"] == "stopped"
      end

      assert_paused(restarted)
    end
  end

  defp assert_paused(fixture) do
    assert RuntimeFixture.control(fixture, %{"op" => "host_state", "id" => "peer"})["state"][
             "count"
           ] == 0

    events = RuntimeFixture.control(fixture, %{"op" => "events"})
    refute Enum.any?(events["events"], &(&1["type"] == "effect_log"))
  end

  defp setup_workers(client) do
    artifact =
      tool(client, "runtime_define", %{
        "logical_name" => "effects",
        "source" => Fixtures.effects_source(),
        "expected_behavior" => "elixir_mixir.behavior.v1",
        "request_id" => "define"
      })

    for id <- ~w(sender peer) do
      assert tool(client, "runtime_start", %{
               "worker_id" => id,
               "artifact_id" => artifact["artifact_id"],
               "config" => %{},
               "request_id" => "start-" <> id
             })["status"] == "running"
    end
  end

  defp batch,
    do: [
      %{"type" => "emit", "to" => "peer", "event" => %{}},
      %{"type" => "schedule", "to" => "peer", "event" => %{}, "delay_ms" => 1},
      %{"type" => "log", "level" => "info", "message" => "must stay paused", "metadata" => %{}}
    ]

  defp directory do
    dir = Path.join(System.tmp_dir!(), "mixir-outbox-http-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp runtime(dir, id) do
    fixture = start_supervised!({RuntimeFixture, data_dir: dir}, id: id)
    ready = RuntimeFixture.ready(fixture)
    client = Client.new(ready.port)
    on_exit(fn -> Client.close(%{client | session: nil}) end)
    await(fn -> Client.raw(client, :get, "/health").status == 200 end)
    {_init, _notification, client} = Client.initialize(client)
    {fixture, client}
  end

  defp uncertain_call(client, name, arguments) do
    Task.async(fn ->
      try do
        Client.call(client, name, arguments)
      rescue
        MatchError -> :connection_closed
      end
    end)
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
