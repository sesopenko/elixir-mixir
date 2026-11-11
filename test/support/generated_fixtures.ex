defmodule ElixirMixir.TestSupport.GeneratedFixtures do
  @moduledoc "Trusted generated-source fixtures used only by runtime and HTTP tests."

  @doc "Returns one Generated template with injectable schema, body and callback expressions."
  @spec source(keyword()) :: String.t()
  def source(opts \\ []) do
    schema = Keyword.get(opts, :schema, "1")
    body = Keyword.get(opts, :body, "")
    init = Keyword.get(opts, :init, "{:ok, config}")

    """
    defmodule Generated do
      @behaviour ElixirMixir.Behavior
      #{body}
      @impl true
      def init(config), do: #{init}
      @impl true
      def handle_event(event, state), do: {:ok, event, state, []}
      @impl true
      def state_schema(), do: #{schema}
      @impl true
      def migrate(state, _metadata), do: {:ok, state}
    end
    """
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
