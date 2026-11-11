defmodule ElixirMixir.MCP.Tools.RuntimeInspect do
  @moduledoc "Read runtime health, limits, and the current empty worker topology."

  use Hermes.Server.Component, type: :tool

  alias ElixirMixir.MCP.Result
  alias ElixirMixir.Runtime.Manager
  alias Hermes.Server.Frame
  alias Hermes.Server.Response

  schema do
    field(:worker_id, :string)
    field(:detail, {:enum, ["summary", "state"]})
    field(:limit, {:integer, {:range, {1, 100}}})
    field(:cursor, :string)
  end

  defoverridable input_schema: 0

  @impl true
  @doc "Returns the strict inspection schema; semantic checks also run inside Manager."
  @spec input_schema() :: map()
  def input_schema, do: Map.put(super(), "additionalProperties", false)

  @impl true
  @doc "Inspects through Manager using original arguments before schema filtering."
  @spec execute(map(), Frame.t()) :: {:reply, Response.t(), Frame.t()}
  def execute(params, frame) do
    # Hermes/Peri can filter unknown keys. The frame retains the protocol arguments.
    args = if frame.request, do: Map.get(frame.request.params, "arguments", %{}), else: params
    id = if frame.request, do: frame.request.id, else: nil
    response = args |> Manager.inspect_runtime() |> Result.tool(id)
    {:reply, response, frame}
  end
end
