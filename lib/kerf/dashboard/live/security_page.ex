defmodule Kerf.Dashboard.Live.SecurityPage do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  alias Kerf.Dashboard.EventLog

  @impl true
  def menu_link(_, _), do: {:ok, "Kerf Security"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, events: EventLog.recent(:security_denial, 50))}
  end

  @impl true
  def handle_refresh(socket) do
    {:noreply, assign(socket, events: EventLog.recent(:security_denial, 50))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.card>
      <h5>Security Denials</h5>
      <%= if @events == [] do %>
        <p>No security denials recorded</p>
      <% else %>
        <table>
          <thead>
            <tr><th>Time</th><th>Module</th><th>Reason</th><th>Input Preview</th></tr>
          </thead>
          <tbody>
            <%= for entry <- @events do %>
              <tr>
                <td><%= format_dt(entry.timestamp) %></td>
                <td><%= entry.event[:module] || entry.event["module"] %></td>
                <td><%= entry.event[:reason] || entry.event["reason"] %></td>
                <td><code><%= String.slice(to_string(entry.event[:input_preview] || entry.event["input_preview"] || ""), 0, 80) %></code></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </.card>
    """
  end

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_dt(_), do: "-"
end
