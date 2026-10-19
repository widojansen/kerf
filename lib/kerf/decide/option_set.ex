defmodule Kerf.Decide.OptionSet do
  @moduledoc """
  SPEC_H F06 — enumerated option sets and executor re-validation.

  A frozen, validated list of option labels (binaries, ≥ 2, unique, caller
  order). `act/3` is the only path from a result to an executor action
  (addendum A1.2): label membership first, then confidence against
  `threshold:`, then the action class from the fixed `action_class/1` table.
  An :effect action needs an Approved for exactly that action (A1.3: taint
  does not change this table). act/3 never asks Kerf.Decide.Gate for one.
  """

  alias Kerf.Decide.Gate.Approved

  @enforce_keys [:labels]
  defstruct [:labels]

  @type t :: %__MODULE__{labels: [String.t(), ...]}
  @type action :: {atom(), term()}

  # SPEC_C 6-value category enum, in SPEC_C order. Guarded by
  # test/agents/email_triage/vocabulary_parity_test.exs (F06.3).
  @triage_categories ~w(business personal newsletter transactional spam social)

  @gate_only [:route, :label, :escalate, :log]
  @effect [:gmail_send, :gmail_trash, :http_external, :vault_read]

  @spec new([String.t()]) :: {:ok, t()} | {:error, term()}
  def new(labels) when is_list(labels) do
    cond do
      length(labels) < 2 -> {:error, :too_few_labels}
      not Enum.all?(labels, &is_binary/1) -> {:error, :non_binary_label}
      length(Enum.uniq(labels)) != length(labels) -> {:error, :duplicate_label}
      true -> {:ok, %__MODULE__{labels: labels}}
    end
  end

  def new(_labels), do: {:error, :not_a_list}

  @spec new!([String.t()]) :: t()
  def new!(labels) do
    case new(labels) do
      {:ok, set} -> set
      {:error, reason} -> raise ArgumentError, "invalid OptionSet: #{inspect(reason)}"
    end
  end

  @spec labels(t()) :: [String.t()]
  def labels(%__MODULE__{labels: labels}), do: labels

  @spec triage_categories() :: t()
  def triage_categories, do: new!(@triage_categories)

  @spec action_class(atom()) :: :gate_only | :effect | :unknown
  def action_class(action) when action in @gate_only, do: :gate_only
  def action_class(action) when action in @effect, do: :effect
  def action_class(_action), do: :unknown

  @spec act(Kerf.Decide.Result.choice(), t(), keyword()) ::
          {:ok, action()} | {:escalate, Kerf.Decide.Result.choice()} | {:error, term()}
  def act(%{label: label, confidence: confidence} = result, %__MODULE__{labels: labels}, opts) do
    threshold = Keyword.fetch!(opts, :threshold)
    actions = Keyword.fetch!(opts, :actions)

    cond do
      label not in labels -> {:error, :label_not_in_set}
      not (is_number(confidence) and confidence >= threshold) -> {:escalate, result}
      true -> resolve(Map.fetch(actions, label), opts[:approved])
    end
  end

  defp resolve(:error, _approved), do: {:error, :no_action_for_label}

  defp resolve({:ok, {name, _arg} = action}, approved) do
    case action_class(name) do
      :gate_only -> {:ok, action}
      :effect -> require_approval(action, approved)
      :unknown -> {:error, {:unknown_action, name}}
    end
  end

  defp resolve({:ok, _malformed}, _approved), do: {:error, :invalid_action}

  # Check, never build: an Approved is only ever handed in by the caller.
  defp require_approval(action, approved) do
    if is_struct(approved, Approved) and approved.action == action,
      do: {:ok, action},
      else: {:error, :approval_required}
  end
end
