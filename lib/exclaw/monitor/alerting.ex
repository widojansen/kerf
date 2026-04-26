defmodule Kerf.Monitor.Alerting do
  @moduledoc """
  Debounced alert delivery via Telegram.

  Receives anomaly notifications from ProcessHealth, debounces per
  alert key, and delivers via Telegram. Falls back to Logger.error
  when Telegram is unavailable or unconfigured.
  """
  use GenServer

  require Logger

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Deliver an anomaly alert (debounced)."
  def notify(name, event_type, measurements, metadata) do
    GenServer.cast(name, {:notify, event_type, measurements, metadata})
  end

  @doc "Signal that an incident has resolved."
  def resolve(name, event_type, metadata) do
    GenServer.cast(name, {:resolve, event_type, metadata})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    state = %{
      debounce_window_ms: Keyword.get(opts, :debounce_window_ms, 300_000),
      telegram_chat_id: Keyword.get(opts, :telegram_chat_id),
      telegram_sender: Keyword.get(opts, :telegram_sender, &default_telegram_sender/2),
      last_fired: %{},
      active_incidents: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:notify, event_type, measurements, metadata}, state) do
    alert_key = {event_type, metadata[:name]}
    now = System.monotonic_time(:millisecond)

    if debounced?(state, alert_key, now) do
      {:noreply, state}
    else
      message = format_alert(event_type, measurements, metadata)
      send_alert(message, state)

      state =
        state
        |> put_in([:last_fired, alert_key], now)
        |> put_in([:active_incidents, alert_key], DateTime.utc_now())

      {:noreply, state}
    end
  end

  def handle_cast({:resolve, event_type, metadata}, state) do
    alert_key = {event_type, metadata[:name]}

    case state.active_incidents[alert_key] do
      nil ->
        {:noreply, state}

      started_at ->
        duration = DateTime.diff(DateTime.utc_now(), started_at, :second)
        message = format_recovery(event_type, metadata, duration)
        send_alert(message, state)

        state =
          state
          |> update_in([:active_incidents], &Map.delete(&1, alert_key))

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp debounced?(state, alert_key, now) do
    case state.last_fired[alert_key] do
      nil -> false
      last -> now - last < state.debounce_window_ms
    end
  end

  defp send_alert(_message, %{telegram_chat_id: nil}), do: :ok

  defp send_alert(message, state) do
    case state.telegram_sender.(state.telegram_chat_id, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[Alerting] Alert delivery failed: #{inspect(reason)}\nMessage: #{message}")
    end
  end

  defp format_alert(:process_down, _measurements, metadata) do
    name = short_name(metadata[:name])
    time = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S UTC")

    """
    \u{1F534} Kerf Alert: #{name} DOWN
    Process #{inspect(metadata[:name])} is not running.
    Detected at #{time}\
    """
  end

  defp format_alert(:queue_high, measurements, metadata) do
    name = short_name(metadata[:name])
    time = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S UTC")

    """
    \u26A0\uFE0F Kerf Alert: #{name} queue high
    Message queue: #{measurements[:queue_len]} (threshold: #{metadata[:threshold]})
    Detected at #{time}\
    """
  end

  defp format_alert(:memory_high, measurements, metadata) do
    name = short_name(metadata[:name])
    mb = Float.round(measurements[:memory_mb] || 0.0, 1)
    time = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S UTC")

    """
    \u26A0\uFE0F Kerf Alert: #{name} memory high
    Memory: #{mb} MB (threshold: #{metadata[:threshold]} MB)
    Detected at #{time}\
    """
  end

  defp format_alert(event_type, measurements, metadata) do
    time = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S UTC")

    """
    \u26A0\uFE0F Kerf Alert: #{event_type}
    Measurements: #{inspect(measurements)}
    Metadata: #{inspect(metadata)}
    Detected at #{time}\
    """
  end

  defp format_recovery(event_type, metadata, duration_seconds) do
    name = short_name(metadata[:name])
    duration_str = format_duration(duration_seconds)

    "\u2705 Kerf: #{name} recovered (#{event_type} resolved, was down for #{duration_str})"
  end

  defp short_name(nil), do: "unknown"

  defp short_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.replace_leading("Elixir.", "")
    |> String.split(".")
    |> List.last()
  end

  defp short_name(name), do: to_string(name)

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}m #{secs}s"
  end

  defp default_telegram_sender(chat_id, text) do
    token = Application.get_env(:exclaw, Kerf.Channels.Telegram, [])[:token]

    if token do
      url = "https://api.telegram.org/bot#{token}/sendMessage"
      body = %{"chat_id" => chat_id, "text" => text}

      case Req.post(url: url, json: body) do
        {:ok, %Req.Response{status: 200}} -> :ok
        {:ok, %Req.Response{status: status}} -> {:error, "HTTP #{status}"}
        {:error, e} -> {:error, Exception.message(e)}
      end
    else
      Logger.error("[Alerting] No Telegram token configured. Alert: #{text}")
      {:error, :no_token}
    end
  rescue
    e ->
      Logger.error("[Alerting] Telegram send error: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end
end
