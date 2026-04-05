defmodule ExClaw.Dashboard.Live.LLMPage do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  alias ExClaw.Dashboard.EventLog

  @impl true
  def menu_link(_, _), do: {:ok, "ExClaw LLM"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket,
      calls: EventLog.recent(:llm_call, 50),
      errors: EventLog.recent(:llm_error, 50)
    )}
  end

  @impl true
  def handle_refresh(socket) do
    {:noreply, assign(socket,
      calls: EventLog.recent(:llm_call, 50),
      errors: EventLog.recent(:llm_error, 50)
    )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.card>
      <h5>LLM Calls</h5>
      <%= if @calls == [] do %>
        <p>No LLM calls recorded</p>
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
                <td><%= entry.event[:response_type] %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </.card>

    <.card>
      <h5>LLM Errors</h5>
      <%= if @errors == [] do %>
        <p>No LLM errors recorded</p>
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
                <td><%= String.slice(to_string(entry.event[:error]), 0, 120) %></td>
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
