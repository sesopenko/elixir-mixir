defmodule ElixirMixir.Runtime.Inspection do
  @moduledoc "Validates runtime inspection arguments independently of MCP schema coercion."

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Values

  @doc "Checks optional keys, types, IDs and page bounds; cursor generation is validated by Inspector."
  @spec validate(term(), Limits.t()) :: :ok | {:error, Error.t()}
  def validate(args, limits) when is_map(args) and not is_struct(args) do
    valid =
      Map.keys(args) -- ["worker_id", "detail", "limit", "cursor"] == [] and
        optional?(args, "worker_id", &Values.valid_id?/1) and
        optional?(args, "detail", &(&1 in ["summary", "state"])) and
        optional?(args, "limit", &(is_integer(&1) and &1 > 0 and &1 <= limits.page_max)) and
        valid_cursor?(args)

    if valid, do: :ok, else: {:error, Error.new("INVALID_ARGUMENT")}
  end

  def validate(_args, _limits), do: {:error, Error.new("INVALID_ARGUMENT")}

  @doc "Validates exclusive event cursor, optional worker filter and bounded page size."
  @spec events(term(), Limits.t()) :: :ok | {:error, Error.t()}
  def events(args, limits) when is_map(args) and not is_struct(args) do
    valid =
      Map.keys(args) -- ["after", "limit", "worker_id"] == [] and
        optional?(args, "worker_id", &Values.valid_id?/1) and
        optional?(args, "after", &(is_integer(&1) and &1 >= 0)) and
        optional?(args, "limit", &(is_integer(&1) and &1 > 0 and &1 <= limits.page_max))

    if valid, do: :ok, else: {:error, Error.new("INVALID_ARGUMENT")}
  end

  def events(_args, _limits), do: {:error, Error.new("INVALID_ARGUMENT")}

  defp valid_cursor?(args) do
    optional?(args, "cursor", &(is_binary(&1) and byte_size(&1) in 1..256)) and
      not (Map.has_key?(args, "worker_id") and Map.has_key?(args, "cursor"))
  end

  defp optional?(args, key, predicate) do
    case Map.fetch(args, key) do
      :error -> true
      {:ok, value} -> predicate.(value)
    end
  end
end
