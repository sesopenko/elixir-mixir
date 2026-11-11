defmodule ElixirMixir.MCP.Tools.RuntimeEvents do
  @moduledoc "Read bounded correlated lifecycle and effect history after an exclusive sequence cursor."

  use Hermes.Server.Component, type: :tool

  alias ElixirMixir.MCP.Result
  alias ElixirMixir.Runtime.Manager
  alias Hermes.Server.Frame
  alias Hermes.Server.Response

  schema do
    field(:after, :integer)
    field(:limit, {:integer, {:range, {1, 100}}})
    field(:worker_id, :string)
  end

  defoverridable input_schema: 0

  @impl true
  @doc "Advertises strict optional history arguments; Manager validates all original fields."
  @spec input_schema() :: map()
  def input_schema do
    super()
    |> Map.put("additionalProperties", false)
    |> put_in(["properties", "after", "minimum"], 0)
  end

  @impl true
  @doc "Reads history through Manager without running generated code or advancing generation."
  @spec execute(map(), Frame.t()) :: {:reply, Response.t(), Frame.t()}
  def execute(params, frame) do
    args = if frame.request, do: Map.get(frame.request.params, "arguments", %{}), else: params
    id = if frame.request, do: frame.request.id, else: nil
    {:reply, args |> Manager.events() |> Result.tool(id), frame}
  end
end
