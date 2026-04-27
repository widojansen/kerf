defmodule Kerf.Agents.EmailTriage.FastClassifier.Cache do
  @moduledoc """
  ETS cache for FastClassifier sender rules.
  Refreshed on startup and periodically.
  """
  use GenServer

  alias Kerf.KnowledgeBase.EmailSender
  import Ecto.Query

  @refresh_interval :timer.minutes(5)

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get_by_email(name, email) do
    table = table_name(name)
    case :ets.lookup(table, {:email, email}) do
      [{_, rule}] -> {:ok, rule}
      [] -> :no_match
    end
  end

  def get_by_domain(name, domain) do
    table = table_name(name)
    case :ets.lookup(table, {:domain, domain}) do
      [{_, rule}] -> {:ok, rule}
      [] -> :no_match
    end
  end

  def get_pattern_rules(name) do
    table = table_name(name)
    :ets.tab2list(table)
    |> Enum.filter(fn
      {{:pattern, _}, _rule} -> true
      _ -> false
    end)
    |> Enum.map(fn {_key, rule} -> rule end)
    |> Enum.sort_by(& &1.priority_override, :desc)
  end

  def refresh(name) do
    GenServer.cast(name, :refresh)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    repo = Keyword.get(opts, :repo, Kerf.Repo)
    name = Keyword.fetch!(opts, :name)
    caller = Keyword.get(opts, :caller)
    table = :ets.new(table_name(name), [:named_table, :set, :public, read_concurrency: true])

    if caller do
      Ecto.Adapters.SQL.Sandbox.allow(repo, caller, self())
    end

    load_rules(table, repo)
    schedule_refresh()
    {:ok, %{table: table, repo: repo}}
  end

  @impl true
  def handle_cast(:refresh, state) do
    load_rules(state.table, state.repo)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    load_rules(state.table, state.repo)
    schedule_refresh()
    {:noreply, state}
  end

  # --- Private ---

  defp load_rules(table, repo) do
    rules =
      from(s in EmailSender,
        where: not is_nil(s.classification_override)
      )
      |> repo.all()

    :ets.delete_all_objects(table)

    Enum.each(rules, fn sender ->
      if sender.email, do: :ets.insert(table, {{:email, sender.email}, sender})
      if sender.domain, do: :ets.insert(table, {{:domain, sender.domain}, sender})

      if sender.match_pattern do
        :ets.insert(table, {{:pattern, sender.id}, sender})
      end
    end)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp table_name(name) do
    :"#{name}_table"
  end
end
