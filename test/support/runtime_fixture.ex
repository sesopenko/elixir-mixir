defmodule ElixirMixir.TestSupport.RuntimeFixture do
  @moduledoc "Owns a separate BEAM OS process for reusable runtime HTTP integration tests."

  use GenServer

  @type ready :: %{port: :inet.port_number(), os_pid: String.t()}

  @doc "Launches the test-only runtime script with the compiled application paths."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [])
  @doc "Waits for the listener readiness marker with a finite deadline."
  @spec ready(pid()) :: ready()
  def ready(pid), do: GenServer.call(pid, :ready, 15_000)
  @doc "Checks that the fixture still owns a live OS port."
  @spec alive?(pid()) :: boolean()
  def alive?(pid), do: GenServer.call(pid, :alive)

  @impl true
  def init([]) do
    paths =
      Path.wildcard(Path.join([Path.dirname(Application.app_dir(:elixir_mixir)), "*", "ebin"]))

    args =
      ["--erl", "+S 2:2 +A 2"] ++
        Enum.flat_map(paths, &["-pa", &1]) ++ ["test/support/runtime_boot.exs"]

    port =
      Port.open(
        {:spawn_executable, System.find_executable("elixir")},
        [:binary, :exit_status, :stderr_to_stdout, :hide, args: args]
      )

    {:ok, %{port: port, output: "", ready: nil, waiter: nil}}
  end

  @impl true
  def handle_call(:ready, from, %{ready: nil} = state), do: {:noreply, %{state | waiter: from}}
  def handle_call(:ready, _from, state), do: {:reply, state.ready, state}

  def handle_call(:alive, _from, state),
    do: {:reply, Port.info(state.port, :os_pid) != nil, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    output = String.slice(state.output <> data, -8_192, 8_192)
    state = %{state | output: output}

    case Regex.run(~r/MIXIR_READY:(\d+):(\d+)/, output) do
      [_, number, os_pid] when is_nil(state.ready) ->
        ready = %{port: String.to_integer(number), os_pid: os_pid}
        if state.waiter, do: GenServer.reply(state.waiter, ready)
        {:noreply, %{state | ready: ready, waiter: nil}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:fixture_exit, status, state.output}, state}
  end

  @impl true
  def terminate(_reason, state) do
    if Port.info(state.port) do
      Port.command(state.port, "stop\n")
      Port.close(state.port)
    end
  end
end
