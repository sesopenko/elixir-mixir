defmodule ElixirMixir.Runtime.Callback do
  @moduledoc "Executes generated callbacks outside hosts and Manager under the callback resource budget."

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Execution
  alias ElixirMixir.Runtime.Limits

  @doc "Runs one generated callback with monitored cleanup and stable failure outcomes."
  @spec run((-> term()), Limits.t()) :: {:ok, term()} | {:error, Error.t()}
  def run(work, limits) do
    case Execution.run(
           ElixirMixir.CallbackTasks,
           work,
           limits.callback_timeout_ms,
           limits.callback_heap_words
         ) do
      {:ok, result, _helpers} -> {:ok, result}
      {:error, :timeout, _helpers} -> {:error, Error.new("CALLBACK_TIMEOUT")}
      {:error, :failed, _helpers} -> {:error, Error.new("CALLBACK_FAILED")}
    end
  end
end
