defmodule ElixirMixir.TestSupport.MCPClient do
  @moduledoc "Reusable finite-timeout HTTP/SSE client for the incremental runtime integration suite."

  defstruct [:url, :profile, :session, next_id: 1]

  @type t :: %__MODULE__{
          url: String.t(),
          profile: pid(),
          session: String.t() | nil,
          next_id: pos_integer()
        }
  @type reply :: %{
          status: non_neg_integer(),
          headers: [{charlist(), charlist()}],
          body: binary(),
          data: term()
        }

  @doc "Creates an isolated HTTP connection pool for one test client."
  @spec new(:inet.port_number()) :: t()
  def new(port) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, profile} = :inets.start(:httpc, [{:profile, :mixir_test}], :stand_alone)
    Process.unlink(profile)
    :ok = :httpc.set_options([max_sessions: 10, max_keep_alive_length: 0], profile)
    %__MODULE__{url: "http://127.0.0.1:#{port}", profile: profile}
  end

  @doc "Negotiates MCP, records its session header, and sends initialized."
  @spec initialize(t()) :: {reply(), reply(), t()}
  def initialize(client) do
    {response, client} =
      request(client, "initialize", %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "mixir-exunit", "version" => "1"}
      })

    {notification, client} = notify(client, "notifications/initialized", %{})
    {response, notification, client}
  end

  @doc "Sends a correlated JSON-RPC request, preserving session identity."
  @spec request(t(), String.t(), map(), term()) :: {reply(), t()}
  def request(client, method, params, id \\ nil) do
    id = id || client.next_id
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    {response, client} = post(client, message)
    {response, %{client | next_id: client.next_id + 1}}
  end

  @doc "Calls a currently advertised tool."
  @spec call(t(), String.t(), map()) :: {reply(), t()}
  def call(client, name, args \\ %{}) do
    request(client, "tools/call", %{"name" => name, "arguments" => args})
  end

  @doc "Sends a protocol notification without an ID."
  @spec notify(t(), String.t(), map()) :: {reply(), t()}
  def notify(client, method, params) do
    post(client, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  @doc "Posts a message and propagates any returned MCP session header."
  @spec post(t(), map()) :: {reply(), t()}
  def post(client, message) do
    response = raw(client, :post, "/mcp", JSON.encode!(message))
    session = header(response, "mcp-session-id") || client.session
    {response, %{client | session: session}}
  end

  @doc "Sends a finite HTTP request, exposing status, headers and decoded JSON."
  @spec raw(t(), atom(), String.t(), binary(), [{charlist(), charlist()}]) :: reply()
  def raw(client, method, path, body \\ "", headers \\ []) do
    defaults = [
      {~c"accept", ~c"application/json, text/event-stream"},
      {~c"connection", ~c"close"}
    ]

    session =
      if client.session, do: [{~c"mcp-session-id", String.to_charlist(client.session)}], else: []

    headers = headers ++ session ++ defaults
    url = String.to_charlist(client.url <> path)

    request =
      if method in [:post, :put],
        do: {url, headers, ~c"application/json", body},
        else: {url, headers}

    {:ok, {{_version, status, _reason}, response_headers, response_body}} =
      :httpc.request(
        method,
        request,
        [timeout: 10_000, connect_timeout: 2_000],
        [body_format: :binary],
        client.profile
      )

    %{status: status, headers: response_headers, body: response_body, data: decode(response_body)}
  end

  @doc "Opens a session-associated GET SSE stream and waits for its headers."
  @spec open_stream(t()) :: reference()
  def open_stream(client) do
    headers = [
      {~c"accept", ~c"text/event-stream"},
      {~c"mcp-session-id", String.to_charlist(client.session)}
    ]

    {:ok, request} =
      :httpc.request(
        :get,
        {String.to_charlist(client.url <> "/mcp"), headers},
        [timeout: 10_000],
        [sync: false, stream: :self, body_format: :binary],
        client.profile
      )

    receive do
      {:http, {^request, :stream_start, _headers}} -> request
    after
      5_000 -> raise "SSE stream did not start"
    end
  end

  @doc "Waits for and decodes one complete SSE message with a finite timeout."
  @spec receive_event(reference(), binary()) :: map()
  def receive_event(request, buffer \\ "") do
    case String.split(buffer, "\n\n", parts: 2) do
      [event, _rest] ->
        decode_sse(event)

      [_partial] ->
        receive do
          {:http, {^request, :stream, data}} ->
            receive_event(request, buffer <> IO.iodata_to_binary(data))
        after
          5_000 -> raise "SSE response not received"
        end
    end
  end

  @doc "Decodes multiline SSE data while ignoring comments, IDs and event names."
  @spec decode_sse(binary()) :: map()
  def decode_sse(event) do
    event
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map_join("\n", &(&1 |> String.trim_leading("data:") |> String.trim_leading()))
    |> Jason.decode!()
  end

  @doc "Closes physical HTTP connections without sending a session DELETE or stopping the runtime."
  @spec disconnect(t()) :: :ok
  def disconnect(client) do
    if Process.alive?(client.profile), do: GenServer.stop(client.profile)
    :ok
  end

  @doc "Closes the MCP stream/session and synchronously stops the standalone HTTP pool."
  @spec close(t()) :: :ok
  def close(client) do
    if not is_nil(client.session) and Process.alive?(client.profile),
      do: raw(client, :delete, "/mcp")

    disconnect(client)
  end

  @doc "Looks up a response header without creating atoms."
  @spec header(reply(), String.t()) :: String.t() | nil
  def header(response, name) do
    case List.keyfind(response.headers, String.to_charlist(name), 0) do
      {_, value} -> to_string(value)
      nil -> nil
    end
  end

  defp decode(""), do: nil
  defp decode(body), do: Jason.decode!(body)
end
