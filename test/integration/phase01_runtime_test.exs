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

  test "host recovery resets volatile state while HTTP, peers and BEAM survive reconnect", ctx do
    artifact = define(ctx.client, args(Fixtures.recovery_source()))

    start = %{
      "worker_id" => "counter",
      "artifact_id" => artifact["artifact_id"],
      "config" => %{"value" => 1},
      "request_id" => "start"
    }

    first = tool(ctx.client, "runtime_start", start)

    peer =
      tool(ctx.client, "runtime_start", %{
        start
        | "worker_id" => "peer",
          "request_id" => "peer-start"
      })

    assert tool(ctx.client, "runtime_invoke", %{
             "worker_id" => "counter",
             "event" => %{"value" => 9},
             "request_id" => "before-crash"
           })["state_revision"] == 2

    health = Client.raw(ctx.client, :get, "/health").data

    assert RuntimeFixture.control(ctx.fixture, %{"op" => "kill_host", "id" => "counter"})[
             "killed"
           ]

    Client.disconnect(ctx.client)
    fresh = Client.new(ctx.ready.port)
    on_exit(fn -> Client.close(%{fresh | session: nil}) end)
    {_init, _notification, fresh} = Client.initialize(fresh)
    restarted = await_worker(fresh, "counter", "running", 100)
    refute restarted["pid"] == first["pid"]
    assert restarted["state"] == %{"value" => 1}
    assert restarted["state_revision"] == 3
    assert restarted["worker_revision"] > first["worker_revision"]
    assert restarted["restart_count"] == 1
    assert restarted["artifact_id"] == artifact["artifact_id"]
    assert tool(fresh, "runtime_inspect", %{"worker_id" => "peer"})["pid"] == peer["pid"]

    assert tool(fresh, "runtime_invoke", %{
             "worker_id" => "peer",
             "event" => %{"value" => 2},
             "request_id" => "peer-event"
           })["reply"] == %{"value" => 2}

    assert Client.raw(fresh, :get, "/health").data == health
    assert RuntimeFixture.alive?(ctx.fixture)
  end

  test "HTTP observes exhaustion, manual budget reset and stop during a pending retry", ctx do
    artifact = define(ctx.client, args(Fixtures.recovery_source()))

    start = %{
      "worker_id" => "counter",
      "artifact_id" => artifact["artifact_id"],
      "config" => %{"value" => 1},
      "request_id" => "start"
    }

    tool(ctx.client, "runtime_start", start)
    RuntimeFixture.control(ctx.fixture, %{"op" => "recovery_failure", "enabled" => true})
    RuntimeFixture.control(ctx.fixture, %{"op" => "kill_host", "id" => "counter"})
    failed = await_worker(ctx.client, "counter", "failed", 150)
    assert failed["restart_count"] == 3
    assert failed["pid"] == nil

    assert tool(ctx.client, "runtime_invoke", %{
             "worker_id" => "counter",
             "event" => %{},
             "request_id" => "failed-invoke"
           })["code"] == "WORKER_NOT_RUNNING"

    events = RuntimeFixture.control(ctx.fixture, %{"op" => "events"})["events"]
    assert Enum.count(events, &(&1["type"] == "worker_restart_attempt")) == 3
    RuntimeFixture.control(ctx.fixture, %{"op" => "recovery_failure", "enabled" => false})

    rejected =
      tool(ctx.client, "runtime_start", %{
        start
        | "config" => %{"value" => 2},
          "request_id" => "change-failed-without-stop"
      })

    assert rejected["code"] == "INVALID_ARGUMENT"
    assert rejected["details"]["hint"] =~ "Stop the worker"

    assert tool(ctx.client, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"}) ==
             failed

    restarted = tool(ctx.client, "runtime_start", %{start | "request_id" => "manual-recovery"})
    assert restarted["restart_count"] == 0
    assert restarted["worker_revision"] > failed["worker_revision"]
    RuntimeFixture.control(ctx.fixture, %{"op" => "kill_host", "id" => "counter"})
    await_worker(ctx.client, "counter", "restarting", 50)

    stopped =
      tool(ctx.client, "runtime_stop", %{
        "worker_id" => "counter",
        "request_id" => "stop-recovery"
      })

    Process.sleep(400)
    assert tool(ctx.client, "runtime_inspect", %{"worker_id" => "counter"})["status"] == "stopped"

    assert tool(ctx.client, "runtime_inspect", %{"worker_id" => "counter"})["generation"] ==
             stopped["generation"]

    refute RuntimeFixture.control(ctx.fixture, %{"op" => "worker_membership", "id" => "counter"})[
             "registered"
           ]

    assert tool(ctx.client, "runtime_start", %{
             start
             | "config" => %{"value" => 2},
               "request_id" => "change-after-stop"
           })["status"] == "running"

    assert worker_state(ctx.client, "counter") == %{"value" => 2}
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

  test "HTTP counter effects deliver exact aggregate totals and correlated logs", ctx do
    artifact = define(ctx.client, args(Fixtures.effects_source()))
    effect_start(ctx.client, artifact, "aggregate")
    effect_start(ctx.client, artifact, "counter", %{"forward" => "aggregate"})

    for amount <- [5, 3] do
      result =
        tool(ctx.client, "runtime_invoke", %{
          "worker_id" => "counter",
          "event" => %{"amount" => amount},
          "request_id" => "counter-#{amount}"
        })

      assert [%{"status" => "accepted", "effect_id" => id}] = result["effects"]
      assert byte_size(id) == 64
    end

    await_http(fn -> worker_state(ctx.client, "aggregate")["total"] == 8 end)
    assert worker_state(ctx.client, "aggregate")["count"] == 2
    effect_start(ctx.client, artifact, "emitter")

    batch = [
      %{"type" => "schedule", "to" => "aggregate", "delay_ms" => 20, "event" => %{"amount" => 4}},
      %{
        "type" => "log",
        "level" => "info",
        "message" => "HTTP effect log",
        "metadata" => %{"value" => 7}
      }
    ]

    assert length(
             tool(ctx.client, "runtime_invoke", %{
               "worker_id" => "emitter",
               "event" => %{"effects" => batch},
               "request_id" => "scheduled-log"
             })["effects"]
           ) == 2

    await_http(fn -> worker_state(ctx.client, "aggregate")["total"] == 12 end)
    assert worker_state(ctx.client, "aggregate")["count"] == 3

    records =
      RuntimeFixture.control(ctx.fixture, %{"op" => "events", "args" => %{"limit" => 100}})[
        "events"
      ]

    assert Enum.any?(
             records,
             &(&1["type"] == "effect_log" and &1["request_id"] == "scheduled-log")
           )

    before = worker_state(ctx.client, "emitter")
    malformed = [hd(batch), %{"type" => "unsupported"}]

    assert tool(ctx.client, "runtime_invoke", %{
             "worker_id" => "emitter",
             "event" => %{"effects" => malformed},
             "request_id" => "bad-batch"
           })["code"] == "INVALID_TRANSITION"

    assert worker_state(ctx.client, "emitter") == before
    assert worker_state(ctx.client, "aggregate")["count"] == 3
  end

  test "physical HTTP disconnect and replay produce one increment and one aggregate delivery",
       ctx do
    artifact = define(ctx.client, args(Fixtures.effects_source()))
    effect_start(ctx.client, artifact, "aggregate")
    first = effect_start(ctx.client, artifact, "counter", %{"forward" => "aggregate"})

    request = %{
      "worker_id" => "counter",
      "event" => %{"amount" => 9, "controlled" => true},
      "request_id" => "effect-disconnect"
    }

    pending =
      Task.async(fn ->
        try do
          {:unexpected_response, Client.call(ctx.client, "runtime_invoke", request)}
        rescue
          MatchError -> :connection_closed
        end
      end)

    await_http(fn ->
      RuntimeFixture.control(ctx.fixture, %{"op" => "barrier_status", "key" => "effects"})[
        "waiting"
      ] == true
    end)

    Client.disconnect(ctx.client)
    RuntimeFixture.control(ctx.fixture, %{"op" => "release_barrier", "key" => "effects"})
    assert Task.await(pending, 1_000) == :connection_closed
    fresh = Client.new(ctx.ready.port)
    on_exit(fn -> Client.close(%{fresh | session: nil}) end)
    {_init, _notification, fresh} = Client.initialize(fresh)
    original = tool(fresh, "runtime_invoke", request)
    assert original["reply"] == 1
    assert length(original["effects"]) == 1
    assert tool(fresh, "runtime_invoke", request) == original
    await_http(fn -> worker_state(fresh, "aggregate")["total"] == 9 end)

    await_http(fn ->
      RuntimeFixture.control(ctx.fixture, %{"op" => "dispatcher_status"})["pending"] == 0
    end)

    assert worker_state(fresh, "counter")["count"] == 1
    assert worker_state(fresh, "aggregate")["count"] == 1
    assert tool(fresh, "runtime_inspect", %{"worker_id" => "counter"})["pid"] == first["pid"]
    assert RuntimeFixture.alive?(ctx.fixture)
  end

  @tag limits: %{pending_effects: 2, effects: 2, effect_hops: 2}
  test "HTTP effect capacity, hop limits, stopped targets and stop cancellation are observable",
       ctx do
    artifact = define(ctx.client, args(Fixtures.effects_source()))
    effect_start(ctx.client, artifact, "counter", %{"forward" => "aggregate"})
    effect_start(ctx.client, artifact, "aggregate", %{"forward" => "counter"})

    tool(ctx.client, "runtime_invoke", %{
      "worker_id" => "counter",
      "event" => %{},
      "request_id" => "cycle"
    })

    await_http(fn ->
      RuntimeFixture.control(ctx.fixture, %{"op" => "dispatcher_status"})["pending"] == 0
    end)

    assert worker_state(ctx.client, "counter")["count"] +
             worker_state(ctx.client, "aggregate")["count"] == 3

    records =
      RuntimeFixture.control(ctx.fixture, %{"op" => "events", "args" => %{"limit" => 100}})[
        "events"
      ]

    assert Enum.any?(
             records,
             &(&1["type"] == "effect_failed" and &1["metadata"]["code"] == "HOP_LIMIT")
           )

    effect_start(ctx.client, artifact, "emitter")
    timer = %{"type" => "schedule", "to" => "aggregate", "delay_ms" => 60_000, "event" => %{}}

    assert length(
             tool(ctx.client, "runtime_invoke", %{
               "worker_id" => "emitter",
               "event" => %{"effects" => [timer, timer]},
               "request_id" => "fill"
             })["effects"]
           ) == 2

    before = worker_state(ctx.client, "emitter")

    assert tool(ctx.client, "runtime_invoke", %{
             "worker_id" => "emitter",
             "event" => %{"effects" => [timer]},
             "request_id" => "full"
           })["code"] == "LIMIT_EXCEEDED"

    assert worker_state(ctx.client, "emitter") == before
    tool(ctx.client, "runtime_stop", %{"worker_id" => "emitter", "request_id" => "cancel-timers"})
    assert RuntimeFixture.control(ctx.fixture, %{"op" => "dispatcher_status"})["pending"] == 0
    effect_start(ctx.client, artifact, "sender")
    tool(ctx.client, "runtime_stop", %{"worker_id" => "aggregate", "request_id" => "stop-target"})
    effects = Enum.map(["aggregate", "missing"], &%{"type" => "emit", "to" => &1, "event" => %{}})

    accepted =
      tool(ctx.client, "runtime_invoke", %{
        "worker_id" => "sender",
        "event" => %{"effects" => effects},
        "request_id" => "bad-targets"
      })

    assert length(accepted["effects"]) == 2

    await_http(fn ->
      RuntimeFixture.control(ctx.fixture, %{"op" => "dispatcher_status"})["pending"] == 0
    end)

    records =
      RuntimeFixture.control(ctx.fixture, %{"op" => "events", "args" => %{"limit" => 100}})[
        "events"
      ]

    codes =
      for record <- records,
          record["type"] == "effect_failed" and record["request_id"] == "bad-targets",
          do: record["metadata"]["code"]

    assert Enum.sort(codes) == ["WORKER_NOT_FOUND", "WORKER_NOT_RUNNING"]
  end

  test "HTTP delayed delivery resolves the target after its host crashes and restarts", ctx do
    artifact = define(ctx.client, args(Fixtures.effects_source()))
    first = effect_start(ctx.client, artifact, "aggregate")
    effect_start(ctx.client, artifact, "counter")

    timer = %{
      "type" => "schedule",
      "to" => "aggregate",
      "delay_ms" => 300,
      "event" => %{"amount" => 11}
    }

    accepted =
      tool(ctx.client, "runtime_invoke", %{
        "worker_id" => "counter",
        "event" => %{"effects" => [timer]},
        "request_id" => "route-after-crash"
      })

    assert length(accepted["effects"]) == 1
    RuntimeFixture.control(ctx.fixture, %{"op" => "kill_host", "id" => "aggregate"})
    restarted = await_worker(ctx.client, "aggregate", "running", 100)
    refute restarted["pid"] == first["pid"]
    await_http(fn -> worker_state(ctx.client, "aggregate")["total"] == 11 end)
    assert worker_state(ctx.client, "aggregate")["count"] == 1
  end

  test "public HTTP inspection explains relationships, pending timers and correlated history across clients",
       ctx do
    artifact = define(ctx.client, args(Fixtures.effects_source()))
    effect_start(ctx.client, artifact, "aggregate")
    effect_start(ctx.client, artifact, "counter", %{"forward" => "aggregate"})

    tool(ctx.client, "runtime_invoke", %{
      "worker_id" => "counter",
      "event" => %{"amount" => 6},
      "request_id" => "observed-delivery"
    })

    await_http(fn -> worker_state(ctx.client, "aggregate")["total"] == 6 end)
    await_http(fn -> tool(ctx.client, "runtime_inspect", %{})["effects"]["pending"] == 0 end)
    overview = tool(ctx.client, "runtime_inspect", %{})

    assert overview["topology"] == [
             %{"from" => "counter", "to" => "aggregate", "count" => 1, "pending" => 0}
           ]

    assert overview["worker_count"] == 2

    counter =
      tool(ctx.client, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"})

    member =
      RuntimeFixture.control(ctx.fixture, %{"op" => "worker_membership", "id" => "counter"})

    assert counter["pid"] == member["pid"]
    assert counter["artifact"]["source_hash"] == artifact["source_hash"]
    effect_start(ctx.client, artifact, "emitter")

    effects = [
      %{"type" => "schedule", "to" => "aggregate", "delay_ms" => 60_000, "event" => %{}},
      %{"type" => "emit", "to" => "missing", "event" => %{}}
    ]

    tool(ctx.client, "runtime_invoke", %{
      "worker_id" => "emitter",
      "event" => %{"effects" => effects},
      "request_id" => "observed-failure"
    })

    await_http(fn -> tool(ctx.client, "runtime_inspect", %{})["effects"]["pending"] == 1 end)
    overview = tool(ctx.client, "runtime_inspect", %{})
    assert overview["effects"]["timers"] == 1
    assert Enum.any?(overview["topology"], &(&1["from"] == "emitter" and &1["pending"] == 1))
    history = public_events(ctx.client, 0)

    assert Enum.any?(
             history,
             &(&1["type"] == "effect_delivered" and &1["request_id"] == "observed-delivery")
           )

    assert Enum.any?(
             history,
             &(&1["type"] == "effect_failed" and &1["request_id"] == "observed-failure" and
                 &1["metadata"]["code"] == "WORKER_NOT_FOUND")
           )

    filtered = tool(ctx.client, "runtime_events", %{"worker_id" => "counter", "limit" => 100})
    assert Enum.all?(filtered["events"], &(&1["worker_id"] == "counter"))
    assert filtered["generation"] == overview["generation"]
    Client.disconnect(ctx.client)
    fresh = Client.new(ctx.ready.port)
    on_exit(fn -> Client.close(%{fresh | session: nil}) end)
    {_init, _notification, fresh} = Client.initialize(fresh)
    after_page = tool(fresh, "runtime_events", %{"after" => List.last(history)["sequence"]})
    assert after_page["events"] == []
    assert after_page["generation"] == overview["generation"]
    tool(fresh, "runtime_stop", %{"worker_id" => "emitter", "request_id" => "inspection-stop"})

    assert tool(fresh, "runtime_inspect", %{"worker_id" => "emitter", "detail" => "state"})[
             "state_omitted"
           ]

    assert tool(fresh, "runtime_inspect", %{})["effects"]["pending"] == 0
  end

  @tag limits: %{history_records: 5, metadata_bytes: 32}
  test "HTTP cursor generations, eviction gaps, history filters and strict read schemas", ctx do
    artifact = define(ctx.client, args(Fixtures.effects_source()))
    for id <- ["a", "b", "c"], do: effect_start(ctx.client, artifact, id)
    first = tool(ctx.client, "runtime_inspect", %{"limit" => 1})
    assert Enum.map(first["workers"], & &1["worker_id"]) == ["a"]

    second =
      tool(ctx.client, "runtime_inspect", %{"limit" => 1, "cursor" => first["next_cursor"]})

    assert Enum.map(second["workers"], & &1["worker_id"]) == ["b"]

    third =
      tool(ctx.client, "runtime_inspect", %{"limit" => 1, "cursor" => second["next_cursor"]})

    assert Enum.map(third["workers"], & &1["worker_id"]) == ["c"]
    assert third["next_cursor"] == nil
    assert third["generation"] == first["generation"]

    tool(ctx.client, "runtime_invoke", %{
      "worker_id" => "a",
      "event" => %{},
      "request_id" => "invalidate-cursor"
    })

    stale = tool(ctx.client, "runtime_inspect", %{"cursor" => first["next_cursor"]})
    assert stale["code"] == "INVALID_ARGUMENT"
    assert stale["details"]["hint"] =~ "Restart pagination"
    history = tool(ctx.client, "runtime_events", %{"limit" => 100})
    assert history["gap"]
    assert history["dropped"] > 0
    assert history["truncated"] > 0

    assert Enum.map(history["events"], & &1["sequence"]) ==
             Enum.sort(Enum.map(history["events"], & &1["sequence"]))

    empty =
      tool(ctx.client, "runtime_events", %{"worker_id" => "b", "after" => history["next_cursor"]})

    assert empty["events"] == []
    assert empty["next_cursor"] >= history["next_cursor"]

    assert tool(ctx.client, "runtime_events", %{"worker_id" => "missing"})["code"] ==
             "WORKER_NOT_FOUND"

    assert tool(ctx.client, "runtime_events", %{"unknown" => true})["code"] == "INVALID_ARGUMENT"

    for arguments <- [%{"after" => -1}, %{"after" => "0"}, %{"limit" => 101}] do
      {response, _} = Client.call(ctx.client, "runtime_events", arguments)
      assert response.data["error"]["code"] == -32_602 or response.data["result"]["isError"]
    end
  end

  test "HTTP maximum worker states and escaped event history stay within full wire ceilings",
       ctx do
    artifact = define(ctx.client, args(Fixtures.worker_source()))
    payload = String.duplicate("\"\\\n😺", 1_630)

    for index <- 1..32 do
      effect_start(
        ctx.client,
        artifact,
        "worker-" <> String.pad_leading(to_string(index), 2, "0"),
        %{"payload" => payload}
      )
    end

    {response, _} =
      Client.call(ctx.client, "runtime_inspect", %{"detail" => "state", "limit" => 100})

    assert byte_size(response.body) <= 65_536
    data = result(response)
    assert length(data["workers"]) == 32
    assert Enum.any?(data["workers"], & &1["state_omitted"])
    assert Enum.any?(data["workers"], & &1["truncated"])
    assert worker_state(ctx.client, "worker-01") == %{"payload" => payload}
    records = public_events(ctx.client, 0)
    assert Enum.count(records, &(&1["type"] == "worker_started")) == 32
    for record <- records, do: assert({:ok, _, 0} = DateTime.from_iso8601(record["timestamp"]))
  end

  test "HTTP performs successive same-PID replacements, migration and explicit reverse migration",
       ctx do
    artifacts = replacement_artifacts(ctx.client)
    first = effect_start(ctx.client, artifacts[1], "counter")
    health = Client.raw(ctx.client, :get, "/health").data

    assert tool(ctx.client, "runtime_invoke", %{
             "worker_id" => "counter",
             "event" => %{"amount" => 3},
             "request_id" => "increment-v1"
           })["reply"] == 3

    before = tool(ctx.client, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"})

    for {source, code} <- [
          {"defmodule Generated do", "COMPILE_FAILED"},
          {"defmodule Generated do @behaviour ElixirMixir.Behavior end", "CALLBACK_MISSING"}
        ] do
      assert define(ctx.client, Map.put(args(source), "request_id", "reject-#{code}"))["code"] ==
               code

      assert tool(ctx.client, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"}) ==
               before
    end

    second = http_replace(ctx.client, "counter", artifacts[2], 1, "replace-v2")
    assert second["migration_result"] == "preserved"
    assert second["pid_before"] == first["pid"]
    assert second["pid_after"] == first["pid"]
    assert second["state_revision"] == before["state_revision"]
    assert worker_state(ctx.client, "counter") == before["state"]

    assert tool(ctx.client, "runtime_invoke", %{
             "worker_id" => "counter",
             "event" => %{},
             "request_id" => "increment-v2"
           })["reply"] == 5

    third =
      http_replace(
        ctx.client,
        "counter",
        artifacts[1],
        second["worker_revision"],
        "replace-v1-again"
      )

    assert third["migration_result"] == "preserved"
    assert third["pid_after"] == first["pid"]

    migrated =
      http_replace(ctx.client, "counter", artifacts[3], third["worker_revision"], "migrate-v3")

    assert migrated["migration_result"] == "migrated"
    assert migrated["pid_after"] == first["pid"]
    assert worker_state(ctx.client, "counter")["value"] == 5
    assert worker_state(ctx.client, "counter")["metadata"]["old_state_schema"] == 1

    assert tool(ctx.client, "runtime_invoke", %{
             "worker_id" => "counter",
             "event" => %{},
             "request_id" => "increment-v3"
           })["reply"] == 15

    reverse =
      http_replace(
        ctx.client,
        "counter",
        artifacts[1],
        migrated["worker_revision"],
        "reverse-migrate"
      )

    assert reverse["migration_result"] == "migrated"
    assert worker_state(ctx.client, "counter")["count"] == 15
    assert Client.raw(ctx.client, :get, "/health").data == health

    assert RuntimeFixture.control(ctx.fixture, %{"op" => "worker_membership", "id" => "counter"})[
             "pid"
           ] == first["pid"]

    assert Enum.count(public_events(ctx.client, 0), &(&1["type"] == "implementation_replaced")) ==
             4
  end

  test "HTTP migration failures retain every old field and revision races admit one winner",
       ctx do
    artifacts = replacement_artifacts(ctx.client)

    for mode <- ~w(error raise exit timeout late malformed invalid_root non_json oversized heap) do
      id = "counter-#{mode}"
      first = effect_start(ctx.client, artifacts[1], id, %{"migration" => mode})
      before = tool(ctx.client, "runtime_inspect", %{"worker_id" => id, "detail" => "state"})

      arguments = %{
        "worker_id" => id,
        "artifact_id" => artifacts[3]["artifact_id"],
        "expected_revision" => first["worker_revision"],
        "request_id" => "fail-#{mode}"
      }

      {response, _} = Client.call(ctx.client, "runtime_replace", arguments)
      assert response.status == 200
      assert response.data["result"]["isError"]
      error = result(response)
      assert error["code"] == "MIGRATION_FAILED"
      assert tool(ctx.client, "runtime_replace", arguments) == error

      assert tool(ctx.client, "runtime_inspect", %{"worker_id" => id, "detail" => "state"}) ==
               before

      assert tool(ctx.client, "runtime_invoke", %{
               "worker_id" => id,
               "event" => %{},
               "request_id" => "still-v1-#{mode}"
             })["reply"] == 1

      assert byte_size(response.body) <= 65_536
    end

    effect_start(ctx.client, artifacts[1], "race")

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          arguments = %{
            "worker_id" => "race",
            "artifact_id" => artifacts[2]["artifact_id"],
            "expected_revision" => 1,
            "request_id" => "race-#{index}"
          }

          {response, _} =
            Client.request(
              ctx.client,
              "tools/call",
              %{"name" => "runtime_replace", "arguments" => arguments},
              "race-rpc-#{index}"
            )

          result(response)
        end)
      end

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &(&1["migration_result"] == "preserved")) == 1
    assert Enum.count(results, &(&1["code"] == "REVISION_CONFLICT")) == 1

    assert tool(ctx.client, "runtime_replace", %{
             "worker_id" => "race",
             "artifact_id" => artifacts[1]["artifact_id"],
             "expected_revision" => 1,
             "request_id" => "race-1"
           })["code"] == "REQUEST_ID_CONFLICT"

    assert tool(ctx.client, "runtime_replace", %{
             "worker_id" => "race",
             "artifact_id" => artifacts[1]["artifact_id"],
             "expected_revision" => 2,
             "request_id" => "unknown-field",
             "extra" => true
           })["code"] == "INVALID_ARGUMENT"

    {missing, _} = Client.call(ctx.client, "runtime_replace", %{"worker_id" => "race"})
    assert missing.data["error"]["code"] == -32_602
    history = public_events(ctx.client, 0)
    assert Enum.count(history, &(&1["type"] == "migration_failed")) == 10
  end

  test "physical HTTP disconnect during replacement replays one committed migration in the same host",
       ctx do
    artifacts = replacement_artifacts(ctx.client)
    first = effect_start(ctx.client, artifacts[1], "counter", %{"migration" => "controlled"})

    arguments = %{
      "worker_id" => "counter",
      "artifact_id" => artifacts[3]["artifact_id"],
      "expected_revision" => 1,
      "request_id" => "replace-disconnect"
    }

    pending =
      Task.async(fn ->
        try do
          {:unexpected_response, Client.call(ctx.client, "runtime_replace", arguments)}
        rescue
          MatchError -> :connection_closed
        end
      end)

    await_http(fn ->
      RuntimeFixture.control(ctx.fixture, %{"op" => "barrier_status", "key" => "replace"})[
        "waiting"
      ]
    end)

    Client.disconnect(ctx.client)
    RuntimeFixture.control(ctx.fixture, %{"op" => "release_barrier", "key" => "replace"})
    assert Task.await(pending, 1_000) == :connection_closed
    fresh = Client.new(ctx.ready.port)
    on_exit(fn -> Client.close(%{fresh | session: nil}) end)
    {_init, _notification, fresh} = Client.initialize(fresh)
    replaced = tool(fresh, "runtime_replace", arguments)
    assert replaced["migration_result"] == "migrated"
    assert replaced["worker_revision"] == 2
    assert replaced["state_revision"] == 2
    assert replaced["pid_before"] == first["pid"]
    assert replaced["pid_after"] == first["pid"]
    assert tool(fresh, "runtime_replace", arguments) == replaced
    current = tool(fresh, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"})
    assert current["artifact_id"] == artifacts[3]["artifact_id"]
    assert current["state"]["value"] == 0
    assert current["pid"] == first["pid"]

    assert Enum.count(
             public_events(fresh, 0),
             &(&1["type"] == "implementation_replaced" and
                 &1["request_id"] == "replace-disconnect")
           ) == 1

    assert RuntimeFixture.alive?(ctx.fixture)
  end

  test "HTTP host death during migration is a cached failure and retains the old active artifact",
       ctx do
    artifacts = replacement_artifacts(ctx.client)
    first = effect_start(ctx.client, artifacts[1], "counter", %{"migration" => "controlled"})

    arguments = %{
      "worker_id" => "counter",
      "artifact_id" => artifacts[3]["artifact_id"],
      "expected_revision" => 1,
      "request_id" => "replace-host-death"
    }

    pending = Task.async(fn -> Client.call(ctx.client, "runtime_replace", arguments) end)

    await_http(fn ->
      RuntimeFixture.control(ctx.fixture, %{"op" => "barrier_status", "key" => "replace"})[
        "waiting"
      ]
    end)

    RuntimeFixture.control(ctx.fixture, %{"op" => "kill_host", "id" => "counter"})
    {response, _} = Task.await(pending)
    failure = result(response)
    assert failure["code"] == "CALLBACK_FAILED"
    recovered = await_worker(ctx.client, "counter", "running", 100)
    refute recovered["pid"] == first["pid"]
    assert recovered["artifact_id"] == artifacts[1]["artifact_id"]
    assert tool(ctx.client, "runtime_replace", arguments) == failure

    assert tool(ctx.client, "runtime_invoke", %{
             "worker_id" => "counter",
             "event" => %{},
             "request_id" => "old-after-failure"
           })["reply"] == 1
  end

  test "HTTP evolves a live counter/aggregator graph while retaining both hosts and compatible state",
       ctx do
    source = Fixtures.effects_source()
    artifact = define(ctx.client, args(source))

    evolved_source =
      String.replace(
        source,
        ~S|Map.get(event, "amount", 1)|,
        ~S|(Map.get(event, "amount", 1) * 2)|
      )

    evolved =
      define(ctx.client, Map.put(args(evolved_source), "request_id", "define-evolved-counter"))

    aggregate = effect_start(ctx.client, artifact, "aggregate")
    counter = effect_start(ctx.client, artifact, "counter", %{"forward" => "aggregate"})

    tool(ctx.client, "runtime_invoke", %{
      "worker_id" => "counter",
      "event" => %{"amount" => 3},
      "request_id" => "graph-before"
    })

    await_http(fn -> worker_state(ctx.client, "aggregate")["total"] == 3 end)
    before = tool(ctx.client, "runtime_inspect", %{"worker_id" => "counter", "detail" => "state"})
    changed = http_replace(ctx.client, "counter", evolved, 1, "evolve-graph")
    assert changed["migration_result"] == "preserved"
    assert changed["pid_after"] == counter["pid"]
    assert worker_state(ctx.client, "counter") == before["state"]

    tool(ctx.client, "runtime_invoke", %{
      "worker_id" => "counter",
      "event" => %{"amount" => 4},
      "request_id" => "graph-after"
    })

    await_http(fn -> worker_state(ctx.client, "aggregate")["total"] == 11 end)
    await_http(fn -> tool(ctx.client, "runtime_inspect", %{})["effects"]["pending"] == 0 end)
    assert worker_state(ctx.client, "aggregate")["count"] == 2
    assert worker_state(ctx.client, "counter")["total"] == 11

    assert tool(ctx.client, "runtime_inspect", %{"worker_id" => "counter"})["pid"] ==
             counter["pid"]

    assert tool(ctx.client, "runtime_inspect", %{"worker_id" => "aggregate"})["pid"] ==
             aggregate["pid"]

    assert tool(ctx.client, "runtime_inspect", %{})["topology"] == [
             %{"from" => "counter", "to" => "aggregate", "count" => 2, "pending" => 0}
           ]
  end

  defp replacement_artifacts(client) do
    for version <- 1..3, into: %{} do
      {version,
       define(
         client,
         Map.put(
           args(Fixtures.replacement_source(version)),
           "request_id",
           "define-version-#{version}"
         )
       )}
    end
  end

  defp http_replace(client, id, artifact, expected, request_id) do
    tool(client, "runtime_replace", %{
      "worker_id" => id,
      "artifact_id" => artifact["artifact_id"],
      "expected_revision" => expected,
      "request_id" => request_id
    })
  end

  defp public_events(client, cursor) do
    {response, _} = Client.call(client, "runtime_events", %{"after" => cursor, "limit" => 100})
    assert byte_size(response.body) <= 65_536
    page = result(response)

    if page["events"] == [],
      do: [],
      else: page["events"] ++ public_events(client, page["next_cursor"])
  end

  defp effect_start(client, artifact, id, config \\ %{}) do
    tool(client, "runtime_start", %{
      "worker_id" => id,
      "artifact_id" => artifact["artifact_id"],
      "config" => config,
      "request_id" => "start-#{id}"
    })
  end

  defp worker_state(client, id),
    do: tool(client, "runtime_inspect", %{"worker_id" => id, "detail" => "state"})["state"]

  defp await_http(check, remaining \\ 200)
  defp await_http(_check, 0), do: flunk("HTTP effect did not settle")

  defp await_http(check, remaining) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await_http(check, remaining - 1)
        )
  end

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
    snapshot = tool(client, "runtime_inspect", %{"worker_id" => id, "detail" => "state"})

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
