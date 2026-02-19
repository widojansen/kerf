defmodule ExClaw.Dashboard.Live.Components.SystemComponent do
  use Phoenix.Component

  def render(assigns) do
    assigns = assign_new(assigns, :tree, fn -> build_supervision_tree() end)
    assigns = assign_new(assigns, :system_info, fn -> build_system_info() end)

    ~H"""
    <div class="card">
      <h3>System Info</h3>
      <div>
        <div class="stat">
          <div class="stat-value"><%= @system_info.process_count %></div>
          <div class="stat-label">Processes</div>
        </div>
        <div class="stat">
          <div class="stat-value"><%= @system_info.memory_mb %> MB</div>
          <div class="stat-label">Memory</div>
        </div>
        <div class="stat">
          <div class="stat-value"><%= @system_info.uptime %></div>
          <div class="stat-label">Uptime</div>
        </div>
        <div class="stat">
          <div class="stat-value"><%= @system_info.otp_release %></div>
          <div class="stat-label">OTP</div>
        </div>
      </div>
    </div>

    <div class="card">
      <h3>Supervision Tree</h3>
      <pre><%= @tree %></pre>
    </div>
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
