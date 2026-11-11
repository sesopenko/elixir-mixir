defmodule ElixirMixir.Runtime.Callback do
  @moduledoc "Executes generated callbacks outside hosts and Manager under the callback resource budget."

  alias ElixirMixir.Runtime.Diagnostics
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Execution
  alias ElixirMixir.Runtime.Limits

  @doc "Runs one generated callback with monitored cleanup and stable failure outcomes."
  @spec run((-> term()), Limits.t()) :: {:ok, term()} | {:error, Error.t()}
  def run(work, limits) do
    case Execution.run(
           ElixirMixir.CallbackTasks,
           fn -> protected(work, limits) end,
           limits.callback_timeout_ms,
           limits.callback_heap_words
         ) do
      {:ok, {:returned, result}, _helpers} ->
        {:ok, result}

      {:ok, {:failed, reason}, _helpers} ->
        {:error, Map.put(Error.new("CALLBACK_FAILED"), "details", %{"reason" => reason})}

      {:error, :timeout, _helpers} ->
        {:error, Error.new("CALLBACK_TIMEOUT")}

      {:error, :failed, _helpers} ->
        {:error, Error.new("CALLBACK_FAILED")}
    end
  end

  defp protected(work, limits) do
    case work.() do
      {:error, reason} -> {:failed, reason_text(reason, limits)}
      result -> {:returned, result}
    end
  rescue
    exception -> {:failed, reason_text(exception, limits)}
  catch
    kind, reason -> {:failed, reason_text({kind, reason}, limits)}
  end

  defp reason_text(reason, limits),
    do:
      reason
      |> inspect(limit: 5, printable_limit: limits.diagnostic_bytes)
      |> Diagnostics.text(limits)
end
