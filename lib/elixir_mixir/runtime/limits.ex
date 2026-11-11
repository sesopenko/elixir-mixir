defmodule ElixirMixir.Runtime.Limits do
  @moduledoc """
  Runtime resource ceilings. Overrides may only reduce the Phase 1 defaults.
  Responses require at least 1_024 bytes so a bounded error envelope can be returned.

  Heap budgets are expressed in VM words, using the current machine word size.
  """

  @defaults %{
    source_bytes: 32_768,
    artifact_slots: 128,
    compile_timeout_ms: 5_000,
    compiler_heap_words: div(64 * 1_024 * 1_024, :erlang.system_info(:wordsize)),
    callback_heap_words: div(8 * 1_024 * 1_024, :erlang.system_info(:wordsize)),
    callback_timeout_ms: 200,
    workers: 32,
    config_bytes: 16_384,
    event_bytes: 16_384,
    state_bytes: 16_384,
    reply_bytes: 16_384,
    depth: 16,
    effects: 16,
    pending_effects: 256,
    timer_delay_ms: 60_000,
    effect_hops: 16,
    history_records: 1_000,
    metadata_bytes: 2_048,
    page_default: 25,
    page_max: 100,
    ledger_entries: 1_024,
    ledger_retention_ms: 600_000,
    diagnostic_bytes: 2_048,
    diagnostics: 10,
    response_bytes: 65_536,
    body_bytes: 65_536,
    operation_timeout_ms: 7_000
  }

  @type t :: %{atom() => pos_integer()}

  @doc "Returns the Phase 1 maximum settings."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc "Builds limits from known positive overrides; raises on invalid configuration."
  @spec new(map()) :: t()
  def new(overrides \\ %{}) when is_map(overrides) do
    Enum.each(overrides, fn {key, value} ->
      unless Map.has_key?(@defaults, key) and is_integer(value) and value > 0 and
               value <= Map.fetch!(@defaults, key) do
        raise ArgumentError, "invalid runtime limit: #{inspect(key)}"
      end
    end)

    limits = Map.merge(@defaults, overrides)

    if limits.response_bytes < 1_024 do
      raise ArgumentError, "response_bytes must allow a bounded error envelope (at least 1_024)"
    end

    if limits.page_default > limits.page_max do
      raise ArgumentError, "page_default must not exceed page_max"
    end

    limits
  end
end
