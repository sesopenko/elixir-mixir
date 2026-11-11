defmodule ElixirMixir.Integration.Phase02ReplacementTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures
  alias ElixirMixir.TestSupport.MCPClient, as: Client
  alias ElixirMixir.TestSupport.RuntimeFixture

  test "live replacements preserve PID and recovered selected state never migrates again" do
    dir = directory()
    {fixture, client, ready} = runtime(dir, :first)
    {artifacts, first} = setup_worker(client, dir)
    assert invoke(client, "event-v1", 3)["reply"] == 3
    compatible = replace(client, artifacts[2], 1, "compatible")
    assert compatible["pid_before"] == first["pid"]
    assert compatible["pid_after"] == first["pid"]
    assert compatible["state_revision"] == 2
    assert compatible["migration_result"] == "preserved"
    assert invoke(client, "event-v2", 2)["reply"] == 7
    migrated = replace(client, artifacts[3], 2, "migrated")
    assert migrated["migration_result"] == "migrated"
    assert migrated["state_revision"] == 4
    assert migrated["pid_after"] == first["pid"]
    assert File.read!(Path.join(dir, "migration")) == "migrated"
    assert invoke(client, "event-v3", 1)["reply"] == 17
    before = inspect_worker(client)
    records = RuntimeFixture.control(fixture, %{"op" => "durable_records"})
    Client.close(client)
    RuntimeFixture.kill(fixture)
    {restarted, fresh, next} = runtime(dir, :second)
    refute ready.os_pid == next.os_pid
    restored = inspect_worker(fresh)

    for key <- ~w(artifact_id state state_revision worker_revision status) do
      assert restored[key] == before[key]
    end

    assert restored["status"] == "running"
    assert RuntimeFixture.control(restarted, %{"op" => "durable_records"}) == records
    assert replace(fresh, artifacts[3], 2, "migrated") == migrated
    assert File.read!(Path.join(dir, "migration")) == "migrated"
    assert invoke(fresh, "continued", 1)["reply"] == 27
  end

  for phase <- ~w(after_prepare before_commit after_commit before_publish before_response) do
    @tag phase: phase
    test "SIGKILL migration at #{phase} keeps old or new selection and schema/state together", %{
      phase: phase
    } do
      dir = directory()
      {fixture, client, _ready} = runtime(dir, :first)
      {artifacts, first} = setup_worker(client, dir)
      invoke(client, "initial", 5)
      RuntimeFixture.control(fixture, %{"op" => "durability_barrier", "phase" => phase})
      arguments = replace_args(artifacts[3], 1, "uncertain")

      pending =
        Task.async(fn ->
          try do
            Client.call(client, "runtime_replace", arguments)
          rescue
            MatchError -> :connection_closed
          end
        end)

      await(fn ->
        RuntimeFixture.control(fixture, %{"op" => "barrier_status", "key" => phase})["waiting"]
      end)

      records = RuntimeFixture.control(fixture, %{"op" => "durable_records"})
      committed = phase in ~w(after_commit before_publish before_response)

      assert hd(records["workers"])["record"]["artifact_id"] ==
               artifacts[if(committed, do: 3, else: 1)]["artifact_id"]

      assert hd(records["states"])["record"]["schema"] == if(committed, do: 2, else: 1)
      live = RuntimeFixture.control(fixture, %{"op" => "host_state", "id" => "counter"})

      assert live["artifact_id"] ==
               artifacts[if(phase == "before_response", do: 3, else: 1)]["artifact_id"]

      assert RuntimeFixture.control(fixture, %{"op" => "worker_membership", "id" => "counter"})[
               "pid"
             ] == first["pid"]

      assert File.read!(Path.join(dir, "migration")) == "migrated"
      Client.disconnect(client)
      assert Task.await(pending) == :connection_closed
      RuntimeFixture.kill(fixture)
      {restarted, fresh, _next} = runtime(dir, :second)
      after_boot = RuntimeFixture.control(restarted, %{"op" => "durable_records"})
      assert after_boot["workers"] == records["workers"]
      assert after_boot["states"] == records["states"]
      assert after_boot["meta"] == records["meta"]
      result = tool(fresh, "runtime_replace", arguments)

      if committed do
        original =
          Enum.find(records["requests"], &(&1["id"] == "uncertain"))["record"]["outcome"]["data"]

        assert result == original
        assert inspect_worker(fresh)["state"]["value"] == 5
        assert invoke(fresh, "continued", 1)["reply"] == 15
      else
        assert result["code"] == "OPERATION_INTERRUPTED"
        assert inspect_worker(fresh)["state"]["count"] == 5
        assert invoke(fresh, "continued", 1)["reply"] == 6
      end
    end
  end

  test "HTTP migration failure and stale revisions retain state/selection and exact outcomes" do
    dir = directory()
    {_fixture, client, _ready} = runtime(dir, :first)

    artifacts =
      for version <- 1..3, into: %{} do
        {version, define(client, Fixtures.replacement_source(version), "v#{version}")}
      end

    for mode <- ~w(error raise timeout non_json oversized) do
      id = "counter-#{mode}"

      tool(client, "runtime_start", %{
        "worker_id" => id,
        "artifact_id" => artifacts[1]["artifact_id"],
        "config" => %{"migration" => mode},
        "request_id" => "start-#{id}"
      })

      before = tool(client, "runtime_inspect", %{"worker_id" => id, "detail" => "state"})
      arguments = Map.put(replace_args(artifacts[3], 1, "failed-#{mode}"), "worker_id", id)
      failure = tool(client, "runtime_replace", arguments)
      assert failure["code"] == "MIGRATION_FAILED"
      assert tool(client, "runtime_replace", arguments) == failure
      assert tool(client, "runtime_inspect", %{"worker_id" => id, "detail" => "state"}) == before
      stale = %{arguments | "expected_revision" => 99, "request_id" => "stale-#{mode}"}
      assert tool(client, "runtime_replace", stale)["code"] == "REVISION_CONFLICT"
    end
  end

  defp setup_worker(client, dir) do
    artifacts =
      for version <- 1..3,
          into: %{},
          do: {version, define(client, source(version), "v#{version}")}

    first =
      tool(client, "runtime_start", %{
        "worker_id" => "counter",
        "artifact_id" => artifacts[1]["artifact_id"],
        "config" => %{"count" => 0, "marker" => Path.join(dir, "migration")},
        "request_id" => "start"
      })

    assert first["status"] == "running"
    {artifacts, first}
  end

  defp source(3) do
    Fixtures.source(
      schema: "2",
      migrate:
        ~S|path = state["marker"]; if File.exists?(path), do: raise("migration repeated"); File.write!(path, "migrated"); {:ok, %{"value" => state["count"], "marker" => path}}|,
      event:
        ~S|next = state["value"] + Map.get(event, "amount", 1) * 10; {:ok, next, Map.put(state, "value", next), []}|
    )
  end

  defp source(version) do
    Fixtures.source(
      event:
        "next = state[\"count\"] + Map.get(event, \"amount\", 1) * #{version}; {:ok, next, Map.put(state, \"count\", next), []}",
      migrate: ~S|raise "compatible migration must not run"|
    )
  end

  defp define(client, source, id),
    do:
      tool(client, "runtime_define", %{
        "source" => source,
        "logical_name" => "replacement",
        "expected_behavior" => "elixir_mixir.behavior.v1",
        "request_id" => id
      })

  defp directory do
    dir = Path.join(System.tmp_dir!(), "mixir-replace-http-#{System.unique_integer([:positive])}")
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
    {fixture, client, ready}
  end

  defp replace_args(artifact, revision, id),
    do: %{
      "worker_id" => "counter",
      "artifact_id" => artifact["artifact_id"],
      "expected_revision" => revision,
      "request_id" => id
    }

  defp replace(client, artifact, revision, id),
    do: tool(client, "runtime_replace", replace_args(artifact, revision, id))

  defp invoke(client, id, amount),
    do:
      tool(client, "runtime_invoke", %{
        "worker_id" => "counter",
        "event" => %{"amount" => amount},
        "request_id" => id
      })

  defp inspect_worker(client),
    do: tool(client, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"})

  defp tool(client, name, arguments) do
    {response, _} = Client.call(client, name, arguments)
    assert response.status == 200
    response.data["result"]["structuredContent"]
  end

  defp await(check, attempts \\ 400)
  defp await(_check, 0), do: flunk("replacement scenario did not settle")

  defp await(check, attempts) do
    unless check.() do
      Process.sleep(5)
      await(check, attempts - 1)
    end
  end
end
