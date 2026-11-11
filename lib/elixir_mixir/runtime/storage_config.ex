defmodule ElixirMixir.Runtime.StorageConfig do
  @moduledoc "Validates explicit durable storage selection without falling back to memory."

  @type t :: %{mode: :memory | :durable, data_dir: String.t() | nil}

  @doc "Builds storage settings. Durable directories are expanded to absolute paths."
  @spec new(keyword()) :: t()
  def new(opts) do
    case Keyword.get(opts, :mode, :memory) do
      :memory -> %{mode: :memory, data_dir: nil}
      :durable -> durable(Keyword.get(opts, :data_dir))
      _other -> raise ArgumentError, "invalid storage mode"
    end
  end

  defp durable(path) when is_binary(path) and byte_size(path) > 0 do
    %{mode: :durable, data_dir: Path.expand(path)}
  end

  defp durable(_path), do: raise(ArgumentError, "durable storage requires data_dir")
end
