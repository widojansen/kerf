defmodule ExClaw.Dashboard.Live.Components.SecurityLogComponent do
  use Phoenix.Component

  def render(assigns) do
    ~H"""
    <div class="card">
      <h3>Security Denials</h3>
      <%= if @events == [] do %>
        <div class="empty">No security denials recorded</div>
      <% else %>
        <table>
          <thead>
            <tr><th>Time</th><th>Module</th><th>Reason</th><th>Input Preview</th></tr>
          </thead>
          <tbody>
            <%= for entry <- @events do %>
              <tr>
                <td><%= format_dt(entry.timestamp) %></td>
                <td><span class="badge badge-red"><%= entry.event[:module] || entry.event["module"] %></span></td>
                <td><%= entry.event[:reason] || entry.event["reason"] %></td>
                <td><code><%= String.slice(to_string(entry.event[:input_preview] || entry.event["input_preview"] || ""), 0, 80) %></code></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_dt(_), do: "-"
end
