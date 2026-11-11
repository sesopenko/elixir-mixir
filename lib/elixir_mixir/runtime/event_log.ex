defmodule ElixirMixir.Runtime.EventLog do
  @moduledoc "Bounded in-memory lifecycle records with monotonic cursors and explicit eviction gaps."

  use GenServer

  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Values

  @doc "Starts a ring with optional name and validated downward limits."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Appends a kernel-owned record, omitting oversized metadata with an explicit truncation marker."
  @spec append(map(), GenServer.server()) :: :ok
  def append(record, server \\ __MODULE__), do: GenServer.call(server, {:append, record})

  @doc "Reads after an exclusive sequence, reporting eviction gaps and truncation counts."
  @spec events(map(), GenServer.server()) :: map()
  def events(args \\ %{}, server \\ __MODULE__), do: GenServer.call(server, {:events, args})

  @impl true
  def init(opts) do
    limits =
      Limits.new(Keyword.get(opts, :limits, Application.get_env(:elixir_mixir, :limits, %{})))

    {:ok,
     %{limits: limits, records: :queue.new(), count: 0, sequence: 0, dropped: 0, truncated: 0}}
  end

  @impl true
  def handle_call({:append, record}, _from, state) do
    metadata = Map.get(record, "metadata", %{})
    truncated = Values.validate(metadata, :metadata, state.limits) != :ok

    record =
      if truncated,
        do: Map.delete(record, "metadata"),
        else: Map.put(record, "metadata", metadata)

    record =
      Map.merge(record, %{
        "truncated" => truncated,
        "sequence" => state.sequence + 1,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    records = :queue.in(record, state.records)

    {records, dropped} =
      if state.count == state.limits.history_records do
        {{:value, _old}, remaining} = :queue.out(records)
        {remaining, 1}
      else
        {records, 0}
      end

    state = %{
      state
      | records: records,
        count: min(state.count + 1, state.limits.history_records),
        sequence: state.sequence + 1,
        dropped: state.dropped + dropped,
        truncated: state.truncated + if(truncated, do: 1, else: 0)
    }

    {:reply, :ok, state}
  end

  def handle_call({:events, args}, _from, state) do
    after_sequence = Map.get(args, "after", 0)
    limit = min(Map.get(args, "limit", state.limits.page_default), state.limits.page_max)

    records =
      state.records
      |> :queue.to_list()
      |> Enum.filter(fn record ->
        record["sequence"] > after_sequence and
          (not Map.has_key?(args, "worker_id") or record["worker_id"] == args["worker_id"])
      end)
      |> Enum.take(limit)

    oldest = state.sequence - state.count + 1

    next =
      case List.last(records) do
        nil -> max(after_sequence, state.sequence)
        record -> record["sequence"]
      end

    {:reply,
     %{
       "events" => records,
       "next_cursor" => next,
       "oldest_sequence" => oldest,
       "gap" => after_sequence < oldest - 1,
       "dropped" => state.dropped,
       "truncated" => state.truncated
     }, state}
  end
end
