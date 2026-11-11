defmodule ElixirMixir.MCP.Tools.RuntimeStop do
  @moduledoc "Explicitly stop a logical worker while retaining its definition for reinitialization."

  use Hermes.Server.Component, type: :tool

  alias ElixirMixir.MCP.Result
  alias ElixirMixir.Runtime.Manager
  alias Hermes.Server.Frame
  alias Hermes.Server.Response

  schema do
    field(:worker_id, {:required, :string})
    field(:request_id, {:required, :string})
  end

  defoverridable input_schema: 0

  @impl true
  @doc "Returns the strict stop schema; Manager repeats semantic validation."
  @spec input_schema() :: map()
  def input_schema, do: Map.put(super(), "additionalProperties", false)

  @impl true
  @doc "Delegates original stop arguments to Manager and preserves request replay outcomes."
  @spec execute(map(), Frame.t()) :: {:reply, Response.t(), Frame.t()}
  def execute(params, frame) do
    args = if frame.request, do: Map.get(frame.request.params, "arguments", %{}), else: params
    id = if frame.request, do: frame.request.id, else: nil
    {:reply, args |> Manager.stop_worker() |> Result.tool(id), frame}
  end
end
