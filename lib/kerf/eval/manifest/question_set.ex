defmodule Kerf.Eval.Manifest.QuestionSet do
  @moduledoc """
  SPEC_H F08.2 — the Phase B question set, defined once (F11 reuses it).

  `order/0` is the single source of question order (ruling S-16): a
  `question_set` is a plain map and does not preserve order, so every
  consumer iterates `order/0`.
  """

  alias Kerf.Decide.OptionSet

  @order ["category", "needs_reply", "urgency", "deadline_present", "client"]

  @spec order() :: [String.t()]
  def order, do: @order

  @spec phase_b([String.t()]) :: %{String.t() => Kerf.Eval.Manifest.question_def()}
  def phase_b(clients) when is_list(clients) do
    %{
      "category" => %{
        "type" => "choice",
        "instructions" =>
          "Which category best describes this email? Pick the single closest category.",
        "options" => OptionSet.labels(OptionSet.triage_categories())
      },
      "needs_reply" => %{
        "type" => "noul",
        "instructions" => "Does this email need a reply from the recipient?"
      },
      "urgency" => %{
        "type" => "score",
        "instructions" =>
          "How urgent is this email for the recipient, from 1 (can wait indefinitely) " <>
            "to 5 (needs action today)?",
        "levels" => ["1", "2", "3", "4", "5"]
      },
      "deadline_present" => %{
        "type" => "noul",
        "instructions" => "Does this email state or imply a concrete deadline or due date?"
      },
      "client" => %{
        "type" => "choice",
        "instructions" =>
          "Which client is this email about? Choose \"none\" if it concerns no client.",
        "options" => clients ++ ["none"]
      }
    }
  end
end
