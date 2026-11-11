defmodule ElixirMixir.Runtime.DurableDefinitions do
  @moduledoc "Coordinates admitted source definitions: prepare, atomic durable outcome, registry publication, response."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.Definition
  alias ElixirMixir.Runtime.DurableArtifacts
  alias ElixirMixir.Runtime.DurableRequests
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.Runtime.Values

  @doc "Runs one validated durable definition, or replays its retained historical outcome."
  @spec execute(map(), map()) :: {{:ok | :error, map()}, map()}
  def execute(args, state) do
    records = Store.snapshot(state.store)
    id = args["request_id"]
    hash = Values.request_hash("define", args)

    case DurableRequests.admit(records, id, hash, state.wall_clock.(), state.limits) do
      {:replay, result, deletes} ->
        if deletes != [], do: commit!(state, %{}, deletes, false, "prune", %{})
        {result, state}

      {:error, error} ->
        {{:error, envelope(error, id, state.generation)}, state}

      {:admitted, entry, deletes} ->
        commit!(state, %{{:request, id} => entry}, deletes, false, entry["operation_id"], %{})
        state.durability_barrier.(:after_admission)
        prepared = prepare(args, records, state)
        state.durability_barrier.(:after_prepare)
        finish(args, entry, prepared, records, state)
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

  defp prepare(args, records, state) do
    count = Enum.count(records, fn {key, _} -> match?({:artifact, _}, key) end)

    result =
      if count < state.limits.artifact_slots,
        do: Definition.prepare(args, state.generation + 1, state.limits),
        else: {:error, Error.new("LIMIT_EXCEEDED")}

    bound_error(result, args, state)
  end

  defp bound_error({:error, error}, args, state) do
    if ResponseBudget.fits?(envelope(error, args["request_id"], state.generation), state.limits),
      do: {:error, error},
      else: {:error, Error.new("LIMIT_EXCEEDED")}
  end

  defp bound_error(prepared, _args, _state), do: prepared

  defp finish(args, entry, prepared, records, state) do
    {result, artifacts, publication, changed} = outcome(prepared)
    {status, data} = result
    generation = state.generation + if(changed, do: 1, else: 0)
    data = envelope(data, args["request_id"], generation)
    result = {status, data}
    request = DurableRequests.complete(entry, result, state.wall_clock.())
    sequence = records[:meta]["next_audit_sequence"]

    audit = %{
      "operation_id" => entry["operation_id"],
      "request_id" => args["request_id"],
      "operation" => "define",
      "outcome" => if(status == :ok, do: "ok", else: data["code"])
    }

    puts =
      artifacts
      |> Map.put({:request, args["request_id"]}, request)
      |> Map.put({:audit, sequence}, audit)

    deletes = audit_expiry(records, sequence, state.limits.history_records)
    commit!(state, puts, deletes, changed, entry["operation_id"], data)
    state.durability_barrier.(:after_commit)
    publish(publication)

    EventLog.append(%{
      "type" => if(changed, do: "compile_succeeded", else: "compile_failed"),
      "logical_id" => args["logical_name"],
      "worker_id" => nil,
      "artifact_revision" => data["revision"],
      "request_id" => args["request_id"],
      "outcome" => audit["outcome"],
      "metadata" => Map.take(data, ["artifact_id", "source_hash"])
    })

    {result, %{state | generation: generation}}
  end

  defp outcome({:ok, data, reservation, artifact}),
    do:
      {{:ok, data}, %{{:artifact, artifact.id} => DurableArtifacts.record(artifact)},
       {reservation, artifact}, true}

  defp outcome({:error, _error} = error), do: {error, %{}, nil, false}

  defp publish(nil), do: :ok

  defp publish({reservation, artifact}),
    do: :ok = ArtifactRegistry.register(reservation, artifact)

  defp audit_expiry(records, sequence, capacity),
    do: for({{:audit, prior} = key, _} <- records, prior <= sequence - capacity, do: key)

  defp envelope(data, id, generation),
    do: Map.merge(data, %{"api_version" => "1", "request_id" => id, "generation" => generation})
end
