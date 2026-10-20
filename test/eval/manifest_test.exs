defmodule Kerf.Eval.ManifestTest do
  @moduledoc """
  SPEC_H F08.1–F08.5, F08.7 — docs/superpowers/specs/SPEC_H_kerf_decide.json,
  addendum 03 (A3.5, A3.9), plan §2.1 and lead rulings S-16..S-19
  (docs/superpowers/plans/2026-10-20-decide-eval-step2-3.md).

  Fixtures come only from Kerf.Eval.Manifest.Synthetic (no PII). Fixtures are
  built inside test bodies, never in setup, so a RED skeleton fails in-body.
  """
  use ExUnit.Case, async: true

  alias Kerf.Eval.Manifest
  alias Kerf.Eval.Manifest.{Item, QuestionSet, Synthetic}

  @now "2026-10-21T09:00:00Z"

  # -- helpers ---------------------------------------------------------------

  defp tmp_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kerf_eval_manifest_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp tmp_path!, do: Path.join(tmp_dir!(), "manifest.json")

  defp real_items(m), do: Enum.filter(m.items, &(not is_nil(&1.doc_id)))
  defp paired?(%Item{pair_id: pair_id}), do: not is_nil(pair_id)
  defp unpaired_real(m), do: m |> real_items() |> Enum.reject(&paired?/1)

  defp update_item(m, id, fun) do
    %{m | items: Enum.map(m.items, fn item -> if item.id == id, do: fun.(item), else: item end)}
  end

  defp item!(m, id), do: Enum.find(m.items, &(&1.id == id)) || flunk("no item #{id}")

  defp codes(violations), do: Enum.map(violations, &elem(&1, 0))

  defp assert_violation(m, code, item_id) do
    assert {:error, violations} = Manifest.validate(m)

    assert Enum.any?(violations, &match?({^code, ^item_id, _}, &1)),
           "expected #{inspect(code)} for #{inspect(item_id)}, got #{inspect(violations)}"
  end

  defp assert_code(result, code) do
    assert {:error, violations} = result
    assert is_list(violations)
    assert code in codes(violations), "expected #{inspect(code)}, got #{inspect(violations)}"
  end

  # Recompute counts through the public API: save/2 recomputes, load/1 re-checks.
  defp recount(m) do
    path = tmp_path!()
    assert :ok = Manifest.save(m, path)
    assert {:ok, reloaded} = Manifest.load(path)
    reloaded
  end

  defp calibration_ids(m),
    do: m.items |> Enum.filter(&(&1.split == "calibration")) |> Enum.map(& &1.id) |> Enum.sort()

  defp split_map(m), do: Map.new(m.items, &{&1.id, &1.split})

  defp valid_labels(m) do
    [first | _] = real_items(m)
    first.labels
  end

  # -- validate/1 -----------------------------------------------------------

  describe "validate/1" do
    test "accepts the default synthetic manifest" do
      assert :ok = Manifest.validate(Synthetic.build())
    end

    test ":duplicate_item_id when two items share an id" do
      m = Synthetic.build()
      [a, b | _] = unpaired_real(m)
      m = update_item(m, b.id, &%{&1 | id: a.id})
      assert {:error, violations} = Manifest.validate(m)
      assert :duplicate_item_id in codes(violations)
    end

    test ":duplicate_doc_id fires for two real items with the same doc_id" do
      m = Synthetic.build()
      [a, b | _] = unpaired_real(m)
      m = update_item(m, b.id, &%{&1 | doc_id: a.doc_id})
      assert {:error, violations} = Manifest.validate(m)
      assert :duplicate_doc_id in codes(violations)
    end

    test ":duplicate_doc_id does not fire for synthetic items that all carry doc_id nil (A3.9)" do
      m = Synthetic.build()
      assert Enum.count(m.items, &is_nil(&1.doc_id)) >= 2
      assert :ok = Manifest.validate(m)
    end

    test ":duplicate_doc_id does not fire for two added synthetic items with doc_id nil" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      {:ok, {m, id1}} = Manifest.add_synthetic_item(m, a.id, a.state, @now)
      {:ok, {m, id2}} = Manifest.add_synthetic_item(m, a.id, a.state, @now)
      assert is_nil(item!(m, id1).doc_id)
      assert is_nil(item!(m, id2).doc_id)

      case Manifest.validate(m) do
        :ok -> :ok
        {:error, violations} -> refute :duplicate_doc_id in codes(violations)
      end
    end

    test ":unknown_question for a label key outside the question set" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | labels: Map.put(&1.labels, "priority", 3)})
      assert_violation(m, :unknown_question, a.id)
    end

    test ":missing_question_label when a labelled item lacks one question" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | labels: Map.delete(&1.labels, "client")})
      assert_violation(m, :missing_question_label, a.id)
    end

    test ":label_not_in_options for a category outside the SPEC_C enum" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | labels: Map.put(&1.labels, "category", "invoice")})
      assert_violation(m, :label_not_in_options, a.id)
    end

    test ":label_not_in_options for an unknown client" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | labels: Map.put(&1.labels, "client", "client-z")})
      assert_violation(m, :label_not_in_options, a.id)
    end

    test ":label_wrong_type for urgency given as the string \"3\"" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | labels: Map.put(&1.labels, "urgency", "3")})
      assert_violation(m, :label_wrong_type, a.id)
    end

    test ":label_wrong_type for a Noul given as the string \"true\"" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | labels: Map.put(&1.labels, "needs_reply", "true")})
      assert_violation(m, :label_wrong_type, a.id)
    end

    test ":urgency_out_of_range for urgency 6" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | labels: Map.put(&1.labels, "urgency", 6)})
      assert_violation(m, :urgency_out_of_range, a.id)
    end

    test ":urgency_out_of_range for urgency 0" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | labels: Map.put(&1.labels, "urgency", 0)})
      assert_violation(m, :urgency_out_of_range, a.id)
    end

    test ":empty_body for an item whose body is empty" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | state: %{&1.state | body: ""}})
      assert_violation(m, :empty_body, a.id)
    end

    test ":empty_tier_reason for a tiered item with a blank reason" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | tier: "hard", tier_reason: ""})
      assert_violation(m, :empty_tier_reason, a.id)
    end

    test ":pair_incomplete when three items share a pair_id" do
      m = Synthetic.build()
      %Item{pair_id: pair_id} = Enum.find(m.items, &paired?/1)
      [c | _] = unpaired_real(m)
      m = update_item(m, c.id, &%{&1 | pair_id: pair_id, pair_fact: "extra member"})
      assert {:error, violations} = Manifest.validate(m)
      assert :pair_incomplete in codes(violations)
    end

    test ":pair_incomplete when a pair_id has a single item" do
      m = Synthetic.build()
      [a, _b] = m.items |> Enum.filter(&paired?/1) |> Enum.group_by(& &1.pair_id) |> hd_pair()
      m = update_item(m, a.id, &%{&1 | pair_id: nil, pair_fact: nil})
      assert {:error, violations} = Manifest.validate(m)
      assert :pair_incomplete in codes(violations)
    end

    test ":pair_no_flip when the two items of a pair have identical labels" do
      m = Synthetic.build()
      [a, b] = m.items |> Enum.filter(&paired?/1) |> Enum.group_by(& &1.pair_id) |> hd_pair()
      m = update_item(m, b.id, &%{&1 | labels: a.labels})
      assert {:error, violations} = Manifest.validate(m)
      assert :pair_no_flip in codes(violations)
    end

    test ":pair_fact_blank when a pair's fact is blank" do
      m = Synthetic.build()
      [a, b] = m.items |> Enum.filter(&paired?/1) |> Enum.group_by(& &1.pair_id) |> hd_pair()

      m =
        m
        |> update_item(a.id, &%{&1 | pair_fact: ""})
        |> update_item(b.id, &%{&1 | pair_fact: ""})

      assert {:error, violations} = Manifest.validate(m)
      assert :pair_fact_blank in codes(violations)
    end

    test ":counts_mismatch when counts.total is wrong" do
      m = Synthetic.build()
      m = %{m | counts: %{m.counts | total: m.counts.total + 1}}
      assert {:error, violations} = Manifest.validate(m)
      assert :counts_mismatch in codes(violations)
    end

    test ":counts_mismatch when total − pairs is not the number of real items (pin 1)" do
      m = Synthetic.build()
      m = %{m | counts: %{m.counts | pairs: m.counts.pairs - 1}}
      assert {:error, violations} = Manifest.validate(m)
      assert :counts_mismatch in codes(violations)
    end

    test ":counts_mismatch when by_language is stale after a language change" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      other = if a.language == "en", do: "de", else: "en"
      m = update_item(m, a.id, &%{&1 | language: other})
      assert {:error, violations} = Manifest.validate(m)
      assert :counts_mismatch in codes(violations)
    end

    test ":language_invalid for a language outside nl/de/en/und" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | language: "fr"})
      assert_violation(m, :language_invalid, a.id)
    end

    test ":unknown_label_source for a category source other than adjudicated/new" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | label_sources: %{"category" => "model"}})
      assert_violation(m, :unknown_label_source, a.id)
    end

    test ":question_set_keys when a Phase B question is missing (S-16)" do
      m = Synthetic.build()
      m = %{m | question_set: Map.delete(m.question_set, "client")}
      assert {:error, violations} = Manifest.validate(m)
      assert :question_set_keys in codes(violations)
    end

    test ":question_set_keys when an extra question is present (S-16)" do
      m = Synthetic.build()
      extra = %{"type" => "noul", "instructions" => "Is this a test?"}
      m = %{m | question_set: Map.put(m.question_set, "priority", extra)}
      assert {:error, violations} = Manifest.validate(m)
      assert :question_set_keys in codes(violations)
    end

    test "violations are {code, item_id | nil, detail} triples" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | language: "fr"})
      assert {:error, [_ | _] = violations} = Manifest.validate(m)

      assert Enum.all?(
               violations,
               &match?({code, id, _} when is_atom(code) and (is_binary(id) or is_nil(id)), &1)
             )
    end
  end

  defp hd_pair(groups), do: groups |> Enum.sort() |> hd() |> elem(1)

  # -- load/1, save/2, sha256/1 ----------------------------------------------

  describe "save/2 and load/1" do
    test "round-trip returns an equal struct" do
      m = Synthetic.build()
      path = tmp_path!()
      assert :ok = Manifest.save(m, path)
      assert {:ok, ^m} = Manifest.load(path)
    end

    test "manifest.json is a string-keyed object with schema_version 1 and items in order" do
      m = Synthetic.build()
      path = tmp_path!()
      assert :ok = Manifest.save(m, path)
      decoded = path |> File.read!() |> Jason.decode!()
      assert decoded["schema_version"] == 1
      assert Enum.map(decoded["items"], & &1["id"]) == Enum.map(m.items, & &1.id)
    end

    test "save writes atomically: only the target file remains in the directory" do
      dir = tmp_dir!()
      path = Path.join(dir, "manifest.json")
      assert :ok = Manifest.save(Synthetic.build(), path)
      assert File.ls!(dir) == ["manifest.json"]
    end

    test "save recomputes counts so a stale manifest loads cleanly" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      other = if a.language == "en", do: "de", else: "en"
      stale = update_item(m, a.id, &%{&1 | language: other})
      reloaded = recount(stale)
      assert reloaded.counts.by_language[other] == m.counts.by_language[other] + 1
    end

    test "save allows incomplete (unlabelled) items before freeze" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | labels: nil, labelled_at: nil, labelled_by: nil})
      assert %Manifest{} = recount(m)
    end

    test "save to a missing directory returns an error, never raises" do
      path = Path.join([tmp_dir!(), "missing", "manifest.json"])
      assert {:error, _} = Manifest.save(Synthetic.build(), path)
    end

    test "load of a missing file returns {:error, [violation]}" do
      assert {:error, [{_code, nil, _} | _]} = Manifest.load(Path.join(tmp_dir!(), "none.json"))
    end

    test "load of malformed JSON returns {:error, [violation]}" do
      path = tmp_path!()
      File.write!(path, "{not json")
      assert {:error, [{_code, nil, _} | _]} = Manifest.load(path)
    end

    test "load rejects JSON round-trip strings for typed labels instead of coercing them" do
      m = Synthetic.build()
      path = tmp_path!()
      assert :ok = Manifest.save(m, path)
      [a | _] = unpaired_real(m)

      decoded = path |> File.read!() |> Jason.decode!()

      items =
        Enum.map(decoded["items"], fn item ->
          if item["id"] == a.id,
            do:
              put_in(item, ["labels", "urgency"], "3")
              |> put_in(["labels", "needs_reply"], "true"),
            else: item
        end)

      File.write!(path, Jason.encode!(%{decoded | "items" => items}))
      assert_code(Manifest.load(path), :label_wrong_type)
    end
  end

  describe "sha256/1" do
    test "is the lowercase hex SHA-256 of the file bytes" do
      path = Path.join(tmp_dir!(), "abc.txt")
      File.write!(path, "abc")

      assert Manifest.sha256(path) ==
               "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    end
  end

  # -- put_* / add_synthetic_item / mark_pair -------------------------------

  describe "put_label/4" do
    test "stores labels, sets labelled_at to now and labelled_by to \"wido\" (S-19)" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      labels = %{a.labels | "needs_reply" => not a.labels["needs_reply"]}
      assert {:ok, m2} = Manifest.put_label(m, a.id, labels, @now)
      item = item!(m2, a.id)
      assert item.labels == labels
      assert item.labelled_at == @now
      assert item.labelled_by == "wido"
    end

    test "marks the category source \"new\" on a previously unlabelled item" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      labels = a.labels
      m = update_item(m, a.id, &%{&1 | labels: nil, label_sources: %{}})
      assert {:ok, m2} = Manifest.put_label(m, a.id, labels, @now)
      assert item!(m2, a.id).label_sources == %{"category" => "new"}
    end

    test "keeps an \"adjudicated\" category source (F08.7)" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | label_sources: %{"category" => "adjudicated"}})
      labels = %{a.labels | "urgency" => rem(a.labels["urgency"], 5) + 1}
      assert {:ok, m2} = Manifest.put_label(m, a.id, labels, @now)
      assert item!(m2, a.id).label_sources == %{"category" => "adjudicated"}
    end

    test "rejects urgency \"3\" with :label_wrong_type" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)

      assert_code(
        Manifest.put_label(m, a.id, %{a.labels | "urgency" => "3"}, @now),
        :label_wrong_type
      )
    end

    test "rejects a Noul \"true\" with :label_wrong_type" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)

      assert_code(
        Manifest.put_label(m, a.id, %{a.labels | "deadline_present" => "true"}, @now),
        :label_wrong_type
      )
    end

    test "rejects an unknown option with :label_not_in_options" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)

      assert_code(
        Manifest.put_label(m, a.id, %{a.labels | "category" => "invoice"}, @now),
        :label_not_in_options
      )
    end

    test "rejects a missing question with :missing_question_label" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)

      assert_code(
        Manifest.put_label(m, a.id, Map.delete(a.labels, "urgency"), @now),
        :missing_question_label
      )
    end

    test "rejects an unknown item id with a violation list" do
      m = Synthetic.build(frozen: false)

      assert {:error, [{_, _, _} | _]} =
               Manifest.put_label(m, "it-missing", valid_labels(m), @now)
    end
  end

  describe "put_tier/5" do
    test "stores tier, reason and tiered_at" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      assert {:ok, m2} = Manifest.put_tier(m, a.id, "hard", "reaches Tier-2 escalation", @now)
      item = item!(m2, a.id)

      assert {item.tier, item.tier_reason, item.tiered_at} ==
               {"hard", "reaches Tier-2 escalation", @now}
    end

    test "requires a non-blank reason" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)

      for reason <- ["", "   ", nil] do
        assert_code(Manifest.put_tier(m, a.id, "easy", reason, @now), :empty_tier_reason)
      end
    end

    test "rejects a tier outside easy/standard/hard" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      assert {:error, [{_, _, _} | _]} = Manifest.put_tier(m, a.id, "medium", "reason", @now)
    end
  end

  describe "put_language/3" do
    test "sets language and marks it human-sourced" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      lang = if a.language == "de", do: "nl", else: "de"
      assert {:ok, m2} = Manifest.put_language(m, a.id, lang)
      assert {item!(m2, a.id).language, item!(m2, a.id).language_source} == {lang, "human"}
    end

    test "rejects an invalid language with :language_invalid" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      assert_code(Manifest.put_language(m, a.id, "fr"), :language_invalid)
    end
  end

  describe "add_synthetic_item/4 and mark_pair/5" do
    test "add_synthetic_item appends an item with doc_id nil and synthetic_of set" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      state = %{a.state | body: a.state.body <> " The deadline is Friday."}
      assert {:ok, {m2, new_id}} = Manifest.add_synthetic_item(m, a.id, state, @now)
      assert length(m2.items) == length(m.items) + 1
      refute new_id in Enum.map(m.items, & &1.id)
      item = item!(m2, new_id)
      assert {item.doc_id, item.synthetic_of, item.state} == {nil, a.id, state}
    end

    test "mark_pair links two items whose labels differ" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      {:ok, {m, b_id}} = Manifest.add_synthetic_item(m, a.id, a.state, @now)
      flipped = %{a.labels | "deadline_present" => not a.labels["deadline_present"]}
      {:ok, m} = Manifest.put_label(m, b_id, flipped, @now)
      assert {:ok, m2} = Manifest.mark_pair(m, "pair-x", a.id, b_id, "deadline added")

      for id <- [a.id, b_id] do
        assert {item!(m2, id).pair_id, item!(m2, id).pair_fact} == {"pair-x", "deadline added"}
      end
    end

    test "mark_pair refuses two items with identical labels (:pair_no_flip)" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      {:ok, {m, b_id}} = Manifest.add_synthetic_item(m, a.id, a.state, @now)
      {:ok, m} = Manifest.put_label(m, b_id, a.labels, @now)
      assert_code(Manifest.mark_pair(m, "pair-x", a.id, b_id, "nothing changed"), :pair_no_flip)
    end

    test "mark_pair refuses a blank fact (:pair_fact_blank)" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      {:ok, {m, b_id}} = Manifest.add_synthetic_item(m, a.id, a.state, @now)
      flipped = %{a.labels | "needs_reply" => not a.labels["needs_reply"]}
      {:ok, m} = Manifest.put_label(m, b_id, flipped, @now)
      assert_code(Manifest.mark_pair(m, "pair-x", a.id, b_id, "  "), :pair_fact_blank)
    end
  end

  # -- freeze/4 and assign_split/3 ------------------------------------------

  describe "freeze/4" do
    test "freezes the default-size set: frozen_at, 50 calibration, no pair item held out" do
      assert {:ok, f} = Manifest.freeze(Synthetic.build(frozen: false), 1, @now, [])
      assert f.frozen_at == @now
      assert length(calibration_ids(f)) == 50
      refute Enum.any?(f.items, &(paired?(&1) and &1.split == "calibration"))
      assert Enum.all?(f.items, &(&1.split in ["eval", "calibration"]))
      assert f.export.mix_shortfall_acknowledged == false
    end

    test "same seed → same split; different seed → different split" do
      m = Synthetic.build(frozen: false)
      {:ok, f1} = Manifest.freeze(m, 1, @now, [])
      {:ok, f1b} = Manifest.freeze(m, 1, @now, [])
      {:ok, f2} = Manifest.freeze(m, 2, @now, [])
      assert calibration_ids(f1) == calibration_ids(f1b)
      refute calibration_ids(f1) == calibration_ids(f2)
    end

    test "split does not depend on the caller's process :rand state" do
      m = Synthetic.build(frozen: false)
      :rand.seed(:exsss, 42)
      {:ok, f1} = Manifest.freeze(m, 1, @now, [])
      :rand.seed(:exsss, 7)
      {:ok, f2} = Manifest.freeze(m, 1, @now, [])
      assert calibration_ids(f1) == calibration_ids(f2)
    end

    test "refuses fewer than 200 REAL items even when the total is ≥ 200 (S-17)" do
      m = Synthetic.build(n: 199, pairs: 24, frozen: false)
      assert length(m.items) >= 200
      assert {:error, [_ | _]} = Manifest.freeze(m, 1, @now, [])
    end

    test "refuses fewer than 20 pairs" do
      assert {:error, [_ | _]} =
               Manifest.freeze(Synthetic.build(pairs: 19, frozen: false), 1, @now, [])
    end

    test "refuses when an item is unlabelled" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      m = recount(update_item(m, a.id, &%{&1 | labels: nil, labelled_at: nil, labelled_by: nil}))
      assert {:error, [_ | _]} = Manifest.freeze(m, 1, @now, [])
    end

    test "refuses when an item is untiered" do
      m = Synthetic.build(frozen: false)
      [a | _] = unpaired_real(m)
      m = recount(update_item(m, a.id, &%{&1 | tier: nil, tier_reason: nil, tiered_at: nil}))
      assert {:error, [_ | _]} = Manifest.freeze(m, 1, @now, [])
    end

    test "refuses a language-mix shortfall unless allowed, then records the acknowledgement (A3.5)" do
      m = Synthetic.build(frozen: false)

      m =
        m
        |> real_items()
        |> Enum.reduce(m, fn item, acc ->
          {:ok, acc} = Manifest.put_language(acc, item.id, "en")
          acc
        end)
        |> recount()

      assert {:error, [_ | _]} = Manifest.freeze(m, 1, @now, [])
      assert {:ok, f} = Manifest.freeze(m, 1, @now, allow_mix_shortfall: true)
      assert f.export.mix_shortfall_acknowledged == true
      assert length(calibration_ids(f)) == 50
    end
  end

  describe "assign_split/3 (S-17, S-18)" do
    for n <- [50, 7] do
      test "n = #{n}: exactly n calibration, none paired, each (language, tier) stratum at ⌊quota⌋ or ⌈quota⌉ over the eligible pool" do
        n = unquote(n)
        m = Synthetic.build(frozen: false)
        s = Manifest.assign_split(m, n, 1)

        assert length(calibration_ids(s)) == n
        refute Enum.any?(s.items, &(paired?(&1) and &1.split == "calibration"))
        assert Enum.all?(s.items, &(&1.split in ["eval", "calibration"]))

        eligible = Enum.reject(s.items, &paired?/1)
        total = length(eligible)

        for {stratum, members} <- Enum.group_by(eligible, &{&1.language, &1.tier}) do
          quota = n * length(members) / total
          got = Enum.count(members, &(&1.split == "calibration"))

          assert got in [floor(quota), ceil(quota)],
                 "stratum #{inspect(stratum)}: quota #{quota}, got #{got}"
        end
      end
    end

    test "is deterministic for a seed and varies with the seed" do
      m = Synthetic.build(frozen: false)

      assert split_map(Manifest.assign_split(m, 50, 1)) ==
               split_map(Manifest.assign_split(m, 50, 1))

      refute split_map(Manifest.assign_split(m, 50, 1)) ==
               split_map(Manifest.assign_split(m, 50, 2))
    end

    test "is pure: leaves the process :rand state untouched (pin 2)" do
      m = Synthetic.build(frozen: false)
      :rand.seed(:exsss, 5)
      _ = Manifest.assign_split(m, 50, 1)
      after_call = :rand.uniform()
      :rand.seed(:exsss, 5)
      assert :rand.uniform() == after_call
    end

    test "does not set frozen_at" do
      s = Manifest.assign_split(Synthetic.build(frozen: false), 50, 1)
      assert is_nil(s.frozen_at)
    end
  end

  # -- frozen manifests ------------------------------------------------------

  describe "frozen manifests are immutable (F08.4/F08.5)" do
    test "put_label/4 refuses with :frozen and leaves the manifest unchanged" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      labels = %{a.labels | "needs_reply" => not a.labels["needs_reply"]}
      assert {:error, [{:frozen, _, _} | _]} = Manifest.put_label(m, a.id, labels, @now)
      assert m == Synthetic.build()
    end

    test "put_tier/5 refuses with :frozen and leaves the manifest unchanged" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)

      assert {:error, [{:frozen, _, _} | _]} =
               Manifest.put_tier(m, a.id, "hard", "late re-tier", @now)

      assert m == Synthetic.build()
    end

    test "put_language/3 refuses with :frozen and leaves the manifest unchanged" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      lang = if a.language == "de", do: "nl", else: "de"
      assert {:error, [{:frozen, _, _} | _]} = Manifest.put_language(m, a.id, lang)
      assert m == Synthetic.build()
    end

    test "add_synthetic_item/4 refuses with :frozen and leaves the manifest unchanged" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      assert {:error, [{:frozen, _, _} | _]} = Manifest.add_synthetic_item(m, a.id, a.state, @now)
      assert m == Synthetic.build()
    end

    test "mark_pair/5 refuses with :frozen and leaves the manifest unchanged" do
      m = Synthetic.build()
      [a | rest] = unpaired_real(m)
      b = Enum.find(rest, &(&1.labels != a.labels)) || flunk("no differing item")

      assert {:error, [{:frozen, _, _} | _]} =
               Manifest.mark_pair(m, "pair-late", a.id, b.id, "late pair")

      assert m == Synthetic.build()
    end

    test "freeze/4 refuses an already-frozen manifest with {:frozen, nil, _}" do
      m = Synthetic.build()
      assert {:error, [{:frozen, nil, _} | _]} = Manifest.freeze(m, 2, @now, [])
      assert m == Synthetic.build()
    end

    test "ready_for_run?/1 rejects an item labelled after frozen_at" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | labelled_at: "2099-01-01T00:00:00Z"})
      assert {:error, {_code, item_id, _}} = Manifest.ready_for_run?(m)
      assert item_id == a.id
    end
  end

  # -- items/2, training_export/1, ready_for_run?/1 -------------------------

  describe "items/2 and training_export/1 (F08.5)" do
    test "items(:calibration) returns the 50 held-out items" do
      assert {:ok, cal} = Manifest.items(Synthetic.build(), :calibration)
      assert length(cal) == 50
      assert Enum.all?(cal, &(&1.split == "calibration"))
    end

    test "items(:eval) returns every other item" do
      m = Synthetic.build()
      assert {:ok, eval} = Manifest.items(m, :eval)
      assert length(eval) == length(m.items) - 50
      assert Enum.all?(eval, &(&1.split == "eval"))
    end

    test "training_export never contains a calibration item" do
      m = Synthetic.build()
      assert {:ok, exported} = Manifest.training_export(m)
      refute Enum.any?(exported, &(&1.split == "calibration"))
      {:ok, cal} = Manifest.items(m, :calibration)
      cal_ids = MapSet.new(cal, & &1.id)
      refute Enum.any?(exported, &MapSet.member?(cal_ids, &1.id))
      assert length(exported) == length(m.items) - 50
    end

    test "both refuse an unfrozen manifest" do
      m = Synthetic.build(frozen: false)
      assert {:error, :not_frozen} = Manifest.items(m, :calibration)
      assert {:error, :not_frozen} = Manifest.items(m, :eval)
      assert {:error, :not_frozen} = Manifest.training_export(m)
    end
  end

  describe "ready_for_run?/1 (F08.4)" do
    test "accepts a frozen, consistent manifest" do
      assert :ok = Manifest.ready_for_run?(Synthetic.build())
    end

    test "rejects an unfrozen manifest" do
      assert {:error, {_code, _, _}} = Manifest.ready_for_run?(Synthetic.build(frozen: false))
    end

    test "rejects an item tiered after frozen_at" do
      m = Synthetic.build()
      [a | _] = unpaired_real(m)
      m = update_item(m, a.id, &%{&1 | tiered_at: "2099-01-01T00:00:00Z"})
      assert {:error, {_code, item_id, _}} = Manifest.ready_for_run?(m)
      assert item_id == a.id
    end

    test "rejects a counts mismatch" do
      m = Synthetic.build()
      m = %{m | counts: %{m.counts | held_out: m.counts.held_out + 1}}
      assert {:error, {_code, _, _}} = Manifest.ready_for_run?(m)
    end
  end

  test "Synthetic question set is the Phase B set over client-a..client-c" do
    m = Synthetic.build()
    assert m.question_set == QuestionSet.phase_b(["client-a", "client-b", "client-c"])
  end
end
