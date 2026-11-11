defmodule ElixirMixir.Application do
  @moduledoc """
  Starts the permanent supervision tree for the elixir-mixir runtime kernel.
  """

  use Application

  @impl true
  @doc """
  Starts the kernel supervisor with its configured children.
  """
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    children = [ElixirMixir.Runtime.Manager]

    opts = [strategy: :one_for_one, name: ElixirMixir.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
