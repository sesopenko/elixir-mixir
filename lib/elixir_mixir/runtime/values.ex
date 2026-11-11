defmodule ElixirMixir.Runtime.Values do
  @moduledoc "Validates bounded JSON values and hashes canonical request arguments."

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits

  @type kind :: :config | :event | :state | :reply | :metadata | :source

  @doc "Checks an ASCII logical, worker, or request ID without creating atoms."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, id)
  def valid_id?(_id), do: false

  @doc "Validates root shape, JSON terms, depth and encoded byte size. Source uses raw UTF-8 bytes."
  @spec validate(term(), kind(), Limits.t()) :: :ok | {:error, Error.t()}
  def validate(value, kind, limits) do
    with :ok <- root(value, kind),
         :ok <- json(value, 0, limits.depth) do
      bytes = if kind == :source, do: byte_size(value), else: byte_size(Jason.encode!(value))
      if bytes <= Map.fetch!(limits, byte_key(kind)), do: :ok, else: limit_error()
    end
  end

  @doc "Hashes validated JSON arguments with sorted map keys, excluding request_id."
  @spec request_hash(String.t(), map()) :: String.t()
  def request_hash(operation, args) do
    canonical = canonical([operation, Map.delete(args, "request_id")])
    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  defp byte_key(:source), do: :source_bytes
  defp byte_key(:config), do: :config_bytes
  defp byte_key(:event), do: :event_bytes
  defp byte_key(:state), do: :state_bytes
  defp byte_key(:reply), do: :reply_bytes
  defp byte_key(:metadata), do: :metadata_bytes

  defp root(value, kind) when kind in [:config, :event, :state, :metadata] do
    if is_map(value) and not is_struct(value), do: :ok, else: invalid()
  end

  defp root(value, :source) when is_binary(value), do: :ok
  defp root(_value, :source), do: invalid()
  defp root(_value, :reply), do: :ok

  defp json(_value, depth, max) when depth > max, do: limit_error()
  defp json(value, _depth, _max) when value in [nil, true, false], do: :ok
  defp json(value, _depth, _max) when is_number(value), do: :ok

  defp json(value, _depth, _max) when is_binary(value) do
    if String.valid?(value), do: :ok, else: invalid()
  end

  defp json(value, depth, max) when is_list(value) do
    children(value, depth, max)
  end

  defp json(value, depth, max) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      with true <- is_binary(key),
           :ok <- json(key, depth + 1, max),
           :ok <- json(item, depth + 1, max) do
        {:cont, :ok}
      else
        false -> {:halt, invalid()}
        error -> {:halt, error}
      end
    end)
  end

  defp json(_value, _depth, _max), do: invalid()

  defp children([], _depth, _max), do: :ok

  defp children([head | tail], depth, max) do
    with :ok <- json(head, depth + 1, max), do: children(tail, depth, max)
  end

  defp children(_improper, _depth, _max), do: invalid()

  defp canonical(value) when is_map(value) do
    entries =
      value |> Enum.sort() |> Enum.map(fn {k, v} -> [Jason.encode!(k), ":", canonical(v)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp canonical(value) when is_list(value) do
    ["[", Enum.intersperse(Enum.map(value, &canonical/1), ","), "]"]
  end

  defp canonical(value), do: Jason.encode!(value)
  defp invalid, do: {:error, Error.new("INVALID_ARGUMENT")}
  defp limit_error, do: {:error, Error.new("LIMIT_EXCEEDED")}
end
