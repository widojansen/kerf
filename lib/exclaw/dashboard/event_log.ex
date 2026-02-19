defmodule ExClaw.Dashboard.EventLog do
  use GenServer

  defmodule Entry do
    defstruct [:seq_id, :timestamp, :category, :event]
  end

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def log(name \\ __MODULE__, category, event_map) do
    GenServer.cast(name, {:log, category, event_map})
  end

  def log_sync(name \\ __MODULE__, category, event_map) do
    GenServer.call(name, {:log, category, event_map})
  end

  def recent(category, limit \\ 50) do
    recent_from(__MODULE__, category, limit)
  end

  def recent_from(table, category, limit \\ 50) do
    try do
      :ets.match_object(table, {:_, :_, category, :_})
      |> Enum.map(&entry_from_tuple/1)
      |> Enum.sort_by(& &1.seq_id, :desc)
      |> Enum.take(limit)
    rescue
      ArgumentError -> []
    end
  end

  def all_recent(limit \\ 50) do
    all_recent_from(__MODULE__, limit)
  end

  def all_recent_from(table, limit \\ 50) do
    try do
      :ets.tab2list(table)
      |> Enum.map(&entry_from_tuple/1)
      |> Enum.sort_by(& &1.seq_id, :desc)
      |> Enum.take(limit)
    rescue
      ArgumentError -> []
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    table =
      Keyword.get(opts, :table, __MODULE__)

    max_size =
      Keyword.get(opts, :max_size) ||
        Application.get_env(:exclaw, __MODULE__)[:max_size] ||
        500

    pubsub = Keyword.get(opts, :pubsub)

    ets_table = :ets.new(table, [:ordered_set, :public, :named_table])

    {:ok,
     %{
       table: ets_table,
       max_size: max_size,
       seq: 0,
       pubsub: pubsub
     }}
  end

  @impl true
  def handle_call({:log, category, event_map}, _from, state) do
    state = do_log(category, event_map, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:log, category, event_map}, state) do
    state = do_log(category, event_map, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp do_log(category, event_map, state) do
    seq = state.seq + 1
    timestamp = DateTime.utc_now()
    event = to_atom_map(event_map)

    :ets.insert(state.table, {seq, timestamp, category, event})

    state = %{state | seq: seq}
    evict_if_needed(state)

    if state.pubsub do
      try do
        Phoenix.PubSub.broadcast(
          state.pubsub,
          "event_log",
          {:event_logged, %Entry{seq_id: seq, timestamp: timestamp, category: category, event: event}}
        )
      rescue
        _ -> :ok
      end
    end

    state
  end

  defp evict_if_needed(state) do
    size = :ets.info(state.table, :size)

    if size > state.max_size do
      # Delete oldest entries (lowest seq_id keys)
      to_delete = size - state.max_size

      state.table
      |> :ets.tab2list()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.take(to_delete)
      |> Enum.each(fn {key, _, _, _} -> :ets.delete(state.table, key) end)
    end
  end

  defp entry_from_tuple({seq_id, timestamp, category, event}) do
    %Entry{seq_id: seq_id, timestamp: timestamp, category: category, event: event}
  end

  defp to_atom_map(map) when is_map(map) do
    for {k, v} <- map, into: %{} do
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, v}
    end
  end
end
