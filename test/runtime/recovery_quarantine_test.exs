defmodule ElixirMixir.Runtime.RecoveryQuarantineTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.DurableArtifacts
  alias ElixirMixir.Runtime.DurableOutbox
  alias ElixirMixir.Runtime.Effects
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.RecoveryDiagnostics
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.Runtime.StoreRecords
  alias ElixirMixir.TestSupport.DurableFixture
  alias ElixirMixir.TestSupport.RuntimeFixture

  test "malformed retained intent metadata cannot enter the delivery queue" do
    record = %{
      "operation_id" => "origin",
      "correlation_id" => "caller",
      "source" => "source",
      "target" => "target",
      "effect" => %{"type" => "emit", "to" => "target", "event" => %{}},
      "path" => [1],
      "remaining_hops" => 16,
      "artifact_revision" => %{"private" => "/secret/path"},
      "due_at" => 1_700_000_000_000,
      "status" => "pending"
    }

    id = Effects.identity("origin", [1])
    records = %{{:effect, id} => record, {:worker, "source"} => %{}}
    assert DurableOutbox.pending(records, Limits.new()) == []
  end

  test "all quarantines paginate at the minimum full-wire response budget" do
    entries =
      for index <- 1..30,
          do:
            RecoveryDiagnostics.entry(
              "artifact",
              String.pad_leading(Integer.to_string(index), 64, "a"),
              "INVALID_ARGUMENT"
            )

    state = %{
      quarantines: entries,
      limits: Limits.new(%{response_bytes: 1_024}),
      generation: 7,
      inspection_id: "abcdefghijklmnop"
    }

    pages = pages(%{}, state)
    assert Enum.flat_map(pages, & &1["quarantines"]) == entries

    for page <- pages do
      assert page["quarantine_count"] == 30

      assert ResponseBudget.fits?(
               Map.merge(page, %{"api_version" => "1", "generation" => 7}),
               state.limits
             )
    end

    first = hd(pages)

    assert {:error, _} =
             RecoveryDiagnostics.page(%{"cursor" => first["next_cursor"]}, %{
               state
               | generation: 8
             })

    assert {:error, _} =
             RecoveryDiagnostics.page(%{"cursor" => first["next_cursor"]}, %{
               state
               | inspection_id: "other_boot"
             })
  end

  test "long worker identities and reason omission fit the minimum diagnostic budget" do
    entries =
      for index <- 1..3,
          do:
            RecoveryDiagnostics.entry(
              "worker",
              String.pad_leading(Integer.to_string(index), 64, "w"),
              "INVALID_ARGUMENT",
              "INVALID_WORKER_RECORD"
            )

    state = %{
      quarantines: entries,
      limits: Limits.new(%{response_bytes: 1_024}),
      generation: 7,
      inspection_id: "abcdefghijklmnop"
    }

    found = pages(%{}, state) |> Enum.flat_map(& &1["quarantines"])

    assert Enum.map(found, &Map.take(&1, ~w(kind id code))) ==
             Enum.map(entries, &Map.take(&1, ~w(kind id code)))

    for row <- found, row["reason"] == nil, do: assert(row["reason_omitted"])
  end

  test "diagnostics omit invalid identifiers and never copy arbitrary payload or path text" do
    row = RecoveryDiagnostics.entry("artifact", "/secret/path", "INVALID_ARGUMENT")
    assert row["id"] == nil
    assert row["id_omitted"]
    refute Jason.encode!(row) =~ "secret"
  end

  test "bounded audit recording preserves original evidence and generation" do
    dir = RuntimeFixture.temp_path("mixir-quarantine")
    on_exit(fn -> File.rm_rf!(dir) end)
    limits = Limits.new(%{history_records: 2})
    store = start_supervised!({Store, data_dir: dir, limits: %{history_records: 2}})
    original = %{"status" => "invalid", "effect" => %{"private" => "retained evidence"}}

    {:ok, nil} =
      Store.commit(store, 0, %{
        puts: %{{:effect, "broken"} => original},
        deletes: [],
        outcome: nil,
        operation_id: "fixture",
        advance: false
      })

    entries =
      for id <- 1..5,
          do: RecoveryDiagnostics.entry("effect", "broken_#{id}", "INVALID_TRANSITION")

    assert :ok =
             RecoveryDiagnostics.record(
               %{store: store, limits: limits, generation: 0, boot_id: "boot"},
               entries
             )

    records = Store.snapshot(store)
    assert records[{:effect, "broken"}] == original
    assert records[:meta]["generation"] == 0
    audits = for {{:audit, _}, row} <- records, do: row
    assert length(audits) == 2
    assert Enum.all?(audits, &(&1["type"] == "recovery_quarantined"))
    refute Jason.encode!(audits) =~ "retained evidence"
  end

  test "every retained table capacity is checked before recovery writes" do
    for {records, limits} <- [
          {%{{:state, "one"} => %{}, {:state, "two"} => %{}}, %{workers: 1}},
          {%{{:request, "one"} => %{}, {:request, "two"} => %{}}, %{ledger_entries: 1}},
          {%{{:audit, 0} => %{}, {:audit, 1} => %{}}, %{history_records: 1}},
          {%{{:edge, "a", "b"} => %{}, {:edge, "b", "a"} => %{}}, %{workers: 1}}
        ] do
      assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
               StoreRecords.validate_capacity(records, Limits.new(limits))
    end

    assert {:error, _} = StoreRecords.validate_capacity(%{unknown: %{}}, Limits.new())
  end

  @tag capture_log: true
  test "global overflow fails before compiler use or interrupted-request reconciliation" do
    dir = RuntimeFixture.temp_path("mixir-capacity")
    on_exit(fn -> File.rm_rf!(dir) end)
    store = start_supervised!({Store, data_dir: dir})

    artifact = DurableFixture.artifact()

    {:ok, nil} =
      Store.commit(store, 0, %{
        puts: %{
          {:artifact, artifact.id} => DurableArtifacts.record(artifact),
          {:request, "a"} => %{"status" => "pending"},
          {:request, "b"} => %{"status" => "pending"}
        },
        deletes: [],
        outcome: nil,
        operation_id: "fixture",
        advance: false
      })

    before = Store.snapshot(store)
    attempts = ArtifactRegistry.status()["attempts"]
    parent = self()

    barrier = fn :recovery_before_validation ->
      send(parent, {:validation, self()})

      receive do
        :continue -> :ok
      end
    end

    manager =
      start_supervised!(
        Supervisor.child_spec(
          {Manager,
           name: nil,
           store: store,
           storage: [mode: :durable, data_dir: dir],
           limits: %{ledger_entries: 1},
           durability_barrier: barrier},
          restart: :temporary
        )
      )

    assert_receive {:validation, task}
    ref = Process.monitor(manager)
    send(task, :continue)
    assert_receive {:DOWN, ^ref, :process, ^manager, :recovery_failed}, 2_000
    assert ArtifactRegistry.status()["attempts"] == attempts
    assert Store.snapshot(store) == before
  end

  @tag capture_log: true
  test "malformed global lineage fails startup without exposing or rewriting it" do
    dir = RuntimeFixture.temp_path("mixir-lineage")
    on_exit(fn -> File.rm_rf!(dir) end)

    meta = %{
      "format_version" => 1,
      "lineage_id" => "/secret/path",
      "generation" => 0,
      "next_audit_sequence" => 0
    }

    {:ok, db} = CubDB.start_link(data_dir: dir)
    :ok = CubDB.put(db, :meta, meta)
    GenServer.stop(db)
    assert {:error, {:unsupported_store_format, _}} = start_supervised({Store, data_dir: dir})
    {:ok, db} = CubDB.start_link(data_dir: dir)
    assert CubDB.get(db, :meta) == meta
    GenServer.stop(db)
  end

  defp pages(args, state) do
    assert {:ok, page} = RecoveryDiagnostics.page(args, state)

    if page["next_cursor"],
      do: [page | pages(Map.put(args, "cursor", page["next_cursor"]), state)],
      else: [page]
  end
end
