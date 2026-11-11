defmodule ElixirMixir.MCP.Tools.RuntimeDefine do
  @moduledoc "Compile a Generated template as an inactive immutable artifact; retries require the same request ID and arguments."

  use Hermes.Server.Component, type: :tool

  alias ElixirMixir.MCP.Result
  alias ElixirMixir.Runtime.Manager
  alias Hermes.Server.Frame
  alias Hermes.Server.Response

  schema do
    field(:logical_name, {:required, :string})
    field(:source, {:required, :string})
    field(:expected_behavior, {:required, :string})
    field(:request_id, {:required, :string})
  end

  defoverridable input_schema: 0

  @impl true
  @doc "Returns the strict definition schema. Manager repeats validation without schema filtering."
  @spec input_schema() :: map()
  def input_schema, do: Map.put(super(), "additionalProperties", false)

  @impl true
  @doc "Delegates original protocol arguments to Manager, then encodes its bounded outcome."
  @spec execute(map(), Frame.t()) :: {:reply, Response.t(), Frame.t()}
  def execute(params, frame) do
    args = if frame.request, do: Map.get(frame.request.params, "arguments", %{}), else: params
    id = if frame.request, do: frame.request.id, else: nil
    {:reply, args |> Manager.define() |> Result.tool(id), frame}
  end
end
