defmodule ElixirMixir.Runtime.Effects do
  @moduledoc "Validates complete generated effect batches and derives bounded deterministic delivery identities."

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Values

  @doc "Validates every effect before admission; malformed batches never produce partial effects."
  @spec validate(term(), Limits.t()) :: :ok | {:error, Error.t()}
  def validate(effects, limits) when is_list(effects) do
    if length(effects) > limits.effects do
      {:error, Error.new("LIMIT_EXCEEDED")}
    else
      Enum.reduce_while(effects, :ok, &validate_next(&1, &2, limits))
    end
  end

  def validate(_effects, _limits), do: invalid()

  @doc "Returns a 64-character SHA-256 identity over the originating request and bounded effect path."
  @spec identity(String.t(), [pos_integer()]) :: String.t()
  def identity(origin, path),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary({origin, path})) |> Base.encode16(case: :lower)

  defp validate_next(effect, :ok, limits) do
    case validate_effect(effect, limits) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp validate_effect(%{"type" => "emit"} = effect, limits) do
    with :ok <- keys(effect, ~w(type to event)),
         :ok <- destination(effect),
         do: event(effect, limits)
  end

  defp validate_effect(%{"type" => "schedule", "delay_ms" => delay} = effect, limits) do
    with :ok <- keys(effect, ~w(type to delay_ms event)),
         :ok <- destination(effect),
         :ok <- event(effect, limits) do
      cond do
        not is_integer(delay) or delay < 0 -> invalid()
        delay > limits.timer_delay_ms -> {:error, Error.new("LIMIT_EXCEEDED")}
        true -> :ok
      end
    end
  end

  defp validate_effect(
         %{"type" => "log", "level" => level, "message" => message} = effect,
         limits
       ) do
    with :ok <- keys(effect, ~w(type level message metadata)),
         true <- level in ~w(debug info warning error) and is_binary(message),
         true <- String.valid?(message),
         :ok <- log_size(message, limits),
         :ok <- value(effect["metadata"], :metadata, limits),
         true <- is_map(effect["metadata"]) do
      :ok
    else
      false -> invalid()
      error -> error
    end
  end

  defp validate_effect(_effect, _limits), do: invalid()
  defp destination(effect), do: if(Values.valid_id?(effect["to"]), do: :ok, else: invalid())
  defp event(effect, limits), do: value(effect["event"], :event, limits)

  defp value(value, kind, limits) do
    case Values.validate(value, kind, limits) do
      {:error, %{"code" => "INVALID_ARGUMENT"}} -> invalid()
      result -> result
    end
  end

  defp log_size(message, limits),
    do:
      if(byte_size(message) <= limits.diagnostic_bytes,
        do: :ok,
        else: {:error, Error.new("LIMIT_EXCEEDED")}
      )

  defp keys(effect, expected),
    do: if(Enum.sort(Map.keys(effect)) == Enum.sort(expected), do: :ok, else: invalid())

  defp invalid, do: {:error, Error.new("INVALID_TRANSITION")}
end
