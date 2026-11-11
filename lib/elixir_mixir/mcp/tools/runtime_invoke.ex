defmodule ElixirMixir.MCP.Tools.RuntimeInvoke do
  @moduledoc "Invoke one bounded worker event, committing valid state once per request ID; effects are not supported yet."

  use Hermes.Server.Component, type: :tool

  alias ElixirMixir.MCP.Result
  alias ElixirMixir.Runtime.Manager
  alias Hermes.Server.Frame
  alias Hermes.Server.Response

  schema do
    field(:worker_id, {:required, :string})
    field(:event, {:required, :map}, type: "object")
    field(:request_id, {:required, :string})
  end

  defoverridable input_schema: 0

  @impl true
  @doc "Returns a strict event schema; semantic validation runs in Manager too."
  @spec input_schema() :: map()
  def input_schema, do: Map.put(super(), "additionalProperties", false)

  @impl true
  @doc "Delegates original event arguments without executing generated code in MCP."
  @spec execute(map(), Frame.t()) :: {:reply, Response.t(), Frame.t()}
  def execute(params, frame) do
    args = if frame.request, do: Map.get(frame.request.params, "arguments", %{}), else: params
    id = if frame.request, do: frame.request.id, else: nil
    {:reply, args |> Manager.invoke() |> Result.tool(id), frame}
  end
end
