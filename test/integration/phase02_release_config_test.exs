defmodule ElixirMixir.Integration.Phase02ReleaseConfigTest do
  use ExUnit.Case, async: false

  setup do
    names = ~w(ELIXIR_MIXIR_DATA_DIR ELIXIR_MIXIR_PORT)
    original = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- original do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    :ok
  end

  test "production release reads the retained data path and loopback port override" do
    System.put_env("ELIXIR_MIXIR_DATA_DIR", "/data")
    System.put_env("ELIXIR_MIXIR_PORT", "4101")
    config = Config.Reader.read!("config/runtime.exs", env: :prod)
    assert config[:elixir_mixir][:storage] == [mode: :durable, data_dir: "/data"]
    assert config[:elixir_mixir][:mcp] == [enabled: true, ip: {127, 0, 0, 1}, port: 4101]
  end

  test "release durability stays opt-in and inherited storage cannot select durable unit tests" do
    System.delete_env("ELIXIR_MIXIR_DATA_DIR")
    System.delete_env("ELIXIR_MIXIR_PORT")
    assert Config.Reader.read!("config/runtime.exs", env: :prod)[:elixir_mixir] == nil
    System.put_env("ELIXIR_MIXIR_DATA_DIR", "/data")
    assert Config.Reader.read!("config/runtime.exs", env: :test)[:elixir_mixir] == nil
  end

  test "release shell keeps distribution off and runtime scratch separate from retained state" do
    {output, 0} =
      System.cmd(
        "sh",
        [
          "-c",
          ~S|. "$1"; printf '%s\n' "RELEASE_DISTRIBUTION=$RELEASE_DISTRIBUTION" "ELIXIR_MIXIR_DATA_DIR=$ELIXIR_MIXIR_DATA_DIR" "RELEASE_TMP=$RELEASE_TMP" "ERL_CRASH_DUMP=$ERL_CRASH_DUMP" "ERL_FLAGS=$ERL_FLAGS"|,
          "sh",
          Path.expand("rel/env.sh.eex")
        ],
        env: [{"ELIXIR_MIXIR_DATA_DIR", "/data"}]
      )

    env =
      output
      |> String.split("\n", trim: true)
      |> Map.new(fn line -> line |> String.split("=", parts: 2) |> List.to_tuple() end)

    assert env["RELEASE_DISTRIBUTION"] == "none"
    assert env["ELIXIR_MIXIR_DATA_DIR"] == "/data"
    assert String.starts_with?(env["RELEASE_TMP"], "/tmp/")
    assert String.starts_with?(env["ERL_CRASH_DUMP"], "/tmp/")
    assert env["ERL_FLAGS"] =~ "+Q 65536"
  end

  test "owned storage paths remain distinct across independent BEAM processes" do
    script = ~S|IO.puts(ElixirMixir.TestSupport.RuntimeFixture.temp_path("mixir-cross-vm"))|

    paths =
      for _ <- 1..2 do
        {output, 0} =
          System.cmd("elixir", [
            "--erl",
            "+S 1:1 +A 1",
            "-pa",
            Application.app_dir(:elixir_mixir, "ebin"),
            "-e",
            script
          ])

        String.trim(output)
      end

    assert length(Enum.uniq(paths)) == 2
    assert Enum.all?(paths, &(not File.exists?(&1)))
  end
end
