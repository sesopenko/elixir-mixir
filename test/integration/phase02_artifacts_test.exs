defmodule ElixirMixir.Integration.Phase02ArtifactsTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures
  alias ElixirMixir.TestSupport.MCPClient, as: Client
  alias ElixirMixir.TestSupport.RuntimeFixture

  test "HTTP definitions recompile without a client, retain identity/revisions and enforce restored capacity" do
    dir = directory()
    {fixture, client} = runtime(dir, :first, limits: %{artifact_slots: 3})
    first = tool(client, "runtime_define", args("one"))
    second = tool(client, "runtime_define", args("two"))
    before = tool(client, "runtime_inspect", %{})
    records = RuntimeFixture.control(fixture, %{"op" => "durable_records"})
    assert length(records["artifacts"]) == 2
    assert second["revision"] == 2
    Client.close(client)
    RuntimeFixture.kill(fixture)
    {restarted, fresh} = runtime(dir, :second, limits: %{artifact_slots: 3})
    after_boot = tool(fresh, "runtime_inspect", %{})
    assert before["generation"] == after_boot["generation"]
    assert before["recovery"]["lineage_id"] == after_boot["recovery"]["lineage_id"]
    refute before["recovery"]["boot_id"] == after_boot["recovery"]["boot_id"]
    assert after_boot["recovery"]["restored"] == 2
    assert RuntimeFixture.control(restarted, %{"op" => "durable_records"}) == records

    for result <- [first, second] do
      restored =
        RuntimeFixture.control(restarted, %{"op" => "artifact", "id" => result["artifact_id"]})

      assert restored["source"] == args("ignored")["source"]
      assert restored["source_hash"] == result["source_hash"]
      assert restored["revision"] == result["revision"]
    end

    assert tool(fresh, "runtime_define", args("one")) == first
    assert tool(fresh, "runtime_define", args("three"))["revision"] == 3
    assert tool(fresh, "runtime_define", args("four"))["code"] == "LIMIT_EXCEEDED"
  end

  for phase <- ~w(after_admission after_prepare after_commit) do
    @tag phase: phase
    test "SIGKILL at #{phase} reconciles admitted or committed definition", %{phase: phase} do
      dir = directory()
      {fixture, client} = runtime(dir, :first)
      invalid = %{args("bad") | "source" => "invalid"}
      assert tool(client, "runtime_define", invalid)["code"] == "COMPILE_FAILED"
      RuntimeFixture.control(fixture, %{"op" => "durability_barrier", "phase" => phase})

      pending =
        Task.async(fn ->
          try do
            Client.call(client, "runtime_define", args("uncertain"))
          rescue
            MatchError -> :connection_closed
          end
        end)

      await(fn ->
        RuntimeFixture.control(fixture, %{"op" => "barrier_status", "key" => phase})["waiting"]
      end)

      before = RuntimeFixture.control(fixture, %{"op" => "durable_records"})
      assert RuntimeFixture.control(fixture, %{"op" => "registry_status"})["artifacts"] == 0
      committed = phase == "after_commit"
      assert length(before["artifacts"]) == if(committed, do: 1, else: 0)
      Client.disconnect(client)
      assert Task.await(pending) == :connection_closed
      RuntimeFixture.kill(fixture)
      {restarted, fresh} = runtime(dir, :second)
      result = tool(fresh, "runtime_define", args("uncertain"))
      after_boot = RuntimeFixture.control(restarted, %{"op" => "durable_records"})
      assert after_boot["artifacts"] == before["artifacts"]
      assert after_boot["meta"]["generation"] == if(committed, do: 1, else: 0)

      if committed do
        entry = Enum.find(before["requests"], &(&1["id"] == "uncertain"))["record"]
        assert result == entry["outcome"]["data"]

        current =
          RuntimeFixture.control(restarted, %{"op" => "artifact", "id" => result["artifact_id"]})

        refute current["module"] == result["module"]
        assert current["source_hash"] == result["source_hash"]
      else
        assert result["code"] == "OPERATION_INTERRUPTED"
      end

      assert tool(fresh, "runtime_define", %{args("uncertain") | "source" => "different"})["code"] ==
               "REQUEST_ID_CONFLICT"

      assert tool(fresh, "runtime_define", invalid)["code"] == "COMPILE_FAILED"
    end
  end

  test "recovery gates health/reads and quarantines corrupt inactive source without deleting evidence" do
    dir = directory()
    {fixture, client} = runtime(dir, :first)

    source =
      String.replace(Fixtures.source(), "defmodule Generated do", """
      defmodule Generated do
        if Application.compile_env(:elixir_mixir, :test_recovery_pause, false),
          do: ElixirMixir.TestSupport.CallbackBarrier.wait("recovery")
      """)

    healthy = tool(client, "runtime_define", %{args("healthy") | "source" => source})
    assert healthy["artifact_id"], inspect(healthy)
    broken = tool(client, "runtime_define", args("broken"))
    Client.close(client)
    RuntimeFixture.kill(fixture)
    {:ok, db} = CubDB.start_link(data_dir: dir)
    key = {:artifact, broken["artifact_id"]}
    original = CubDB.get(db, key)
    :ok = CubDB.put(db, key, %{original | "source_hash" => "corrupt"})
    GenServer.stop(db)

    restarted =
      start_supervised!({RuntimeFixture, data_dir: dir, pause_recovery: true}, id: :second)

    ready = RuntimeFixture.ready(restarted)
    fresh = Client.new(ready.port)
    on_exit(fn -> Client.close(%{fresh | session: nil}) end)
    {_init, _notification, fresh} = Client.initialize(fresh)

    await(fn ->
      RuntimeFixture.control(restarted, %{"op" => "barrier_status", "key" => "recovery"})[
        "waiting"
      ]
    end)

    assert Client.raw(fresh, :get, "/health").status == 503
    assert tool(fresh, "runtime_inspect", %{})["code"] == "RUNTIME_RECOVERING"
    assert tool(fresh, "runtime_define", args("not-admitted"))["code"] == "RUNTIME_RECOVERING"
    RuntimeFixture.control(restarted, %{"op" => "release_barrier", "key" => "recovery"})
    await(fn -> Client.raw(fresh, :get, "/health").status == 200 end)
    summary = tool(fresh, "runtime_inspect", %{})
    assert summary["recovery"]["quarantined"] == 1
    assert summary["recovery"]["degraded"]
    assert summary["recovery"]["restored"] == 1
    retained = RuntimeFixture.control(restarted, %{"op" => "durable_records"})

    assert Enum.find(retained["artifacts"], &(&1["id"] == broken["artifact_id"]))["record"][
             "source_hash"
           ] == "corrupt"

    refute Enum.any?(retained["requests"], &(&1["id"] == "not-admitted"))

    assert RuntimeFixture.control(restarted, %{"op" => "artifact", "id" => healthy["artifact_id"]})[
             "source_hash"
           ] == healthy["source_hash"]

    assert tool(fresh, "runtime_define", args("next"))["revision"] == 3
  end

  test "retention expires across downtime and request capacity survives restart" do
    dir = directory()

    {fixture, client} =
      runtime(dir, :first, limits: %{ledger_entries: 1, ledger_retention_ms: 1_000})

    first = tool(client, "runtime_define", args("same"))
    assert tool(client, "runtime_define", args("busy"))["code"] == "BUSY"
    Client.close(client)
    RuntimeFixture.kill(fixture)
    Process.sleep(1_050)

    {_restarted, fresh} =
      runtime(dir, :second, limits: %{ledger_entries: 1, ledger_retention_ms: 1_000})

    next = tool(fresh, "runtime_define", args("same"))
    refute next["artifact_id"] == first["artifact_id"]
    assert next["revision"] == 2
  end

  defp directory do
    dir =
      RuntimeFixture.temp_path("mixir-artifact-http")

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp runtime(dir, id, opts \\ []) do
    fixture = start_supervised!({RuntimeFixture, Keyword.put(opts, :data_dir, dir)}, id: id)
    ready = RuntimeFixture.ready(fixture)
    client = Client.new(ready.port)
    on_exit(fn -> Client.close(%{client | session: nil}) end)
    await(fn -> Client.raw(client, :get, "/health").status == 200 end)
    {_init, _notification, client} = Client.initialize(client)
    {fixture, client}
  end

  defp args(id),
    do: %{
      "request_id" => id,
      "logical_name" => "retained",
      "source" => Fixtures.source(),
      "expected_behavior" => "elixir_mixir.behavior.v1"
    }

  defp tool(client, name, args) do
    {response, _} = Client.call(client, name, args)
    assert response.status == 200
    response.data["result"]["structuredContent"]
  end

  defp await(check, attempts \\ 300)
  defp await(_check, 0), do: flunk("recovery or barrier did not settle")

  defp await(check, attempts) do
    unless check.() do
      Process.sleep(5)
      await(check, attempts - 1)
    end
  end
end
