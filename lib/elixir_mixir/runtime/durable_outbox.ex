defmodule ElixirMixir.Runtime.DurableOutbox do
  @moduledoc "Serializes complete pending effect intents and reconstructs bounded queue accounting before ordered durable delivery."

  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.Effects
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.RecoveryDiagnostics
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.Runtime.Values

  @doc "Serializes an owner-bound reservation, excluding all transient handles."
  @spec batch(GenServer.server(), reference() | :none) :: {:ok, map()} | {:error, Error.t()}
  def batch(dispatcher, token) do
    with {:ok, items} <- EffectDispatcher.reserved_items(dispatcher, token) do
      {:ok, Map.new(items, fn item -> {{:effect, item.id}, record(item)} end)}
    end
  end

  @doc "Rejects retained queues exceeding configured capacity before reconstruction."
  @spec validate_capacity(map(), Limits.t()) :: :ok | {:error, Error.t()}
  def validate_capacity(records, limits) do
    if counts(records)["pending"] <= limits.pending_effects,
      do: :ok,
      else: {:error, Error.new("LIMIT_EXCEEDED")}
  end

  @doc "Reconstructs pending/timer counts for the calling Manager without dispatch."
  @spec sync(map()) :: :ok
  def sync(state) do
    EffectDispatcher.retained_counts(state.dispatcher, counts(Store.snapshot(state.store)))
  end

  @doc "Counts all retained effects, including records reserved for later quarantine diagnosis."
  @spec counts(map()) :: map()
  def counts(records) do
    effects = for {{:effect, _id}, effect} <- records, do: effect
    %{"pending" => length(effects), "timers" => Enum.count(effects, &scheduled?/1)}
  end

  @doc "Selects valid pending intents without dispatching malformed retained records."
  @spec pending(map(), Limits.t()) :: [{String.t(), map()}]
  def pending(records, limits) do
    for {{:effect, id}, record} <- records,
        valid?(id, record, limits) and source_retained?(record, records),
        do: {id, record}
  end

  @doc "Reports every malformed or orphaned retained intent without changing its evidence."
  @spec quarantines(map(), Limits.t()) :: [map()]
  def quarantines(records, limits) do
    for {{:effect, id}, record} <- records,
        not (valid?(id, record, limits) and source_retained?(record, records)),
        do: RecoveryDiagnostics.entry("effect", id, "INVALID_TRANSITION")
  end

  defp source_retained?(%{"source" => source}, records),
    do: Map.has_key?(records, {:worker, source})

  defp source_retained?(_record, _records), do: false

  defp valid?(id, %{"status" => "pending", "effect" => effect} = record, limits) do
    with :ok <-
           Values.validate(record, :reply, %{
             limits
             | reply_bytes: limits.event_bytes + limits.metadata_bytes,
               depth: limits.depth + 4
           }),
         true <-
           Enum.sort(Map.keys(record)) ==
             ~w(artifact_revision correlation_id due_at effect operation_id path remaining_hops source status target),
         true <- is_integer(record["artifact_revision"]) and record["artifact_revision"] > 0,
         true <- valid_context?(record, limits),
         true <- valid_path?(record["path"], limits),
         :ok <- Effects.validate([effect], limits) do
      record["target"] == effect["to"] and
        id == Effects.identity(record["operation_id"], record["path"])
    else
      _invalid -> false
    end
  end

  defp valid?(_id, _record, _limits), do: false

  defp valid_context?(record, limits) do
    is_integer(record["due_at"]) and record["due_at"] >= 0 and
      is_integer(record["remaining_hops"]) and record["remaining_hops"] in 0..limits.effect_hops and
      Values.valid_id?(record["operation_id"]) and Values.valid_id?(record["source"]) and
      Values.valid_id?(record["correlation_id"])
  end

  defp valid_path?(path, limits) do
    is_list(path) and length(path) in 1..(limits.effect_hops + 1) and
      Enum.all?(path, &(is_integer(&1) and &1 in 1..limits.effects))
  end

  defp scheduled?(%{"effect" => %{"type" => "schedule"}}), do: true
  defp scheduled?(_record), do: false

  defp record(item) do
    %{
      "operation_id" => item.operation_id,
      "correlation_id" => item.correlation_id,
      "source" => item.source,
      "target" => item.effect["to"],
      "effect" => item.effect,
      "path" => item.path,
      "remaining_hops" => item.remaining_hops,
      "artifact_revision" => item.artifact_revision,
      "due_at" => item.due_at,
      "status" => "pending"
    }
  end
end
