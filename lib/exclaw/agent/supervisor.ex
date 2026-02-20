defmodule ExClaw.Agent.Supervisor do
  @moduledoc """
  DynamicSupervisor for Agent.Session processes.
  """
  use DynamicSupervisor

  alias ExClaw.Agent.Session

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  def start_session(sup \\ __MODULE__, opts) do
    DynamicSupervisor.start_child(sup, {Session, opts})
  end

  def handle_message(sup \\ __MODULE__, registry \\ ExClaw.SessionRegistry, group_id, message, opts \\ []) do
    case find_or_start_session(sup, registry, group_id, opts) do
      {:ok, pid} ->
        try do
          Session.send_message(pid, message)
        catch
          :exit, {:noproc, _} ->
            # Session died between lookup and call; retry once
            case find_or_start_session(sup, registry, group_id, opts) do
              {:ok, new_pid} -> Session.send_message(new_pid, message)
              {:error, reason} -> {:error, reason}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # --- Private ---

  defp find_or_start_session(sup, registry, group_id, opts) do
    case Registry.lookup(registry, group_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        session_opts =
          Keyword.merge(opts,
            group_id: group_id,
            registry: registry
          )

        case start_registered_session(sup, registry, group_id, session_opts) do
          {:ok, pid} ->
            emit_telemetry(:session_lifecycle, %{group_id: group_id, event: "session_created"})
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, reason} ->
            emit_telemetry(:session_lifecycle, %{group_id: group_id, event: "session_start_failed", error_message: inspect(reason)})
            {:error, reason}
        end
    end
  end

  defp start_registered_session(sup, registry, group_id, opts) do
    via = {:via, Registry, {registry, group_id}}
    session_opts = Keyword.put(opts, :name, via)

    DynamicSupervisor.start_child(sup, {Session, session_opts})
  end

  defp emit_telemetry(category, data) do
    try do
      ExClaw.Telemetry.emit(category, data)
    rescue
      _ -> :ok
    end
  end
end
