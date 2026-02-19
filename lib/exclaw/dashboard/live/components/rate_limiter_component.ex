defmodule ExClaw.Dashboard.Live.Components.RateLimiterComponent do
  use Phoenix.Component

  def render(assigns) do
    ~H"""
    <div class="card">
      <h3>Rate Limiter</h3>
      <%= if @stats == %{} do %>
        <div class="empty">No rate limiter data</div>
      <% else %>
        <div>
          <div class="stat">
            <div class="stat-value"><%= Map.get(@stats, :tokens_this_minute, 0) %></div>
            <div class="stat-label">Tokens / min</div>
          </div>
          <div class="stat">
            <div class="stat-value"><%= Map.get(@stats, :requests_this_minute, 0) %></div>
            <div class="stat-label">Requests / min</div>
          </div>
          <div class="stat">
            <div class="stat-value"><%= Map.get(@stats, :total_tokens, 0) %></div>
            <div class="stat-label">Total tokens</div>
          </div>
          <div class="stat">
            <div class="stat-value"><%= Map.get(@stats, :total_requests, 0) %></div>
            <div class="stat-label">Total requests</div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
