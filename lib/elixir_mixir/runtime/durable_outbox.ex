defmodule ElixirMixir.Runtime.DurableOutbox do
  @moduledoc "Serializes complete pending effect intents and reconstructs bounded queue accounting with delivery paused."

  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Store

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
