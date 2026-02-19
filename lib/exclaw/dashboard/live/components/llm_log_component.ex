defmodule ExClaw.Dashboard.Live.Components.LlmLogComponent do
  use Phoenix.Component

  def render(assigns) do
    ~H"""
    <div class="card">
      <h3>LLM Calls</h3>
      <%= if @calls == [] do %>
        <div class="empty">No LLM calls recorded</div>
      <% else %>
        <table>
          <thead>
            <tr><th>Time</th><th>Model</th><th>Duration</th><th>Tokens In</th><th>Tokens Out</th><th>Type</th></tr>
          </thead>
          <tbody>
            <%= for entry <- @calls do %>
              <tr>
                <td><%= format_dt(entry.timestamp) %></td>
                <td><%= entry.event[:model] %></td>
                <td><%= entry.event[:duration_ms] %>ms</td>
                <td><%= entry.event[:input_tokens] %></td>
                <td><%= entry.event[:output_tokens] %></td>
                <td><span class="badge badge-green"><%= entry.event[:response_type] %></span></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>

    <div class="card">
      <h3>LLM Errors</h3>
      <%= if @errors == [] do %>
        <div class="empty">No LLM errors recorded</div>
      <% else %>
        <table>
          <thead>
            <tr><th>Time</th><th>Model</th><th>Duration</th><th>Error</th></tr>
          </thead>
          <tbody>
            <%= for entry <- @errors do %>
              <tr>
                <td><%= format_dt(entry.timestamp) %></td>
                <td><%= entry.event[:model] %></td>
                <td><%= entry.event[:duration_ms] %>ms</td>
                <td><span class="badge badge-red"><%= String.slice(to_string(entry.event[:error]), 0, 120) %></span></td>
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
