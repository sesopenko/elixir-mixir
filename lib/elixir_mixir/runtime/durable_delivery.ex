defmodule ElixirMixir.Runtime.DurableDelivery do
  @moduledoc "Restores ordered UTC work and atomically consumes intents with target state, children and topology."

  alias ElixirMixir.Runtime.DurableOperations
  alias ElixirMixir.Runtime.DurableOutbox
  alias ElixirMixir.Runtime.DurableTransitions
  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.Store

  @doc "Rebuilds the next volatile wakeup from committed pending work and transient retry eligibility."
  @spec schedule(map()) :: map()
  def schedule(%{storage: %{mode: :memory}} = state), do: state

  def schedule(state) do
    cancel(state.delivery_timer)
    records = Store.snapshot(state.store)
    pending = DurableOutbox.pending(records, state.limits)
    retries = Map.take(state.delivery_retries, Enum.map(pending, &elem(&1, 0)))
    state = %{state | delivery_timer: nil, delivery_retries: retries}
    now = state.wall_clock.()

    case next(pending, retries, now) do
      nil ->
        state

      {id, record} ->
        delay = max(0, max(record["due_at"], Map.get(retries, id, 0)) - now)
        nonce = make_ref()
        ref = state.delivery_clock.({:durable_delivery, id, nonce}, delay)
        %{state | delivery_timer: %{id: id, nonce: nonce, ref: ref}}
    end
  end

  @doc "Rechecks disk existence and wall-clock eligibility before processing the current wakeup."
  @spec wake(map(), String.t(), reference()) :: map()
  def wake(%{delivery_timer: %{id: id, nonce: nonce}} = state, id, nonce) do
    records = Store.snapshot(state.store)
    pending = DurableOutbox.pending(records, state.limits)
    now = state.wall_clock.()

    case next(pending, state.delivery_retries, now) do
      {^id, record} ->
        if record["due_at"] <= now and Map.get(state.delivery_retries, id, 0) <= now,
          do: deliver(state, records, id, record) |> schedule(),
          else: schedule(state)

      _changed ->
        schedule(state)
    end
  end

  def wake(state, _id, _nonce), do: state

  defp next([], _retries, _now), do: nil

  defp next(pending, retries, now) do
    eligible =
      Enum.filter(pending, fn {id, record} ->
        record["due_at"] <= now and Map.get(retries, id, 0) <= now
      end)

    if eligible == [],
      do:
        Enum.min_by(pending, fn {id, record} ->
          {max(record["due_at"], Map.get(retries, id, 0)), id}
        end),
      else: Enum.min_by(eligible, fn {id, record} -> {record["due_at"], id} end)
  end

  defp deliver(state, records, id, %{"effect" => %{"type" => "log"}} = record) do
    :ok =
      EffectDispatcher.execute_log(%{
        id: id,
        source: record["source"],
        effect: record["effect"],
        correlation_id: record["correlation_id"],
        artifact_revision: record["artifact_revision"]
      })

    state.durability_barrier.(:delivery_after_log)
    complete(state, records, id, record, empty(), "effect_completed", "ok")
  end

  defp deliver(state, records, id, record) do
    case prepare(state, id, record) do
      {:ok, prepared} ->
        complete(state, records, id, record, prepared, "effect_delivered", "ok")

      {:error, %{"code" => "BUSY"}} ->
        %{
          state
          | delivery_retries: Map.put(state.delivery_retries, id, state.wall_clock.() + 100)
        }

      {:error, error} ->
        complete(state, records, id, record, empty(), "effect_failed", error["code"])
    end
  end

  defp prepare(_state, _id, %{"remaining_hops" => 0}), do: {:error, %{"code" => "HOP_LIMIT"}}

  defp prepare(state, id, record) do
    case state.workers[record["target"]] do
      %{status: "restarting"} ->
        {:error, %{"code" => "BUSY"}}

      %{status: "running"} = worker ->
        args = %{
          "worker_id" => worker.worker_id,
          "request_id" => id,
          "event" => record["effect"]["event"]
        }

        inherited = %{
          operation_id: record["operation_id"],
          correlation_id: record["correlation_id"],
          path: record["path"],
          remaining_hops: record["remaining_hops"] - 1,
          consumed_effect: id
        }

        args
        |> DurableTransitions.prepare(worker, %{"operation_id" => id}, state, inherited)
        |> host_outcome(worker.pid)

      nil ->
        {:error, %{"code" => "WORKER_NOT_FOUND"}}

      _terminal ->
        {:error, %{"code" => "WORKER_NOT_RUNNING"}}
    end
  end

  defp host_outcome({:error, _error} = result, host) do
    if Process.alive?(host), do: result, else: {:error, %{"code" => "BUSY"}}
  end

  defp host_outcome(result, _host), do: result

  defp complete(state, records, id, record, prepared, type, outcome) do
    sequence = records[:meta]["next_audit_sequence"]

    audit = %{
      "operation_id" => id,
      "request_id" => record["correlation_id"],
      "operation" => "delivery",
      "effect_id" => id,
      "worker_id" => record["target"],
      "source" => record["source"],
      "outcome" => outcome,
      "type" => type
    }

    puts =
      prepared.puts
      |> Map.merge(edge(records, record, type))
      |> Map.put({:audit, sequence}, audit)

    deletes = [
      {:effect, id}
      | for(
          {{:audit, prior} = key, _} <- records,
          prior <= sequence - state.limits.history_records,
          do: key
        )
    ]

    state.durability_barrier.(:delivery_before_commit)
    DurableOperations.commit!(state, puts, deletes, true, id, audit)
    state.durability_barrier.(:delivery_after_commit)
    state.durability_barrier.(:delivery_before_publish)
    next = prepared.publish.(state)
    :ok = DurableOutbox.sync(next)
    state.durability_barrier.(:delivery_after_publish)
    EventLog.append(Map.put(audit, "logical_id", record["target"] || record["source"]))

    %{
      next
      | generation: state.generation + 1,
        delivery_retries: Map.delete(next.delivery_retries, id)
    }
  end

  defp edge(records, record, "effect_delivered") do
    key = {:edge, record["source"], record["target"]}
    count = Map.get(records, key, %{"count" => 0})["count"]
    %{key => %{"count" => count + 1}}
  end

  defp edge(_records, _record, _type), do: %{}
  defp empty, do: %{puts: %{}, publish: fn state -> state end}
  defp cancel(%{ref: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel(_timer), do: :ok
end
