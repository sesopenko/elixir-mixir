defmodule ElixirMixirTest do
  use ExUnit.Case, async: true
  doctest ElixirMixir

  test "greets the world" do
    assert ElixirMixir.hello() == :world
  end

  test "starts the application supervisor" do
    assert is_pid(Process.whereis(ElixirMixir.Supervisor))
  end
end
