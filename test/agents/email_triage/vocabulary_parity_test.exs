defmodule Kerf.Agents.EmailTriage.VocabularyParityTest do
  @moduledoc """
  SPEC_C §6 — docs/superpowers/specs/SPEC_C_triage_enum_fix.md

  Vocabulary-parity guard: the FastClassifier category vocabulary and the LLM
  schema's category enum must be the same set. The D11 audit (2026-08-12) and
  its 2026-08-13 addendum found these had silently drifted for months —
  "social" was missing from the LLM enum despite real production occurrences
  via the Gmail-label branch, while "marketing" survived in FastClassifier
  with zero real producers (0 of 31,581 ingested documents). This guard turns
  future drift into a CI failure instead of a three-month production leak.
  """
  use Kerf.DataCase

  alias Kerf.StructuredOutput.Builtins
  alias Kerf.Agents.EmailTriage.FastClassifier
  alias Kerf.KnowledgeBase.EmailSender

  # Canonical set, pinned once — both sides are compared against this literal
  # rather than against each other directly, so a future editor who adds a
  # 7th value to only one side gets a specific, readable failure instead of
  # a bare set-inequality diff.
  @canonical_categories ~w(business personal newsletter transactional spam social)

  # Per Stage 1 read-back (SPEC_C_triage_enum_fix.md §2 item 2), neither
  # vocabulary is programmatically introspectable end-to-end:
  #
  #   * LLM side (builtins.ex :email_classification schema) IS introspectable
  #     — Builtins.schemas() returns the live schema map — so it's read
  #     directly below rather than pinned a second time.
  #
  #   * FastClassifier side is NOT introspectable, and — see the
  #     "collision" test below — cannot even be verified indirectly by
  #     exercising FastClassifier.classify/2's output, because
  #     default_priority/1 and default_action/1 (fast_classifier.ex) each
  #     carry a universal catch-all (`defp default_priority(_), do: 2`,
  #     `defp default_action(_), do: "archive"`) whose fallback values are
  #     identical to several real per-category clause values. A category
  #     outside the set is therefore NOT reliably distinguishable from one
  #     inside it by observing classify/2's output alone. Per SPEC_C §6's
  #     stated fallback, this side is pinned as a documented literal instead
  #     of derived.
  @fast_classifier_categories ~w(business personal newsletter transactional spam social)

  defp llm_category_enum do
    {:email_classification, schema} =
      Enum.find(Builtins.schemas(), fn {name, _schema} -> name == :email_classification end)

    schema.json_schema["properties"]["category"]["enum"]
  end

  # Exercises the narrowest honest public seam: an EmailSender row with
  # classification_override set to `category` (no priority_override, so
  # default_priority/1 and default_action/1 are the ones actually called)
  # routes through FastClassifier.classify/2's real match_by_email/1 ->
  # build_classification/1 path — not a stub.
  defp classify_via_override!(category, unique_tag) do
    {:ok, _sender} =
      Repo.insert(
        EmailSender.changeset(%EmailSender{}, %{
          email: "vocab-parity-#{unique_tag}@example.com",
          classification_override: category
        })
      )

    {:ok, classification} =
      FastClassifier.classify(%{
        from: "Vocab Parity <vocab-parity-#{unique_tag}@example.com>",
        subject: "test",
        labels: []
      })

    classification
  end

  describe "parity: canonical set" do
    test "FastClassifier vocabulary and LLM schema enum are the same set (both = 6 values)" do
      assert length(@canonical_categories) == 6
      assert MapSet.new(@fast_classifier_categories) == MapSet.new(@canonical_categories)

      assert MapSet.new(llm_category_enum()) == MapSet.new(@canonical_categories)
      assert length(llm_category_enum()) == 6
    end
  end

  # SPEC_H F06.3 — docs/superpowers/specs/SPEC_H_kerf_decide.json
  #
  # Kerf.Decide triage Choice questions draw their labels from this same
  # guarded vocabulary. `assert_triage_vocabulary!/1` is the guard; the second
  # test proves it bites (validate-the-validator), using "invoice", which the
  # SPEC_H F11 appendix names as a category but SPEC_C's enum does not contain.
  defp assert_triage_vocabulary!(option_set) do
    outside = Kerf.Decide.OptionSet.labels(option_set) -- @canonical_categories

    assert outside == [],
           "triage OptionSet label(s) #{inspect(outside)} are not in the SPEC_C vocabulary; " <>
             "add them to the canonical set (and both producers) first"
  end

  describe "SPEC_H F06.3: Decide triage OptionSet" do
    setup do
      assert Code.ensure_loaded?(Kerf.Decide.OptionSet),
             "Kerf.Decide.OptionSet is not implemented yet (SPEC_H F06.3, RED)"

      :ok
    end

    test "Decide's triage category OptionSet is exactly the parity-guarded vocabulary" do
      option_set = Kerf.Decide.OptionSet.triage_categories()

      assert_triage_vocabulary!(option_set)

      assert MapSet.new(Kerf.Decide.OptionSet.labels(option_set)) ==
               MapSet.new(@canonical_categories)
    end

    test "a triage OptionSet built from an out-of-vocabulary label fails the guard" do
      {:ok, rogue} = Kerf.Decide.OptionSet.new(["business", "invoice"])

      assert_raise ExUnit.AssertionError, fn -> assert_triage_vocabulary!(rogue) end
    end
  end

  describe "why FastClassifier's side is pinned, not derived" do
    test "classify/2 is total (non-crashing) for every canonical category via classification_override" do
      for category <- @canonical_categories do
        classification = classify_via_override!(category, category)
        assert classification.category == category
        assert is_integer(classification.priority)
        assert is_binary(classification.action)
      end
    end

    test "an out-of-set category collides with default_priority/1's and default_action/1's fallback — proving classify/2's output can't distinguish in-set from out-of-set" do
      # "quux_out_of_set" is not, and must never become, a canonical category.
      # It's a legal value for the unvalidated `classification_override`
      # column (out of scope per SPEC_C §1: no validate_inclusion on category
      # anywhere in this pipeline).
      out_of_set = classify_via_override!("quux_out_of_set", "outofset")
      assert out_of_set.priority == 2
      assert out_of_set.action == "archive"

      # "transactional" is IN the canonical set, yet its priority is
      # identical to the out-of-set fallback above — default_priority/1's
      # explicit `defp default_priority("transactional"), do: 2` clause is
      # observationally indistinguishable from the catch-all.
      transactional = classify_via_override!("transactional", "transactional")
      assert transactional.priority == out_of_set.priority

      # "newsletter" is IN the canonical set, yet its action is identical to
      # the out-of-set fallback — same collision on the action dimension.
      newsletter = classify_via_override!("newsletter", "newsletter")
      assert newsletter.action == out_of_set.action
    end
  end
end
