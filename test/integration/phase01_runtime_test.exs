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

  test "HTTP invocation commits once and rejected definitions cannot alter the active counter",
       ctx do
    artifact = define(ctx.client, args(Fixtures.counter_source()))
    started = start_counter(ctx.client, artifact)

    result =
      tool(ctx.client, "runtime_invoke", %{
        "worker_id" => "counter",
        "event" => %{"amount" => 3},
        "request_id" => "increment"
      })

    assert result["reply"] == 3
    assert result["state_revision"] == 2
    assert result["effects"] == []
    before = counter_snapshot(ctx.client)
    assert before["pid"] == started["pid"]
    assert before["state"] == %{"count" => 3}

    for {source, id} <- [
          {"defmodule Generated do", "bad-source"},
          {"defmodule Generated do end", "missing-callbacks"}
        ] do
      assert define(ctx.client, Map.put(args(source), "request_id", id))["code"] in [
               "COMPILE_FAILED",
               "CALLBACK_MISSING"
             ]

      assert counter_snapshot(ctx.client) == before
    end

    next =
      tool(ctx.client, "runtime_invoke", %{
        "worker_id" => "counter",
        "event" => %{"amount" => 2},
        "request_id" => "increment-next"
      })

    assert next["reply"] == 5
    assert counter_snapshot(ctx.client)["pid"] == started["pid"]
  end

  test "HTTP timeout, malformed transitions and payload limits preserve committed counter state",
       ctx do
    artifact = define(ctx.client, args(Fixtures.counter_source()))
    start_counter(ctx.client, artifact)
    before = counter_snapshot(ctx.client)

    for {event, code, id} <- [
          {%{"mode" => "timeout"}, "CALLBACK_TIMEOUT", "timeout"},
          {%{"mode" => "effects"}, "INVALID_TRANSITION", "effects"},
          {%{"mode" => "malformed"}, "INVALID_TRANSITION", "malformed"},
          {%{"mode" => "reply_non_json"}, "INVALID_TRANSITION", "non-json"},
          {%{"mode" => "reply_payload", "bytes" => 16_383}, "LIMIT_EXCEEDED", "reply-limit"},
          {%{"big" => String.duplicate("x", 16_384)}, "LIMIT_EXCEEDED", "event-limit"}
        ] do
      outcome =
        tool(ctx.client, "runtime_invoke", %{
          "worker_id" => "counter",
          "event" => event,
          "request_id" => id
        })

      assert outcome["code"] == code
      assert counter_snapshot(ctx.client) == before
    end

    accepted =
      tool(ctx.client, "runtime_invoke", %{
        "worker_id" => "counter",
        "event" => %{},
        "request_id" => "healthy"
      })

    assert accepted["reply"] == 1

    {response, _client} =
      Client.call(ctx.client, "runtime_invoke", %{
        "worker_id" => "counter",
        "event" => %{},
        "request_id" => "healthy"
      })

    assert byte_size(response.body) <= 65_536
    assert result(response) == accepted
  end

  test "disconnect during accepted HTTP work and retry in a fresh client commits exactly one increment",
       ctx do
    artifact = define(ctx.client, args(Fixtures.counter_source()))
    started = start_counter(ctx.client, artifact)

    invoke_args = %{
      "worker_id" => "counter",
      "event" => %{"mode" => "controlled"},
      "request_id" => "once-across-disconnect"
    }

    pending =
      Task.async(fn ->
        try do
          {:unexpected_response, Client.call(ctx.client, "runtime_invoke", invoke_args)}
        rescue
          MatchError -> :connection_closed
        end
      end)

    assert await_barrier(ctx.fixture, 100)
    Client.disconnect(ctx.client)

    assert RuntimeFixture.control(ctx.fixture, %{"op" => "release_barrier", "key" => "invoke"})[
             "released"
           ]

    assert Task.await(pending, 1_000) == :connection_closed

    client = Client.new(ctx.ready.port)
    on_exit(fn -> Client.close(%{client | session: nil}) end)
    {_init, _notification, client} = Client.initialize(client)
    replay = tool(client, "runtime_invoke", invoke_args)
    assert replay["reply"] == 1
    assert replay["state_revision"] == 2
    assert replay["generation"] == 3
    assert counter_snapshot(client)["state"] == %{"count" => 1}
    assert counter_snapshot(client)["pid"] == started["pid"]
    assert tool(client, "runtime_invoke", invoke_args) == replay
  end

  @tag limits: %{response_bytes: 2_048}
  test "HTTP full-response preflight rejects an otherwise valid reply without a state change",
       ctx do
    artifact = define(ctx.client, args(Fixtures.counter_source()))
    start_counter(ctx.client, artifact)
    before = counter_snapshot(ctx.client)

    outcome =
      tool(ctx.client, "runtime_invoke", %{
        "worker_id" => "counter",
        "event" => %{"mode" => "reply_payload", "bytes" => 1_500},
        "request_id" => "too-large-on-wire"
      })

    assert outcome["code"] == "LIMIT_EXCEEDED"
    assert counter_snapshot(ctx.client) == before
  end

  defp start_counter(client, artifact) do
    tool(client, "runtime_start", %{
      "worker_id" => "counter",
      "artifact_id" => artifact["artifact_id"],
      "config" => %{},
      "request_id" => "start-counter"
    })
  end

  defp counter_snapshot(client),
    do: tool(client, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"})

  defp await_barrier(_fixture, 0), do: false

  defp await_barrier(fixture, remaining) do
    if RuntimeFixture.control(fixture, %{"op" => "barrier_status", "key" => "invoke"})["waiting"] do
      true
    else
      Process.sleep(1)
      await_barrier(fixture, remaining - 1)
    end
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
