defmodule Kerf.Decide.OptionSet do
  @moduledoc """
  SPEC_H F06 — RED skeleton.

  A frozen, validated list of option labels (binaries, ≥ 2, unique, caller
  order). `act/3` is the only path from a result to an executor action: it
  re-checks label membership, then confidence against `threshold:`, then the
  action class from a fixed table (:gate_only | :effect). An :effect action
  needs an approval from Kerf.Decide.Gate (placeholder for Kerf.Gate, SPEC_G).
  """

  @enforce_keys [:labels]
  defstruct [:labels]

  @type t :: %__MODULE__{labels: [String.t(), ...]}
  @type action :: {atom(), term()}

  @spec new([String.t()]) :: {:ok, t()} | {:error, term()}
  def new(_labels), do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.OptionSet.new/1")

  @spec labels(t()) :: [String.t()]
  def labels(_set),
    do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.OptionSet.labels/1")

  @spec triage_categories() :: t()
  def triage_categories,
    do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.OptionSet.triage_categories/0")

  @spec action_class(atom()) :: :gate_only | :effect | :unknown
  def action_class(_action),
    do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.OptionSet.action_class/1")

  @spec act(Kerf.Decide.Result.choice(), t(), keyword()) ::
          {:ok, action()} | {:escalate, Kerf.Decide.Result.choice()} | {:error, term()}
  def act(_result, _set, _opts),
    do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.OptionSet.act/3")
end
