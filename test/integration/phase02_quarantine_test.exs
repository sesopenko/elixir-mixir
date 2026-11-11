defmodule ElixirMixir.Integration.Phase02QuarantineTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures
  alias ElixirMixir.TestSupport.MCPClient, as: Client
  alias ElixirMixir.TestSupport.RuntimeFixture

  for corruption <-
        ~w(hash source contract state schema reference inactive effect metadata worker_metadata) do
    @tag corruption: corruption
    test "#{corruption} corruption preserves evidence and isolates recovery from a healthy peer",
         %{corruption: corruption} do
      dir = directory()
      {fixture, client} = runtime(dir, :first, pause_delivery: true)
      artifacts = setup_workers(client)

      if corruption in ["effect", "metadata"] do
        tool(client, "runtime_invoke", %{
          "worker_id" => "broken",
          "event" => %{
            "effects" => [
              %{"type" => "schedule", "to" => "healthy", "event" => %{}, "delay_ms" => 60_000}
            ]
          },
          "request_id" => "pending"
        })
      end

      Client.disconnect(client)
      RuntimeFixture.kill(fixture)
      {key, damaged} = corrupt(dir, artifacts, corruption)
      {restarted, fresh} = runtime(dir, :second)
      snapshot = records(restarted)
      assert retained(snapshot, key) == damaged
      summary = tool(fresh, "runtime_inspect", %{})
      assert summary["health"] == "degraded"
      assert summary["recovery"]["degraded"]
      assert summary["recovery"]["quarantine_count"] > 0
      assert Client.raw(fresh, :get, "/health").status == 200
      rows = quarantine_pages(fresh)
      assert length(rows) == summary["recovery"]["quarantine_count"]
      refute Jason.encode!(rows) =~ "/secret/path"
      refute Jason.encode!(rows) =~ "defmodule"
      assert Enum.any?(snapshot["audits"], &(&1["record"]["type"] == "recovery_quarantined"))
      audits = Enum.filter(snapshot["audits"], &(&1["record"]["type"] == "recovery_quarantined"))
      refute Jason.encode!(audits) =~ "defmodule"
      refute Jason.encode!(audits) =~ "/secret/path"

      assert tool(fresh, "runtime_invoke", %{
               "worker_id" => "healthy",
               "event" => %{"amount" => 2},
               "request_id" => "healthy-continued"
             })["reply"] == 2

      assert data(records(restarted), "healthy")["total"] == 6
      worker = tool(fresh, "runtime_inspect", %{"worker_id" => "broken"})

      if corruption in ["inactive", "effect", "metadata"] do
        assert worker["status"] == "running"
      else
        assert worker["status"] == "quarantined"

        if corruption == "schema",
          do: assert(worker["quarantine_reason"] == "STATE_SCHEMA_MISMATCH")

        events = tool(fresh, "runtime_events", %{"worker_id" => "broken"})
        assert Enum.any?(events["events"], &(&1["type"] == "recovery_quarantined"))

        refute RuntimeFixture.control(restarted, %{"op" => "worker_membership", "id" => "broken"})[
                 "registered"
               ]

        assert tool(fresh, "runtime_start", %{
                 "worker_id" => "broken",
                 "artifact_id" => artifacts["healthy"],
                 "config" => %{},
                 "request_id" => "before-stop"
               })["code"] == "INVALID_ARGUMENT"

        assert tool(fresh, "runtime_stop", %{
                 "worker_id" => "broken",
                 "request_id" => "stop-broken"
               })["status"] == "stopped"

        # Explicit init may replace an old checkpoint; stop itself preserves it.
        if elem(key, 0) == :state, do: assert(retained(records(restarted), key) == damaged)
        repaired = define(fresh, "repair")

        assert tool(fresh, "runtime_start", %{
                 "worker_id" => "broken",
                 "artifact_id" => repaired,
                 "config" => %{},
                 "request_id" => "repaired"
               })["status"] == "running"

        assert tool(fresh, "runtime_invoke", %{
                 "worker_id" => "broken",
                 "event" => %{"amount" => 3},
                 "request_id" => "repair-event"
               })["reply"] == 1

        assert data(records(restarted), "broken")["total"] == 3
        if elem(key, 0) == :artifact, do: assert(retained(records(restarted), key) == damaged)
      end

      if corruption in ["effect", "metadata"] do
        assert summary["effects"]["pending"] == 1
        assert summary["recovery"]["effects_quarantined"] == 1
        assert retained(records(restarted), key) == damaged
      end
    end
  end

  test "minimum response size paginates inactive and worker quarantines without leaking source" do
    dir = directory()
    {fixture, client} = runtime(dir, :first)
    artifacts = setup_workers(client)
    Client.disconnect(client)
    RuntimeFixture.kill(fixture)
    {:ok, db} = CubDB.start_link(data_dir: dir)

    template =
      CubDB.get(db, {:artifact, artifacts["broken"]}) |> Map.put("source_hash", "corrupt")

    for index <- 1..20,
        do:
          CubDB.put(
            db,
            {:artifact, String.pad_leading(Integer.to_string(index), 64, "a")},
            template
          )

    :ok = CubDB.put(db, {:artifact, artifacts["broken"]}, template)
    GenServer.stop(db)
    {restarted, fresh} = runtime(dir, :second, limits: %{response_bytes: 1_024})
    rows = quarantine_pages(fresh)
    assert length(rows) == 22
    assert Enum.count(rows, &(&1["kind"] == "artifact")) == 21
    assert Client.raw(fresh, :get, "/health").status == 200
    assert data(records(restarted), "healthy")["total"] == 4

    assert tool(fresh, "runtime_invoke", %{
             "worker_id" => "healthy",
             "event" => %{},
             "request_id" => "small-wire"
           })["reply"] == 2
  end

  test "readiness and admission stay closed through validation and quarantine reconstruction" do
    dir = directory()
    {fixture, client} = runtime(dir, :first)
    artifacts = setup_workers(client)
    Client.disconnect(client)
    RuntimeFixture.kill(fixture)
    corrupt(dir, artifacts, "hash")

    restarted =
      start_supervised!({RuntimeFixture, data_dir: dir, pause_validation: true}, id: :second)

    ready = RuntimeFixture.ready(restarted)
    fresh = Client.new(ready.port)
    on_exit(fn -> Client.close(%{fresh | session: nil}) end)
    {_init, _notification, fresh} = Client.initialize(fresh)
    await_barrier(restarted, "recovery_validation")
    before = records(restarted)
    assert Client.raw(fresh, :get, "/health").status == 503

    assert tool(fresh, "runtime_inspect", %{"detail" => "recovery"})["code"] ==
             "RUNTIME_RECOVERING"

    assert tool(fresh, "runtime_invoke", %{
             "worker_id" => "healthy",
             "event" => %{},
             "request_id" => "not-admitted"
           })["code"] == "RUNTIME_RECOVERING"

    assert records(restarted) == before

    RuntimeFixture.control(restarted, %{"op" => "release_barrier", "key" => "recovery_validation"})

    await(fn -> Client.raw(fresh, :get, "/health").status == 200 end)
    assert tool(fresh, "runtime_inspect", %{})["health"] == "degraded"
    refute Enum.any?(records(restarted)["requests"], &(&1["id"] == "not-admitted"))
  end

  @tag capture_log: true
  test "lowered global capacity closes readiness before compilation or reconciliation writes" do
    dir = directory()
    {fixture, client} = runtime(dir, :first)
    setup_workers(client)
    before = records(fixture)
    Client.disconnect(client)
    RuntimeFixture.kill(fixture)

    restarted =
      start_supervised!(
        {RuntimeFixture, data_dir: dir, pause_validation: true, limits: %{workers: 1}},
        id: :second
      )

    RuntimeFixture.ready(restarted)
    await_barrier(restarted, "recovery_validation")

    RuntimeFixture.control(restarted, %{"op" => "release_barrier", "key" => "recovery_validation"})

    await(fn ->
      not RuntimeFixture.control(restarted, %{"op" => "runtime_status"})["manager_alive"]
    end)

    assert RuntimeFixture.control(restarted, %{"op" => "runtime_status"})["ready"] == false
    # Store authority closed with the kernel; reopen it only after killing the owned BEAM.
    RuntimeFixture.kill(restarted)
    {:ok, db} = CubDB.start_link(data_dir: dir)
    assert CubDB.get(db, :meta) == before["meta"]

    for entry <- before["workers"],
        do: assert(CubDB.get(db, {:worker, entry["id"]}) == entry["record"])

    GenServer.stop(db)
  end

  for failure <- ~w(format directory) do
    @tag failure: failure, capture_log: true
    test "global #{failure} failure closes startup without rewriting evidence", %{
      failure: failure
    } do
      dir = directory()

      if failure == "format" do
        {:ok, db} = CubDB.start_link(data_dir: dir)
        :ok = CubDB.put(db, :meta, %{"format_version" => 999})
        GenServer.stop(db)
      else
        File.write!(dir, "occupied evidence")
      end

      fixture =
        start_supervised!(
          Supervisor.child_spec({RuntimeFixture, data_dir: dir}, restart: :temporary)
        )

      ref = Process.monitor(fixture)
      assert_receive {:DOWN, ^ref, :process, ^fixture, {:fixture_exit, 1, output}}, 15_000

      assert output =~
               if(failure == "format",
                 do: "unsupported_store_format",
                 else: "storage_unavailable"
               )

      if failure == "format" do
        {:ok, db} = CubDB.start_link(data_dir: dir)
        assert CubDB.get(db, :meta) == %{"format_version" => 999}
        GenServer.stop(db)
      else
        assert File.read!(dir) == "occupied evidence"
      end
    end
  end

  defp corrupt(dir, artifacts, corruption) do
    {:ok, db} = CubDB.start_link(data_dir: dir)
    key = corruption_key(db, artifacts, corruption)
    damaged = damage(CubDB.get(db, key), corruption)
    :ok = CubDB.put(db, key, damaged)
    GenServer.stop(db)
    {key, damaged}
  end

  defp corruption_key(_db, _artifacts, corruption) when corruption in ["state", "schema"],
    do: {:state, "broken"}

  defp corruption_key(_db, _artifacts, corruption)
       when corruption in ["reference", "worker_metadata"],
       do: {:worker, "broken"}

  defp corruption_key(_db, artifacts, "inactive"), do: {:artifact, artifacts["inactive"]}

  defp corruption_key(db, _artifacts, corruption) when corruption in ["effect", "metadata"] do
    Enum.find_value(CubDB.select(db), fn {key, _} -> if match?({:effect, _}, key), do: key end)
  end

  defp corruption_key(_db, artifacts, _corruption), do: {:artifact, artifacts["broken"]}

  defp damage(record, "state"), do: Map.put(record, "data", ["invalid root"])
  defp damage(record, "schema"), do: Map.put(record, "schema", 999)
  defp damage(record, "reference"), do: Map.put(record, "artifact_id", "missing")

  defp damage(record, "worker_metadata"),
    do: Map.put(record, "desired_status", %{"private" => "/secret/path"})

  defp damage(record, "contract"), do: Map.put(record, "contract_version", "unsupported")

  defp damage(record, "source"),
    do:
      record
      |> Map.put("source", "invalid source")
      |> Map.put(
        "source_hash",
        Base.encode16(:crypto.hash(:sha256, "invalid source"), case: :lower)
      )

  defp damage(record, "effect"), do: Map.put(record, "effect", %{"type" => "unsupported"})

  defp damage(record, "metadata"),
    do: Map.put(record, "artifact_revision", %{"private" => "/secret/path"})

  defp damage(record, _hash), do: Map.put(record, "source_hash", "corrupt")

  defp setup_workers(client) do
    artifacts =
      for name <- ~w(healthy broken inactive), into: %{}, do: {name, define(client, name)}

    for name <- ~w(healthy broken) do
      assert tool(client, "runtime_start", %{
               "worker_id" => name,
               "artifact_id" => artifacts[name],
               "config" => %{},
               "request_id" => "start-" <> name
             })["status"] == "running"

      tool(client, "runtime_invoke", %{
        "worker_id" => name,
        "event" => %{"amount" => if(name == "healthy", do: 4, else: 9)},
        "request_id" => "event-" <> name
      })
    end

    artifacts
  end

  defp define(client, name),
    do:
      tool(client, "runtime_define", %{
        "logical_name" => name,
        "source" => Fixtures.effects_source(),
        "expected_behavior" => "elixir_mixir.behavior.v1",
        "request_id" => "define-" <> name
      })["artifact_id"]

  defp records(fixture), do: RuntimeFixture.control(fixture, %{"op" => "durable_records"})
  defp data(records, id), do: retained(records, {:state, id})["data"]

  defp retained(records, {tag, id}) do
    table = %{artifact: "artifacts", worker: "workers", state: "states", effect: "effects"}[tag]
    Enum.find(records[table], &(&1["id"] == id))["record"]
  end

  defp quarantine_pages(client, args \\ %{"detail" => "recovery", "limit" => 100}) do
    page = tool(client, "runtime_inspect", args)
    assert is_list(page["quarantines"]), inspect(page)

    if page["next_cursor"],
      do:
        page["quarantines"] ++
          quarantine_pages(client, Map.put(args, "cursor", page["next_cursor"])),
      else: page["quarantines"]
  end

  defp directory do
    dir =
      RuntimeFixture.temp_path("mixir-quarantine-http")

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
