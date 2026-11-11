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
      dialyzer: [plt_core_path: "_build/dialyzer", plt_local_path: "_build/dialyzer"],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {ElixirMixir.Application, []}
    ]
  end

  defp deps do
    [
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
