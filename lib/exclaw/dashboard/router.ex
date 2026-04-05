defmodule ExClaw.Dashboard.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {ExClaw.Dashboard.Layouts, :root}
  end

  scope "/", ExClaw.Dashboard.Live do
    pipe_through :browser

    live "/", DashboardLive
  end

  scope "/" do
    pipe_through :browser

    live_dashboard "/dashboard",
      metrics: ExClaw.Dashboard.Telemetry,
      additional_pages: [
        exclaw_overview: ExClaw.Dashboard.Live.OverviewPage,
        exclaw_memory: ExClaw.Dashboard.Live.MemoryPage,
        exclaw_security: ExClaw.Dashboard.Live.SecurityPage,
        exclaw_llm: ExClaw.Dashboard.Live.LLMPage,
        exclaw_system: ExClaw.Dashboard.Live.SystemPage,
        exclaw_scheduler: ExClaw.Dashboard.Live.SchedulerPage
      ]
  end
end
