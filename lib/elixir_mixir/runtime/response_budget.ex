defmodule ElixirMixir.Runtime.ResponseBudget do
  @moduledoc "Preflights mutation outcomes for the largest accepted JSON-RPC correlation ID."

  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Values

  @doc "Checks JSON terms and the full duplicate MCP encoding before any domain commit."
  @spec fits?(map(), Limits.t()) :: boolean()
  def fits?(data, limits) do
    json_limits = %{limits | reply_bytes: limits.response_bytes, depth: limits.depth + 4}

    case Values.validate(data, :reply, json_limits) do
      :ok ->
        # false is longer than true; 126 ASCII characters plus quotes is the 128-byte ID cap.
        result = %{
          "content" => [%{"type" => "text", "text" => JSON.encode!(data)}],
          "structuredContent" => data,
          "isError" => false
        }

        wire =
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => String.duplicate("r", 126),
            "result" => result
          }) <> "\n"

        byte_size(wire) <= limits.response_bytes

      _invalid ->
        false
    end
  end
end
