defmodule ElixirMixir.MCP.Result do
  @moduledoc "Encodes bounded MCP results, including duplicate JSON text and structured content."

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias Hermes.Server.Response

  @doc "Encodes a kernel outcome, accounting for the complete JSON-RPC response before returning it."
  @spec tool({:ok | :error, map()}, term(), Limits.t()) :: Response.t()
  def tool(result, id, limits \\ Limits.new(Application.get_env(:elixir_mixir, :limits, %{}))) do
    response = build(result)

    if byte_size(encode(response, id)) <= limits.response_bytes do
      response
    else
      {_status, data} = result

      error =
        Error.new("LIMIT_EXCEEDED")
        |> Map.merge(Map.take(data, ["api_version", "generation", "request_id"]))

      build({:error, error})
    end
  end

  @doc "Serializes a tool result exactly as the Hermes JSON transport does."
  @spec encode(Response.t(), term()) :: binary()
  def encode(response, id) do
    JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => Response.to_protocol(response)}) <>
      "\n"
  end

  defp build({status, data}) do
    response = Response.tool() |> Response.structured(data)
    %{response | isError: status == :error}
  end
end
