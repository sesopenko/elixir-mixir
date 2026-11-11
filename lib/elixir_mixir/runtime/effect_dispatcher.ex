defmodule ElixirMixir.Runtime.EffectDispatcher do
  @moduledoc "Admits bounded effect batches before state commit and asynchronously delivers committed logical events."

  use GenServer
  require Logger

  alias ElixirMixir.Runtime.Effects
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.Limits

  @doc "Starts an in-memory dispatcher with optional name and injectable timer scheduling."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Reserves a validated batch owned by the calling host until Manager commits or it expires."
  @spec reserve_batch(GenServer.server(), term(), map(), Limits.t()) ::
          {:ok, reference() | :none, [map()]} | {:error, Error.t()}
  def reserve_batch(_server, [], _context, _limits), do: {:ok, :none, []}

  def reserve_batch(server, effects, context, limits),
    do: GenServer.call(server, {:reserve, effects, context, limits}, limits.operation_timeout_ms)

  @doc "Pins an unexpired reservation during host publication; only its preparing host can pin it."
  @spec hold_batch(GenServer.server(), reference() | :none) :: :ok | {:error, Error.t()}
  def hold_batch(_server, :none), do: :ok
  def hold_batch(server, token), do: GenServer.call(server, {:hold, token})

  @doc "Reads a reservation only for its Manager, before durable serialization."
  @spec reserved_items(GenServer.server(), reference() | :none) ::
          {:ok, [map()]} | {:error, Error.t()}
  def reserved_items(_server, :none), do: {:ok, []}
  def reserved_items(server, token), do: GenServer.call(server, {:reserved_items, token})

  @doc "Reconstructs this Manager's retained queue counts without dispatch or volatile reservations."
  @spec retained_counts(GenServer.server(), map()) :: :ok
  def retained_counts(server, counts), do: GenServer.call(server, {:retained_counts, counts})

  @doc "Publishes one reserved batch only for its Manager; repeated commit is rejected."
  @spec commit_batch(GenServer.server(), reference() | :none) :: :ok | {:error, Error.t()}
  def commit_batch(_server, :none), do: :ok
  def commit_batch(server, token), do: GenServer.call(server, {:commit, token})

  @doc "Releases an uncommitted reservation; repeated cleanup is harmless."
  @spec release(GenServer.server(), reference() | :none) :: :ok
  def release(_server, :none), do: :ok
  def release(server, token), do: GenServer.call(server, {:release, token})

  @doc "Claims an asynchronous delivery for its intended Manager, ignoring cancelled messages."
  @spec claim(GenServer.server(), String.t()) :: {:ok, map()} | :cancelled
  def claim(server, id), do: GenServer.call(server, {:claim, id})

  @doc "Completes an active delivery, recording its bounded outcome and relationship count."
  @spec complete(GenServer.server(), String.t(), {:ok, map()} | {:error, map()}) :: :ok
  def complete(server, id, outcome), do: GenServer.call(server, {:complete, id, outcome})

  @doc "Cancels pending effects and timers from one logical source owned by the calling Manager."
  @spec cancel_source(GenServer.server(), String.t()) :: :ok
  def cancel_source(server, source), do: GenServer.call(server, {:cancel_source, source})

  @doc "Returns bounded pending counts and aggregated delivered relationships for one Manager."
  @spec snapshot(GenServer.server(), pid()) :: map()
  def snapshot(server \\ __MODULE__, manager \\ self()),
    do: GenServer.call(server, {:snapshot, manager})

  @impl true
  def init(opts) do
    {:ok,
     %{
       reservations: %{},
       retained: %{},
       owners: %{},
       pending: %{},
       edges: %{},
       timer: Keyword.get(opts, :timer, &Process.send_after(self(), &1, &2)),
       reservation_ms: Keyword.get(opts, :reservation_timeout_ms, 7_000)
     }}
  end

  @impl true
  def handle_call({:reserve, effects, context, limits}, {host, _}, state) do
    with :ok <- Effects.validate(effects, limits),
         true <- used(state) + length(effects) <= limits.pending_effects + credit(context, state) do
      token = make_ref()
      monitor = Process.monitor(host)
      expiry = Process.send_after(self(), {:expire, token}, state.reservation_ms)

      items =
        Enum.with_index(effects, 1)
        |> Enum.map(fn {effect, index} ->
          path = context.path ++ [index]

          Map.merge(context, %{
            effect: effect,
            path: path,
            id: Effects.identity(Map.get(context, :operation_id, context.correlation_id), path),
            due_at: Map.get(context, :wall_now, 0) + Map.get(effect, "delay_ms", 0),
            limits: limits,
            active: false
          })
        end)

      batch = %{
        held: false,
        host: host,
        monitor: monitor,
        expiry: expiry,
        items: items,
        manager: context.manager
      }

      acks = Enum.map(items, &%{"effect_id" => &1.id, "status" => "accepted"})

      {:reply, {:ok, token, acks},
       %{state | reservations: Map.put(state.reservations, token, batch)}}
    else
      false -> {:reply, {:error, Error.new("LIMIT_EXCEEDED")}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:reserved_items, token}, {manager, _}, state) do
    case state.reservations[token] do
      %{manager: ^manager, items: items} -> {:reply, {:ok, items}, state}
      _missing -> {:reply, {:error, Error.new("CALLBACK_FAILED")}, state}
    end
  end

  def handle_call({:retained_counts, counts}, {manager, _}, state) do
    owners =
      if Map.has_key?(state.owners, manager),
        do: state.owners,
        else: Map.put(state.owners, manager, Process.monitor(manager))

    {:reply, :ok, %{state | retained: Map.put(state.retained, manager, counts), owners: owners}}
  end

  def handle_call({:hold, token}, {host, _}, state) do
    case Map.get(state.reservations, token) do
      %{host: ^host} = batch ->
        Process.cancel_timer(batch.expiry)
        batch = %{batch | held: true}
        {:reply, :ok, %{state | reservations: Map.put(state.reservations, token, batch)}}

      _missing ->
        {:reply, {:error, Error.new("CALLBACK_FAILED")}, state}
    end
  end

  def handle_call({:commit, token}, {manager, _}, state) do
    case Map.get(state.reservations, token) do
      %{manager: ^manager} = batch ->
        state = discard_reservation(state, token)

        state =
          Enum.reduce(batch.items, state, fn item, acc ->
            record("effect_accepted", item, %{})
            enqueue(item, acc)
          end)

        {:reply, :ok, state}

      _missing ->
        {:reply, {:error, Error.new("INTERNAL_ERROR")}, state}
    end
  end

  def handle_call({:release, token}, _from, state),
    do: {:reply, :ok, discard_reservation(state, token)}

  def handle_call({:claim, id}, {manager, _}, state) do
    case Map.get(state.pending, id) do
      %{manager: ^manager, active: false} = item ->
        {:reply, {:ok, item},
         %{state | pending: Map.put(state.pending, id, %{item | active: true})}}

      _missing ->
        {:reply, :cancelled, state}
    end
  end

  def handle_call({:complete, id, result}, {manager, _}, state) do
    case Map.get(state.pending, id) do
      %{manager: ^manager, active: true} = item ->
        {status, data} = result
        type = if status == :ok, do: "effect_delivered", else: "effect_failed"
        record(type, item, %{"code" => Map.get(data, "code", "ok")})
        state = remove_pending(state, id)

        edges =
          if status == :ok,
            do: Map.update(state.edges, {manager, item.source, item.effect["to"]}, 1, &(&1 + 1)),
            else: state.edges

        {:reply, :ok, %{state | edges: edges}}

      _missing ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:cancel_source, source}, {manager, _}, state) do
    ids =
      for {id, item} <- state.pending, item.manager == manager and item.source == source, do: id

    state =
      Enum.reduce(ids, state, fn id, acc ->
        record("effect_failed", acc.pending[id], %{"code" => "SOURCE_STOPPED"})
        remove_pending(acc, id)
      end)

    {:reply, :ok, state}
  end

  def handle_call({:snapshot, manager}, _from, state) do
    retained = Map.get(state.retained, manager, %{"pending" => 0, "timers" => 0})
    pending = Enum.filter(Map.values(state.pending), &(&1.manager == manager))
    reservations = Enum.filter(Map.values(state.reservations), &(&1.manager == manager))

    edges =
      for {{owner, source, target}, count} <- state.edges,
          owner == manager,
          do: %{"from" => source, "to" => target, "count" => count}

    pending_edges =
      pending
      |> Enum.frequencies_by(&{&1.source, &1.effect["to"]})
      |> Enum.map(fn {{source, target}, count} ->
        %{"from" => source, "to" => target, "pending" => count}
      end)

    {:reply,
     %{
       "pending" => length(pending) + retained["pending"],
       "pending_edges" => pending_edges,
       "timers" =>
         Enum.count(pending, &(&1.effect["type"] == "schedule" and &1.waiting)) +
           retained["timers"],
       "reserved" => Enum.sum(Enum.map(reservations, &length(&1.items))),
       "topology" => Enum.sort_by(edges, &{&1["from"], &1["to"]})
     }, state}
  end

  @impl true
  def handle_info({:expire, token}, state) do
    case Map.get(state.reservations, token) do
      %{held: true} -> {:noreply, state}
      _missing -> {:noreply, discard_reservation(state, token)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    tokens = for {token, batch} <- state.reservations, batch.monitor == ref, do: token
    state = Enum.reduce(tokens, state, &discard_reservation(&2, &1))
    owners = for {owner, monitor} <- state.owners, monitor == ref, do: owner

    {:noreply,
     %{state | owners: Map.drop(state.owners, owners), retained: Map.drop(state.retained, owners)}}
  end

  def handle_info({:fire, id, nonce}, state) do
    case Map.get(state.pending, id) do
      %{nonce: ^nonce} = item ->
        send(item.manager, {:effect_delivery, self(), id})

        expiry =
          Process.send_after(
            self(),
            {:delivery_expired, id, nonce},
            item.limits.operation_timeout_ms
          )

        {:noreply,
         %{state | pending: Map.put(state.pending, id, %{item | timer: expiry, waiting: false})}}

      _missing ->
        {:noreply, state}
    end
  end

  def handle_info({:delivery_expired, id, nonce}, state) do
    case Map.get(state.pending, id) do
      %{nonce: ^nonce} = item ->
        record("effect_failed", item, %{"code" => "DELIVERY_TIMEOUT"})
        {:noreply, remove_pending(state, id)}

      _missing ->
        {:noreply, state}
    end
  end

  defp enqueue(%{effect: %{"type" => "log"}} = item, state) do
    log(item)
    state
  end

  defp enqueue(%{remaining_hops: 0} = item, state) do
    record("effect_failed", item, %{"code" => "HOP_LIMIT"})
    state
  end

  defp enqueue(item, state) do
    nonce = make_ref()
    delay = Map.get(item.effect, "delay_ms", 0)
    timer = state.timer.({:fire, item.id, nonce}, delay)
    record("effect_scheduled", item, %{"delay_ms" => delay, "to" => item.effect["to"]})

    item =
      Map.merge(item, %{nonce: nonce, timer: timer, waiting: item.effect["type"] == "schedule"})

    %{state | pending: Map.put(state.pending, item.id, item)}
  end

  defp log(item) do
    effect = item.effect

    level =
      case effect["level"] do
        "debug" -> :debug
        "info" -> :info
        "warning" -> :warning
        "error" -> :error
      end

    Logger.log(level, effect["message"],
      mixir_metadata: effect["metadata"],
      request_id: item.correlation_id,
      effect_id: item.id
    )

    record("effect_log", item, %{
      "level" => effect["level"],
      "message" => effect["message"],
      "metadata" => effect["metadata"]
    })
  end

  defp record(type, item, metadata) do
    EventLog.append(%{
      "type" => type,
      "worker_id" => item.source,
      "logical_id" => item.source,
      "artifact_revision" => Map.get(item, :artifact_revision),
      "request_id" => item.correlation_id,
      "effect_id" => item.id,
      "outcome" => type,
      "metadata" => metadata
    })
  end

  @doc "Executes an already committed durable log intent, retaining its effect ID in output."
  @spec execute_log(map()) :: :ok
  def execute_log(item), do: log(item)

  defp credit(%{consumed_effect: _id, manager: manager}, state),
    do: min(1, get_in(state.retained, [manager, "pending"]) || 0)

  defp credit(_context, _state), do: 0

  defp used(state),
    do:
      map_size(state.pending) +
        Enum.sum(Enum.map(state.retained, fn {_owner, counts} -> counts["pending"] end)) +
        Enum.sum(Enum.map(state.reservations, fn {_token, batch} -> length(batch.items) end))

  defp discard_reservation(state, token) do
    case Map.pop(state.reservations, token) do
      {nil, _same} ->
        state

      {batch, rest} ->
        Process.demonitor(batch.monitor, [:flush])
        Process.cancel_timer(batch.expiry)
        %{state | reservations: rest}
    end
  end

  defp remove_pending(state, id) do
    {item, pending} = Map.pop(state.pending, id)
    if is_reference(item.timer), do: Process.cancel_timer(item.timer)
    %{state | pending: pending}
  end
end
