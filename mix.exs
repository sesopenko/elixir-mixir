defmodule ElixirMixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_mixir,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      preferred_cli_env: [check: :test],
      dialyzer: [
        plt_core_path: "_build/dialyzer",
        plt_local_path: "_build/dialyzer",
        plt_add_apps: [:ex_unit]
      ],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto] ++ test_applications(Mix.env()),
      mod: {ElixirMixir.Application, []}
    ]
  end

  defp test_applications(:test), do: [:inets]
  defp test_applications(_env), do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:cubdb, "== 2.0.2"},
      {:hermes_mcp, "== 0.14.1"},
      {:plug, "== 1.20.3"},
      {:bandit, "== 1.14.1"},
      {:jason, "== 1.4.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.23.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "doctor --raise",
        "test --warnings-as-errors",
        "dialyzer"
      ]
    ]
  end
end
