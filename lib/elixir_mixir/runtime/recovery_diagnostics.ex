defmodule ElixirMixir.Runtime.RecoveryDiagnostics do
  @moduledoc "Retains bounded recovery evidence and paginates sanitized quarantine descriptions without source or host paths."

  alias ElixirMixir.Runtime.DurableOperations
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.Runtime.Values

  @doc "Builds a bounded diagnostic, omitting malformed identifiers rather than exposing arbitrary retained text."
  @spec entry(String.t(), term(), String.t(), String.t() | nil) :: map()
  def entry(kind, id, code, reason \\ nil) do
    data = %{"kind" => kind, "id" => if(Values.valid_id?(id), do: id), "code" => code}
    data = if data["id"], do: data, else: Map.put(data, "id_omitted", true)
    if reason, do: Map.put(data, "reason", reason), else: data
  end

  @doc "Records compact quarantine audits without rewriting original records or advancing generation."
  @spec record(map(), [map()]) :: :ok
  def record(_state, []), do: :ok

  def record(state, entries) do
    records = Store.snapshot(state.store)
    sequence = records[:meta]["next_audit_sequence"]
    cutoff = sequence + length(entries) - state.limits.history_records

    puts =
      entries
      |> Enum.with_index(sequence)
      |> Enum.filter(fn {_entry, index} -> index >= cutoff end)
      |> Map.new(fn {entry, index} ->
        {{:audit, index},
         Map.merge(context(entry), %{
           "type" => "recovery_quarantined",
           "operation" => "recovery",
           "operation_id" => state.boot_id,
           "outcome" => entry["code"]
         })}
      end)

    deletes = for {{:audit, index} = key, _} <- records, index < cutoff, do: key
    DurableOperations.commit!(state, puts, deletes, false, state.boot_id, %{})

    Enum.each(entries, fn entry ->
      EventLog.append(
        Map.merge(context(entry), %{"type" => "recovery_quarantined", "outcome" => entry["code"]})
      )
    end)

    :ok
  end

  @doc "Returns a generation/boot-bound recovery page that fits the complete MCP response."
  @spec page(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def page(args, state) do
    entries = state.quarantines

    with {:ok, offset} <- offset(args, state, length(entries)) do
      rows =
        entries
        |> Enum.drop(offset)
        |> Enum.take(Map.get(args, "limit", state.limits.page_default))

      fit(rows, offset, length(entries), state)
    end
  end

  defp context(%{"kind" => "worker"} = entry), do: Map.put(entry, "worker_id", entry["id"])
  defp context(entry), do: entry

  defp fit(rows, offset, count, state) do
    next = offset + length(rows)

    data = %{
      "quarantines" => rows,
      "quarantine_count" => count,
      "next_cursor" => if(next < count, do: cursor(state, next)),
      "truncated" => next < count
    }

    envelope = Map.merge(data, %{"api_version" => "1", "generation" => state.generation})

    cond do
      ResponseBudget.fits?(envelope, state.limits) ->
        {:ok, data}

      length(rows) > 1 ->
        fit(Enum.drop(rows, -1), offset, count, state)

      Enum.any?(rows, &Map.has_key?(&1, "reason")) ->
        fit(
          Enum.map(rows, &(Map.delete(&1, "reason") |> Map.put("reason_omitted", true))),
          offset,
          count,
          state
        )

      true ->
        {:error, Error.new("LIMIT_EXCEEDED")}
    end
  end

  defp offset(%{"cursor" => encoded}, state, count) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, ["recovery", runtime, generation, offset]} <- Jason.decode(json),
         true <- runtime == state.inspection_id and generation == state.generation,
         true <- is_integer(offset) and offset >= 0 and offset <= count do
      {:ok, offset}
    else
      _invalid -> {:error, Error.new("INVALID_ARGUMENT")}
    end
  end

  defp offset(_args, _state, _count), do: {:ok, 0}

  defp cursor(state, offset),
    do:
      ["recovery", state.inspection_id, state.generation, offset]
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)
end
