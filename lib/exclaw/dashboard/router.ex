defmodule Kerf.Dashboard.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {Kerf.Dashboard.Layouts, :root}
  end

  scope "/" do
    pipe_through :browser

    get "/", Kerf.Dashboard.RedirectController, :index
  end

  scope "/" do
    pipe_through :browser

    live_dashboard "/dashboard",
      metrics: Kerf.Dashboard.Telemetry,
      additional_pages: [
        exclaw_overview: Kerf.Dashboard.Live.OverviewPage,
        exclaw_memory: Kerf.Dashboard.Live.MemoryPage,
        exclaw_security: Kerf.Dashboard.Live.SecurityPage,
        exclaw_llm: Kerf.Dashboard.Live.LLMPage,
        exclaw_system: Kerf.Dashboard.Live.SystemPage,
        exclaw_scheduler: Kerf.Dashboard.Live.SchedulerPage
      ]
  end
end
