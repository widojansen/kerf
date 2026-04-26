defmodule Kerf.Dashboard.Live.MemoryPage do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  @impl true
  def menu_link(_, _), do: {:ok, "Kerf Memory"}

  @impl true
  def mount(_params, _session, socket) do
    sessions = load_sessions()
    {:ok, assign(socket,
      sessions: sessions,
      group_id: nil,
      facts: [],
      group_memory: "",
      messages: []
    )}
  end

  @impl true
  def handle_event("load_memory", %{"group_id" => group_id}, socket) do
    {facts, group_memory, messages} = load_memory_data(group_id)
    {:noreply, assign(socket, group_id: group_id, facts: facts, group_memory: group_memory, messages: messages)}
  end

  @impl true
  def handle_refresh(socket) do
    sessions = load_sessions()
    socket = assign(socket, sessions: sessions)

    socket =
      if socket.assigns.group_id do
        {facts, group_memory, messages} = load_memory_data(socket.assigns.group_id)
        assign(socket, facts: facts, group_memory: group_memory, messages: messages)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.card>
      <h5>Memory Browser</h5>
      <p>
        <strong>Select group: </strong>
        <%= for session <- @sessions do %>
          <a
            phx-click="load_memory"
            phx-value-group_id={session.group_id}
            style={"cursor:pointer; margin-right:0.5rem; font-weight:#{if @group_id == session.group_id, do: "bold", else: "normal"};"}
          >
            <%= session.group_id %>
          </a>
        <% end %>
        <%= if @sessions == [] do %>
          <span>No active sessions</span>
        <% end %>
      </p>
    </.card>

    <%= if @group_id do %>
      <.card>
        <h5>Facts (<%= @group_id %>)</h5>
        <%= if @facts == [] do %>
          <p>No facts stored</p>
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
      </.card>

      <.card>
        <h5>MEMORY.md (<%= @group_id %>)</h5>
        <%= if @group_memory == "" do %>
          <p>No group memory</p>
        <% else %>
          <pre><%= @group_memory %></pre>
        <% end %>
      </.card>

      <.card>
        <h5>Recent Messages (<%= @group_id %>)</h5>
        <%= if @messages == [] do %>
          <p>No messages</p>
        <% else %>
          <table>
            <thead><tr><th>Role</th><th>Content</th><th>Time</th></tr></thead>
            <tbody>
              <%= for msg <- @messages do %>
                <tr>
                  <td><%= msg.role %></td>
                  <td><%= String.slice(msg.content || "", 0, 120) %></td>
                  <td><%= format_dt(msg.inserted_at) %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </.card>
    <% else %>
      <.card>
        <p>Select a group above to view memory</p>
      </.card>
    <% end %>
    """
  end

  defp load_sessions do
    try do
      Registry.select(Kerf.SessionRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.map(fn {group_id, pid} ->
        info =
          try do
            Kerf.Agent.Session.get_info(pid)
          catch
            :exit, _ -> %{group_id: group_id, message_count: 0, model: "?", started_at: nil, last_activity: nil}
          end
        Map.put(info, :pid, pid)
      end)
    rescue
      _ -> []
    end
  end

  defp load_memory_data(group_id) do
    facts =
      try do
        case Kerf.Memory.Store.get_facts(group_id) do
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
        case Kerf.Memory.Store.load_group(group_id) do
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
        case Kerf.Memory.Store.get_messages(group_id, limit: 20) do
          {:ok, m} -> m
          _ -> []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    {facts, group_memory, messages}
  end

  defp format_dt(nil), do: "-"
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_dt(other), do: inspect(other)
end
