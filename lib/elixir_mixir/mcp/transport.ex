defmodule ElixirMixir.MCP.Transport do
  @moduledoc """
  POST adapter for the pinned Hermes transport with an explicit operation wait.

  Hermes 0.14.1 public wrappers use GenServer.call's five-second default despite
  the configured seven-second request timeout. This adapter sends the same pinned
  transport messages with the full wait, preserving session and SSE routing.
  """

  import Plug.Conn

  alias ElixirMixir.MCP.Server
  alias ElixirMixir.Runtime.Limits
  alias Hermes.MCP.Error
  alias Hermes.MCP.ID
  alias Hermes.MCP.Message
  alias Hermes.Server.Registry
  alias Hermes.Server.Transport.StreamableHTTP

  require Message

  @doc "Posts a prevalidated cached message using the full operation deadline."
  @spec post(Plug.Conn.t(), Limits.t()) :: Plug.Conn.t()
  def post(conn, limits) do
    accept = get_req_header(conn, "accept") |> List.first("")

    if String.contains?(accept, "application/json") and
         String.contains?(accept, "text/event-stream") do
      send_message(conn, limits)
    else
      error(conn, 406, -32_600, "Accept must include application/json and text/event-stream", nil)
    end
  end

  defp send_message(conn, limits) do
    message = conn.body_params
    transport = Registry.transport(Server, :streamable_http)

    session =
      case get_req_header(conn, "mcp-session-id") do
        [id] when id != "" -> id
        _other -> ID.generate_session_id()
      end

    request? = Message.is_request(message)
    kind = if request?, do: :handle_message_for_sse, else: :handle_message

    context = %{
      assigns: conn.assigns,
      type: :http,
      req_headers: conn.req_headers,
      query_params: nil,
      remote_ip: conn.remote_ip,
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port,
      request_path: conn.request_path
    }

    conn =
      if get_req_header(conn, "mcp-session-id") == [],
        do: put_resp_header(conn, "mcp-session-id", session),
        else: conn

    outcome =
      GenServer.call(transport, {kind, session, message, context}, limits.operation_timeout_ms)

    respond(conn, outcome, transport, session, message, request?)
  catch
    :exit, _reason ->
      error(conn, 500, -32_603, "Runtime transport unavailable", conn.body_params["id"])
  end

  defp respond(conn, {:ok, nil}, _transport, _session, _message, _request?),
    do: send_resp(conn, 202, "")

  defp respond(conn, {:ok, body}, _transport, _session, _message, _request?),
    do: json(conn, 200, body)

  defp respond(conn, {:sse, body}, transport, session, _message, _request?) do
    case StreamableHTTP.get_sse_handler(transport, session) do
      pid when is_pid(pid) ->
        send(pid, {:sse_message, body})
        send_resp(conn, 202, "")

      nil ->
        json(conn, 200, body)
    end
  end

  defp respond(conn, {:error, %Error{} = error}, _transport, _session, message, _request?) do
    {:ok, body} = Error.to_json_rpc(error, message["id"])
    json(conn, 400, body)
  end

  defp respond(conn, {:error, _reason}, _transport, _session, message, _request?),
    do: error(conn, 500, -32_603, "Runtime transport unavailable", message["id"])

  defp error(conn, status, code, message, id),
    do:
      json(
        conn,
        status,
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => code, "message" => message}
        })
      )

  defp json(conn, status, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, body)
end
