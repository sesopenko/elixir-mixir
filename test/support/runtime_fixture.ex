defmodule ElixirMixir.TestSupport.RuntimeFixture do
  @moduledoc "Owns a separate BEAM OS process for reusable runtime HTTP integration tests."

  use GenServer

  @type ready :: %{port: :inet.port_number(), os_pid: String.t()}

  @doc "Launches the test-only runtime script with the compiled application paths."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @doc "Waits for the listener readiness marker with a finite deadline."
  @spec ready(pid()) :: ready()
  def ready(pid), do: GenServer.call(pid, :ready, 15_000)
  @doc "Checks that the fixture still owns a live OS port."
  @spec alive?(pid()) :: boolean()
  def alive?(pid), do: GenServer.call(pid, :alive)

  @doc "Queries test-only control state without adding a production HTTP tool."
  @spec control(pid(), map()) :: map()
  def control(pid, request), do: GenServer.call(pid, {:control, request}, 15_000)

  @impl true
  def init(opts) do
    paths =
      Path.wildcard(Path.join([Path.dirname(Application.app_dir(:elixir_mixir)), "*", "ebin"]))

    args =
      ["--erl", "+S 2:2 +A 2"] ++
        Enum.flat_map(paths, &["-pa", &1]) ++
        ["test/support/runtime_boot.exs", JSON.encode!(Map.new(opts))]

    port =
      Port.open(
        {:spawn_executable, System.find_executable("elixir")},
        [:binary, :exit_status, :stderr_to_stdout, :hide, args: args]
      )

    {:ok, %{port: port, output: "", pending: "", ready: nil, waiter: nil, control_waiter: nil}}
  end

  @impl true
  def handle_call(:ready, from, %{ready: nil} = state), do: {:noreply, %{state | waiter: from}}
  def handle_call(:ready, _from, state), do: {:reply, state.ready, state}

  def handle_call(:alive, _from, state),
    do: {:reply, Port.info(state.port, :os_pid) != nil, state}

  def handle_call({:control, request}, from, state) do
    true = Port.command(state.port, JSON.encode!(request) <> "\n")
    {:noreply, %{state | control_waiter: from}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    parts = String.split(state.pending <> data, "\n")
    {lines, [pending]} = Enum.split(parts, -1)
    state = Enum.reduce(lines, state, &line/2)
    {:noreply, %{state | pending: pending}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:fixture_exit, status, state.output}, state}
  end

  defp line("MIXIR_READY:" <> value, state) do
    [port, os_pid] = String.split(value, ":")
    ready = %{port: String.to_integer(port), os_pid: os_pid}
    if state.waiter, do: GenServer.reply(state.waiter, ready)
    %{state | ready: ready, waiter: nil}
  end

  defp line("MIXIR_CONTROL:" <> value, state) do
    GenServer.reply(state.control_waiter, Jason.decode!(value))
    %{state | control_waiter: nil}
  end

  defp line(value, state),
    do: %{state | output: String.slice(state.output <> value <> "\n", -8_192, 8_192)}

  @impl true
  def terminate(_reason, state) do
    if Port.info(state.port) do
      Port.command(state.port, "stop\n")
      Port.close(state.port)
    end
  end
end
