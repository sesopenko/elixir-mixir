defmodule ElixirMixir.Runtime.StoreTest do
  use ExUnit.Case, async: true
  alias ElixirMixir.Runtime.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "mixir-store-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "atomic records, generation checks and rejected values survive reopening", %{dir: dir} do
    {:ok, store} = Store.start_link(data_dir: dir)
    original = Store.snapshot(store)
    change = change(%{{:audit, 0} => %{"value" => 2}, {:audit, 1} => %{"value" => 3}})
    assert Store.commit(store, 0, change) == {:ok, %{"ok" => true}}
    committed = Store.snapshot(store)
    assert committed[:meta]["generation"] == 1
    assert committed[{:audit, 1}] == %{"value" => 3}
    assert {:error, %{"code" => "REVISION_CONFLICT"}} = Store.commit(store, 0, change)

    assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
             Store.commit(store, 1, change(%{{:audit, 0} => %{"pid" => self()}}))

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             Store.commit(
               store,
               1,
               change(%{{:audit, 0} => %{"big" => String.duplicate("x", 3000)}})
             )

    assert Store.snapshot(store) == committed
    GenServer.stop(store)
    {:ok, reopened} = Store.start_link(data_dir: dir)
    assert Store.snapshot(reopened) == committed
    assert original[:meta]["lineage_id"] == committed[:meta]["lineage_id"]
    GenServer.stop(reopened)
  end

  test "table bounds, immutable metadata and changed dependencies reject atomically", %{dir: dir} do
    store = start_supervised!({Store, data_dir: dir, limits: %{history_records: 1}})
    before = Store.snapshot(store)

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             Store.commit(store, 0, change(%{{:audit, 0} => %{}, {:audit, 1} => %{}}))

    assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
             Store.commit(store, 0, change(%{meta: %{}}))

    assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
             Store.commit(
               store,
               0,
               change(%{{:worker, "orphan"} => %{"artifact_id" => "missing"}})
             )

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             Store.commit(
               store,
               0,
               change(%{
                 {:state, "orphan"} => %{"data" => %{"large" => String.duplicate("x", 16_384)}}
               })
             )

    assert Store.snapshot(store) == before
  end

  test "duplicate owners and invalid directory fail closed", %{dir: dir} do
    store = start_supervised!({Store, data_dir: dir})

    assert {:error, {:directory_in_use, _child}} =
             start_supervised({Store, data_dir: dir}, id: :duplicate)

    File.write!(Path.join(dir, "file"), "occupied")

    assert {:error, {:storage_unavailable, _child}} =
             start_supervised({Store, data_dir: Path.join(dir, "file/child")}, id: :invalid)

    assert Process.alive?(store)
  end

  test "unknown format is preserved and rejected", %{dir: dir} do
    # Corruption setup deliberately uses the backend; production callers cannot.
    File.mkdir_p!(dir)
    {:ok, db} = CubDB.start_link(data_dir: dir)
    :ok = CubDB.put(db, :meta, %{"format_version" => 999})
    GenServer.stop(db)

    assert {:error, {:unsupported_store_format, _child}} =
             start_supervised({Store, data_dir: dir})

    {:ok, db} = CubDB.start_link(data_dir: dir)
    assert CubDB.get(db, :meta) == %{"format_version" => 999}
    GenServer.stop(db)
  end

  defp change(puts),
    do: %{puts: puts, deletes: [], outcome: %{"ok" => true}, operation_id: "test", advance: true}
end
