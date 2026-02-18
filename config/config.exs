import Config

config :exclaw, ecto_repos: [ExClaw.Repo]

config :exclaw, ExClaw.Repo,
  database: "priv/exclaw_#{config_env()}.db"

import_config "#{config_env()}.exs"
