defmodule ElixirMixir.Runtime.DurableRequestsTest do
  use ExUnit.Case, async: true
  alias ElixirMixir.Runtime.DurableRequests
  alias ElixirMixir.Runtime.Limits

  test "admission identities, exact replay, conflicts and capacity survive serialization" do
    limits = Limits.new(%{ledger_entries: 1})
    {:admitted, entry, []} = DurableRequests.admit(%{}, "key", "hash", 100, limits)
    records = %{{:request, "key"} => entry}

    assert {:error, %{"code" => "BUSY"}} =
             DurableRequests.admit(records, "other", "hash", 101, limits)

    assert {:error, %{"code" => "REQUEST_ID_CONFLICT"}} =
             DurableRequests.admit(records, "key", "changed", 101, limits)

    outcome = {:error, %{"code" => "COMPILE_FAILED", "generation" => 1}}
    done = entry |> DurableRequests.complete(outcome, 102) |> Jason.encode!() |> Jason.decode!()

    assert {:replay, ^outcome, []} =
             DurableRequests.admit(%{{:request, "key"} => done}, "key", "hash", 200, limits)

    assert entry["deadline_at"] == 100 + limits.operation_timeout_ms
    assert byte_size(entry["operation_id"]) == 32
  end

  test "downtime expires completion; backward time conservatively retains it; reuse gets fresh operation ID" do
    limits = Limits.new(%{ledger_retention_ms: 100})
    {:admitted, entry, []} = DurableRequests.admit(%{}, "key", "hash", 100, limits)
    result = {:ok, %{"value" => 42}}
    done = DurableRequests.complete(entry, result, 150)
    records = %{{:request, "key"} => done}
    assert {:replay, ^result, []} = DurableRequests.admit(records, "key", "hash", 50, limits)
    assert {:replay, ^result, []} = DurableRequests.admit(records, "key", "hash", 249, limits)

    assert {:admitted, next, [{:request, "key"}]} =
             DurableRequests.admit(records, "key", "different", 250, limits)

    refute next["operation_id"] == entry["operation_id"]
  end

  test "boot interrupts pending admissions and retains the exact failure for replay" do
    limits = Limits.new()
    {:admitted, entry, []} = DurableRequests.admit(%{}, "pending", "hash", 100, limits)
    records = %{{:request, "pending"} => entry}

    assert {:error, %{"code" => "BUSY"}} =
             DurableRequests.admit(records, "pending", "hash", 100_000_000, limits)

    puts = DurableRequests.interrupted(records, 3, 200)

    assert {:replay, {:error, %{"code" => "OPERATION_INTERRUPTED", "generation" => 3}}, []} =
             DurableRequests.admit(puts, "pending", "hash", 201, limits)

    assert DurableRequests.interrupted(puts, 3, 300) == %{}
  end
end
