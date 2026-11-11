defmodule ElixirMixir.MCPBootstrapTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ElixirMixir.MCP.Config
  alias ElixirMixir.MCP.Result
  alias ElixirMixir.MCP.Router
  alias ElixirMixir.MCP.Server
  alias ElixirMixir.MCP.Tools.RuntimeInspect
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Manager
  alias Hermes.MCP.Message
  alias Hermes.Server.Frame
  alias Hermes.Server.Response

  @config Config.new(port: 4100)

  test "configuration rejects non-loopback, malformed and unknown settings" do
    assert Config.new([]).port == 4100
    assert Config.new(enabled: false, port: 0).enabled == false

    for opts <- [
          [ip: {0, 0, 0, 0}],
          [port: -1],
          [port: 65_536],
          [port: "4100"],
          [enabled: 1],
          [unknown: true]
        ] do
      assert_raise ArgumentError, fn -> Config.new(opts) end
    end
  end

  @tag capture_log: true
  test "an occupied port fails MCP startup instead of publishing false readiness" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    on_exit(fn -> :gen_tcp.close(socket) end)
    {:ok, {_ip, port}} = :inet.sockname(socket)

    assert {:error, reason} =
             start_supervised({ElixirMixir.MCP.Supervisor, Config.new(port: port)})

    assert inspect(reason) =~ "eaddrinuse"
    refute Process.whereis(ElixirMixir.MCP.Supervisor)
  end

  test "unit-test startup does not open a listener" do
    refute Process.whereis(ElixirMixir.MCP.Supervisor)
  end

  test "Host and Origin must each be an exact configured loopback authority" do
    for host <- ["evil.test:4100", "127.0.0.1:9999", "127.0.0.1.evil.test:4100", "localhost", ""] do
      conn = %{request(:get, "/health") | req_headers: [{"host", host}]}
      assert Router.call(conn, @config).status == 403
    end

    for origin <- [
          "https://localhost:4100",
          "http://localhost:9999",
          "null",
          "http://evil.test:4100"
        ] do
      conn = request(:get, "/health") |> put_req_header("origin", origin)
      assert Router.call(conn, @config).status == 403
    end

    conn = request(:get, "/missing") |> put_req_header("origin", "http://localhost:4100")
    assert Router.call(conn, @config).status == 404
  end

  test "readiness requires Manager and MCP server, and paths and methods are exact" do
    assert Router.call(request(:get, "/health"), @config).status == 503
    start_mcp()
    assert Router.call(request(:get, "/health"), @config).status == 200
    assert Router.call(request(:get, "/mcp/extra"), @config).status == 404
    assert Router.call(request(:put, "/mcp"), @config).status == 405
    assert Router.call(request(:post, "/health"), @config).status == 405
  end

  test "ingress rejects invalid JSON, batch requests, depth, UTF-8 and oversized IDs" do
    for body <- [
          "{",
          "[]",
          "null",
          <<255>>,
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "ping",
            "id" => String.duplicate("x", 129),
            "params" => %{}
          }),
          JSON.encode!(Enum.reduce(1..17, %{}, fn _, acc -> %{"nested" => acc} end))
        ] do
      response = Router.call(request(:post, "/mcp", body), @config)
      assert response.status == 400
      assert byte_size(response.resp_body) < 1_024
      assert Jason.decode!(response.resp_body)["id"] == nil
    end

    response =
      request(:post, "/mcp", "{}")
      |> put_req_header("content-type", "text/plain")
      |> Router.call(@config)

    assert response.status == 415

    assert Router.call(request(:post, "/mcp", String.duplicate("x", 65_537)), @config).status ==
             413
  end

  test "transport enforces required Accept header" do
    start_mcp()

    conn =
      request(
        :post,
        "/mcp",
        JSON.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1, "params" => %{}})
      )

    assert Router.call(conn, @config).status == 406
    assert Router.call(request(:get, "/mcp"), @config).status == 406
  end

  test "Manager validates inspection inputs without executing generated code" do
    for args <- [
          %{"detail" => "summary"},
          %{"detail" => "state", "limit" => 1},
          %{"limit" => 100}
        ] do
      assert {:ok, %{"generation" => 0, "workers" => []}} = Manager.inspect_runtime(args)
    end

    for args <- [
          %{"detail" => nil},
          %{"detail" => "bogus"},
          %{"limit" => 0},
          %{"limit" => 101},
          %{"limit" => 1.0},
          %{"worker_id" => "bad id"},
          %{"worker_id" => nil},
          %{"cursor" => ""},
          %{"extra" => true},
          [],
          nil
        ] do
      assert {:error, %{"code" => "INVALID_ARGUMENT", "generation" => 0}} =
               Manager.inspect_runtime(args)
    end

    assert {:error, %{"code" => "WORKER_NOT_FOUND"}} =
             Manager.inspect_runtime(%{"worker_id" => "absent"})
  end

  test "adapter uses original arguments and publishes a strict read-only schema" do
    schema = RuntimeInspect.input_schema()
    assert schema["additionalProperties"] == false
    assert Map.keys(schema["properties"]) |> Enum.sort() == ~w(cursor detail limit worker_id)

    frame = %Frame{
      request: %{id: "rpc", method: "tools/call", params: %{"arguments" => %{"extra" => true}}}
    }

    assert {:reply, response, ^frame} = RuntimeInspect.execute(%{}, frame)
    assert response.isError
    assert response.structured_content["code"] == "INVALID_ARGUMENT"
  end

  test "wire preflight counts JSON-RPC, escaped text, structured content and ID" do
    limits = Limits.new(%{response_bytes: 1_024})
    data = %{"api_version" => "1", "generation" => 0, "payload" => String.duplicate("\"\n", 200)}
    assert byte_size(JSON.encode!(data)) < 1_024
    response = Result.tool({:ok, data}, "rpc-id", limits)
    assert response.isError
    assert response.structured_content["code"] == "LIMIT_EXCEEDED"
    assert byte_size(Result.encode(response, "rpc-id")) <= 1_024

    {:ok, data} = Manager.inspect_runtime(%{})
    response = Result.tool({:ok, data}, 0)
    assert Response.to_protocol(response)["structuredContent"] == data
    assert Jason.decode!(hd(response.content)["text"]) == data
  end

  test "wire accounting matches the installed Hermes encoder byte for byte" do
    {:ok, data} = Manager.inspect_runtime(%{})
    response = Result.tool({:ok, data}, "encoding-id")

    {:ok, wire} =
      Message.encode_response(
        %{"result" => Response.to_protocol(response)},
        "encoding-id"
      )

    assert Result.encode(response, "encoding-id") == wire
  end

  test "minimum wire ceiling fits a correlated duplicate error result" do
    assert_raise ArgumentError, fn -> Limits.new(%{response_bytes: 512}) end
    limits = Limits.new(%{response_bytes: 1_024})

    data =
      Map.merge(Error.new("REQUEST_ID_CONFLICT"), %{
        "api_version" => "1",
        "generation" => 1,
        "request_id" => String.duplicate("a", 64)
      })

    id = String.duplicate("i", 126)
    response = Result.tool({:error, data}, id, limits)
    assert byte_size(Result.encode(response, id)) <= limits.response_bytes
  end

  defp start_mcp do
    start_supervised!(Hermes.Server.Registry)
    start_supervised!({Server, transport: {:streamable_http, start: true}})
  end

  defp request(method, path, body \\ "") do
    conn = conn(method, path, body) |> put_req_header("content-type", "application/json")
    %{conn | req_headers: [{"host", "127.0.0.1:4100"} | conn.req_headers]}
  end
end
