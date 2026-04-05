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
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: [
        exclaw: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :os_mon],
      mod: {ExClaw.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:pgvector, "~> 0.3"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},

      # Web dashboard
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_html, "~> 4.0"},
      {:bandit, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},

      # Tools
      {:quantum, "~> 3.5"},
      {:floki, "~> 0.36"},

      # Security
      {:plug_crypto, "~> 2.0"},

      # Telemetry / ClickHouse
      {:ch, "~> 0.7"},
      {:telemetry_poller, "~> 1.1"},
      {:logger_json, "~> 6.0"},

      # Dev/Test
      {:lazy_html, ">= 0.1.0", only: :test},
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

