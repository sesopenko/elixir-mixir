defmodule ElixirMixir.MCP.Router do
  @moduledoc "Exact MCP routing with bounded JSON ingress and loopback Host/Origin checks."

  @behaviour Plug

  import Plug.Conn

  alias ElixirMixir.MCP.Server
  alias ElixirMixir.MCP.Transport
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.Values
  alias Hermes.MCP.Message
  alias Hermes.Server.Transport.StreamableHTTP

  @impl true
  @doc "Accepts validated listener configuration; resolves Hermes transport only during requests."
  @spec init(ElixirMixir.MCP.Config.t()) :: ElixirMixir.MCP.Config.t()
  def init(config), do: config

  @impl true
  @doc "Routes health and MCP requests after checking their authority and bounded bodies."
  @spec call(Plug.Conn.t(), ElixirMixir.MCP.Config.t()) :: Plug.Conn.t()
  def call(conn, config) do
    port = listener_port(config)
    limits = Limits.new(Application.get_env(:elixir_mixir, :limits, %{}))

    if allowed_headers?(conn, port) do
      route(conn, limits)
    else
      protocol_error(conn, 403, -32_600, "Unexpected Host or Origin")
    end
  end

  defp route(%{request_path: "/health", method: "GET"} = conn, _limits) do
    if ready?() do
      send_json(conn, 200, %{
        "api_version" => "1",
        "status" => "ready",
        "runtime_id" => System.pid()
      })
    else
      send_json(conn, 503, %{"api_version" => "1", "status" => "unavailable"})
    end
  end

  defp route(%{request_path: "/mcp", method: "POST"} = conn, limits) do
    if json_content?(conn) do
      read_message(conn, limits)
    else
      protocol_error(conn, 415, -32_600, "Content-Type must be application/json")
    end
  end

  defp route(%{request_path: "/mcp", method: method} = conn, limits)
       when method in ["GET", "DELETE"] do
    forward(conn, limits)
  end

  defp route(%{request_path: path} = conn, _limits) when path in ["/health", "/mcp"],
    do: protocol_error(conn, 405, -32_601, "Method not allowed")

  defp route(conn, _limits), do: protocol_error(conn, 404, -32_601, "Endpoint not found")

  defp read_message(conn, limits) do
    case read_body(conn,
           length: limits.body_bytes,
           read_length: limits.body_bytes + 1,
           read_timeout: 7_000
         ) do
      {:ok, body, conn} when byte_size(body) <= limits.body_bytes -> parse(conn, body, limits)
      {:more, _body, conn} -> protocol_error(conn, 413, -32_600, "Request body too large")
      {:ok, _body, conn} -> protocol_error(conn, 413, -32_600, "Request body too large")
      {:error, _reason} -> protocol_error(conn, 400, -32_600, "Could not read request body")
    end
  end

  defp parse(conn, body, limits) do
    case Jason.decode(body) do
      {:ok, message} when is_map(message) -> validate_message(conn, message, limits)
      {:ok, _other} -> protocol_error(conn, 400, -32_600, "Expected one JSON-RPC object")
      {:error, _reason} -> protocol_error(conn, 400, -32_700, "Invalid JSON")
    end
  end

  defp validate_message(conn, message, limits) do
    with :ok <- Values.validate(message, :reply, %{limits | reply_bytes: limits.body_bytes}),
         true <- valid_rpc_id?(message),
         true <- valid_tool_arguments?(message),
         message <- default_tool_arguments(message),
         {:ok, validated} <- Message.validate_message(message) do
      conn = %{conn | body_params: validated}
      forward(conn, limits)
    else
      _error ->
        id = if valid_rpc_id?(message), do: Map.get(message, "id")
        protocol_error(conn, 400, -32_600, "Invalid JSON-RPC message", id)
    end
  end

  defp forward(conn, limits) do
    conn = register_before_send(conn, &normalize(&1, limits))

    if conn.method == "POST" do
      Transport.post(conn, limits)
    else
      StreamableHTTP.Plug.call(
        conn,
        StreamableHTTP.Plug.init(server: Server, timeout: limits.operation_timeout_ms)
      )
    end
  end

  defp normalize(%{status: 202} = conn, _limits), do: resp(conn, 202, "")

  defp normalize(%{state: :set, resp_body: body} = conn, limits) do
    case Jason.decode(body) do
      {:ok, %{"result" => %{"protocolVersion" => _} = result} = message} ->
        message =
          Map.put(message, "result", Map.put(result, "instructions", Server.instructions()))

        bounded_response(conn, JSON.encode!(message), limits)

      _other ->
        bounded_response(conn, IO.iodata_to_binary(body), limits)
    end
  end

  defp normalize(conn, _limits), do: conn

  defp bounded_response(conn, body, limits) when byte_size(body) <= limits.response_bytes,
    do: resp(conn, conn.status, body)

  defp bounded_response(conn, body, _limits) do
    id =
      case Jason.decode(body) do
        {:ok, message} -> Map.get(message, "id")
        _error -> nil
      end

    resp(
      conn,
      200,
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32_000, "message" => "Response limit exceeded"}
      })
    )
  end

  defp ready? do
    is_pid(Process.whereis(Manager)) and is_pid(Process.whereis(Hermes.Server.Registry)) and
      is_pid(Hermes.Server.Registry.whereis_server(Server))
  end

  defp listener_port(%{port: 0}) do
    {:ok, {_ip, port}} = ElixirMixir.MCP.Supervisor.address()
    port
  end

  defp listener_port(%{port: port}), do: port

  defp allowed_headers?(conn, port) do
    hosts = for host <- ["127.0.0.1", "localhost"], do: "#{host}:#{port}"
    origins = Enum.map(hosts, &("http://" <> &1))

    get_req_header(conn, "host") in Enum.map(hosts, &[&1]) and
      get_req_header(conn, "origin") in [[] | Enum.map(origins, &[&1])]
  end

  defp json_content?(conn) do
    case get_req_header(conn, "content-type") do
      [type] -> type |> String.split(";") |> hd() |> String.trim() == "application/json"
      _other -> false
    end
  end

  defp valid_tool_arguments?(%{"method" => "tools/call", "params" => params})
       when is_map(params) do
    not Map.has_key?(params, "arguments") or is_map(params["arguments"])
  end

  defp valid_tool_arguments?(%{"method" => "tools/call"}), do: false
  defp valid_tool_arguments?(_other), do: true

  # MCP permits tools/call arguments to be omitted; Hermes' handler requires a map.
  defp default_tool_arguments(%{"method" => "tools/call", "params" => params} = message)
       when is_map(params) do
    Map.put(message, "params", Map.put_new(params, "arguments", %{}))
  end

  defp default_tool_arguments(message), do: message

  defp valid_rpc_id?(%{"id" => id}),
    do: (is_binary(id) or is_integer(id)) and byte_size(JSON.encode!(id)) <= 128

  defp valid_rpc_id?(_notification), do: true

  defp protocol_error(conn, status, code, message, id \\ nil) do
    send_json(conn, status, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp send_json(conn, status, data) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(data))
  end
end
