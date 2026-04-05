defmodule ExClaw.Dashboard.Live.OverviewPage do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  @impl true
  def menu_link(_, _), do: {:ok, "ExClaw Overview"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, sessions: load_sessions(), rate_limiter_stats: load_rate_limiter_stats())}
  end

  @impl true
  def handle_refresh(socket) do
    {:noreply, assign(socket, sessions: load_sessions(), rate_limiter_stats: load_rate_limiter_stats())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.card>
      <h5>Active Sessions</h5>
      <%= if @sessions == [] do %>
        <p>No active sessions</p>
      <% else %>
        <.live_table
          id="exclaw-sessions"
          dom_id="exclaw-sessions"
          page={@page}
          title="Sessions"
          row_fetcher={&fetch_sessions/2}
          rows_name="sessions"
        >
          <:col field={:group_id} header="Group ID" />
          <:col field={:model} header="Model" />
          <:col field={:message_count} header="Messages" text_align="right" />
          <:col field={:started_at} header="Started" />
          <:col field={:pid} header="PID" />
        </.live_table>
      <% end %>
    </.card>

    <.card>
      <h5>Rate Limiter</h5>
      <%= if @rate_limiter_stats == %{} do %>
        <p>No rate limiter data</p>
      <% else %>
        <.fields_card
          fields={[
            tokens_per_min: Map.get(@rate_limiter_stats, :tokens_this_minute, 0),
            requests_per_min: Map.get(@rate_limiter_stats, :requests_this_minute, 0),
            total_tokens: Map.get(@rate_limiter_stats, :total_tokens, 0),
            total_requests: Map.get(@rate_limiter_stats, :total_requests, 0)
          ]}
        />
      <% end %>
    </.card>
    """
  end

  defp fetch_sessions(_params, _node) do
    sessions = load_sessions()
    rows = Enum.map(sessions, fn s ->
      %{
        group_id: s.group_id,
        model: s.model,
        message_count: s.message_count,
        started_at: format_dt(s[:started_at]),
        pid: inspect(s[:pid])
      }
    end)
    {rows, length(rows)}
  end

  defp load_sessions do
    try do
      Registry.select(ExClaw.SessionRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.map(fn {group_id, pid} ->
        info =
          try do
            ExClaw.Agent.Session.get_info(pid)
          catch
            :exit, _ -> %{group_id: group_id, message_count: 0, model: "?", started_at: nil, last_activity: nil}
          end
        Map.put(info, :pid, pid)
      end)
    rescue
      _ -> []
    end
  end

  defp load_rate_limiter_stats do
    try do
      ExClaw.LLM.RateLimiter.get_stats()
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end

  defp format_dt(nil), do: "-"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_dt(other), do: inspect(other)
end
