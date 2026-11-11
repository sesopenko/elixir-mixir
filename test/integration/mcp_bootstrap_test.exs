defmodule ElixirMixir.MCPBootstrapIntegrationTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.TestSupport.MCPClient, as: Client
  alias ElixirMixir.TestSupport.RuntimeFixture

  setup do
    fixture = start_supervised!(RuntimeFixture)
    ready = RuntimeFixture.ready(fixture)
    client = Client.new(ready.port)
    on_exit(fn -> Client.close(%{client | session: nil}) end)
    %{fixture: fixture, client: client, ready: ready}
  end

  test "real HTTP handshake, discovery, inspect and reconnect preserve the independent BEAM",
       ctx do
    health = Client.raw(ctx.client, :get, "/health")
    assert health.status == 200
    assert health.data["runtime_id"] == ctx.ready.os_pid
    {init, notification, client} = Client.initialize(ctx.client)
    assert init.status == 200
    assert init.data["id"] == 1
    assert init.data["result"]["protocolVersion"] == "2025-03-26"
    assert init.data["result"]["instructions"] =~ "runtime_inspect"
    assert notification.status == 202
    assert notification.body == ""
    assert is_binary(client.session)

    {list, client} = Client.request(client, "tools/list", %{}, "discovery-id")
    assert list.data["id"] == "discovery-id"

    assert [
             %{"name" => "runtime_define"},
             %{"name" => "runtime_inspect", "inputSchema" => schema}
           ] =
             list.data["result"]["tools"]

    assert schema["additionalProperties"] == false
    {inspection, client} = Client.call(client, "runtime_inspect")
    assert inspection.status == 200
    assert inspection.data["result"]["isError"] == false
    data = inspection.data["result"]["structuredContent"]
    assert data["workers"] == []
    assert data["generation"] == 0
    assert Jason.decode!(hd(inspection.data["result"]["content"])["text"]) == data
    assert byte_size(inspection.body) <= 65_536
    assert :ok = Client.close(client)
    assert RuntimeFixture.alive?(ctx.fixture)

    client = Client.new(ctx.ready.port)
    on_exit(fn -> Client.close(%{client | session: nil}) end)
    {_init, _notification, client} = Client.initialize(client)

    {inspection, _client} =
      Client.call(client, "runtime_inspect", %{"detail" => "state", "limit" => 1})

    assert inspection.data["result"]["structuredContent"] == data
    assert Client.raw(client, :get, "/health").data["runtime_id"] == ctx.ready.os_pid
  end

  test "optional tool arguments default to an empty object and protocol IDs are preserved", ctx do
    {_init, _notification, client} = Client.initialize(ctx.client)

    {response, _client} =
      Client.post(client, %{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "tools/call",
        "params" => %{"name" => "runtime_inspect"}
      })

    assert response.status == 200
    assert response.data["id"] == 0
    assert response.data["result"]["isError"] == false
  end

  test "exact ingress limit is accepted and invalid headers are rejected on the wire", ctx do
    message =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "exact-limit",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        }
      })

    body = message <> String.duplicate(" ", 65_536 - byte_size(message))
    response = Client.raw(ctx.client, :post, "/mcp", body)
    assert response.status == 200
    assert response.data["id"] == "exact-limit"

    for {name, value} <- [{~c"host", ~c"evil.test"}, {~c"origin", ~c"http://evil.test"}] do
      assert Client.raw(ctx.client, :get, "/health", "", [{name, value}]).status == 403
    end
  end

  test "fixture cleanup terminates the child OS process", ctx do
    assert RuntimeFixture.alive?(ctx.fixture)
    assert :ok = stop_supervised(RuntimeFixture)
    assert wait_for_exit(ctx.ready.os_pid, 100)
  end

  test "malformed tool arguments produce bounded protocol errors without breaking the session",
       ctx do
    {_init, _notification, client} = Client.initialize(ctx.client)

    for args <- [nil, [], 1, "invalid"] do
      {response, _client} =
        Client.post(client, %{
          "jsonrpc" => "2.0",
          "id" => "invalid-args",
          "method" => "tools/call",
          "params" => %{"name" => "runtime_inspect", "arguments" => args}
        })

      assert response.status == 400
      assert response.data["error"]["code"] < 0
      assert response.data["id"] == "invalid-args"
      assert byte_size(response.body) < 1_024
    end

    {response, _client} = Client.call(client, "runtime_inspect")
    assert response.data["result"]["isError"] == false
  end

  test "kernel errors retain isError envelopes and unknown keys survive schema filtering", ctx do
    {_init, _notification, client} = Client.initialize(ctx.client)

    for {args, code} <- [
          {%{"worker_id" => "missing"}, "WORKER_NOT_FOUND"},
          {%{"unknown" => "value"}, "INVALID_ARGUMENT"},
          {%{"cursor" => "invalid"}, "INVALID_ARGUMENT"}
        ] do
      {response, _client} = Client.call(client, "runtime_inspect", args)
      assert response.status == 200
      assert response.data["result"]["isError"] == true
      assert response.data["result"]["structuredContent"]["code"] == code
      assert response.data["result"]["structuredContent"]["generation"] == 0
    end
  end

  test "SSE on GET uses the session and POST notification framing stays empty", ctx do
    {_init, _notification, client} = Client.initialize(ctx.client)
    stream = Client.open_stream(client)
    {response, _client} = Client.request(client, "tools/list", %{}, "sse-id")
    assert response.status == 202
    assert response.body == ""
    event = Client.receive_event(stream)
    assert event["id"] == "sse-id"

    assert [%{"name" => "runtime_define"}, %{"name" => "runtime_inspect"}] =
             event["result"]["tools"]

    :httpc.cancel_request(stream, client.profile)
    assert RuntimeFixture.alive?(ctx.fixture)
  end

  test "real socket rejects oversized fixed and chunked bodies and stays ready", ctx do
    huge = String.duplicate("x", 65_537)
    assert Client.raw(ctx.client, :post, "/mcp", huge).status == 413

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, ctx.ready.port, [:binary, active: false], 2_000)

    on_exit(fn -> :gen_tcp.close(socket) end)

    :ok =
      :gen_tcp.send(socket, [
        "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:",
        Integer.to_string(ctx.ready.port),
        "\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n",
        "Accept: application/json, text/event-stream\r\nConnection: close\r\n\r\n",
        Integer.to_string(byte_size(huge), 16),
        "\r\n",
        huge,
        "\r\n0\r\n\r\n"
      ])

    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    assert response =~ "413"
    assert Client.raw(ctx.client, :get, "/health").status == 200
  end

  defp wait_for_exit(_os_pid, 0), do: false

  defp wait_for_exit(os_pid, attempts) do
    case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
      {_output, 0} ->
        Process.sleep(10)
        wait_for_exit(os_pid, attempts - 1)

      {_output, _not_alive} ->
        true
    end
  end
end
