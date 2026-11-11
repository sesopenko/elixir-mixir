defmodule ElixirMixir.Integration.Phase02TransitionsTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures
  alias ElixirMixir.TestSupport.MCPClient, as: Client
  alias ElixirMixir.TestSupport.RuntimeFixture

  for phase <- ~w(before_commit after_commit before_publish before_response) do
    @tag phase: phase
    test "SIGKILL at #{phase} keeps state and its exact outcome in the same commit", %{
      phase: phase
    } do
      dir = directory()
      {fixture, client} = runtime(dir, :first)
      setup_counter(client)
      assert tool(client, "runtime_invoke", args("first", 2))["reply"] == 2
      RuntimeFixture.control(fixture, %{"op" => "durability_barrier", "phase" => phase})
      pending = uncertain_call(client, args("uncertain", 5))
      await_barrier(fixture, phase)
      records = RuntimeFixture.control(fixture, %{"op" => "durable_records"})
      committed = phase != "before_commit"
      expected = if committed, do: 7, else: 2
      assert hd(records["states"])["record"]["data"] == %{"count" => expected}
      live = RuntimeFixture.control(fixture, %{"op" => "host_state", "id" => "counter"})
      assert live["state"]["count"] == if(phase == "before_response", do: 7, else: 2)
      Client.disconnect(client)
      assert Task.await(pending) == :connection_closed
      RuntimeFixture.kill(fixture)
      {restarted, fresh} = runtime(dir, :second)
      after_boot = RuntimeFixture.control(restarted, %{"op" => "durable_records"})
      assert after_boot["states"] == records["states"]
      assert after_boot["workers"] == records["workers"]
      result = tool(fresh, "runtime_invoke", args("uncertain", 5))

      if committed do
        original =
          Enum.find(records["requests"], &(&1["id"] == "uncertain"))["record"]["outcome"]["data"]

        assert result == original
        assert result["reply"] == 7
        assert result["state_revision"] == 3
      else
        assert result["code"] == "OPERATION_INTERRUPTED"
      end

      assert inspect_worker(fresh)["state"] == %{"count" => expected}
      assert tool(fresh, "runtime_invoke", args("continued", 1))["reply"] == expected + 1
    end
  end

  for mode <- ~w(raise_before_commit timeout_after_commit) do
    @tag fault: mode
    test "#{mode} closes authority and restart reads the actual stored outcome", %{fault: mode} do
      dir = directory()
      {fixture, client} = runtime(dir, :first)
      setup_counter(client)
      RuntimeFixture.control(fixture, %{"op" => "store_fault", "mode" => mode})
      pending = uncertain_call(client, args("faulty", 9))

      await(
        fn ->
          RuntimeFixture.control(fixture, %{"op" => "runtime_status"})["manager_alive"] == false
        end,
        1_600
      )

      assert RuntimeFixture.control(fixture, %{"op" => "runtime_status"})["ready"] == false
      Task.await(pending, 12_000)
      Client.disconnect(client)
      RuntimeFixture.kill(fixture)
      {restarted, fresh} = runtime(dir, :second)
      result = tool(fresh, "runtime_invoke", args("faulty", 9))
      records = RuntimeFixture.control(restarted, %{"op" => "durable_records"})

      if mode == "timeout_after_commit" do
        assert result["reply"] == 9
        assert result["generation"] == 3
        assert hd(records["states"])["record"]["data"] == %{"count" => 9}
        entry = Enum.find(records["requests"], &(&1["id"] == "faulty"))["record"]
        assert entry["outcome"]["status"] == "ok"
      else
        assert result["code"] == "OPERATION_INTERRUPTED"
        assert hd(records["states"])["record"]["data"] == %{"count" => 0}
        assert records["meta"]["generation"] == 2
      end
    end
  end

  test "host death after a known commit closes authority without overwriting durable success" do
    dir = directory()
    {fixture, client} = runtime(dir, :first)
    setup_counter(client)
    RuntimeFixture.control(fixture, %{"op" => "durability_barrier", "phase" => "after_commit"})
    pending = uncertain_call(client, args("published-later", 13))
    await_barrier(fixture, "after_commit")
    before = RuntimeFixture.control(fixture, %{"op" => "durable_records"})
    assert hd(before["states"])["record"]["data"] == %{"count" => 13}
    RuntimeFixture.control(fixture, %{"op" => "kill_host", "id" => "counter"})
    RuntimeFixture.control(fixture, %{"op" => "release_barrier", "key" => "after_commit"})

    await(fn ->
      RuntimeFixture.control(fixture, %{"op" => "runtime_status"})["manager_alive"] == false
    end)

    Task.await(pending, 12_000)
    Client.disconnect(client)
    RuntimeFixture.kill(fixture)
    {restarted, fresh} = runtime(dir, :second)
    result = tool(fresh, "runtime_invoke", args("published-later", 13))
    assert result["reply"] == 13
    assert result["state_revision"] == 2
    assert inspect_worker(fresh)["state"] == %{"count" => 13}
    after_boot = RuntimeFixture.control(restarted, %{"op" => "durable_records"})
    assert after_boot["states"] == before["states"]
    assert after_boot["requests"] == before["requests"]
  end

  test "HTTP failures and unsupported effects preserve committed state and peer health" do
    dir = directory()
    {fixture, client} = runtime(dir, :first)
    artifact = setup_counter(client)

    tool(client, "runtime_start", %{
      "worker_id" => "peer",
      "artifact_id" => artifact["artifact_id"],
      "config" => %{},
      "request_id" => "start-peer"
    })

    for mode <- ~w(error raise exit timeout invalid_state state_non_json reply_non_json) do
      result =
        tool(client, "runtime_invoke", %{
          "worker_id" => "counter",
          "event" => %{"mode" => mode},
          "request_id" => mode
        })

      assert result["code"]
      assert inspect_worker(client)["state"] == %{"count" => 0}
    end

    effects =
      tool(client, "runtime_define", %{
        "logical_name" => "effects",
        "source" => Fixtures.effects_source(),
        "expected_behavior" => "elixir_mixir.behavior.v1",
        "request_id" => "define-effects"
      })

    tool(client, "runtime_start", %{
      "worker_id" => "sender",
      "artifact_id" => effects["artifact_id"],
      "config" => %{"forward" => "peer"},
      "request_id" => "start-sender"
    })

    assert tool(client, "runtime_invoke", %{
             "worker_id" => "sender",
             "event" => %{},
             "request_id" => "blocked-effect"
           })["code"] == "DURABILITY_UNAVAILABLE"

    assert tool(client, "runtime_inspect", %{"worker_id" => "peer", "detail" => "state"})["state"][
             "count"
           ] == 0

    assert RuntimeFixture.control(fixture, %{"op" => "dispatcher_status"})["pending"] == 0
    assert tool(client, "runtime_invoke", args("healthy", 3))["reply"] == 3
    RuntimeFixture.control(fixture, %{"op" => "kill_host", "id" => "counter"})

    await(fn ->
      data = inspect_worker(client)
      data["status"] == "running" and data["state"]["count"] == 3
    end)

    assert tool(client, "runtime_invoke", args("continued", 1))["reply"] == 4
  end

  defp setup_counter(client) do
    artifact =
      tool(client, "runtime_define", %{
        "logical_name" => "counter",
        "source" => Fixtures.counter_source(),
        "expected_behavior" => "elixir_mixir.behavior.v1",
        "request_id" => "define"
      })

    assert tool(client, "runtime_start", %{
             "worker_id" => "counter",
             "artifact_id" => artifact["artifact_id"],
             "config" => %{},
             "request_id" => "start"
           })["status"] == "running"

    artifact
  end

  defp directory do
    dir = Path.join(System.tmp_dir!(), "mixir-events-http-#{System.unique_integer([:positive])}")
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

  defp uncertain_call(client, arguments) do
    Task.async(fn ->
      try do
        Client.call(client, "runtime_invoke", arguments)
      rescue
        MatchError -> :connection_closed
      end
    end)
  end

  defp args(id, amount),
    do: %{"worker_id" => "counter", "event" => %{"amount" => amount}, "request_id" => id}

  defp inspect_worker(client),
    do: tool(client, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"})

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
