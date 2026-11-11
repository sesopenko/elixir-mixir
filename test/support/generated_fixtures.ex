defmodule ElixirMixir.TestSupport.GeneratedFixtures do
  @moduledoc "Trusted generated-source fixtures used only by runtime and HTTP tests."

  @doc "Returns one Generated template with injectable schema, body and callback expressions."
  @spec source(keyword()) :: String.t()
  def source(opts \\ []) do
    schema = Keyword.get(opts, :schema, "1")
    body = Keyword.get(opts, :body, "")
    init = Keyword.get(opts, :init, "{:ok, config}")
    event = Keyword.get(opts, :event, "{:ok, event, state, []}")
    migrate = Keyword.get(opts, :migrate, "{:ok, state}")

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
      def migrate(state, metadata) do
      _ = state
      _ = metadata
      (#{migrate})
    end
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
        "effects" -> {:ok, count, next, [%{"type" => "unsupported"}]}
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

  @doc "Returns counting/aggregating workers with declarative effects and test-only callback controls."
  @spec effects_source() :: String.t()
  def effects_source do
    source(
      init: ~S|{:ok, Map.merge(%{"count" => 0, "total" => 0}, config)}|,
      event: ~S"""
      if event["controlled"], do: ElixirMixir.TestSupport.CallbackBarrier.wait("effects")
      count = state["count"] + 1
      total = state["total"] + Map.get(event, "amount", 1)
      next = Map.merge(state, %{"count" => count, "total" => total})
      effects = if state["forward"], do: [%{"type" => "emit", "to" => state["forward"], "event" => %{"amount" => Map.get(event, "amount", 1)}}], else: Map.get(event, "effects", [])
      cond do
        event["failure"] -> {:error, :rejected}
        event["invalid_state"] -> {:ok, count, %{"pid" => self()}, effects}
        true -> {:ok, count, next, effects}
      end
      """
    )
  end

  @doc "Returns versioned counters with explicit reverse migration and bounded failure/barrier modes."
  @spec replacement_source(1 | 2 | 3) :: String.t()
  def replacement_source(version) when version in [1, 2, 3] do
    key = if version == 3, do: "value", else: "count"

    factor =
      case version do
        1 -> 1
        2 -> 2
        3 -> 10
      end

    migration =
      case version do
        1 ->
          ~S|{:ok, %{"count" => state["value"], "migration" => "ok"}}|

        2 ->
          ~S|raise "same-schema migration must not execute"|

        3 ->
          ~S"""
          next = %{"value" => state["count"], "migration" => state["migration"], "metadata" => metadata}
          case state["migration"] do
            "error" -> {:error, String.duplicate("😺", 3_000)}
            "raise" -> raise "migration raised"
            "exit" -> exit(:migration_exit)
            "timeout" -> Process.sleep(:infinity)
            "late" -> Process.sleep(300); {:ok, next}
            "malformed" -> {:ok, next, []}
            "invalid_root" -> {:ok, []}
            "non_json" -> {:ok, %{"pid" => self()}}
            "oversized" -> {:ok, %{"v" => String.duplicate("x", 16_384)}}
            "heap" -> {:ok, %{"large" => Enum.to_list(1..1_000_000)}}
            "controlled" -> ElixirMixir.TestSupport.CallbackBarrier.wait("replace"); {:ok, next}
            _normal -> {:ok, next}
          end
          """
      end

    source(
      schema: if(version == 3, do: "2", else: "1"),
      init:
        "{:ok, %{\"#{key}\" => Map.get(config, \"initial\", 0), \"migration\" => Map.get(config, \"migration\", \"ok\")}}",
      event: """
      if event["controlled"], do: ElixirMixir.TestSupport.CallbackBarrier.wait("event")
      count = state["#{key}"] + Map.get(event, "amount", 1) * #{factor}
      {:ok, count, Map.put(state, "#{key}", count), []}
      """,
      migrate: migration
    )
  end

  @doc "Returns a mutable worker with a test-only reinitialization failure switch."
  @spec recovery_source() :: String.t()
  def recovery_source do
    source(
      init:
        "if Application.get_env(:elixir_mixir, :test_recovery_failure, false), do: {:error, :reinit_failed}, else: {:ok, config}",
      event: "{:ok, event, Map.merge(state, event), []}"
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
