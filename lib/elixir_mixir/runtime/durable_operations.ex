defmodule ElixirMixir.Runtime.DurableOperations do
  @moduledoc "Serializes durable admission, bounded preparation, atomic outcomes and live publication."

  alias ElixirMixir.Runtime.DurableRequests
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.Runtime.Values

  @doc "Runs a validated kernel operation through durable admission and publication."
  @spec execute(String.t(), map(), map(), (map(), map() -> {:ok, map()} | {:error, Error.t()})) ::
          {{:ok | :error, map()}, map()}
  def execute(operation, args, state, prepare) do
    records = Store.snapshot(state.store)
    id = args["request_id"]
    hash = Values.request_hash(operation, args)

    case DurableRequests.admit(records, id, hash, state.wall_clock.(), state.limits) do
      {:replay, result, deletes} ->
        if deletes != [], do: commit!(state, %{}, deletes, false, "prune", %{})
        {result, state}

      {:error, error} ->
        {{:error, envelope(error, id, state.generation)}, state}

      {:admitted, entry, deletes} ->
        commit!(state, %{{:request, id} => entry}, deletes, false, entry["operation_id"], %{})
        state.durability_barrier.(:after_admission)
        prepared = prepare.(records, entry) |> preflight(args, state)
        state.durability_barrier.(:after_prepare)
        finish(operation, args, entry, prepared, records, state)
    end
  end

  @doc "Commits trusted prepared records or closes availability on any uncertain/rejected store write."
  @spec commit!(map(), map(), list(), boolean(), String.t(), map()) :: :ok
  def commit!(state, puts, deletes, advance, operation_id, outcome) do
    case Store.commit(state.store, state.generation, %{
           puts: puts,
           deletes: deletes,
           advance: advance,
           operation_id: operation_id,
           outcome: outcome
         }) do
      {:ok, ^outcome} -> :ok
      {:error, _error} -> exit(:durability_unavailable)
    end
  end

  defp preflight({:ok, prepared}, args, state) do
    generation = state.generation + if(prepared.changed, do: 1, else: 0)

    if ResponseBudget.fits?(envelope(prepared.data, args["request_id"], generation), state.limits) do
      prepared
    else
      prepared.abort.()
      preflight({:error, Error.new("LIMIT_EXCEEDED")}, args, state)
    end
  end

  defp preflight({:error, error}, args, state) do
    error =
      if ResponseBudget.fits?(
           envelope(error, args["request_id"], state.generation),
           state.limits
         ),
         do: error,
         else: Error.new("LIMIT_EXCEEDED")

    %{
      status: :error,
      data: error,
      puts: %{},
      deletes: [],
      changed: false,
      publish: fn state -> state end,
      abort: fn -> :ok end
    }
  end

  defp finish(operation, args, entry, prepared, records, state) do
    status = Map.get(prepared, :status, :ok)
    data = prepared.data
    generation = state.generation + if(prepared.changed, do: 1, else: 0)
    data = envelope(data, args["request_id"], generation)
    result = {status, data}
    request = DurableRequests.complete(entry, result, state.wall_clock.())
    sequence = records[:meta]["next_audit_sequence"]

    audit = %{
      "operation_id" => entry["operation_id"],
      "request_id" => args["request_id"],
      "operation" => operation,
      "worker_id" => args["worker_id"],
      "logical_id" => args["logical_name"] || args["worker_id"],
      "outcome" => if(status == :ok, do: "ok", else: data["code"])
    }

    puts =
      prepared.puts
      |> Map.put({:request, args["request_id"]}, request)
      |> Map.put({:audit, sequence}, audit)

    deletes = prepared.deletes ++ audit_expiry(records, sequence, state.limits.history_records)
    state.durability_barrier.(:before_commit)
    commit!(state, puts, deletes, prepared.changed, entry["operation_id"], data)
    state.durability_barrier.(:after_commit)
    state.durability_barrier.(:before_publish)
    next = prepared.publish.(state)
    state.durability_barrier.(:before_response)

    EventLog.append(%{
      "type" => event_type(operation, status, data),
      "logical_id" => args["logical_name"] || args["worker_id"],
      "worker_id" => args["worker_id"],
      "artifact_revision" => data["revision"],
      "request_id" => args["request_id"],
      "outcome" => audit["outcome"],
      "metadata" => Map.take(data, ["artifact_id", "source_hash"])
    })

    {result, %{next | generation: generation}}
  end

  defp event_type("replace", :error, %{"code" => "MIGRATION_FAILED"}), do: "migration_failed"
  defp event_type(operation, status, _data), do: event_type(operation, status)

  defp event_type("define", :ok), do: "compile_succeeded"
  defp event_type("define", :error), do: "compile_failed"
  defp event_type("replace", :ok), do: "implementation_replaced"
  defp event_type("replace", :error), do: "replacement_failed"
  defp event_type("invoke", :ok), do: "event_delivered"
  defp event_type("invoke", :error), do: "event_failed"
  defp event_type("start", :ok), do: "worker_started"
  defp event_type("stop", :ok), do: "worker_stopped"
  defp event_type(_operation, _status), do: "operation_failed"

  defp audit_expiry(records, sequence, capacity),
    do: for({{:audit, prior} = key, _} <- records, prior <= sequence - capacity, do: key)

  defp envelope(data, id, generation),
    do: Map.merge(data, %{"api_version" => "1", "request_id" => id, "generation" => generation})
end
