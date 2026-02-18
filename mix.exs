defmodule ExClaw.MixProject do
  use Mix.Project

  def project do
    [
      app: :exclaw,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExClaw.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core
      {:ecto_sqlite3, "~> 0.17"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},

      # Web dashboard (optional)
      # {:phoenix, "~> 1.7"},
      # {:phoenix_live_view, "~> 1.0"},
      # {:phoenix_html, "~> 4.0"},

      # Tools
      {:quantum, "~> 3.5"},
      {:floki, "~> 0.36"},

      # Security
      {:plug_crypto, "~> 2.0"},

      # Dev/Test
      {:mox, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end

