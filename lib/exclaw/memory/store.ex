defmodule ExClaw.Memory.Store do
  use GenServer

  alias ExClaw.Memory.Fact
  alias ExClaw.Memory.Message
  import Ecto.Query

  # ── Client API ──

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def save_fact(name \\ __MODULE__, group_id, key, value, source \\ nil),
    do: GenServer.call(name, {:save_fact, group_id, key, value, source})

  def get_facts(name \\ __MODULE__, group_id),
    do: GenServer.call(name, {:get_facts, group_id})

  def search(name \\ __MODULE__, group_id, query),
    do: GenServer.call(name, {:search, group_id, query})

  def delete_fact(name \\ __MODULE__, group_id, key),
    do: GenServer.call(name, {:delete_fact, group_id, key})

  def load_group(name \\ __MODULE__, group_id),
    do: GenServer.call(name, {:load_group, group_id})

  def update_group(name \\ __MODULE__, group_id, content),
    do: GenServer.call(name, {:update_group, group_id, content})

  def save_message(name \\ __MODULE__, group_id, role, content, opts \\ []),
    do: GenServer.call(name, {:save_message, group_id, role, content, opts})

  def get_messages(name \\ __MODULE__, group_id, opts \\ []),
    do: GenServer.call(name, {:get_messages, group_id, opts})

  # ── GenServer Callbacks ──

  @impl true
  def init(opts) do
    data_dir =
      Keyword.get(opts, :data_dir) ||
        Application.get_env(:exclaw, __MODULE__)[:data_dir] ||
        "priv/data"

    data_dir = Path.expand(data_dir)
    repo = Keyword.get(opts, :repo, ExClaw.Repo)

    {:ok, %{data_dir: data_dir, repo: repo}}
  end

  # ── Facts ──

  @impl true
  def handle_call({:save_fact, group_id, key, value, source}, _from, state) do
    result = timed_op("save_fact", group_id, fn ->
      attrs = %{group_id: group_id, key: key, value: value, source: source}

      %Fact{}
      |> Fact.changeset(attrs)
      |> state.repo.insert(
        on_conflict: {:replace, [:value, :source, :updated_at]},
        conflict_target: [:group_id, :key],
        returning: true
      )
    end)

    {:reply, result, state}
  end

  def handle_call({:get_facts, group_id}, _from, state) do
    result = timed_op("get_facts", group_id, fn ->
      facts =
        from(f in Fact, where: f.group_id == ^group_id, order_by: f.key)
        |> state.repo.all()

      {:ok, facts}
    end)

    {:reply, result, state}
  end

  def handle_call({:search, group_id, query}, _from, state) do
    result = timed_op("search", group_id, fn ->
      escaped = escape_like(query)
      pattern = "%#{escaped}%"

      facts =
        from(f in Fact,
          where:
            f.group_id == ^group_id and
              (fragment("? ILIKE ? ESCAPE '\\'", f.key, ^pattern) or
                 fragment("? ILIKE ? ESCAPE '\\'", f.value, ^pattern)),
          order_by: f.key
        )
        |> state.repo.all()

      {:ok, facts}
    end)

    {:reply, result, state}
  end

  def handle_call({:delete_fact, group_id, key}, _from, state) do
    result = timed_op("delete_fact", group_id, fn ->
      from(f in Fact, where: f.group_id == ^group_id and f.key == ^key)
      |> state.repo.delete_all()

      :ok
    end)

    {:reply, result, state}
  end

  # ── MEMORY.md ──

  def handle_call({:load_group, group_id}, _from, state) do
    result = timed_op("load_group", group_id, fn ->
      path = group_memory_path(state.data_dir, group_id)

      case File.read(path) do
        {:ok, data} -> {:ok, data}
        {:error, :enoent} -> {:ok, ""}
        {:error, reason} -> {:error, "could not read MEMORY.md: #{inspect(reason)}"}
      end
    end)

    {:reply, result, state}
  end

  def handle_call({:update_group, group_id, content}, _from, state) do
    result = timed_op("update_group", group_id, fn ->
      path = group_memory_path(state.data_dir, group_id)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, content) do
        :ok
      else
        {:error, reason} -> {:error, "could not write MEMORY.md: #{inspect(reason)}"}
      end
    end)

    {:reply, result, state}
  end

  # ── Messages ──

  def handle_call({:save_message, group_id, role, content, opts}, _from, state) do
    result = timed_op("save_message", group_id, fn ->
      tool_input =
        case Keyword.get(opts, :tool_input) do
          nil -> nil
          map when is_map(map) -> Jason.encode!(map)
          other -> other
        end

      attrs = %{
        group_id: group_id,
        role: role,
        content: content,
        tool_name: Keyword.get(opts, :tool_name),
        tool_input: tool_input
      }

      %Message{}
      |> Message.changeset(attrs)
      |> state.repo.insert()
    end)

    {:reply, result, state}
  end

  def handle_call({:get_messages, group_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)

    result = timed_op("get_messages", group_id, fn ->
      # Fetch the N most recent messages (desc), then reverse to chronological order
      messages =
        from(m in Message,
          where: m.group_id == ^group_id,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: ^limit
        )
        |> state.repo.all()
        |> Enum.reverse()

      {:ok, messages}
    end)

    {:reply, result, state}
  end

  # ── Private Helpers ──

  defp sanitize_group_id(group_id) do
    group_id
    |> String.replace(~r/[^a-zA-Z0-9_\-]/, "_")
  end

  defp group_memory_path(data_dir, group_id) do
    safe_id = sanitize_group_id(group_id)
    path = Path.join([data_dir, "groups", safe_id, "MEMORY.md"])
    # Verify resolved path stays inside data_dir (prevent traversal)
    expanded = Path.expand(path)

    if String.starts_with?(expanded, data_dir) do
      expanded
    else
      Path.join([data_dir, "groups", "_invalid_", "MEMORY.md"])
    end
  end

  # SQLite LIKE escaping. The ESCAPE clause uses a single backslash.
  # In Elixir strings "\\" is a single backslash, so this is correct.
  defp escape_like(query) do
    query
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp timed_op(op_type, group_id, fun) do
    started_at = System.monotonic_time(:millisecond)

    try do
      fun.()
    rescue
      e -> {:error, Exception.message(e)}
    after
      duration_ms = System.monotonic_time(:millisecond) - started_at

      try do
        ExClaw.Telemetry.emit(:memory_operation, %{
          op_type: op_type,
          group_id: group_id,
          duration_ms: duration_ms
        })
      rescue
        _ -> :ok
      end
    end
  end
end
