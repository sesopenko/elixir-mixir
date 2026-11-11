defmodule ElixirMixir.Runtime.Compiler do
  @moduledoc "Compiles one Generated template into its reserved immutable module under resource controls."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.Diagnostics
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Execution
  alias ElixirMixir.Runtime.Limits

  @callbacks [init: 1, handle_event: 2, state_schema: 0, migrate: 2]

  @doc "Compiles a reserved template and validates all exports and its bounded schema callback."
  @spec compile(String.t(), ArtifactRegistry.reservation(), Limits.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def compile(source, reservation, limits) do
    result =
      Execution.run(
        ElixirMixir.CompilerTasks,
        fn -> compile_source(source, reservation, limits) end,
        limits.compile_timeout_ms,
        limits.compiler_heap_words
      )

    case result do
      {:ok, {:ok, compiled}, helpers} ->
        schema(Map.put(compiled, :compiler_helpers, helpers), limits)

      {:ok, {:error, _error} = error, _helpers} ->
        error

      {:error, reason, helpers} ->
        Diagnostics.error(
          "COMPILE_FAILED",
          "Compilation #{reason}; tracked helper processes: #{helpers}",
          limits
        )
    end
  end

  defp compile_source(source, reservation, limits) do
    with {:ok, ast} <- Code.string_to_quoted(source),
         {:ok, ast} <- template(ast, reservation.module) do
      {outcome, diagnostics} =
        Code.with_diagnostics(
          [log: false],
          fn ->
            try do
              {:ok, Code.compile_quoted(ast, "generated/slot_#{reservation.slot}.ex")}
            rescue
              exception -> {:error, Exception.message(exception)}
            catch
              _kind, _reason -> {:error, "Compilation terminated"}
            end
          end
        )

      compiled(outcome, diagnostics, reservation.module, limits)
    else
      _invalid ->
        Diagnostics.error(
          "COMPILE_FAILED",
          "Expected one Generated template without nested or dynamic module construction",
          limits
        )
    end
  end

  defp template({:defmodule, meta, [{:__aliases__, _, [:Generated]}, [do: body]]}, module) do
    {_body, forbidden} =
      Macro.prewalk(body, false, fn node, found -> {node, found or forbidden?(node)} end)

    if forbidden, do: {:error, :forbidden}, else: {:ok, {:defmodule, meta, [module, [do: body]]}}
  end

  defp template(_ast, _module), do: {:error, :template}

  defp forbidden?({:defmodule, _, _}), do: true
  defp forbidden?({{:., _, [_module, :defmodule]}, _, _}), do: true

  defp forbidden?({{:., _, [module, function]}, _, _}) do
    (module in [{:__aliases__, [], [:Module]}, Module] and function == :create) or
      (code_module?(module) and is_atom(function) and
         String.starts_with?(Atom.to_string(function), "compile_")) or
      (module_alias(module) == Module and function == :create)
  end

  defp forbidden?(_ast), do: false

  defp code_module?(module), do: module_alias(module) == Code
  defp module_alias({:__aliases__, _, [:Module]}), do: Module
  defp module_alias({:__aliases__, _, [:"Elixir", :Module]}), do: Module
  defp module_alias({:__aliases__, _, [:Code]}), do: Code
  defp module_alias({:__aliases__, _, [:"Elixir", :Code]}), do: Code
  defp module_alias(module), do: module

  defp compiled({:ok, [{module, beam}]}, diagnostics, module, limits) do
    if Enum.all?(@callbacks, fn {callback, arity} ->
         function_exported?(module, callback, arity)
       end) do
      if diagnostics == [],
        do: {:ok, %{module: module, beam: beam, diagnostics: []}},
        else: compiled({:error, "Compiler diagnostics"}, diagnostics, module, limits)
    else
      Diagnostics.error(
        "CALLBACK_MISSING",
        "Required callbacks: init/1, handle_event/2, state_schema/0, migrate/2",
        limits
      )
    end
  end

  defp compiled(_outcome, [_ | _] = diagnostics, _module, limits) do
    {:error,
     Map.put(Error.new("COMPILE_FAILED"), "details", %{
       "diagnostics" => Diagnostics.normalize(diagnostics, limits)
     })}
  end

  defp compiled({:error, message}, [], _module, limits),
    do: Diagnostics.error("COMPILE_FAILED", message, limits)

  defp compiled(_outcome, [], _module, limits),
    do:
      Diagnostics.error(
        "COMPILE_FAILED",
        "Compilation output must contain exactly the reserved module",
        limits
      )

  defp schema(compiled, limits) do
    case Execution.run(
           ElixirMixir.CallbackTasks,
           fn ->
             Code.with_diagnostics([log: false], fn -> compiled.module.state_schema() end)
           end,
           limits.callback_timeout_ms,
           limits.callback_heap_words
         ) do
      {:ok, {version, []}, _helpers} when is_integer(version) and version > 0 ->
        {:ok, Map.put(compiled, :state_schema, version)}

      _failure ->
        Diagnostics.error(
          "COMPILE_FAILED",
          "state_schema/0 must return a positive integer within its callback deadline and heap budget",
          limits
        )
    end
  end
end
