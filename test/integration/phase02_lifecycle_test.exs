defmodule ElixirMixir.Integration.Phase02LifecycleTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures
  alias ElixirMixir.TestSupport.MCPClient, as: Client
  alias ElixirMixir.TestSupport.RuntimeFixture

  test "linked desired definitions and initial state recover without init, migration or a client" do
    dir = directory()
    {fixture, ready} = boot(dir, :first)
    client = connect(ready.port)

    source =
      Fixtures.source(
        init:
          ~S|path = config["path"]; if File.exists?(path), do: raise("init repeated"); File.write!(path, "initialized"); {:ok, %{"count" => config["initial"], "peer" => config["peer"]}}|,
        migrate: ~S|raise "migration must not run"|
      )

    artifact = define(client, source)

    for {id, initial, peer} <- [
          {"source", 7, "peer"},
          {"peer", 11, "source"},
          {"stopped", 19, "source"}
        ] do
      result =
        start(client, artifact, id, %{
          "initial" => initial,
          "peer" => peer,
          "path" => Path.join(dir, "init-#{id}")
        })

      assert result["status"] == "running"
    end

    stopped = tool(client, "runtime_stop", %{"worker_id" => "stopped", "request_id" => "stop"})
    before = tool(client, "runtime_inspect", %{"detail" => "state"})
    records = RuntimeFixture.control(fixture, %{"op" => "durable_records"})
    Client.close(client)
    RuntimeFixture.kill(fixture)
    {restarted, next} = boot(dir, :second)
    refute ready.os_pid == next.os_pid
    # Recovery has completed with only health and stdin observations, no MCP session.
    assert RuntimeFixture.control(restarted, %{"op" => "durable_records"}) == records

    for id <- ["source", "peer"] do
      assert %{"registered" => true, "supervised" => true} =
               RuntimeFixture.control(restarted, %{"op" => "worker_membership", "id" => id})

      assert File.read!(Path.join(dir, "init-#{id}")) == "initialized"
    end

    assert RuntimeFixture.control(restarted, %{"op" => "worker_membership", "id" => "stopped"})[
             "registered"
           ] == false

    fresh = connect(next.port)
    restored = tool(fresh, "runtime_inspect", %{"detail" => "state"})
    assert restored["generation"] == before["generation"]
    assert restored["recovery"]["lineage_id"] == before["recovery"]["lineage_id"]
    refute restored["recovery"]["boot_id"] == before["recovery"]["boot_id"]
    assert restored["recovery"]["workers_restored"] == 2

    for old <- before["workers"] do
      current = Enum.find(restored["workers"], &(&1["worker_id"] == old["worker_id"]))

      for key <-
            ~w(worker_id artifact_id config desired_status state state_revision worker_revision status) do
        assert current[key] == old[key]
      end
    end

    assert tool(fresh, "runtime_stop", %{"worker_id" => "stopped", "request_id" => "stop"}) ==
             stopped

    result =
      start(
        fresh,
        artifact,
        "stopped",
        %{"initial" => 42, "peer" => "source", "path" => Path.join(dir, "new-init")},
        "manual"
      )

    assert result["worker_revision"] == 3
    assert result["state_revision"] == 2
    assert inspect_worker(fresh, "stopped")["state"]["count"] == 42

    assert tool(fresh, "runtime_invoke", %{
             "worker_id" => "source",
             "event" => %{},
             "request_id" => "gated"
           })["code"] == "DURABILITY_UNAVAILABLE"
  end

  for operation <- ~w(start stop), phase <- ~w(after_admission after_prepare after_commit) do
    @tag operation: operation, phase: phase
    test "SIGKILL #{operation} at #{phase} restores one complete desired definition", %{
      operation: operation,
      phase: phase
    } do
      dir = directory()
      {fixture, ready} = boot(dir, :first)
      client = connect(ready.port)
      artifact = define(client, Fixtures.source())
      if operation == "stop", do: start(client, artifact, "target", %{"count" => 5})
      RuntimeFixture.control(fixture, %{"op" => "durability_barrier", "phase" => phase})

      args =
        if operation == "start",
          do: start_args(artifact, "target", %{"count" => 5}, "uncertain"),
          else: %{"worker_id" => "target", "request_id" => "uncertain"}

      pending =
        Task.async(fn ->
          try do
            Client.call(client, "runtime_#{operation}", args)
          rescue
            MatchError -> :connection_closed
          end
        end)

      await(fn ->
        RuntimeFixture.control(fixture, %{"op" => "barrier_status", "key" => phase})["waiting"]
      end)

      records = RuntimeFixture.control(fixture, %{"op" => "durable_records"})
      committed = phase == "after_commit"
      expected = if operation == "stop", do: "stopped", else: "running"

      if operation == "start" do
        assert RuntimeFixture.control(fixture, %{"op" => "worker_membership", "id" => "target"})[
                 "registered"
               ] == false

        assert length(records["workers"]) == if(committed, do: 1, else: 0)
        assert length(records["states"]) == if(committed, do: 1, else: 0)
      else
        assert RuntimeFixture.control(fixture, %{"op" => "worker_membership", "id" => "target"})[
                 "registered"
               ]

        assert hd(records["workers"])["record"]["desired_status"] ==
                 if(committed, do: "stopped", else: "running")
      end

      Client.disconnect(client)
      assert Task.await(pending) == :connection_closed
      RuntimeFixture.kill(fixture)
      {restarted, next} = boot(dir, :second)
      fresh = connect(next.port)
      after_boot = RuntimeFixture.control(restarted, %{"op" => "durable_records"})
      assert after_boot["workers"] == records["workers"]
      assert after_boot["states"] == records["states"]
      assert after_boot["meta"] == records["meta"]
      result = tool(fresh, "runtime_#{operation}", args)

      if committed do
        original =
          Enum.find(records["requests"], &(&1["id"] == "uncertain"))["record"]["outcome"]["data"]

        assert result == original
        assert inspect_worker(fresh, "target")["status"] == expected
      else
        assert result["code"] == "OPERATION_INTERRUPTED"
      end
    end
  end

  test "readiness remains closed until desired hosts are reconstructed and routed" do
    dir = directory()
    {fixture, ready} = boot(dir, :first)
    client = connect(ready.port)

    source =
      Fixtures.source(
        body:
          ~S|if Application.compile_env(:elixir_mixir, :test_recovery_pause, false), do: ElixirMixir.TestSupport.CallbackBarrier.wait("recovery")|
      )

    artifact = define(client, source)
    for id <- ["one", "two"], do: start(client, artifact, id, %{"count" => 5})
    Client.close(client)
    RuntimeFixture.kill(fixture)

    restarted =
      start_supervised!({RuntimeFixture, data_dir: dir, pause_recovery: true}, id: :second)

    next = RuntimeFixture.ready(restarted)
    fresh = connect(next.port)

    await(fn ->
      RuntimeFixture.control(restarted, %{"op" => "barrier_status", "key" => "recovery"})[
        "waiting"
      ]
    end)

    assert Client.raw(fresh, :get, "/health").status == 503
    assert tool(fresh, "runtime_inspect", %{})["code"] == "RUNTIME_RECOVERING"

    for id <- ["one", "two"] do
      refute RuntimeFixture.control(restarted, %{"op" => "worker_membership", "id" => id})[
               "registered"
             ]
    end

    RuntimeFixture.control(restarted, %{"op" => "restoration_barrier"})
    RuntimeFixture.control(restarted, %{"op" => "release_barrier", "key" => "recovery"})

    await(fn ->
      RuntimeFixture.control(restarted, %{"op" => "barrier_status", "key" => "restoration"})[
        "waiting"
      ]
    end)

    pending = Task.async(fn -> tool(fresh, "runtime_inspect", %{}) end)
    observed = Task.yield(pending, 1_000)
    assert Client.raw(fresh, :get, "/health").status == 503

    rejected =
      tool(fresh, "runtime_start", start_args(artifact, "during-restore", %{}, "not-admitted"))

    assert rejected["code"] == "RUNTIME_RECOVERING"
    RuntimeFixture.control(restarted, %{"op" => "release_barrier", "key" => "restoration"})
    if observed == nil, do: Task.await(pending)
    assert {:ok, %{"code" => "RUNTIME_RECOVERING"}} = observed
    await(fn -> Client.raw(fresh, :get, "/health").status == 200 end)
    assert tool(fresh, "runtime_inspect", %{})["worker_count"] == 2
    records = RuntimeFixture.control(restarted, %{"op" => "durable_records"})
    refute Enum.any?(records["requests"], &(&1["id"] == "not-admitted"))

    for id <- ["one", "two"] do
      assert RuntimeFixture.control(restarted, %{"op" => "worker_membership", "id" => id})[
               "registered"
             ]

      assert inspect_worker(fresh, id)["status"] == "running"
    end
  end

  test "failed restart budget survives VM death and manual start resets it" do
    dir = directory()
    {fixture, ready} = boot(dir, :first)
    client = connect(ready.port)
    artifact = define(client, Fixtures.source())
    start(client, artifact, "target", %{"count" => 5})
    RuntimeFixture.control(fixture, %{"op" => "recovery_failure", "enabled" => true})
    RuntimeFixture.control(fixture, %{"op" => "kill_host", "id" => "target"})
    await(fn -> inspect_worker(client, "target")["status"] == "failed" end)
    assert inspect_worker(client, "target")["restart_count"] == 3
    before = RuntimeFixture.control(fixture, %{"op" => "durable_records"})
    Client.close(client)
    RuntimeFixture.kill(fixture)
    {restarted, next} = boot(dir, :second)
    assert RuntimeFixture.control(restarted, %{"op" => "durable_records"}) == before
    fresh = connect(next.port)
    assert inspect_worker(fresh, "target")["status"] == "failed"
    assert inspect_worker(fresh, "target")["restart_count"] == 3

    assert tool(
             fresh,
             "runtime_start",
             start_args(artifact, "target", %{"count" => 6}, "changed")
           )["code"] == "INVALID_ARGUMENT"

    assert start(fresh, artifact, "target", %{"count" => 5}, "manual")["restart_count"] == 0
  end

  for corruption <- ~w(schema reference) do
    @tag corruption: corruption
    test "#{corruption} corruption quarantines one worker while the healthy graph recovers", %{
      corruption: corruption
    } do
      dir = directory()
      {fixture, ready} = boot(dir, :first)
      client = connect(ready.port)
      marker = Path.join(dir, "migration-called")

      artifact =
        define(
          client,
          Fixtures.source(migrate: ~S|File.write!(state["marker"], "called"); {:ok, state}|)
        )

      for id <- ["broken", "healthy"],
          do: start(client, artifact, id, %{"count" => 3, "marker" => marker})

      Client.close(client)
      RuntimeFixture.kill(fixture)
      {:ok, db} = CubDB.start_link(data_dir: dir)

      if corruption == "schema" do
        checkpoint = CubDB.get(db, {:state, "broken"})
        :ok = CubDB.put(db, {:state, "broken"}, %{checkpoint | "schema" => 999})
      else
        worker = CubDB.get(db, {:worker, "broken"})
        :ok = CubDB.put(db, {:worker, "broken"}, %{worker | "artifact_id" => "missing"})
      end

      GenServer.stop(db)
      {restarted, next} = boot(dir, :second)
      fresh = connect(next.port)
      assert inspect_worker(fresh, "broken")["status"] == "quarantined"
      assert inspect_worker(fresh, "healthy")["status"] == "running"
      assert inspect_worker(fresh, "healthy")["state"]["count"] == 3
      refute File.exists?(marker)
      summary = tool(fresh, "runtime_inspect", %{})
      assert summary["recovery"]["degraded"]
      assert summary["recovery"]["workers_quarantined"] == 1
      records = RuntimeFixture.control(restarted, %{"op" => "durable_records"})

      if corruption == "schema" do
        assert Enum.find(records["states"], &(&1["id"] == "broken"))["record"]["schema"] == 999
      else
        assert Enum.find(records["workers"], &(&1["id"] == "broken"))["record"]["artifact_id"] ==
                 "missing"

        assert inspect_worker(fresh, "broken")["artifact_unavailable"]
        assert inspect_worker(fresh, "broken")["implementation_version"] == nil
      end

      tool(fresh, "runtime_stop", %{"worker_id" => "broken", "request_id" => "repair-stop"})

      assert start(fresh, artifact, "broken", %{"count" => 10}, "repair-start")["status"] ==
               "running"
    end
  end

  defp directory do
    dir = Path.join(System.tmp_dir!(), "mixir-life-http-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp boot(dir, id) do
    fixture = start_supervised!({RuntimeFixture, data_dir: dir}, id: id)
    ready = RuntimeFixture.ready(fixture)
    probe = Client.new(ready.port)
    on_exit(fn -> Client.close(probe) end)
    await(fn -> Client.raw(probe, :get, "/health").status == 200 end)
    Client.close(probe)
    {fixture, ready}
  end

  defp connect(port) do
    client = Client.new(port)
    {_init, _notification, client} = Client.initialize(client)
    on_exit(fn -> Client.close(%{client | session: nil}) end)
    client
  end

  defp define(client, source),
    do:
      tool(client, "runtime_define", %{
        "logical_name" => "lifecycle",
        "request_id" => "define",
        "source" => source,
        "expected_behavior" => "elixir_mixir.behavior.v1"
      })

  defp start(client, artifact, id, config, request \\ nil),
    do: tool(client, "runtime_start", start_args(artifact, id, config, request || "start-#{id}"))

  defp start_args(artifact, id, config, request),
    do: %{
      "worker_id" => id,
      "artifact_id" => artifact["artifact_id"],
      "config" => config,
      "request_id" => request
    }

  defp inspect_worker(client, id),
    do: tool(client, "runtime_inspect", %{"worker_id" => id, "detail" => "state"})

  defp tool(client, name, args) do
    {response, _} = Client.call(client, name, args)
    assert response.status == 200
    response.data["result"]["structuredContent"]
  end

  defp await(check, attempts \\ 300)
  defp await(_check, 0), do: flunk("lifecycle HTTP scenario did not settle")

  defp await(check, attempts) do
    unless check.() do
      Process.sleep(5)
      await(check, attempts - 1)
    end
  end
end
