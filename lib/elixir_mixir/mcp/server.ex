defmodule ElixirMixir.MCP.Server do
  @moduledoc "MCP discovery and dispatch for the currently implemented kernel tools."

  use Hermes.Server, name: "elixir-mixir", version: "0.1.0", capabilities: [:tools]

  component(ElixirMixir.MCP.Tools.RuntimeDefine, name: "runtime_define")
  component(ElixirMixir.MCP.Tools.RuntimeInspect, name: "runtime_inspect")

  @doc "Returns read-only connection instructions included in initialization responses."
  @spec instructions() :: String.t()
  def instructions do
    "Use runtime_inspect for health and runtime_define to compile an inactive Generated template. " <>
      "The runtime lives independently of this connection. API version 1; in-memory metadata only. " <>
      "Define requires logical_name, source, expected_behavior elixir_mixir.behavior.v1 and request_id. " <>
      "Reuse request_id only for identical retries. All four callbacks are mandatory. " <>
      "Compilation does not start workers. Generated code requires a trusted disposable environment."
  end
end
