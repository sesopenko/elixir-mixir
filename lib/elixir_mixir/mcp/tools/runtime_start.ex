defmodule ElixirMixir.MCP.Tools.RuntimeStart do
  @moduledoc "Start or explicitly reinitialize a logical worker from an immutable artifact and bounded JSON config."

  use Hermes.Server.Component, type: :tool

  alias ElixirMixir.MCP.Result
  alias ElixirMixir.Runtime.Manager
  alias Hermes.Server.Frame
  alias Hermes.Server.Response

  schema do
    field(:worker_id, {:required, :string})
    field(:artifact_id, {:required, :string})
    field(:config, {:required, :map}, type: "object")
    field(:request_id, {:required, :string})
  end

  defoverridable input_schema: 0

  @impl true
  @doc "Returns the strict startup schema; Manager repeats semantic validation."
  @spec input_schema() :: map()
  def input_schema, do: Map.put(super(), "additionalProperties", false)

  @impl true
  @doc "Delegates original startup arguments to Manager without executing callbacks in MCP."
  @spec execute(map(), Frame.t()) :: {:reply, Response.t(), Frame.t()}
  def execute(params, frame) do
    args = if frame.request, do: Map.get(frame.request.params, "arguments", %{}), else: params
    id = if frame.request, do: frame.request.id, else: nil
    {:reply, args |> Manager.start_worker() |> Result.tool(id), frame}
  end
end
