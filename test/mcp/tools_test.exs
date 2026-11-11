defmodule ElixirMixir.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias ElixirMixir.MCP.Result
  alias ElixirMixir.MCP.Tools.RuntimeDefine
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.ResponseBudget

  test "define schema requires all four fields and rejects unknown keys" do
    schema = RuntimeDefine.input_schema()
    assert Enum.sort(schema["required"]) == ~w(expected_behavior logical_name request_id source)
    assert schema["additionalProperties"] == false
    assert Enum.all?(schema["properties"], fn {_key, value} -> value["type"] == "string" end)
  end

  test "kernel preflight covers the exact full MCP encoding with the largest protocol ID" do
    data = %{"api_version" => "1", "generation" => 1, "payload" => String.duplicate("\"", 300)}
    limits = Limits.new(%{response_bytes: 1_024})
    refute ResponseBudget.fits?(data, limits)
    response = Result.tool({:ok, data}, String.duplicate("r", 126), limits)
    assert byte_size(Result.encode(response, String.duplicate("r", 126))) <= 1_024
    assert response.isError
  end
end
