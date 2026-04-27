defmodule Kerf.Dashboard.Endpoint do
  use Phoenix.Endpoint, otp_app: :kerf

  # Salt indexes data at rest (signed cookies). Treat as opaque-internal data identity, not code identity.
  @session_options [
    store: :cookie,
    key: "_kerf_key",
    signing_salt: "exclaw_salt"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/dashboard/css",
    from: {:phoenix_live_dashboard, "priv/static/css"},
    only: ~w(app.css)

  plug Plug.Static,
    at: "/dashboard/js",
    from: {:phoenix_live_dashboard, "priv/static/js"},
    only: ~w(app.js)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug Plug.Session, @session_options
  plug Kerf.Dashboard.Router
end
