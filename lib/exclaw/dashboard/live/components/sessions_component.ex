defmodule ExClaw.Dashboard.Live.Components.SessionsComponent do
  use Phoenix.Component

  def render(assigns) do
    ~H"""
    <div class="card">
      <h3>Active Sessions</h3>
      <%= if @sessions == [] do %>
        <div class="empty">No active sessions</div>
      <% else %>
        <table>
          <thead>
            <tr><th>Group ID</th><th>Model</th><th>Messages</th><th>Started</th><th>Last Activity</th><th>PID</th></tr>
          </thead>
          <tbody>
            <%= for session <- @sessions do %>
              <tr>
                <td><%= session.group_id %></td>
                <td><%= session.model %></td>
                <td><%= session.message_count %></td>
                <td><%= format_dt(session[:started_at]) %></td>
                <td><%= format_dt(session[:last_activity]) %></td>
                <td><code><%= inspect(session[:pid]) %></code></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp format_dt(nil), do: "-"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_dt(other), do: inspect(other)
end
