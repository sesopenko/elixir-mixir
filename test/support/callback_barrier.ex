defmodule ElixirMixir.TestSupport.CallbackBarrier do
  @moduledoc "Test-only callback barriers controlled through the independent fixture's stdin channel."

  use GenServer

  @doc "Starts the fixture's named barrier registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Registers the current callback and waits for explicit release; kernel callback deadlines still apply."
  @spec wait(String.t()) :: :ok
  def wait(key) do
    :ok = GenServer.call(__MODULE__, {:wait, key, self()})

    receive do
      {:release, ^key} -> :ok
    end
  end

  @doc "Reports whether the controlled callback has reached its acceptance barrier."
  @spec status(String.t()) :: map()
  def status(key), do: GenServer.call(__MODULE__, {:status, key})

  @doc "Releases a waiting callback exactly once."
  @spec release(String.t()) :: map()
  def release(key), do: GenServer.call(__MODULE__, {:release, key})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:wait, key, pid}, _from, state) do
    {:reply, :ok, Map.put(state, key, {pid, Process.monitor(pid)})}
  end

  def handle_call({:status, key}, _from, state) do
    waiting =
      case Map.get(state, key) do
        {pid, _ref} -> Process.alive?(pid)
        nil -> false
      end

    {:reply, %{"waiting" => waiting}, state}
  end

  def handle_call({:release, key}, _from, state) do
    case Map.pop(state, key) do
      {nil, state} ->
        {:reply, %{"released" => false}, state}

      {{pid, ref}, state} ->
        Process.demonitor(ref, [:flush])
        send(pid, {:release, key})
        {:reply, %{"released" => true}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, Map.reject(state, fn {_key, {_pid, monitor}} -> monitor == ref end)}
  end
end
