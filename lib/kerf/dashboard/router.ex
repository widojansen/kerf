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

  # SPEC_H §2.8: the labelling page exists only where config sets :eval_ui
  # (dev and test); prod.exs and runtime.exs never do, so a release lacks it.
  @eval_pages if Application.compile_env(:kerf, :eval_ui),
                do: [eval_label: Kerf.Dashboard.Live.Eval.LabelPage],
                else: []

  scope "/" do
    pipe_through :browser

    live_dashboard "/dashboard",
      metrics: Kerf.Dashboard.Telemetry,
      additional_pages: [
        kerf_overview: Kerf.Dashboard.Live.OverviewPage,
        kerf_memory: Kerf.Dashboard.Live.MemoryPage,
        kerf_security: Kerf.Dashboard.Live.SecurityPage,
        kerf_llm: Kerf.Dashboard.Live.LLMPage,
        kerf_system: Kerf.Dashboard.Live.SystemPage,
        kerf_scheduler: Kerf.Dashboard.Live.SchedulerPage
      ] ++ @eval_pages
  end
end
