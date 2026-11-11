defmodule ElixirMixir.MCP.Server do
  @moduledoc "MCP discovery and dispatch for the currently implemented kernel tools."

  use Hermes.Server, name: "elixir-mixir", version: "0.1.0", capabilities: [:tools]

  component(ElixirMixir.MCP.Tools.RuntimeDefine, name: "runtime_define")
  component(ElixirMixir.MCP.Tools.RuntimeEvents, name: "runtime_events")
  component(ElixirMixir.MCP.Tools.RuntimeInspect, name: "runtime_inspect")

  component(ElixirMixir.MCP.Tools.RuntimeInvoke, name: "runtime_invoke")
  component(ElixirMixir.MCP.Tools.RuntimeReplace, name: "runtime_replace")
  component(ElixirMixir.MCP.Tools.RuntimeStart, name: "runtime_start")
  component(ElixirMixir.MCP.Tools.RuntimeStop, name: "runtime_stop")

  @doc "Returns connection instructions included in initialization responses."
  @spec instructions() :: String.t()
  def instructions do
    "Use runtime_inspect for health and runtime_define to compile an inactive Generated template. " <>
      "The runtime lives independently of this connection. API version 1; in-memory metadata only. " <>
      "Define requires logical_name, source, expected_behavior elixir_mixir.behavior.v1 and request_id. " <>
      "Reuse request_id only for identical retries. All four callbacks are mandatory. " <>
      "Use runtime_start with worker_id/artifact_id/config/request_id; runtime_stop retains the definition. " <>
      "Inspect worker state with worker_id and detail state; runtime pages have generation-bound cursors. Use runtime_events after/limit/worker_id for correlated history. Host crashes rerun init within three restart attempts per rolling ten seconds; stopped or exhausted workers require explicit start. " <>
      "Use runtime_invoke with worker_id/event/request_id; repeat an identical ID to replay its outcome. " <>
      "Use runtime_replace with worker_id/artifact_id/expected_revision/request_id. Expected revision is the current worker revision; matching schemas preserve state, changed schemas run explicit migrate. Effects may emit, schedule or log; accepted effect IDs acknowledge admission, and delivery failures appear in history. Generated code requires a trusted disposable environment."
  end
end
