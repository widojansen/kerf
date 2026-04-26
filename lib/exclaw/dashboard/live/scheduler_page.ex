defmodule Kerf.Dashboard.Live.SchedulerPage do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  @impl true
  def menu_link(_, _), do: {:ok, "Kerf Scheduler"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, tasks: load_scheduler_tasks())}
  end

  @impl true
  def handle_refresh(socket) do
    {:noreply, assign(socket, tasks: load_scheduler_tasks())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.card>
      <h5>Scheduled Tasks</h5>
      <%= if @tasks == [] do %>
        <p>No scheduled tasks</p>
      <% else %>
        <table>
          <thead>
            <tr><th>ID</th><th>Group</th><th>Type</th><th>Status</th><th>Next Run</th><th>Prompt</th></tr>
          </thead>
          <tbody>
            <%= for task <- @tasks do %>
              <tr>
                <td><%= task.id %></td>
                <td><%= task.group_id %></td>
                <td><%= task.schedule_type %></td>
                <td><%= task.status %></td>
                <td><%= format_datetime(task.next_run) %></td>
                <td><%= String.slice(task.prompt, 0, 60) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </.card>
    """
  end

  defp load_scheduler_tasks do
    try do
      case Kerf.Scheduler.Scheduler.list_tasks() do
        {:ok, tasks} -> tasks
        _ -> []
      end
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(other), do: inspect(other)
end
