defmodule ElixirMixir.MCP.Supervisor do
  @moduledoc "Starts MCP sessions and the listener independently of client lifetimes."

  use Supervisor

  alias ElixirMixir.MCP.Router
  alias ElixirMixir.MCP.Server

  @doc "Starts the MCP subtree with validated listener settings."
  @spec start_link(ElixirMixir.MCP.Config.t()) :: Supervisor.on_start()
  def start_link(config), do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  @doc "Returns the actual bound loopback address and port, including ephemeral test ports."
  @spec address() :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def address, do: ThousandIsland.listener_info(ElixirMixir.MCP.Listener)

  @impl true
  def init(config) do
    children = [
      Hermes.Server.Registry,
      {Server, transport: {:streamable_http, start: true}, request_timeout: 7_000},
      {Bandit,
       plug: {Router, config},
       ip: config.ip,
       port: config.port,
       thousand_island_options: [supervisor_options: [name: ElixirMixir.MCP.Listener]],
       startup_log: false}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
