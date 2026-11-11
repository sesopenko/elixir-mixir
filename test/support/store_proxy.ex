defmodule ElixirMixir.TestSupport.StoreProxy do
  @moduledoc "Test-only Store protocol proxy for uncertain final-commit failures, never a production fault tool."
  use GenServer
  alias ElixirMixir.Runtime.Store

  @doc "Starts an unlinked proxy monitored by its test control owner."
  @spec start(GenServer.server(), :raise_before_commit | :timeout_after_commit) ::
          GenServer.on_start()
  def start(target, mode), do: GenServer.start(__MODULE__, {target, mode, self()})

  @impl true
  def init({target, mode, owner}) do
    {:ok, %{target: target, mode: mode, owner: Process.monitor(owner)}}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, Store.snapshot(state.target), state}

  def handle_call({:commit, generation, %{advance: false} = change}, _from, state),
    do: {:reply, Store.commit(state.target, generation, change), state}

  def handle_call({:commit, _generation, _change}, _from, %{mode: :raise_before_commit}),
    do: raise("injected commit exception")

  def handle_call({:commit, generation, change}, _from, %{mode: :timeout_after_commit} = state) do
    {:ok, _outcome} = Store.commit(state.target, generation, change)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner: ref} = state),
    do: {:stop, :normal, state}
end
