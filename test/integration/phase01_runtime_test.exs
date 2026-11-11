defmodule ElixirMixir.Phase01RuntimeIntegrationTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures
  alias ElixirMixir.TestSupport.MCPClient, as: Client
  alias ElixirMixir.TestSupport.RuntimeFixture

  setup context do
    opts = [limits: Map.get(context, :limits, %{})]
    fixture = start_supervised!({RuntimeFixture, opts})
    ready = RuntimeFixture.ready(fixture)
    client = Client.new(ready.port)
    on_exit(fn -> Client.close(%{client | session: nil}) end)
    {_init, _notification, client} = Client.initialize(client)
    %{fixture: fixture, client: client, ready: ready}
  end

  test "define, immutable artifact identity, revisions and replay survive reconnect", ctx do
    args = args(Fixtures.source())
    first = define(ctx.client, args)
    assert first["generation"] == 1
    assert first["revision"] == 1

    assert first["source_hash"] ==
             :crypto.hash(:sha256, args["source"]) |> Base.encode16(case: :lower)

    control = %{"op" => "artifact", "id" => first["artifact_id"]}
    artifact = RuntimeFixture.control(ctx.fixture, control)
    assert artifact["module"] == first["module"]
    assert artifact["beam_bytes"] > 0
    assert artifact["compiler_helpers"] > 0
    assert define(ctx.client, args) == first
    assert status(ctx)["attempts"] == 1
    assert :ok = Client.close(ctx.client)

    client = Client.new(ctx.ready.port)
    on_exit(fn -> Client.close(%{client | session: nil}) end)
    {_init, _notification, client} = Client.initialize(client)
    assert define(client, args) == first
    assert status(ctx)["attempts"] == 1
    assert RuntimeFixture.control(ctx.fixture, control) == artifact
    {response, _} = Client.call(client, "runtime_inspect")
    assert response.data["result"]["structuredContent"]["generation"] == 1
    assert response.data["result"]["structuredContent"]["workers"] == []
    second = define(client, Map.put(args, "request_id", "next-revision"))
    assert second["revision"] == 2
    refute second["module"] == first["module"]
    assert RuntimeFixture.control(ctx.fixture, control) == artifact
  end

  test "invalid source, missing callbacks, warnings and conflicts preserve the good artifact",
       ctx do
    args = args(Fixtures.source())
    first = define(ctx.client, args)
    control = %{"op" => "artifact", "id" => first["artifact_id"]}
    artifact = RuntimeFixture.control(ctx.fixture, control)

    for {source, code} <- [
          {"defmodule Generated do", "COMPILE_FAILED"},
          {"defmodule Generated do @behaviour ElixirMixir.Behavior end", "CALLBACK_MISSING"},
          {Fixtures.source(body: "IO.warn(\"rejected warning\")"), "COMPILE_FAILED"},
          {Fixtures.source(schema: "-1"), "COMPILE_FAILED"}
        ] do
      altered = %{args | "source" => source, "request_id" => "reject-#{status(ctx)["attempts"]}"}
      {response, _} = Client.call(ctx.client, "runtime_define", altered)
      assert response.data["result"]["isError"]
      error = result(response)
      assert error["code"] == code
      assert error["generation"] == 1
      assert byte_size(response.body) <= 65_536
      assert define(ctx.client, altered) == error
      assert RuntimeFixture.control(ctx.fixture, control) == artifact
    end

    {response, _} =
      Client.call(ctx.client, "runtime_define", Map.put(args, "source", "different"))

    assert result(response)["code"] == "REQUEST_ID_CONFLICT"
    assert status(ctx) == %{"attempts" => 5, "artifacts" => 1}
    events = RuntimeFixture.control(ctx.fixture, %{"op" => "events"})["events"]
    assert Enum.count(events, &(&1["type"] == "compile_succeeded")) == 1
    assert Enum.count(events, &(&1["type"] == "compile_failed")) == 4
  end

  @tag limits: %{artifact_slots: 2}
  test "failed slots are consumed across application restarts within one BEAM", ctx do
    args = args("invalid")
    assert define(ctx.client, args)["code"] == "COMPILE_FAILED"

    assert define(ctx.client, Map.put(args, "request_id", "failure-2"))["code"] ==
             "COMPILE_FAILED"

    assert define(ctx.client, Map.put(args, "request_id", "exhausted"))["code"] ==
             "LIMIT_EXCEEDED"

    assert status(ctx) == %{"attempts" => 2, "artifacts" => 0}
    Client.close(%{ctx.client | session: nil})
    restart = RuntimeFixture.control(ctx.fixture, %{"op" => "restart_application"})
    client = Client.new(restart["port"])
    on_exit(fn -> Client.close(%{client | session: nil}) end)
    {_init, _notification, client} = Client.initialize(client)

    assert define(client, Map.put(args, "request_id", "after-restart"))["code"] ==
             "LIMIT_EXCEEDED"

    assert status(ctx)["attempts"] == 2
  end

  test "the default five-second compiler deadline returns a runtime error over HTTP", ctx do
    args = args(Fixtures.source(body: "Process.sleep(:infinity)"))
    assert define(ctx.client, args)["code"] == "COMPILE_FAILED"
    assert define(ctx.client, args)["code"] == "COMPILE_FAILED"
    assert status(ctx)["attempts"] == 1
    assert Client.raw(ctx.client, :get, "/health").status == 200
  end

  @tag limits: %{compile_timeout_ms: 100, callback_timeout_ms: 30}
  test "compile and schema timeout errors leave HTTP and metadata available", ctx do
    for {source, id} <- [
          {Fixtures.source(body: "Process.sleep(:infinity)"), "compile-timeout"},
          {Fixtures.source(schema: "Process.sleep(:infinity)"), "schema-timeout"}
        ] do
      assert define(ctx.client, %{args(source) | "request_id" => id})["code"] == "COMPILE_FAILED"
      assert Client.raw(ctx.client, :get, "/health").status == 200
    end

    assert status(ctx) == %{"attempts" => 2, "artifacts" => 0}
  end

  test "unknown argument keys and over-limit source never consume a compiler slot", ctx do
    for altered <- [
          Map.put(args(Fixtures.source()), "unexpected", true),
          Map.put(args(String.duplicate("x", 32_769)), "request_id", "oversized")
        ] do
      assert define(ctx.client, altered)["code"] in ["INVALID_ARGUMENT", "LIMIT_EXCEEDED"]
    end

    assert status(ctx)["attempts"] == 0
  end

  test "loss of authoritative registry shuts down the kernel instead of resetting it", ctx do
    assert RuntimeFixture.control(ctx.fixture, %{"op" => "kill_registry"}) == %{
             "kernel_down" => true,
             "manager_alive" => false
           }

    assert RuntimeFixture.alive?(ctx.fixture)
  end

  defp define(client, args) do
    {response, _} = Client.call(client, "runtime_define", args)
    assert response.status == 200
    result(response)
  end

  defp result(response) do
    data = response.data["result"]["structuredContent"]
    assert Jason.decode!(hd(response.data["result"]["content"])["text"]) == data
    data
  end

  defp status(ctx), do: RuntimeFixture.control(ctx.fixture, %{"op" => "registry_status"})

  defp args(source),
    do: %{
      "logical_name" => "counter",
      "request_id" => "define-counter",
      "source" => source,
      "expected_behavior" => "elixir_mixir.behavior.v1"
    }
end
