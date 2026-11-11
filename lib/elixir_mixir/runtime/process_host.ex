defmodule ElixirMixir.Runtime.ProcessHost do
  @moduledoc "Stable temporary worker host owning its committed artifact, state and revisions."

  use GenServer, restart: :temporary

  alias ElixirMixir.Runtime.Callback
  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Replacement
  alias ElixirMixir.Runtime.Transition
  alias ElixirMixir.Runtime.Values

  @doc "Starts an unrouted candidate host; failed bounded init leaves no running child."
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Returns kernel-owned state with a finite timeout, never invoking generated code."
  @spec snapshot(pid(), pos_integer()) :: {:ok, map()} | {:error, Error.t()}
  def snapshot(pid, timeout \\ 200) do
    GenServer.call(pid, :snapshot, timeout)
  catch
    :exit, _reason -> {:error, Error.new("WORKER_NOT_RUNNING")}
  end

  @doc "Prepares an event without exposing its candidate state or dispatching effects."
  @spec prepare_invoke(pid(), map(), map(), pos_integer()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def prepare_invoke(pid, event, context, timeout),
    do: call(pid, {:prepare_invoke, event, context}, timeout)

  @doc "Prepares compatible replacement or migration without activating it."
  @spec prepare_replace(pid(), map(), pos_integer(), map(), pos_integer()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def prepare_replace(pid, artifact, expected, context, timeout),
    do: call(pid, {:prepare_replace, artifact, expected, context}, timeout)

  @doc "Reads a matching prepared checkpoint for its owning Manager without publishing it."
  @spec prepared_snapshot(pid(), map()) :: {:ok, map()} | {:error, Error.t()}
  def prepared_snapshot(pid, ticket), do: call(pid, {:prepared_snapshot, ticket}, 1_000)

  @doc "Publishes the matching candidate once; repeating its ticket is harmless."
  @spec publish(pid(), map()) :: {:ok, map(), reference() | :none} | {:error, Error.t()}
  def publish(pid, ticket), do: call(pid, {:publish, ticket}, 1_000)

  @doc "Aborts a matching candidate and releases its effect capacity."
  @spec abort(pid(), map()) :: :ok | {:error, Error.t()}
  def abort(pid, ticket), do: call(pid, {:abort, ticket}, 1_000)

  defp call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, _reason -> {:error, Error.new("CALLBACK_FAILED")}
  end

  @doc "Stops a host through its owning Manager, which owns logical route cleanup."
  @spec stop(pid()) :: :ok | {:error, Error.t()}
  def stop(pid) do
    GenServer.call(pid, :stop, Limits.defaults().operation_timeout_ms)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    with {:ok, data} <- initial_data(opts),
         :ok <- valid_state(data, opts.limits) do
      {:ok,
       Map.merge(Map.delete(opts, :restore_data), %{
         data: data,
         staged: nil,
         last_publication: nil,
         incarnation: make_ref(),
         owner_monitor: Process.monitor(opts.manager)
       })}
    else
      {:error, error} -> {:stop, {:runtime_error, error}}
    end
  end

  defp initial_data(%{restore_data: data}), do: {:ok, data}

  defp initial_data(opts) do
    case Callback.run(fn -> opts.artifact.module.init(opts.config) end, opts.limits) do
      {:ok, {:ok, data}} -> {:ok, data}
      {:ok, _invalid} -> {:error, Error.new("CALLBACK_FAILED")}
      error -> error
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     {:ok, Map.take(state, [:artifact, :data, :worker_revision, :state_revision, :worker_id])},
     state}
  end

  def handle_call(
        {:prepare_invoke, event, context},
        {manager, _},
        %{manager: manager, staged: nil} = state
      ) do
    result =
      with {:ok, result} <-
             Callback.run(
               fn -> state.artifact.module.handle_event(event, state.data) end,
               state.limits
             ),
           {:ok, outcome, next, token} <- Transition.stage(result, state, context) do
        stage(state, next, outcome, token, context)
      end

    prepared_reply(result, state)
  end

  def handle_call(
        {:prepare_replace, artifact, expected, context},
        {manager, _},
        %{manager: manager, staged: nil} = state
      ) do
    result =
      with {:ok, outcome, next} <- Replacement.stage(state, artifact, expected, context),
           do: stage(state, next, outcome, :none, context)

    prepared_reply(result, state)
  end

  def handle_call({operation, _, _}, {manager, _}, %{manager: manager} = state)
      when operation == :prepare_invoke do
    {:reply, {:error, Error.new("BUSY")}, state}
  end

  def handle_call({:prepare_replace, _, _, _}, {manager, _}, %{manager: manager} = state),
    do: {:reply, {:error, Error.new("BUSY")}, state}

  def handle_call(
        {:prepared_snapshot, ticket},
        {manager, _},
        %{manager: manager, staged: %{ticket: ticket, next: next, token: token}} = state
      ) do
    snapshot = Map.take(next, [:artifact, :data, :worker_revision, :state_revision, :worker_id])
    {:reply, {:ok, Map.put(snapshot, :effect_token, token)}, state}
  end

  def handle_call(
        {:publish, ticket},
        {manager, _},
        %{manager: manager, staged: %{ticket: ticket} = candidate} = state
      ) do
    case EffectDispatcher.hold_batch(state.dispatcher, candidate.token) do
      :ok ->
        Process.cancel_timer(candidate.expiry)
        result = {:ok, candidate.outcome, candidate.token}
        next = %{candidate.next | staged: nil, last_publication: {ticket, result}}
        {:reply, result, next}

      {:error, _error} = error ->
        {:reply, error, discard(state)}
    end
  end

  def handle_call(
        {:publish, ticket},
        {manager, _},
        %{manager: manager, staged: nil, last_publication: {ticket, result}} = state
      ),
      do: {:reply, result, state}

  def handle_call(
        {:abort, ticket},
        {manager, _},
        %{manager: manager, staged: %{ticket: ticket}} = state
      ),
      do: {:reply, :ok, discard(state)}

  def handle_call({:abort, _ticket}, {manager, _}, %{manager: manager, staged: nil} = state),
    do: {:reply, :ok, state}

  def handle_call(:stop, {manager, _tag}, %{manager: manager} = state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call(_unsupported, _from, state),
    do: {:reply, {:error, Error.new("INVALID_ARGUMENT")}, state}

  @impl true
  def handle_cast(_unsupported, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state),
    do: {:stop, :normal, discard(state)}

  def handle_info({:expire_candidate, ticket}, %{staged: %{ticket: ticket}} = state),
    do: {:noreply, discard(state)}

  def handle_info(_unsupported, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    discard(state)
    :ok
  end

  defp stage(state, next, outcome, token, context) do
    ticket = %{
      operation_id: Map.get(context, :operation_id, context.request_id),
      worker_revision: state.worker_revision,
      state_revision: state.state_revision,
      incarnation: state.incarnation,
      nonce: make_ref()
    }

    expiry =
      Process.send_after(self(), {:expire_candidate, ticket}, state.limits.operation_timeout_ms)

    candidate = %{ticket: ticket, next: next, outcome: outcome, token: token, expiry: expiry}
    {:prepared, outcome, ticket, %{state | staged: candidate}}
  end

  defp prepared_reply({:prepared, outcome, ticket, next}, _state),
    do: {:reply, {:ok, outcome, ticket}, next}

  defp prepared_reply({:error, _error} = error, state), do: {:reply, error, state}

  defp discard(%{staged: nil} = state), do: state

  defp discard(state) do
    Process.cancel_timer(state.staged.expiry)
    EffectDispatcher.release(state.dispatcher, state.staged.token)
    %{state | staged: nil}
  end

  @doc "Validates callback state; non-JSON results are invalid transitions and size excess is a limit error."
  @spec valid_state(term(), Limits.t()) :: :ok | {:error, Error.t()}
  def valid_state(data, limits) do
    case Values.validate(data, :state, limits) do
      :ok -> :ok
      {:error, %{"code" => "INVALID_ARGUMENT"}} -> {:error, Error.new("INVALID_TRANSITION")}
      error -> error
    end
  end
end
