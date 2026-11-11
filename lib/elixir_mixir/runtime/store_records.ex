defmodule ElixirMixir.Runtime.StoreRecords do
  @moduledoc false

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Values

  @doc "Validates JSON records, fixed keys, record bounds and resulting table capacities."
  @spec validate(map(), map(), map()) :: :ok | {:error, Error.t()}
  def validate(records, change, limits) do
    with %{puts: puts, deletes: deletes, advance: advance, operation_id: id, outcome: outcome} <-
           change,
         true <- is_map(puts) and is_list(deletes) and is_boolean(advance),
         true <- Values.valid_id?(id),
         true <- Enum.all?(deletes, &valid_key?/1),
         :ok <- Values.validate(outcome, :reply, %{limits | reply_bytes: limits.response_bytes}),
         :ok <- validate_puts(puts, limits) do
      resulting = records |> Map.drop(deletes) |> Map.merge(puts)
      with :ok <- references(puts, resulting), do: capacity(resulting, limits)
    else
      {:error, _error} = error -> error
      _invalid -> {:error, Error.new("INVALID_ARGUMENT")}
    end
  end

  defp validate_puts(puts, limits) do
    Enum.reduce_while(puts, :ok, fn {key, value}, :ok ->
      result =
        if valid_key?(key) and is_map(value),
          do:
            Values.validate(value, :reply, %{
              limits
              | reply_bytes: record_bytes(key, limits),
                depth: limits.depth + 4
            }),
          else: {:error, Error.new("INVALID_ARGUMENT")}

      with :ok <- result,
           :ok <- fields(value, limits) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp fields(value, limits) do
    kinds = %{"source" => :source, "config" => :config, "data" => :state, "payload" => :event}

    Enum.reduce_while(kinds, :ok, fn {field, kind}, :ok ->
      case field(value, field, kind, limits) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp field(value, field, kind, limits) do
    case Map.fetch(value, field) do
      :error -> :ok
      {:ok, data} -> Values.validate(data, kind, limits)
    end
  end

  defp references(puts, records) do
    valid =
      Enum.all?(puts, fn
        {{:worker, _id}, value} ->
          value["desired_status"] == "stopped" or
            Map.has_key?(records, {:artifact, value["artifact_id"]})

        {{:state, id}, _value} ->
          Map.has_key?(records, {:worker, id})

        {_key, _value} ->
          true
      end)

    if valid, do: :ok, else: {:error, Error.new("INVALID_ARGUMENT")}
  end

  defp valid_key?({tag, id}) when tag in [:artifact, :worker, :state, :request, :effect],
    do: Values.valid_id?(id)

  defp valid_key?({:audit, sequence}), do: is_integer(sequence) and sequence >= 0

  defp valid_key?({:edge, source, target}),
    do: Values.valid_id?(source) and Values.valid_id?(target)

  defp valid_key?(_key), do: false

  defp record_bytes({:artifact, _}, limits), do: limits.source_bytes * 6 + limits.metadata_bytes
  defp record_bytes({:state, _}, limits), do: limits.state_bytes + limits.metadata_bytes
  defp record_bytes({:worker, _}, limits), do: limits.config_bytes + limits.metadata_bytes
  defp record_bytes({:request, _}, limits), do: limits.response_bytes + limits.metadata_bytes
  defp record_bytes({:effect, _}, limits), do: limits.event_bytes + limits.metadata_bytes
  defp record_bytes(_key, limits), do: limits.metadata_bytes

  defp capacity(records, limits) do
    ceilings = %{
      artifact: limits.artifact_slots,
      worker: limits.workers,
      state: limits.workers,
      request: limits.ledger_entries,
      effect: limits.pending_effects,
      audit: limits.history_records,
      edge: limits.workers * limits.workers
    }

    counts = Enum.frequencies_by(Map.keys(Map.delete(records, :meta)), &elem(&1, 0))

    if Enum.all?(counts, fn {tag, count} -> count <= Map.fetch!(ceilings, tag) end),
      do: :ok,
      else: {:error, Error.new("LIMIT_EXCEEDED")}
  end
end
