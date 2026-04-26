defmodule Kerf.Monitor.TelemetryHandlers do
  @moduledoc """
  Attaches `:telemetry` handlers that persist events to the
  `telemetry_events` PostgreSQL table.

  Handlers are resilient — a failed DB write logs a warning and
  moves on; it never crashes the process that emitted the event.
  """
  require Logger

  alias Kerf.Monitor.TelemetryEvent
  alias Kerf.Repo

  @handler_prefix "exclaw-monitor"

  @events [
    # Process health (from ProcessHealth GenServer)
    {[:exclaw, :monitor, :process_down], "monitor.process_down"},
    {[:exclaw, :monitor, :queue_high], "monitor.queue_high"},
    {[:exclaw, :monitor, :memory_high], "monitor.memory_high"},
    {[:exclaw, :monitor, :health_check], "monitor.health_check"},
    # LLM provider spans
    {[:exclaw, :llm, :call, :stop], "llm.call.stop"},
    {[:exclaw, :llm, :call, :exception], "llm.call.exception"},
    # Ecto slow queries
    {[:exclaw, :repo, :query], "repo.query"}
  ]

  @doc "Attach all telemetry handlers. Idempotent — safe to call multiple times."
  def attach do
    for {event, event_name} <- @events do
      handler_id = "#{@handler_prefix}-#{event_name}"

      # Detach first to make idempotent
      :telemetry.detach(handler_id)

      :telemetry.attach(
        handler_id,
        event,
        &__MODULE__.handle_event/4,
        %{event_name: event_name}
      )
    end

    :ok
  end

  @doc "Returns the list of handler IDs for cleanup."
  def handler_ids do
    Enum.map(@events, fn {_event, event_name} ->
      "#{@handler_prefix}-#{event_name}"
    end)
  end

  @doc false
  def handle_event(_event, measurements, metadata, %{event_name: "repo.query"} = config) do
    # Only persist slow queries (>100ms)
    query_time_ms = System.convert_time_unit(measurements[:query_time] || 0, :native, :millisecond)

    if query_time_ms > 100 do
      persist(config.event_name, stringify(measurements), stringify(metadata))
    end
  end

  def handle_event(_event, measurements, metadata, config) do
    persist(config.event_name, stringify(measurements), stringify(metadata))
  end

  defp persist(event_name, measurements, metadata) do
    try do
      %TelemetryEvent{}
      |> TelemetryEvent.changeset(%{
        event_name: event_name,
        measurements: measurements,
        metadata: metadata
      })
      |> Repo.insert()
    rescue
      e ->
        Logger.warning("[TelemetryHandlers] Failed to persist #{event_name}: #{Exception.message(e)}")
    catch
      :exit, reason ->
        Logger.warning("[TelemetryHandlers] Failed to persist #{event_name}: #{inspect(reason)}")
    end
  end

  # Convert all keys and values to JSON-safe types.
  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_json_safe(v)} end)
  end

  defp to_json_safe(true), do: true
  defp to_json_safe(false), do: false
  defp to_json_safe(nil), do: nil
  defp to_json_safe(v) when is_atom(v), do: to_string(v)
  defp to_json_safe(v) when is_pid(v), do: inspect(v)
  defp to_json_safe(v) when is_reference(v), do: inspect(v)
  defp to_json_safe(v) when is_function(v), do: inspect(v)
  defp to_json_safe(v) when is_tuple(v), do: Tuple.to_list(v) |> Enum.map(&to_json_safe/1)
  defp to_json_safe(v) when is_map(v), do: stringify(v)
  defp to_json_safe(v) when is_list(v), do: Enum.map(v, &to_json_safe/1)
  defp to_json_safe(v), do: v

  # Thin GenServer wrapper — attaches handlers on init, then idles.
  defmodule Server do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(_opts) do
      Kerf.Monitor.TelemetryHandlers.attach()
      {:ok, %{}}
    end
  end
end
