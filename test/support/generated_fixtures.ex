defmodule ElixirMixir.TestSupport.GeneratedFixtures do
  @moduledoc "Trusted generated-source fixtures used only by runtime and HTTP tests."

  @doc "Returns one Generated template with injectable schema, body and callback expressions."
  @spec source(keyword()) :: String.t()
  def source(opts \\ []) do
    schema = Keyword.get(opts, :schema, "1")
    body = Keyword.get(opts, :body, "")
    init = Keyword.get(opts, :init, "{:ok, config}")
    event = Keyword.get(opts, :event, "{:ok, event, state, []}")

    """
    defmodule Generated do
      @behaviour ElixirMixir.Behavior
      #{body}
      @impl true
      def init(config), do: (#{init})
      @impl true
      def handle_event(event, state), do: (#{event})
      @impl true
      def state_schema(), do: #{schema}
      @impl true
      def migrate(state, _metadata), do: {:ok, state}
    end
    """
  end

  @doc "Returns reusable startup behavior including deliberate failure paths selected by config."
  @spec worker_source() :: String.t()
  def worker_source do
    source(
      init: """
      case config["mode"] do
        "error" -> {:error, "initialization rejected"}
        "raise" -> raise "initialization raised"
        "exit" -> exit(:initialization_exit)
        "timeout" -> Process.sleep(:infinity)
        "non_json" -> {:ok, %{"pid" => self()}}
        "invalid_root" -> {:ok, []}
        "invalid_shape" -> :ok
        "heap" -> {:ok, %{"large" => Enum.to_list(1..1_000_000)}}
        "payload" -> {:ok, %{"v" => String.duplicate("x", config["bytes"])}}
        _normal -> {:ok, config}
      end
      """
    )
  end

  @doc "Returns a counter with deliberate event rejection/resource-limit modes."
  @spec counter_source() :: String.t()
  def counter_source do
    source(
      init: "{:ok, %{\"count\" => Map.get(config, \"initial\", 0)}}",
      event: """
      count = state["count"] + Map.get(event, "amount", 1)
      next = %{"count" => count}
      case event["mode"] do
        "error" -> {:error, Map.get(event, "reason", "rejected event")}
        "raise" -> raise "callback raised"
        "exit" -> exit(:event_exit)
        "timeout" -> Process.sleep(:infinity)
        "late" -> Process.sleep(300); {:ok, count, next, []}
        "malformed" -> {:ok, count}
        "reply_non_json" -> {:ok, self(), next, []}
        "state_non_json" -> {:ok, count, %{"pid" => self()}, []}
        "invalid_state" -> {:ok, count, [], []}
        "effects" -> {:ok, count, next, [%{"type" => "log", "message" => "not supported"}]}
        "reply_payload" -> {:ok, String.duplicate("x", event["bytes"]), next, []}
        "state_payload" -> {:ok, count, %{"v" => String.duplicate("x", event["bytes"])}, []}
        "reply" -> {:ok, event["value"], next, []}
        "heap" -> {:ok, Enum.to_list(1..1_000_000), next, []}
        "controlled" -> ElixirMixir.TestSupport.CallbackBarrier.wait("invoke"); {:ok, count, next, []}
        _normal -> {:ok, count, next, []}
      end
      """
    )
  end

  @doc "Expands an extra module to verify actual compiler output independently of AST checks."
  @spec extra_module() :: Macro.t()
  defmacro extra_module do
    quote do
      defmodule ElixirMixir.TestSupport.UnexpectedArtifact do
        @moduledoc "Unexpected macro expansion fixture."
        @doc "Returns an observable constant."
        @spec hello() :: :world
        def hello, do: :world
      end
    end
  end
end
