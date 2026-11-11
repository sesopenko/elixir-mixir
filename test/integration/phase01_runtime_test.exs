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

  test "define/start/inspect/stop is supervised and worker identity survives client reconnect",
       ctx do
    artifact = define(ctx.client, args(Fixtures.worker_source()))

    start = %{
      "worker_id" => "counter",
      "artifact_id" => artifact["artifact_id"],
      "config" => %{"count" => 7},
      "request_id" => "start-counter"
    }

    first = tool(ctx.client, "runtime_start", start)
    assert first["worker_revision"] == 1
    assert first["state_revision"] == 1
    assert first["generation"] == 2

    assert RuntimeFixture.control(ctx.fixture, %{"op" => "worker_membership", "id" => "counter"}) ==
             %{"registered" => true, "supervised" => true, "pid" => first["pid"]}

    assert tool(ctx.client, "runtime_start", start) == first

    assert tool(ctx.client, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"})[
             "state"
           ] == %{"count" => 7}

    Client.close(ctx.client)
    client = Client.new(ctx.ready.port)
    on_exit(fn -> Client.close(%{client | session: nil}) end)
    {_init, _notification, client} = Client.initialize(client)
    snapshot = tool(client, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"})
    assert snapshot["pid"] == first["pid"]
    assert snapshot["state"] == %{"count" => 7}

    stopped =
      tool(client, "runtime_stop", %{"worker_id" => "counter", "request_id" => "stop-counter"})

    assert stopped["definition_retained"]
    assert stopped["worker_revision"] == 2

    repeated =
      tool(client, "runtime_stop", %{"worker_id" => "counter", "request_id" => "stop-again"})

    assert repeated["generation"] == stopped["generation"]
    assert tool(client, "runtime_inspect", %{"worker_id" => "counter"})["status"] == "stopped"

    restarted =
      tool(client, "runtime_start", %{
        start
        | "request_id" => "restart-counter",
          "config" => %{"count" => 9}
      })

    assert restarted["worker_revision"] == 3
    assert restarted["state_revision"] == 2
    refute restarted["pid"] == first["pid"]

    assert tool(client, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"})[
             "state"
           ] == %{"count" => 9}
  end

  test "init failure, timeout and schema errors leave no live half-created worker", ctx do
    artifact = define(ctx.client, args(Fixtures.worker_source()))

    base = %{
      "worker_id" => "counter",
      "artifact_id" => artifact["artifact_id"],
      "config" => %{},
      "request_id" => "start"
    }

    for {mode, code} <- [
          {"error", "CALLBACK_FAILED"},
          {"timeout", "CALLBACK_TIMEOUT"},
          {"non_json", "INVALID_TRANSITION"}
        ] do
      result =
        tool(ctx.client, "runtime_start", %{
          base
          | "config" => %{"mode" => mode},
            "request_id" => mode
        })

      assert result["code"] == code
      assert result["generation"] == 1

      assert RuntimeFixture.control(ctx.fixture, %{"op" => "worker_membership", "id" => "counter"}) ==
               %{"registered" => false, "supervised" => false}
    end

    assert tool(ctx.client, "runtime_start", Map.put(base, "unknown", true))["code"] ==
             "INVALID_ARGUMENT"

    {response, _client} = Client.call(ctx.client, "runtime_start", Map.delete(base, "request_id"))
    assert response.status == 200
    assert response.data["error"]["code"] == -32_602

    assert tool(ctx.client, "runtime_stop", %{
             "worker_id" => "missing",
             "request_id" => "unknown-stop"
           })["code"] == "WORKER_NOT_FOUND"
  end

  test "a test-controlled host kill preserves HTTP and peer state without automatic restart",
       ctx do
    artifact = define(ctx.client, args(Fixtures.worker_source()))

    start = %{
      "worker_id" => "counter",
      "artifact_id" => artifact["artifact_id"],
      "config" => %{"value" => 1},
      "request_id" => "start"
    }

    _first = tool(ctx.client, "runtime_start", start)

    peer =
      tool(ctx.client, "runtime_start", %{
        start
        | "worker_id" => "peer",
          "request_id" => "peer-start"
      })

    assert RuntimeFixture.control(ctx.fixture, %{"op" => "kill_host", "id" => "counter"})[
             "killed"
           ]

    failed = await_worker(ctx.client, "counter", "failed", 50)
    assert failed["pid"] == nil

    assert tool(ctx.client, "runtime_inspect", %{"worker_id" => "peer", "detail" => "state"})[
             "state"
           ] == %{"value" => 1}

    assert tool(ctx.client, "runtime_inspect", %{"worker_id" => "peer"})["pid"] == peer["pid"]
    assert Client.raw(ctx.client, :get, "/health").status == 200
    restarted = tool(ctx.client, "runtime_start", %{start | "request_id" => "manual-recovery"})
    assert restarted["worker_revision"] > failed["worker_revision"]
  end

  test "the full config depth limit survives HTTP and worker inspection", ctx do
    artifact = define(ctx.client, args(Fixtures.worker_source()))
    config = Enum.reduce(1..16, %{}, fn _, child -> %{"nested" => child} end)

    start = %{
      "worker_id" => "counter",
      "artifact_id" => artifact["artifact_id"],
      "config" => config,
      "request_id" => "deep-start"
    }

    assert tool(ctx.client, "runtime_start", start)["status"] == "running"

    assert tool(ctx.client, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"})[
             "state"
           ] == config

    assert tool(ctx.client, "runtime_start", %{
             start
             | "config" => %{"extra" => config},
               "worker_id" => "too-deep",
               "request_id" => "deep-reject"
           })["code"] == "LIMIT_EXCEEDED"
  end

  defp await_worker(_client, _id, _status, 0), do: flunk("worker lifecycle did not settle")

  defp await_worker(client, id, status, remaining) do
    snapshot = tool(client, "runtime_inspect", %{"worker_id" => id})

    if snapshot["status"] == status,
      do: snapshot,
      else:
        (
          Process.sleep(5)
          await_worker(client, id, status, remaining - 1)
        )
  end

  defp tool(client, name, args) do
    {response, _} = Client.call(client, name, args)
    assert response.status == 200
    result(response)
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
