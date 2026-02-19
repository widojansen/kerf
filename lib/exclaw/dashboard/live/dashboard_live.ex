defmodule ExClaw.Dashboard.Live.DashboardLive do
  use Phoenix.LiveView, layout: {ExClaw.Dashboard.Layouts, :app}

  alias ExClaw.Dashboard.EventLog
  alias ExClaw.Dashboard.Live.Components.{
    SessionsComponent,
    RateLimiterComponent,
    MemoryComponent,
    SecurityLogComponent,
    LlmLogComponent,
    SystemComponent
  }

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, :tick)
      Phoenix.PubSub.subscribe(ExClaw.PubSub, "event_log")
    end

    socket =
      socket
      |> assign(:tab, "overview")
      |> assign(:sessions, [])
      |> assign(:rate_limiter_stats, %{})
      |> assign(:security_events, [])
      |> assign(:llm_calls, [])
      |> assign(:llm_errors, [])
      |> assign(:memory_group_id, nil)
      |> assign(:facts, [])
      |> assign(:group_memory, "")
      |> assign(:messages, [])
      |> load_tab_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = Map.get(params, "tab", "overview")
    socket = socket |> assign(:tab, tab) |> load_tab_data()
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket = socket |> assign(:tab, tab) |> load_tab_data()
    {:noreply, push_patch(socket, to: "/?tab=#{tab}")}
  end

  @impl true
  def handle_event("load_memory", %{"group_id" => group_id}, socket) do
    socket = socket |> assign(:memory_group_id, group_id) |> load_memory_data(group_id)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, load_tab_data(socket)}
  end

  @impl true
  def handle_info({:event_logged, _entry}, socket) do
    if socket.assigns.tab in ["security", "llm"] do
      {:noreply, load_tab_data(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="tabs">
      <a class={"tab #{if @tab == "overview", do: "active"}"} phx-click="switch_tab" phx-value-tab="overview">Overview</a>
      <a class={"tab #{if @tab == "memory", do: "active"}"} phx-click="switch_tab" phx-value-tab="memory">Memory</a>
      <a class={"tab #{if @tab == "security", do: "active"}"} phx-click="switch_tab" phx-value-tab="security">Security</a>
      <a class={"tab #{if @tab == "llm", do: "active"}"} phx-click="switch_tab" phx-value-tab="llm">LLM</a>
      <a class={"tab #{if @tab == "system", do: "active"}"} phx-click="switch_tab" phx-value-tab="system">System</a>
      <a class={"tab #{if @tab == "scheduler", do: "active"}"} phx-click="switch_tab" phx-value-tab="scheduler">Scheduler</a>
    </div>

    <div style="padding: 1rem 0;">
      <%= case @tab do %>
        <% "overview" -> %>
          <SessionsComponent.render sessions={@sessions} />
          <RateLimiterComponent.render stats={@rate_limiter_stats} />
        <% "memory" -> %>
          <MemoryComponent.render
            group_id={@memory_group_id}
            facts={@facts}
            group_memory={@group_memory}
            messages={@messages}
            sessions={@sessions}
          />
        <% "security" -> %>
          <SecurityLogComponent.render events={@security_events} />
        <% "llm" -> %>
          <LlmLogComponent.render calls={@llm_calls} errors={@llm_errors} />
        <% "system" -> %>
          <SystemComponent.render />
        <% "scheduler" -> %>
          <.scheduler_tab />
        <% _ -> %>
          <div class="empty">Unknown tab</div>
      <% end %>
    </div>
    """
  end

  defp scheduler_tab(assigns) do
    assigns = assign_new(assigns, :tasks, fn -> load_scheduler_tasks() end)

    ~H"""
    <div class="card">
      <h3>Scheduled Tasks</h3>
      <%= if @tasks == [] do %>
        <div class="empty">No scheduled tasks</div>
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
                <td><span class="badge badge-blue"><%= task.schedule_type %></span></td>
                <td>
                  <span class={"badge #{status_badge(task.status)}"}><%= task.status %></span>
                </td>
                <td><%= format_datetime(task.next_run) %></td>
                <td><%= String.slice(task.prompt, 0, 60) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp status_badge("active"), do: "badge-green"
  defp status_badge("paused"), do: "badge-yellow"
  defp status_badge("completed"), do: "badge-blue"
  defp status_badge(_), do: ""

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(other), do: inspect(other)

  # --- Data loading ---

  defp load_tab_data(socket) do
    case socket.assigns.tab do
      "overview" ->
        socket
        |> assign(:sessions, load_sessions())
        |> assign(:rate_limiter_stats, load_rate_limiter_stats())

      "memory" ->
        socket
        |> assign(:sessions, load_sessions())
        |> maybe_load_memory(socket.assigns[:memory_group_id])

      "security" ->
        assign(socket, :security_events, EventLog.recent(:security_denial, 50))

      "llm" ->
        socket
        |> assign(:llm_calls, EventLog.recent(:llm_call, 50))
        |> assign(:llm_errors, EventLog.recent(:llm_error, 50))

      _ ->
        socket
    end
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

  defp maybe_load_memory(socket, nil), do: socket
  defp maybe_load_memory(socket, group_id), do: load_memory_data(socket, group_id)

  defp load_memory_data(socket, group_id) do
    facts =
      try do
        case ExClaw.Memory.Store.get_facts(group_id) do
          {:ok, f} -> f
          _ -> []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    group_memory =
      try do
        case ExClaw.Memory.Store.load_group(group_id) do
          {:ok, m} -> m
          _ -> ""
        end
      rescue
        _ -> ""
      catch
        :exit, _ -> ""
      end

    messages =
      try do
        case ExClaw.Memory.Store.get_messages(group_id, limit: 20) do
          {:ok, m} -> m
          _ -> []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    socket
    |> assign(:facts, facts)
    |> assign(:group_memory, group_memory)
    |> assign(:messages, messages)
  end

  defp load_scheduler_tasks do
    try do
      case ExClaw.Scheduler.Scheduler.list_tasks() do
        {:ok, tasks} -> tasks
        _ -> []
      end
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end
end
