defmodule ElixirMixir.Application do
  @moduledoc """
  Starts the permanent supervision tree for the elixir-mixir runtime kernel.
  """

  use Application

  alias ElixirMixir.MCP.Config
  alias ElixirMixir.MCP.Supervisor, as: MCPSupervisor
  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.Manager

  @impl true
  @doc """
  Starts the kernel supervisor with its configured children.
  """
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    config = Config.new(Application.get_env(:elixir_mixir, :mcp, []))
    mcp = if config.enabled, do: [{MCPSupervisor, config}], else: []

    children =
      [
        EventLog,
        Supervisor.child_spec(ArtifactRegistry, restart: :temporary, significant: true),
        Supervisor.child_spec({Task.Supervisor, name: ElixirMixir.CompilerTasks},
          id: ElixirMixir.CompilerTasks
        ),
        Supervisor.child_spec({Task.Supervisor, name: ElixirMixir.CallbackTasks},
          id: ElixirMixir.CallbackTasks
        ),
        {Registry, keys: :unique, name: ElixirMixir.Runtime.ProcessRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: ElixirMixir.Runtime.WorkerSupervisor},
        Supervisor.child_spec(Manager, restart: :temporary, significant: true)
      ] ++ mcp

    opts = [strategy: :one_for_one, auto_shutdown: :any_significant, name: ElixirMixir.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
