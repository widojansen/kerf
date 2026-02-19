defmodule ExClaw.Dashboard.DashboardLiveTest do
  use ExClaw.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "mounting and tabs" do
    test "mounts on / with overview tab", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")
      assert html =~ "Active Sessions"
      assert html =~ "Rate Limiter"
      assert has_element?(view, ".tab.active", "Overview")
    end

    test "switches to security tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element(".tab", "Security") |> render_click()
      assert has_element?(view, ".tab.active", "Security")
      assert render(view) =~ "Security Denials"
    end

    test "switches to llm tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element(".tab", "LLM") |> render_click()
      assert has_element?(view, ".tab.active", "LLM")
      assert render(view) =~ "LLM Calls"
      assert render(view) =~ "LLM Errors"
    end

    test "switches to memory tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element(".tab", "Memory") |> render_click()
      assert has_element?(view, ".tab.active", "Memory")
      assert render(view) =~ "Memory Browser"
    end

    test "switches to system tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element(".tab", "System") |> render_click()
      assert has_element?(view, ".tab.active", "System")
      assert render(view) =~ "System Info"
      assert render(view) =~ "Supervision Tree"
    end

    test "switches to scheduler tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element(".tab", "Scheduler") |> render_click()
      assert has_element?(view, ".tab.active", "Scheduler")
      assert render(view) =~ "Scheduled Tasks"
    end
  end

  describe "overview tab content" do
    test "shows empty sessions when none active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "No active sessions"
    end
  end

  describe "security tab with events" do
    test "displays security denial events", %{conn: conn} do
      # Log a security denial event
      ExClaw.Dashboard.EventLog.log_sync(:security_denial, %{
        module: "FileGuard",
        reason: "path traversal detected",
        input_preview: "/etc/passwd",
        timestamp: DateTime.utc_now()
      })

      {:ok, view, _html} = live(conn, "/?tab=security")
      html = render(view)

      assert html =~ "FileGuard"
      assert html =~ "path traversal detected"
    end
  end

  describe "llm tab with events" do
    test "displays LLM call events", %{conn: conn} do
      ExClaw.Dashboard.EventLog.log_sync(:llm_call, %{
        model: "claude-sonnet-4-20250514",
        duration_ms: 250,
        input_tokens: 100,
        output_tokens: 50,
        response_type: :text,
        timestamp: DateTime.utc_now()
      })

      {:ok, view, _html} = live(conn, "/?tab=llm")
      html = render(view)

      assert html =~ "claude-sonnet-4-20250514"
      assert html =~ "250ms"
    end

    test "displays LLM error events", %{conn: conn} do
      ExClaw.Dashboard.EventLog.log_sync(:llm_error, %{
        model: "claude-sonnet-4-20250514",
        duration_ms: 500,
        error: "API error 500: internal",
        timestamp: DateTime.utc_now()
      })

      {:ok, view, _html} = live(conn, "/?tab=llm")
      html = render(view)

      assert html =~ "API error 500"
    end
  end

  describe "system tab" do
    test "shows process count and memory", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/?tab=system")
      assert html =~ "Processes"
      assert html =~ "Memory"
      assert html =~ "Uptime"
      assert html =~ "OTP"
    end

    test "shows supervision tree", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/?tab=system")
      assert html =~ "Supervision Tree"
    end
  end
end
