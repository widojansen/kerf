defmodule Kerf.Decide.Question do
  @moduledoc """
  SPEC_H F01 / F06.1 — constructors for the three question types.

  They check argument types only (a Choice takes an OptionSet, never a raw
  list) and raise FunctionClauseError otherwise; counts and emptiness are
  validated by `Kerf.Decide.validate/2` before any adapter call.

  Options: `criteria:` (descriptions) and `branch:` (marks a speculative
  follow-up, F02.4).
  """

  alias Kerf.Decide.OptionSet
  alias Kerf.Decide.Question.{Choice, Noul, Score}

  @type t :: Noul.t() | Choice.t() | Score.t()

  @spec noul(atom(), String.t() | map(), keyword()) :: Noul.t()
  def noul(name, instructions, opts \\ []) when is_atom(name) and is_list(opts) do
    %Noul{
      name: name,
      instructions: instructions,
      criteria: opts[:criteria],
      branch: opts[:branch]
    }
  end

  @spec choice(atom(), String.t() | map(), OptionSet.t(), keyword()) :: Choice.t()
  def choice(name, instructions, options, opts \\ [])
      when is_atom(name) and is_struct(options, OptionSet) and is_list(opts) do
    %Choice{
      name: name,
      instructions: instructions,
      options: options,
      criteria: opts[:criteria],
      branch: opts[:branch]
    }
  end

  @spec score(atom(), String.t() | map(), [String.t()], keyword()) :: Score.t()
  def score(name, instructions, levels, opts \\ [])
      when is_atom(name) and is_list(levels) and is_list(opts) do
    %Score{
      name: name,
      instructions: instructions,
      levels: levels,
      criteria: opts[:criteria],
      branch: opts[:branch]
    }
  end
end
