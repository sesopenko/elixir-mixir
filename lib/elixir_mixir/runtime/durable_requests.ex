defmodule ElixirMixir.Runtime.DurableRequests do
  @moduledoc "Pure JSON request records with wall-clock retention and exact historical result replay."

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits

  @type result :: {:ok, map()} | {:error, Error.t()}
  @type admission ::
          {:admitted, map(), list()} | {:replay, result(), list()} | {:error, Error.t()}

  @doc "Prunes completed outcomes for admission, comparing arguments before allowing a new operation."
  @spec admit(map(), String.t(), String.t(), integer(), Limits.t()) :: admission()
  def admit(records, id, hash, now, limits) do
    expired =
      for {{:request, key}, entry} <- records,
          entry["status"] == "done" and now - entry["completed_at"] >= limits.ledger_retention_ms,
          do: {:request, key}

    retained = Map.drop(records, expired)

    case Map.get(retained, {:request, id}) do
      nil -> new(retained, id, hash, now, limits, expired)
      %{"argument_hash" => ^hash, "status" => "done"} = entry -> {:replay, result(entry), expired}
      %{"argument_hash" => ^hash} -> {:error, Error.new("BUSY")}
      _entry -> {:error, Error.new("REQUEST_ID_CONFLICT")}
    end
  end

  @doc "Converts one admitted request into its exact JSON-compatible bounded outcome."
  @spec complete(map(), result(), integer()) :: map()
  def complete(entry, {status, data}, now) do
    Map.merge(entry, %{
      "status" => "done",
      "completed_at" => now,
      "outcome" => %{"status" => Atom.to_string(status), "data" => data}
    })
  end

  @doc "Retains interrupted admissions as failures without changing application generation."
  @spec interrupted(map(), non_neg_integer(), integer()) :: map()
  def interrupted(records, generation, now) do
    Map.new(
      for {{:request, id} = key, %{"status" => "pending"} = entry} <- records do
        error =
          Map.merge(Error.new("OPERATION_INTERRUPTED"), %{
            "api_version" => "1",
            "generation" => generation,
            "request_id" => id
          })

        {key, complete(entry, {:error, error}, now)}
      end
    )
  end

  @doc "Decodes a retained outcome using fixed status atoms only."
  @spec result(map()) :: result()
  def result(%{"outcome" => %{"status" => "ok", "data" => data}}), do: {:ok, data}
  def result(%{"outcome" => %{"status" => "error", "data" => data}}), do: {:error, data}

  defp new(records, id, hash, now, limits, expired) do
    count = Enum.count(records, fn {key, _} -> match?({:request, _}, key) end)

    if count < limits.ledger_entries do
      {:admitted,
       %{
         "request_id" => id,
         "argument_hash" => hash,
         "status" => "pending",
         "operation_id" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
         "admitted_at" => now,
         "deadline_at" => now + limits.operation_timeout_ms
       }, expired}
    else
      {:error, Error.new("BUSY")}
    end
  end
end
