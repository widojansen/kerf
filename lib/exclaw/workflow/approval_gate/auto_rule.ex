defmodule ExClaw.Workflow.ApprovalGate.AutoRule do
  @moduledoc """
  Ecto schema and matching logic for auto-approval rules.
  Rules match on {agent_module, action, context_pattern} and can
  auto-approve requests without requiring human interaction.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias ExClaw.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "approval_gate_auto_rules" do
    field :agent_module, :string
    field :action, :string
    field :context_pattern, :map, default: %{}
    field :decision, :string, default: "approve"
    field :enabled, :boolean, default: true
    field :times_matched, :integer, default: 0
    field :last_matched_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule \\ %__MODULE__{}, attrs) do
    rule
    |> cast(attrs, [:agent_module, :action, :context_pattern, :decision, :enabled])
    |> validate_required([:agent_module, :action])
  end

  @doc """
  Create a new auto-approval rule.
  """
  def create(attrs) do
    changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Delete a rule by ID.
  """
  def delete(rule_id) do
    case Repo.get(__MODULE__, rule_id) do
      nil -> {:error, :not_found}
      rule -> Repo.delete(rule) |> then(fn {:ok, _} -> :ok end)
    end
  end

  @doc """
  List rules, optionally filtered by agent and/or action.
  """
  def list(opts \\ []) do
    __MODULE__
    |> maybe_filter_agent(opts[:agent])
    |> maybe_filter_action(opts[:action])
    |> Repo.all()
  end

  @doc """
  Check if a request matches any enabled auto-approval rule.
  Returns {:ok, rule} or :no_match.

  The agent module is converted to its string representation for matching.
  Context pattern matching: the rule's context_pattern must be a subset of
  the request's context (all keys present with matching values).
  """
  def match(request) do
    agent_str = to_string(request.agent)

    candidates =
      __MODULE__
      |> where([r], r.agent_module == ^agent_str)
      |> where([r], r.action == ^request.action)
      |> where([r], r.enabled == true)
      |> Repo.all()

    case Enum.find(candidates, &context_matches?(&1, request.context)) do
      nil ->
        :no_match

      rule ->
        now = DateTime.utc_now()

        {1, [updated]} =
          from(r in __MODULE__,
            where: r.id == ^rule.id,
            select: r
          )
          |> Repo.update_all(
            inc: [times_matched: 1],
            set: [last_matched_at: now]
          )

        {:ok, updated}
    end
  end

  defp context_matches?(rule, request_context) do
    rule.context_pattern
    |> Enum.all?(fn {key, value} ->
      str_key = to_string(key)
      atom_key = safe_to_atom(str_key)

      match_value =
        Map.get(request_context, str_key) ||
          (atom_key && Map.get(request_context, atom_key))

      match_value != nil && to_string(match_value) == to_string(value)
    end)
  end

  defp safe_to_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  defp maybe_filter_agent(query, nil), do: query
  defp maybe_filter_agent(query, agent), do: where(query, [r], r.agent_module == ^agent)

  defp maybe_filter_action(query, nil), do: query
  defp maybe_filter_action(query, action), do: where(query, [r], r.action == ^action)
end
