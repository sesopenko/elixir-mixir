defmodule ElixirMixir.MCP.Tools.RuntimeReplace do
  @moduledoc "Replace a running implementation at an expected worker revision, preserving PID and explicitly migrating schemas."

  use Hermes.Server.Component, type: :tool

  alias ElixirMixir.MCP.Result
  alias ElixirMixir.Runtime.Manager
  alias Hermes.Server.Frame
  alias Hermes.Server.Response

  schema do
    field(:worker_id, {:required, :string})
    field(:artifact_id, {:required, :string})
    field(:expected_revision, {:required, :integer})
    field(:request_id, {:required, :string})
  end

  defoverridable input_schema: 0

  @impl true
  @doc "Advertises a positive worker revision and rejects unknown fields; Manager revalidates original arguments."
  @spec input_schema() :: map()
  def input_schema do
    super()
    |> Map.put("additionalProperties", false)
    |> put_in(["properties", "expected_revision", "minimum"], 1)
  end

  @impl true
  @doc "Delegates replacement to Manager without executing generated migration code in MCP."
  @spec execute(map(), Frame.t()) :: {:reply, Response.t(), Frame.t()}
  def execute(params, frame) do
    args = if frame.request, do: Map.get(frame.request.params, "arguments", %{}), else: params
    id = if frame.request, do: frame.request.id, else: nil
    {:reply, args |> Manager.replace() |> Result.tool(id), frame}
  end
end
