defmodule ExClaw.Dashboard.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {ExClaw.Dashboard.Layouts, :root}
  end

  scope "/", ExClaw.Dashboard.Live do
    pipe_through :browser

    live "/", DashboardLive
  end
end
