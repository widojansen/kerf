defmodule Kerf.Decide.Question do
  @moduledoc """
  SPEC_H F01 / F06.1 — RED skeleton.

  Constructors for the three question types. They check argument types only
  (a Choice takes an OptionSet, never a raw list) and raise
  FunctionClauseError otherwise; counts and emptiness are validated by
  Kerf.Decide before any adapter call.

  Options: `criteria:` (descriptions) and `branch:` (marks a speculative
  follow-up, F02.4).
  """

  alias Kerf.Decide.OptionSet
  alias Kerf.Decide.Question.{Choice, Noul, Score}

  @type t :: Noul.t() | Choice.t() | Score.t()

  @spec noul(atom(), String.t() | map(), keyword()) :: Noul.t()
  def noul(_name, _instructions, _opts \\ []),
    do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.Question.noul/3")

  @spec choice(atom(), String.t() | map(), OptionSet.t(), keyword()) :: Choice.t()
  def choice(_name, _instructions, _options, _opts \\ []),
    do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.Question.choice/4")

  @spec score(atom(), String.t() | map(), [String.t()], keyword()) :: Score.t()
  def score(_name, _instructions, _levels, _opts \\ []),
    do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.Question.score/4")
end
