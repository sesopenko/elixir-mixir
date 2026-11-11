defmodule ElixirMixir.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias ElixirMixir.MCP.Result
  alias ElixirMixir.MCP.Tools.RuntimeDefine
  alias ElixirMixir.MCP.Tools.RuntimeEvents
  alias ElixirMixir.MCP.Tools.RuntimeInvoke
  alias ElixirMixir.MCP.Tools.RuntimeReplace
  alias ElixirMixir.MCP.Tools.RuntimeStart
  alias ElixirMixir.MCP.Tools.RuntimeStop
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.ResponseBudget

  test "define schema requires all four fields and rejects unknown keys" do
    schema = RuntimeDefine.input_schema()
    assert Enum.sort(schema["required"]) == ~w(expected_behavior logical_name request_id source)
    assert schema["additionalProperties"] == false
    assert Enum.all?(schema["properties"], fn {_key, value} -> value["type"] == "string" end)
  end

  test "start and stop advertise required IDs/config and strict object schemas" do
    start = RuntimeStart.input_schema()
    assert Enum.sort(start["required"]) == ~w(artifact_id config request_id worker_id)
    assert start["properties"]["config"]["type"] == "object"
    assert start["additionalProperties"] == false
    stop = RuntimeStop.input_schema()
    assert Enum.sort(stop["required"]) == ~w(request_id worker_id)
    assert stop["additionalProperties"] == false
  end

  test "invoke requires a map event and request identity with no unknown keys" do
    schema = RuntimeInvoke.input_schema()
    assert Enum.sort(schema["required"]) == ~w(event request_id worker_id)
    assert schema["properties"]["event"]["type"] == "object"
    assert schema["additionalProperties"] == false
  end

  test "events advertises optional bounded cursor/filter fields and rejects unknown keys" do
    schema = RuntimeEvents.input_schema()
    assert Map.get(schema, "required", []) == []
    assert Enum.sort(Map.keys(schema["properties"])) == ~w(after limit worker_id)
    assert schema["properties"]["after"]["minimum"] == 0
    assert schema["additionalProperties"] == false
  end

  test "replace requires artifact, positive worker revision and request identity" do
    schema = RuntimeReplace.input_schema()
    assert Enum.sort(schema["required"]) == ~w(artifact_id expected_revision request_id worker_id)
    assert schema["properties"]["expected_revision"]["type"] == "integer"
    assert schema["properties"]["expected_revision"]["minimum"] == 1
    assert schema["additionalProperties"] == false
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
