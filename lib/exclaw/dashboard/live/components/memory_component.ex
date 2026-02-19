defmodule ExClaw.Dashboard.Live.Components.MemoryComponent do
  use Phoenix.Component

  def render(assigns) do
    ~H"""
    <div class="card">
      <h3>Memory Browser</h3>
      <div style="margin-bottom: 1rem;">
        <strong>Select group:</strong>
        <%= for session <- @sessions do %>
          <a
            phx-click="load_memory"
            phx-value-group_id={session.group_id}
            style={"cursor: pointer; margin-right: 0.5rem; color: #{if @group_id == session.group_id, do: "#e94560", else: "#888"};"}
          >
            <%= session.group_id %>
          </a>
        <% end %>
        <%= if @sessions == [] do %>
          <span style="color: #555;">No active sessions</span>
        <% end %>
      </div>

      <%= if @group_id do %>
        <div class="card">
          <h3>Facts (<%= @group_id %>)</h3>
          <%= if @facts == [] do %>
            <div class="empty">No facts stored</div>
          <% else %>
            <table>
              <thead><tr><th>Key</th><th>Value</th><th>Source</th></tr></thead>
              <tbody>
                <%= for fact <- @facts do %>
                  <tr>
                    <td><code><%= fact.key %></code></td>
                    <td><%= String.slice(fact.value, 0, 100) %></td>
                    <td><%= fact.source || "-" %></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </div>

        <div class="card">
          <h3>MEMORY.md (<%= @group_id %>)</h3>
          <%= if @group_memory == "" do %>
            <div class="empty">No group memory</div>
          <% else %>
            <pre><%= @group_memory %></pre>
          <% end %>
        </div>

        <div class="card">
          <h3>Recent Messages (<%= @group_id %>)</h3>
          <%= if @messages == [] do %>
            <div class="empty">No messages</div>
          <% else %>
            <table>
              <thead><tr><th>Role</th><th>Content</th><th>Time</th></tr></thead>
              <tbody>
                <%= for msg <- @messages do %>
                  <tr>
                    <td><span class={"badge #{role_badge(msg.role)}"}><%= msg.role %></span></td>
                    <td><%= String.slice(msg.content || "", 0, 120) %></td>
                    <td><%= format_dt(msg.inserted_at) %></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </div>
      <% else %>
        <div class="empty">Select a group to view memory</div>
      <% end %>
    </div>
    """
  end

  defp role_badge("user"), do: "badge-blue"
  defp role_badge("assistant"), do: "badge-green"
  defp role_badge("tool"), do: "badge-yellow"
  defp role_badge(_), do: ""

  defp format_dt(nil), do: "-"
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_dt(other), do: inspect(other)
end
