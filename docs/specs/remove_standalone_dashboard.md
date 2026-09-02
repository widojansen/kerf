# Spec: Remove Standalone Dashboard, Redirect / to /dashboard

**Goal:** Remove the standalone custom dashboard at `/` and redirect to `/dashboard` (Phoenix LiveDashboard). The custom Kerf pages already exist as `additional_pages` in LiveDashboard, so the standalone version is redundant and its tabs are broken.

## What to Change

### 1. Router (`lib/kerf/dashboard/router.ex`)

Remove the standalone LiveView route and replace with a redirect:

**Before:**
```elixir
scope "/", Kerf.Dashboard.Live do
  pipe_through :browser
  live "/", DashboardLive
end
```

**After:**
```elixir
scope "/" do
  pipe_through :browser
  get "/", Kerf.Dashboard.RedirectController, :index
end
```

Create `lib/kerf/dashboard/redirect_controller.ex`:
```elixir
defmodule Kerf.Dashboard.RedirectController do
  use Phoenix.Controller, formats: [:html]

  def index(conn, _params) do
    redirect(conn, to: "/dashboard")
  end
end
```

### 2. Delete the standalone DashboardLive

Delete this file — it is fully replaced by the `additional_pages` in LiveDashboard:

- `lib/kerf/dashboard/live/dashboard_live.ex`

### 3. Delete standalone components (if not used by additional_pages)

Check each component file to see if it's imported/aliased by any of the `additional_pages` (`overview_page.ex`, `memory_page.ex`, etc.). If a component is ONLY used by `dashboard_live.ex`, delete it:

- `lib/kerf/dashboard/live/components/sessions_component.ex`
- `lib/kerf/dashboard/live/components/rate_limiter_component.ex`
- `lib/kerf/dashboard/live/components/memory_component.ex`
- `lib/kerf/dashboard/live/components/security_log_component.ex`
- `lib/kerf/dashboard/live/components/llm_log_component.ex`
- `lib/kerf/dashboard/live/components/system_component.ex`

**To check:** `grep -r "SessionsComponent\|RateLimiterComponent\|MemoryComponent\|SecurityLogComponent\|LlmLogComponent\|SystemComponent" lib/kerf/dashboard/live/ --include="*.ex" | grep -v dashboard_live.ex`

If nothing references them besides `dashboard_live.ex`, delete them all.

### 4. Verify the additional_pages are complete

The LiveDashboard `additional_pages` should cover everything the standalone dashboard had. Confirm these files exist and work:

- `lib/kerf/dashboard/live/overview_page.ex` — sessions + rate limiter
- `lib/kerf/dashboard/live/memory_page.ex` — facts, group memory, messages
- `lib/kerf/dashboard/live/security_page.ex` — security denial events
- `lib/kerf/dashboard/live/llm_page.ex` — LLM calls + errors
- `lib/kerf/dashboard/live/system_page.ex` — system info
- `lib/kerf/dashboard/live/scheduler_page.ex` — scheduled tasks

### 5. Ensure `:os_mon` is in extra_applications

In `mix.exs`, add `:os_mon` to `extra_applications` if not already present:

```elixir
extra_applications: [:logger, :runtime_tools, :os_mon]
```

This enables the OS Data tab in LiveDashboard.

## Testing

- `mix compile --warnings-as-errors` — no warnings from removed modules
- Start with `iex -S mix phx.server`
- `GET /` should redirect (302) to `/dashboard`
- `/dashboard` shows standard tabs: Home, Processes, Ports, Sockets, ETS, Applications, OS Data
- `/dashboard` also shows Kerf tabs: Kerf Overview, Kerf Memory, Kerf Security, Kerf LLM, Kerf System, Kerf Scheduler
- All Kerf tabs render correctly with live data

## Commit

`refactor: remove standalone dashboard, redirect / to Phoenix LiveDashboard`
