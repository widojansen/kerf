defmodule ExClaw.Dashboard.Live.SystemPage do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  @impl true
  def menu_link(_, _), do: {:ok, "ExClaw System"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, system_info: build_system_info(), tree: build_supervision_tree())}
  end

  @impl true
  def handle_refresh(socket) do
    {:noreply, assign(socket, system_info: build_system_info(), tree: build_supervision_tree())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.card>
      <h5>ExClaw System Info</h5>
      <.fields_card
        fields={[
          processes: @system_info.process_count,
          memory: "#{@system_info.memory_mb} MB",
          uptime: @system_info.uptime,
          otp_release: @system_info.otp_release
        ]}
      />
    </.card>

    <.card>
      <h5>Supervision Tree</h5>
      <pre><%= @tree %></pre>
    </.card>
    """
  end

  defp build_system_info do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    memory_bytes = :erlang.memory(:total)

    hours = div(uptime_ms, 3_600_000)
    minutes = div(rem(uptime_ms, 3_600_000), 60_000)

    %{
      process_count: length(Process.list()),
      memory_mb: Float.round(memory_bytes / 1_048_576, 1),
      uptime: "#{hours}h #{minutes}m",
      otp_release: to_string(:erlang.system_info(:otp_release))
    }
  end

  defp build_supervision_tree do
    try do
      format_tree(ExClaw.Supervisor, 0)
    rescue
      _ -> "Could not read supervision tree"
    catch
      :exit, _ -> "Could not read supervision tree"
    end
  end

  defp format_tree(name, depth) do
    prefix = String.duplicate("  ", depth)

    case Supervisor.which_children(name) do
      children when is_list(children) ->
        children
        |> Enum.map(fn {id, pid, type, _modules} ->
          status = if is_pid(pid) and Process.alive?(pid), do: "running", else: "stopped"
          line = "#{prefix}|- #{inspect(id)} (#{type}) [#{status}]"

          sub =
            if type == :supervisor and is_pid(pid) and Process.alive?(pid) do
              try do
                "\n" <> format_tree(pid, depth + 1)
              catch
                :exit, _ -> ""
              end
            else
              ""
            end

          line <> sub
        end)
        |> Enum.join("\n")

      _ ->
        "#{prefix}(empty)"
    end
  end
end
