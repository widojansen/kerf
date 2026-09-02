# Spec: Enable Standard Phoenix LiveDashboard Pages

**Goal:** The ExClaw LiveDashboard currently shows only custom ExClaw tabs (Overview, Memory, Security, LLM, System, Scheduler). The standard Phoenix LiveDashboard pages (Home, Processes, Ports, Sockets, ETS, Applications/OS Data) are missing. Fix the router configuration so both sets of pages appear.

## Context

Phoenix LiveDashboard ships with built-in pages that provide BEAM/Erlang introspection:
- **Home** — VM memory, atoms, IO, uptime, system info
- **Processes** — list all processes, sort by memory/message_queue_len/reductions
- **Ports** — open ports
- **Sockets** — TCP/UDP sockets
- **ETS** — all ETS tables with sizes
- **Applications** — supervision tree viewer (critical for OTP debugging)
- **OS Data** — CPU, memory, disk from the OS level

These appear automatically when using the standard `live_dashboard` macro — unless the configuration overrides or replaces the default pages.

## What to Do

1. **Find the LiveDashboard route** — look in `lib/exclaw_web/router.ex` for the `live_dashboard` call.

2. **Ensure custom pages use `additional_pages`** — the correct pattern is:

```elixir
live_dashboard "/dashboard",
  metrics: ExClawWeb.Telemetry,
  additional_pages: [
    overview: ExClawWeb.Live.Dashboard.OverviewPage,
    memory: ExClawWeb.Live.Dashboard.MemoryPage,
    security: ExClawWeb.Live.Dashboard.SecurityPage,
    llm: ExClawWeb.Live.Dashboard.LLMPage,
    system: ExClawWeb.Live.Dashboard.SystemPage,
    scheduler: ExClawWeb.Live.Dashboard.SchedulerPage
  ]
```

The key: custom pages go in `additional_pages`. The standard pages (Home, Processes, Ports, ETS, Applications, OS Data) then appear automatically alongside them.

**Common mistake:** If the router currently uses a `:pages` option (instead of `:additional_pages`), that *replaces* all default pages. Switch from `:pages` to `:additional_pages`.

3. **Verify `phoenix_live_dashboard` dependency** includes the optional deps for full functionality. In `mix.exs`, ensure these are present:

```elixir
{:phoenix_live_dashboard, "~> 0.8"},
{:telemetry_poller, "~> 1.0"},   # enables VM polling metrics on Home page
{:telemetry_metrics, "~> 1.0"},  # enables metrics graphs
```

If `telemetry_poller` is missing, the Home page will show limited data.

4. **Verify `Telemetry` module exists** — the `metrics:` option points to a module (likely `ExClawWeb.Telemetry`) that defines `metrics/0` returning a list of `Telemetry.Metrics` structs. If this module doesn't exist or `metrics/0` returns `[]`, the metrics graphs on Home will be empty (but the page still works).

5. **Enable `:os_mon`** for the OS Data page — in `mix.exs`, add to `extra_applications`:

```elixir
def application do
  [
    mod: {ExClaw.Application, []},
    extra_applications: [:logger, :runtime_tools, :os_mon]
  ]
end
```

Without `:os_mon`, the OS Data tab won't appear.

6. **Enable request logger for per-request metrics** (optional but nice) — in `endpoint.ex`, ensure `Plug.RequestId` and `Plug.Telemetry` are present:

```elixir
plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
```

## Expected Result

After the fix, the dashboard at `/dashboard` should show tabs in this order:
- Home, Processes, Ports, Sockets, ETS, Applications, OS Data (standard)
- Overview, Memory, Security, LLM, System, Scheduler (custom ExClaw)

## Testing

- Start the app with `MIX_ENV=dev iex -S mix phx.server`
- Navigate to `http://localhost:4000/dashboard` (or whatever port)
- Verify all standard tabs are visible and functional
- Verify all custom ExClaw tabs still work
- On the Processes tab, find named ExClaw processes (e.g., `ExClaw.LLM.ModelRouter`)
- On the Applications tab, verify the ExClaw supervision tree is visible

## No New Tests Needed

This is a configuration change, not new functionality. The standard LiveDashboard pages are tested by the `phoenix_live_dashboard` library itself. Visual verification is sufficient.
