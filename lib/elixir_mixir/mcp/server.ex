defmodule ElixirMixir.MCP.Server do
  @moduledoc "MCP discovery and dispatch for the currently implemented kernel tools."

  use Hermes.Server, name: "elixir-mixir", version: "0.1.0", capabilities: [:tools]

  component(ElixirMixir.MCP.Tools.RuntimeInspect, name: "runtime_inspect")

  @doc "Returns read-only connection instructions included in initialization responses."
  @spec instructions() :: String.t()
  def instructions do
    "Use runtime_inspect to read runtime health and configured limits. " <>
      "The runtime lives independently of this connection. API version 1; in-memory metadata only. " <>
      "No worker or generated behavior tools are available at this checkpoint."
  end
end
