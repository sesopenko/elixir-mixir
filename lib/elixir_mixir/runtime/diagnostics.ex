defmodule ElixirMixir.Runtime.Diagnostics do
  @moduledoc "Bounds compiler diagnostic text and counts without returning stack traces."

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits

  @doc "Truncates UTF-8 text to the configured diagnostic byte ceiling."
  @spec text(String.t(), Limits.t()) :: String.t()
  def text(value, limits) do
    value |> binary_part(0, min(byte_size(value), limits.diagnostic_bytes)) |> valid_prefix()
  end

  @doc "Converts compiler diagnostics to bounded JSON records."
  @spec normalize([map()], Limits.t()) :: [map()]
  def normalize(diagnostics, limits) do
    diagnostics
    |> Enum.take(limits.diagnostics)
    |> Enum.map(fn diagnostic ->
      %{
        "severity" => to_string(diagnostic.severity),
        "message" => text(diagnostic.message, limits)
      }
    end)
  end

  @doc "Builds a stable error containing a bounded diagnostic list."
  @spec error(String.t(), String.t(), Limits.t()) :: {:error, Error.t()}
  def error(code, message, limits) do
    {:error,
     Map.put(Error.new(code), "details", %{
       "diagnostics" => [%{"severity" => "error", "message" => text(message, limits)}]
     })}
  end

  defp valid_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_prefix(binary_part(value, 0, byte_size(value) - 1))
  end
end
