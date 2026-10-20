defmodule Kerf.Eval.Manifest.QuestionSetTest do
  @moduledoc """
  SPEC_H F08.2 — Phase B question set (plan §2.1, ruling S-16: order lives only
  in order/0; category options are the SPEC_C enum per A1.9).
  """
  use ExUnit.Case, async: true

  alias Kerf.Decide.OptionSet
  alias Kerf.Eval.Manifest.QuestionSet

  @clients ["client-a", "client-b"]

  test "order/0 is the Phase B order, literally" do
    assert QuestionSet.order() == [
             "category",
             "needs_reply",
             "urgency",
             "deadline_present",
             "client"
           ]
  end

  test "phase_b/1 has exactly the order/0 keys" do
    assert @clients |> QuestionSet.phase_b() |> Map.keys() |> Enum.sort() ==
             Enum.sort(QuestionSet.order())
  end

  test "category is a choice over the SPEC_C enum in OptionSet order" do
    category = QuestionSet.phase_b(@clients)["category"]
    assert category["type"] == "choice"
    assert category["options"] == OptionSet.labels(OptionSet.triage_categories())
  end

  test "client is a choice over the clients with \"none\" last" do
    client = QuestionSet.phase_b(@clients)["client"]
    assert client["type"] == "choice"
    assert client["options"] == @clients ++ ["none"]
  end

  test "needs_reply and deadline_present are Nouls" do
    qs = QuestionSet.phase_b(@clients)
    assert qs["needs_reply"]["type"] == "noul"
    assert qs["deadline_present"]["type"] == "noul"
  end

  test "urgency is a score over levels 1..5" do
    urgency = QuestionSet.phase_b(@clients)["urgency"]
    assert urgency["type"] == "score"
    assert urgency["levels"] == ["1", "2", "3", "4", "5"]
  end

  test "every question carries non-blank instructions" do
    for {_name, q} <- QuestionSet.phase_b(@clients) do
      assert is_binary(q["instructions"]) and String.trim(q["instructions"]) != ""
    end
  end
end
