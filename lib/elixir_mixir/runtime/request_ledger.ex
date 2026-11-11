defmodule ElixirMixir.Runtime.RequestLedger do
  @moduledoc "In-memory admission and exact result replay with monotonic completion retention."

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits

  defstruct [:capacity, :retention_ms, entries: %{}]

  @type result :: {:ok, map()} | {:error, Error.t()}
  @type entry :: {String.t(), :pending | {:done, integer(), result()}}
  @type t :: %__MODULE__{
          capacity: pos_integer(),
          retention_ms: pos_integer(),
          entries: %{String.t() => entry()}
        }

  @doc "Creates an empty ledger using validated runtime limits."
  @spec new(Limits.t()) :: t()
  def new(limits) do
    %__MODULE__{capacity: limits.ledger_entries, retention_ms: limits.ledger_retention_ms}
  end

  @doc "Reserves an ID/hash, replays completion, or reports pending/conflict/capacity."
  @spec admit(t(), String.t(), String.t(), integer()) ::
          {:admitted, t()} | {:replay, result(), t()} | {:pending, t()} | {:error, Error.t(), t()}
  def admit(ledger, id, hash, now) do
    entries = Map.reject(ledger.entries, fn {_id, entry} -> expired?(entry, now, ledger) end)
    ledger = %{ledger | entries: entries}
    admission(ledger, id, hash, Map.get(entries, id))
  end

  @doc "Completes a pending reservation once; duplicate or unknown completion is rejected."
  @spec complete(t(), String.t(), result(), integer()) :: {:ok, t()} | {:error, :not_pending}
  def complete(ledger, id, result, now) do
    case Map.get(ledger.entries, id) do
      {hash, :pending} ->
        {:ok, %{ledger | entries: Map.put(ledger.entries, id, {hash, {:done, now, result}})}}

      _entry ->
        {:error, :not_pending}
    end
  end

  defp expired?({_hash, {:done, completed_at, _result}}, now, ledger),
    do: now - completed_at >= ledger.retention_ms

  defp expired?({_hash, :pending}, _now, _ledger), do: false

  defp admission(ledger, _id, hash, {hash, {:done, _at, result}}),
    do: {:replay, result, ledger}

  defp admission(ledger, _id, hash, {hash, :pending}), do: {:pending, ledger}

  defp admission(ledger, _id, _hash, {_other, _status}),
    do: {:error, Error.new("REQUEST_ID_CONFLICT"), ledger}

  defp admission(ledger, id, hash, nil) do
    if map_size(ledger.entries) < ledger.capacity do
      {:admitted, %{ledger | entries: Map.put(ledger.entries, id, {hash, :pending})}}
    else
      {:error, Error.new("BUSY"), ledger}
    end
  end
end
