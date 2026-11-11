defmodule ElixirMixir.Application do
  @moduledoc """
  Starts the permanent supervision tree for the elixir-mixir runtime kernel.
  """

  use Application

  alias ElixirMixir.MCP.Config
  alias ElixirMixir.MCP.Supervisor, as: MCPSupervisor
  alias ElixirMixir.Runtime.Manager

  @impl true
  @doc """
  Starts the kernel supervisor with its configured children.
  """
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    config = Config.new(Application.get_env(:elixir_mixir, :mcp, []))
    mcp = if config.enabled, do: [{MCPSupervisor, config}], else: []
    children = [Manager] ++ mcp

    opts = [strategy: :one_for_one, name: ElixirMixir.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
