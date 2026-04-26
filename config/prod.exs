import Config

config :kerf, Kerf.Repo,
  database: "exclaw_prod",
  hostname: "localhost",
  port: 5432,
  pool_size: 10

config :kerf, Kerf.Dashboard.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true

config :logger, level: :info

# Structured JSON logging for journalctl queryability.
# Usage: journalctl -u exclaw --output=cat | jq 'select(.severity == "error")'
config :logger, :default_handler,
  formatter: {LoggerJSON.Formatters.Basic, metadata: :all}
