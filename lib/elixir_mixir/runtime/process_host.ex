defmodule ElixirMixir.Runtime.ProcessHost do
  @moduledoc "Stable temporary worker host owning its committed artifact, state and revisions."

  use GenServer, restart: :temporary

  alias ElixirMixir.Runtime.Callback
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Transition
  alias ElixirMixir.Runtime.Values

  @doc "Starts a logical host; failed bounded init leaves no running child."
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {ElixirMixir.Runtime.ProcessRegistry, opts.worker_id}}
    )
  end

  @doc "Returns kernel-owned state with a finite timeout, never invoking generated code."
  @spec snapshot(pid(), pos_integer()) :: {:ok, map()} | {:error, Error.t()}
  def snapshot(pid, timeout \\ 200) do
    GenServer.call(pid, :snapshot, timeout)
  catch
    :exit, _reason -> {:error, Error.new("WORKER_NOT_RUNNING")}
  end

  @doc "Invokes a host from its owning Manager with a finite API wait; generated callbacks run in tasks."
  @spec invoke(pid(), map(), map(), pos_integer()) :: {:ok, map()} | {:error, Error.t()}
  def invoke(pid, event, context, timeout) do
    GenServer.call(pid, {:invoke, event, context}, timeout)
  catch
    :exit, _reason -> {:error, Error.new("CALLBACK_FAILED")}
  end

  @impl true
  def init(opts) do
    with {:ok, {:ok, data}} <-
           Callback.run(fn -> opts.artifact.module.init(opts.config) end, opts.limits),
         :ok <- valid_state(data, opts.limits) do
      {:ok, Map.put(opts, :data, data)}
    else
      {:ok, _invalid} -> {:stop, {:runtime_error, Error.new("CALLBACK_FAILED")}}
      {:error, error} -> {:stop, {:runtime_error, error}}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     {:ok, Map.take(state, [:artifact, :data, :worker_revision, :state_revision, :worker_id])},
     state}
  end

  def handle_call({:invoke, event, context}, {manager, _tag}, %{manager: manager} = state) do
    outcome =
      with {:ok, result} <-
             Callback.run(
               fn -> state.artifact.module.handle_event(event, state.data) end,
               state.limits
             ),
           {:ok, data, next} <- Transition.stage(result, state, context) do
        {:commit, data, next}
      end

    case outcome do
      {:commit, data, next} -> {:reply, {:ok, data}, next}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(_unsupported, _from, state),
    do: {:reply, {:error, Error.new("INVALID_ARGUMENT")}, state}

  @impl true
  def handle_cast(_unsupported, state), do: {:noreply, state}

  @impl true
  def handle_info(_unsupported, state), do: {:noreply, state}

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
