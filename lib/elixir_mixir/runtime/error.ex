defmodule ElixirMixir.Runtime.Error do
  @moduledoc "Builds stable JSON error values without exposing exception terms."

  @codes ~w(INVALID_ARGUMENT LIMIT_EXCEEDED COMPILE_FAILED CALLBACK_MISSING
    ARTIFACT_NOT_FOUND WORKER_NOT_FOUND WORKER_EXISTS WORKER_NOT_RUNNING
    CALLBACK_FAILED CALLBACK_TIMEOUT INVALID_TRANSITION MIGRATION_FAILED
    REVISION_CONFLICT REQUEST_ID_CONFLICT BUSY INTERNAL_ERROR)

  @type t :: %{String.t() => term()}

  @doc "Returns a bounded error with a known code and kernel-owned message."
  @spec new(String.t()) :: t()
  def new(code) when code in @codes do
    %{"code" => code, "message" => message(code), "details" => %{}}
  end

  defp message("INVALID_ARGUMENT"), do: "Invalid argument"
  defp message("LIMIT_EXCEEDED"), do: "Resource limit exceeded"
  defp message("REQUEST_ID_CONFLICT"), do: "Request ID already used for different arguments"
  defp message("BUSY"), do: "Runtime capacity unavailable"
  defp message(_code), do: "Runtime operation failed"
end
