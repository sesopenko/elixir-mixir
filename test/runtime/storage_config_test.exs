defmodule ElixirMixir.Runtime.StorageConfigTest do
  use ExUnit.Case, async: true
  alias ElixirMixir.Runtime.StorageConfig

  test "storage is explicit and durable directories are absolute" do
    assert StorageConfig.new([]) == %{mode: :memory, data_dir: nil}
    assert StorageConfig.new(mode: :durable, data_dir: "data").data_dir == Path.expand("data")

    for opts <- [[mode: :unknown], [mode: :durable], [mode: :durable, data_dir: ""]] do
      assert_raise ArgumentError, fn -> StorageConfig.new(opts) end
    end
  end
end
