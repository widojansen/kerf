defmodule Kerf.Eval.Harness.ScoreTest.FakeItem do
  @moduledoc false
  # Stands in for %Kerf.Eval.Manifest.Item{} (D1): a struct has no Access
  # behaviour, so the scorer must read items with Map.get/2 or dot access.
  defstruct [:id, :doc_id, :language, :tier, :split, :pair_id, :labels]
end

defmodule Kerf.Eval.Harness.ScoreTest do
  @moduledoc """
  SPEC_H F09.1–F09.7 (scoring side) and F07.3 (histogram shape) — plan §2.4 / §7 H2.

  Lines are hand-built in the §2.3 shape (string keys, probs as [label, p]
  pairs), the way `Run.read/1` returns them. Manifest items are atom-keyed maps
  (the future `%Kerf.Eval.Manifest.Item{}` fields) with string-keyed `labels`.

  Contract pinned here (the plan names the functions, not their argument shapes):

    * `ece/1` takes `[{p, outcome}]`; `outcome` is `gold == true` for a Noul
      (p = p_yes) and `label == gold` for a Choice (p = p_max) — the reading
      under which the oracle passes F09.2 (A3.2).
    * `fit_temperature/1` takes `[{probs, gold_index}]` (a Noul as `[p, 1 - p]`,
      gold index 0 when gold is true); no samples → 1.0.
    * `apply_temperature/2` takes a probability list and T.
    * `coverage/2` takes the lines and the expected line count; `score/4`
      computes that count as `n × (permutations × Q + Q) + 2 × min(isolation_items, n_eval)`
      with Q = 5 Phase B questions and n the first `limit` items when a limit is set.
    * `histograms/1` takes `%{model_id:, confidences: %{question => [p]}}`.
    * `gates/1` takes the report without `"gates"`; it reads the run's `limit`,
      `latency_skipped`, `baseline_accuracy` and `host_class`. F09.1 fails on category
      easy < 0.90 whatever the baseline; it is pending only when easy >= 0.90 and the
      baseline is nil (owner ruling 2026-10-20).
    * `accuracy/2` and `contrastive/2` take gold, split, tier and language from the
      manifest items; an error line counts as a wrong answer in accuracy.
    * Flip rate, isolation and latency count every split; accuracy, ECE (raw and
      scaled) and histograms the eval split only; temperatures the calibration split only.
    * Histograms cover Noul and Choice questions (the F09.2 confidence), raw, identity order.
    * Coverage keys a line by (item, probe, order_index, question): a key with more than
      one line is not answered ("exactly once", F09.6); `errors` counts lines.
    * Isolation `n` is the number of distinct items with an isolation line (errored ones
      included); the means average the non-error lines only.
    * `score/4` takes `host_class:` as an atom and records it in the run as a string.

  Synthetic data only; client names are placeholders.
  """
  use ExUnit.Case, async: true

  alias Kerf.Eval.Harness.Score
  alias Kerf.Eval.Harness.ScoreTest.FakeItem

  @categories ~w(business personal newsletter transactional spam social)
  @clients ~w(client-a client-b none)
  @levels ~w(1 2 3 4 5)
  @phase_b [
    {"category", "choice"},
    {"needs_reply", "noul"},
    {"urgency", "score"},
    {"deadline_present", "noul"},
    {"client", "choice"}
  ]
  @report_keys ~w(accuracy contrastive coverage ece flip_rate gates histograms isolation
                  latency run schema_version temperature)
  @gate_ids ~w(F09.1 F09.2 F09.3 F09.4 F09.5 F09.6 F09.7)

  # ---------- line and item fixtures ----------

  defp probs(labels, gold, p_gold) do
    rest = (1 - p_gold) / (length(labels) - 1)
    Enum.map(labels, &[&1, if(&1 == gold, do: p_gold, else: rest)])
  end

  defp choice_result(labels, label, p_gold \\ 0.97) do
    k = length(labels)

    %{
      "label" => label,
      "probs" => probs(labels, label, p_gold),
      "confidence" => (p_gold - 1 / k) / (1 - 1 / k)
    }
  end

  defp noul_result(p_yes), do: %{"p_yes" => p_yes}

  defp score_result(expected, mass_level),
    do: %{
      "expected" => expected,
      "probs" => probs(@levels, mass_level, 0.97),
      "confidence" => 0.97
    }

  defp line(overrides) do
    Map.merge(
      %{
        "type" => "answer",
        "item_id" => "it-0001",
        "doc_id" => "doc-it-0001",
        "language" => "nl",
        "tier" => "easy",
        "split" => "eval",
        "pair_id" => nil,
        "question" => "category",
        "qtype" => "choice",
        "probe" => "main",
        "packed" => true,
        "order_index" => 0,
        "order" => @categories,
        "gold" => "business",
        "result" => choice_result(@categories, "business"),
        "latency_ms" => 10,
        "error" => nil
      },
      overrides
    )
  end

  defp noul_line(overrides) do
    line(
      Map.merge(
        %{
          "question" => "needs_reply",
          "qtype" => "noul",
          "order" => nil,
          "gold" => true,
          "result" => noul_result(0.97)
        },
        overrides
      )
    )
  end

  defp score_line(overrides) do
    line(
      Map.merge(
        %{
          "question" => "urgency",
          "qtype" => "score",
          "order" => nil,
          "gold" => 4,
          "result" => score_result(3.0, "4")
        },
        overrides
      )
    )
  end

  defp item(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        doc_id: "doc-" <> id,
        language: "nl",
        tier: "easy",
        split: "eval",
        pair_id: nil,
        labels: %{
          "category" => "business",
          "needs_reply" => true,
          "urgency" => 4,
          "deadline_present" => false,
          "client" => "client-a"
        }
      },
      overrides
    )
  end

  defp labels(overrides), do: Map.merge(item("x").labels, overrides)

  # ---------- a whole oracle-shaped run (plan §2.3 line order) ----------

  # 6 items: 4 eval (one pair among them, two hard), 2 calibration.
  defp run_items do
    [
      item("it-0001", %{language: "nl", tier: "easy"}),
      item("it-0002", %{
        language: "de",
        tier: "standard",
        labels:
          labels(%{
            "category" => "personal",
            "needs_reply" => false,
            "urgency" => 2,
            "deadline_present" => true,
            "client" => "none"
          })
      }),
      item("it-0003", %{
        language: "en",
        tier: "hard",
        pair_id: "pair-01",
        labels: labels(%{"category" => "spam", "needs_reply" => false, "urgency" => 1})
      }),
      item("it-0004", %{
        doc_id: nil,
        language: "en",
        tier: "hard",
        pair_id: "pair-01",
        labels: labels(%{"category" => "business", "needs_reply" => false, "urgency" => 1})
      }),
      item("it-0005", %{
        language: "nl",
        tier: "standard",
        split: "calibration",
        labels:
          labels(%{
            "category" => "newsletter",
            "needs_reply" => false,
            "urgency" => 1,
            "client" => "none"
          })
      }),
      item("it-0006", %{
        language: "de",
        tier: "easy",
        split: "calibration",
        labels:
          labels(%{
            "category" => "transactional",
            "urgency" => 3,
            "deadline_present" => true,
            "client" => "client-b"
          })
      })
    ]
  end

  defp options("category"), do: @categories
  defp options("client"), do: @clients

  defp rotate(labels, n) do
    {front, back} = Enum.split(labels, rem(n, length(labels)))
    back ++ front
  end

  defp oracle_result("choice", order, gold), do: choice_result(order, gold)
  defp oracle_result("noul", nil, gold), do: noul_result(if(gold, do: 0.97, else: 0.03))
  defp oracle_result("score", nil, gold), do: score_result(gold - 1.0, Integer.to_string(gold))

  defp oracle_line(item, question, qtype, probe, order_index) do
    order = if qtype == "choice", do: rotate(options(question), order_index)
    gold = item.labels[question]

    %{
      "type" => "answer",
      "item_id" => item.id,
      "doc_id" => item.doc_id,
      "language" => item.language,
      "tier" => item.tier,
      "split" => item.split,
      "pair_id" => item.pair_id,
      "question" => question,
      "qtype" => qtype,
      "probe" => probe,
      "packed" => probe != "separate",
      "order_index" => order_index,
      "order" => order,
      "gold" => gold,
      "result" => oracle_result(qtype, order, gold),
      "latency_ms" => 0,
      "error" => nil
    }
  end

  defp isolation_line(item, probe, gold, p_yes) do
    %{
      "type" => "answer",
      "item_id" => item.id,
      "doc_id" => item.doc_id,
      "language" => item.language,
      "tier" => item.tier,
      "split" => item.split,
      "pair_id" => item.pair_id,
      "question" => "secret_present",
      "qtype" => "noul",
      "probe" => probe,
      "packed" => true,
      "order_index" => 0,
      "order" => nil,
      "gold" => gold,
      "result" => noul_result(p_yes),
      "latency_ms" => 0,
      "error" => nil
    }
  end

  defp oracle_run(items) do
    isolated = items |> Enum.filter(&(&1.split == "eval")) |> Enum.take(30) |> MapSet.new(& &1.id)

    Enum.flat_map(items, fn item ->
      main =
        for order_index <- 0..5,
            {question, qtype} <- @phase_b,
            do: oracle_line(item, question, qtype, "main", order_index)

      separate =
        for {question, qtype} <- @phase_b, do: oracle_line(item, question, qtype, "separate", 0)

      isolation =
        if MapSet.member?(isolated, item.id),
          do: [
            isolation_line(item, "isolation_sibling", false, 0.03),
            isolation_line(item, "isolation_state", true, 0.97)
          ],
          else: []

      main ++ separate ++ isolation
    end)
  end

  defp header(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "run_manifest",
        "schema_version" => 1,
        "run_id" => "decide-v1-oracle-s1-2026-10-22T10:00:00Z",
        "set_id" => "decide-v1",
        "manifest_path" => "/tmp/manifest.json",
        "manifest_sha256" => String.duplicate("a", 64),
        "manifest_frozen_at" => "2026-10-21T09:00:00Z",
        "adapter" => "Kerf.Eval.Adapters.Oracle",
        "adapter_opts" => %{},
        "info" => %{
          "model_id" => "eval-oracle",
          "types" => ["noul", "choice", "score"],
          "max_state_tokens" => 8192,
          "languages" => ["nl", "de", "en"]
        },
        "seed" => 1,
        "permutations" => 6,
        "isolation_items" => 30,
        "limit" => nil,
        "latency_skipped" => true,
        "host" => "testhost",
        "kerf_git_sha" => "abc1234",
        "started_at" => "2026-10-22T10:00:00Z"
      },
      overrides
    )
  end

  defp oracle_report(opts \\ [baseline_accuracy: 0.5, host_class: :decoder]) do
    items = run_items()
    Score.score(header(), oracle_run(items), items, opts)
  end

  defp statuses(gates), do: Map.new(gates, fn {id, gate} -> {id, gate["status"]} end)

  # ---------- ece/1 ----------

  test "ece/1 of a perfectly calibrated two-bin set is 0" do
    samples =
      [{0.25, true}] ++
        List.duplicate({0.25, false}, 3) ++ List.duplicate({0.75, true}, 3) ++ [{0.75, false}]

    assert_in_delta Score.ece(samples), 0.0, 1.0e-12
  end

  test "ece/1 of a 0.9-confident, 0.5-accurate set is 0.4" do
    samples = List.duplicate({0.9, true}, 5) ++ List.duplicate({0.9, false}, 5)

    assert_in_delta Score.ece(samples), 0.4, 1.0e-12
  end

  test "ece/1 weights each bin by n_b / N" do
    samples = List.duplicate({0.9, true}, 3) ++ [{0.05, true}]

    # 3/4 · |1 − 0.9| + 1/4 · |1 − 0.05|
    assert_in_delta Score.ece(samples), 0.75 * 0.1 + 0.25 * 0.95, 1.0e-12
  end

  test "ece/1 puts p = 1.0 in bin 9 (min(trunc(p * 10), 9))" do
    # same bin: |0.5 − 0.95| = 0.45; a separate eleventh bin would give 0.55
    assert_in_delta Score.ece([{1.0, false}, {0.9, true}]), 0.45, 1.0e-12
  end

  test "ece/1 puts p = 0.1 in bin 1, not bin 0" do
    # same bin: |0.5 − 0.145| = 0.355; 0.1 in bin 0 would give 0.545
    assert_in_delta Score.ece([{0.1, true}, {0.19, false}]), 0.355, 1.0e-12
  end

  test "ece/1 of no samples is nil" do
    assert Score.ece([]) == nil
  end

  # ---------- fit_temperature/1 and apply_temperature/2 ----------

  test "fit_temperature/1 returns T < 1 for under-confident correct probs (the NLL optimum)" do
    samples = List.duplicate({[0.6, 0.4], 0}, 9) ++ [{[0.6, 0.4], 1}]

    t = Score.fit_temperature(samples)

    assert t < 1
    # scaled p = 0.9 at the optimum: 1.5^(1/T) = 9
    assert_in_delta t, :math.log(1.5) / :math.log(9), 1.0e-6
  end

  test "fit_temperature/1 returns T > 1 for over-confident probs (the NLL optimum)" do
    samples = List.duplicate({[0.9, 0.1], 0}, 7) ++ List.duplicate({[0.9, 0.1], 1}, 3)

    t = Score.fit_temperature(samples)

    assert t > 1
    # scaled p = 0.7 at the optimum: 9^(1/T) = 7/3
    assert_in_delta t, :math.log(9) / :math.log(7 / 3), 1.0e-6
  end

  test "fit_temperature/1 fits a multi-class softmax" do
    samples =
      List.duplicate({[0.8, 0.1, 0.1], 0}, 6) ++
        List.duplicate({[0.8, 0.1, 0.1], 1}, 2) ++ List.duplicate({[0.8, 0.1, 0.1], 2}, 2)

    # scaled p_max = 0.6 at the optimum: 8^(1/T) = 3
    assert_in_delta Score.fit_temperature(samples), :math.log(8) / :math.log(3), 1.0e-6
  end

  test "fit_temperature/1 stays inside log T ∈ [-4, 4] when the optimum is at the edge" do
    t = Score.fit_temperature(List.duplicate({[0.97, 0.03], 0}, 10))

    assert t < 1
    assert t >= :math.exp(-4) - 1.0e-9
  end

  test "fit_temperature/1 with no samples is 1.0" do
    assert Score.fit_temperature([]) == 1.0
  end

  test "apply_temperature/2 is softmax(log(p + 1e-12) / T)" do
    [a, b] = Score.apply_temperature([0.9, 0.1], 2.0)

    # sqrt(0.9) : sqrt(0.1) = 3 : 1
    assert_in_delta a, 0.75, 1.0e-9
    assert_in_delta b, 0.25, 1.0e-9
  end

  test "apply_temperature/2 output still sums to 1 within 1e-9, zeros included" do
    probs = [0.5, 0.2, 0.15, 0.1, 0.05, 0.0]

    for t <- [:math.exp(-4), 0.5, 1.0, 2.0, :math.exp(4)] do
      scaled = Score.apply_temperature(probs, t)

      assert length(scaled) == length(probs)
      assert_in_delta Enum.sum(scaled), 1.0, 1.0e-9
    end
  end

  test "apply_temperature/2 at T = 1 is the identity, T < 1 sharpens and T > 1 flattens" do
    probs = [0.6, 0.3, 0.1]

    for {p, q} <- Enum.zip(probs, Score.apply_temperature(probs, 1.0)),
        do: assert_in_delta(p, q, 1.0e-9)

    assert hd(Score.apply_temperature(probs, 0.5)) > 0.6
    assert hd(Score.apply_temperature(probs, 2.0)) < 0.6
  end

  # ---------- accuracy/2 ----------

  test "accuracy/2 counts only eval-split, probe main, order_index 0 lines" do
    items = [item("it-0001"), item("it-0002", %{split: "calibration"})]

    lines = [
      line(%{"item_id" => "it-0001"}),
      line(%{
        "item_id" => "it-0001",
        "order_index" => 1,
        "result" => choice_result(@categories, "spam")
      }),
      line(%{
        "item_id" => "it-0001",
        "probe" => "separate",
        "packed" => false,
        "result" => choice_result(@categories, "spam")
      }),
      line(%{"item_id" => "it-0002", "result" => choice_result(@categories, "spam")})
    ]

    assert %{"category" => %{"overall" => 1.0, "n" => 1}} = Score.accuracy(lines, items)
  end

  test "accuracy/2 reports overall, by_tier and by_language from the manifest items" do
    items = [
      item("it-0001", %{tier: "easy", language: "nl"}),
      item("it-0002", %{tier: "easy", language: "de"}),
      item("it-0003", %{tier: "hard", language: "de"}),
      item("it-0004", %{tier: "hard", language: "en"})
    ]

    lines = [
      line(%{"item_id" => "it-0001"}),
      line(%{"item_id" => "it-0002"}),
      line(%{"item_id" => "it-0003"}),
      line(%{"item_id" => "it-0004", "result" => choice_result(@categories, "spam")})
    ]

    assert Score.accuracy(lines, items) == %{
             "category" => %{
               "overall" => 0.75,
               "by_tier" => %{"easy" => 1.0, "hard" => 0.5},
               "by_language" => %{"nl" => 1.0, "de" => 1.0, "en" => 0.0},
               "n" => 4
             }
           }
  end

  test "accuracy/2 takes the gold from the manifest, not from the line" do
    items = [item("it-0001", %{labels: labels(%{"category" => "spam"})})]

    lines = [line(%{"item_id" => "it-0001", "gold" => "business"})]

    assert %{"category" => %{"overall" => +0.0}} = Score.accuracy(lines, items)
  end

  test "accuracy/2 predicts a Noul as p_yes >= 0.5" do
    items = [
      item("it-0001", %{labels: labels(%{"needs_reply" => true})}),
      item("it-0002", %{labels: labels(%{"needs_reply" => false})}),
      item("it-0003", %{labels: labels(%{"needs_reply" => true})})
    ]

    lines = [
      noul_line(%{"item_id" => "it-0001", "result" => noul_result(0.5)}),
      noul_line(%{"item_id" => "it-0002", "result" => noul_result(0.49)}),
      noul_line(%{"item_id" => "it-0003", "result" => noul_result(0.2)})
    ]

    assert %{"needs_reply" => %{"overall" => overall, "n" => 3}} = Score.accuracy(lines, items)
    assert_in_delta overall, 2 / 3, 1.0e-12
  end

  test "accuracy/2 predicts a Score as levels[round(expected)] against the integer gold" do
    items = [item("it-0001"), item("it-0002")]

    lines = [
      score_line(%{"item_id" => "it-0001", "result" => score_result(2.6, "4")}),
      score_line(%{"item_id" => "it-0002", "result" => score_result(2.4, "3")})
    ]

    assert %{"urgency" => %{"overall" => 0.5, "n" => 2}} = Score.accuracy(lines, items)
  end

  test "accuracy/2 counts an error line as a wrong answer" do
    items = [item("it-0001"), item("it-0002")]

    lines = [
      line(%{"item_id" => "it-0001"}),
      line(%{"item_id" => "it-0002", "result" => nil, "error" => ":timeout"})
    ]

    assert %{"category" => %{"overall" => 0.5, "n" => 2}} = Score.accuracy(lines, items)
  end

  test "accuracy/2 reads struct items (no Access on the item)" do
    maps = [item("it-0001"), item("it-0002", %{tier: "hard"})]
    structs = Enum.map(maps, &struct(FakeItem, &1))
    lines = [line(%{"item_id" => "it-0001"}), line(%{"item_id" => "it-0002"})]

    assert Score.accuracy(lines, structs) == Score.accuracy(lines, maps)
  end

  # ---------- flip_rate/1 ----------

  defp orders_with_labels(base, options, labels) do
    for {label, order_index} <- Enum.with_index(labels),
        do:
          Map.merge(base, %{
            "order_index" => order_index,
            "result" => choice_result(options, label)
          })
  end

  test "flip_rate/1 counts order_index 1..5 against order 0 and splits by tier and question" do
    easy_category = line(%{"item_id" => "it-0001", "tier" => "easy"})

    hard_client =
      line(%{
        "item_id" => "it-0002",
        "tier" => "hard",
        "question" => "client",
        "order" => @clients,
        "gold" => "none"
      })

    lines =
      orders_with_labels(
        easy_category,
        @categories,
        ~w(business business business spam business business)
      ) ++
        orders_with_labels(hard_client, @clients, ~w(none none client-a none client-b none))

    # flips / (item, order) pairs: 1 of 5 easy, 2 of 5 hard
    flip_rate = Score.flip_rate(lines)

    assert_in_delta flip_rate["overall"], 0.3, 1.0e-12
    assert flip_rate["by_tier"] |> Map.keys() |> Enum.sort() == ["easy", "hard"]
    assert_in_delta flip_rate["by_tier"]["easy"], 0.2, 1.0e-12
    assert_in_delta flip_rate["by_tier"]["hard"], 0.4, 1.0e-12
    assert flip_rate["by_question"] |> Map.keys() |> Enum.sort() == ["category", "client"]
    assert_in_delta flip_rate["by_question"]["category"], 0.2, 1.0e-12
    assert_in_delta flip_rate["by_question"]["client"], 0.4, 1.0e-12
  end

  test "flip_rate/1 ignores order_index above 5, separate and isolation probes and non-Choice lines" do
    base = line(%{"item_id" => "it-0001"})

    lines =
      orders_with_labels(base, @categories, List.duplicate("business", 6)) ++
        [
          Map.merge(base, %{"order_index" => 6, "result" => choice_result(@categories, "spam")}),
          Map.merge(base, %{
            "probe" => "separate",
            "packed" => false,
            "result" => choice_result(@categories, "spam")
          }),
          noul_line(%{"item_id" => "it-0001", "order_index" => 3, "result" => noul_result(0.1)})
        ]

    assert %{"overall" => +0.0, "by_question" => by_question} = Score.flip_rate(lines)
    assert Map.keys(by_question) == ["category"]
  end

  test "flip_rate/1 compares every order with order 0, not with the previous order" do
    lines = orders_with_labels(line(%{}), @categories, ~w(business spam spam spam spam spam))

    assert %{"overall" => 1.0} = Score.flip_rate(lines)
  end

  # ---------- isolation/1 ----------

  test "isolation/1 reports the sibling and state means and the packed/separate agreement" do
    sibling = %{"question" => "secret_present", "probe" => "isolation_sibling", "gold" => false}
    state = %{"question" => "secret_present", "probe" => "isolation_state", "gold" => true}

    lines = [
      noul_line(Map.merge(sibling, %{"item_id" => "it-0001", "result" => noul_result(0.1)})),
      noul_line(Map.merge(sibling, %{"item_id" => "it-0002", "result" => noul_result(0.3)})),
      noul_line(
        Map.merge(sibling, %{"item_id" => "it-0003", "result" => nil, "error" => ":timeout"})
      ),
      noul_line(Map.merge(state, %{"item_id" => "it-0001", "result" => noul_result(0.8)})),
      noul_line(Map.merge(state, %{"item_id" => "it-0002", "result" => noul_result(1.0)})),
      # packed (main, order 0) vs separate: category agrees, needs_reply disagrees
      line(%{"item_id" => "it-0001"}),
      line(%{"item_id" => "it-0001", "probe" => "separate", "packed" => false}),
      noul_line(%{"item_id" => "it-0001", "result" => noul_result(0.9)}),
      noul_line(%{
        "item_id" => "it-0001",
        "probe" => "separate",
        "packed" => false,
        "result" => noul_result(0.2)
      }),
      # a main line with no separate counterpart is not compared
      score_line(%{"item_id" => "it-0001"})
    ]

    assert %{
             "sibling_mean_p_yes" => sibling_mean,
             "state_mean_p_yes" => state_mean,
             "packed_separate_agreement" => 0.5,
             "n" => 3
           } = Score.isolation(lines)

    assert_in_delta sibling_mean, 0.2, 1.0e-12
    assert_in_delta state_mean, 0.9, 1.0e-12
  end

  # ---------- latency/1 ----------

  defp request_lines(item_id, latency_ms) do
    for {question, qtype} <- @phase_b do
      line(%{
        "item_id" => item_id,
        "question" => question,
        "qtype" => qtype,
        "latency_ms" => latency_ms
      })
    end
  end

  test "latency/1 takes one latency per main order-0 request and nearest-rank percentiles" do
    lines =
      Enum.flat_map(1..10, &request_lines("it-#{&1}", &1)) ++
        [
          line(%{"item_id" => "it-1", "order_index" => 1, "latency_ms" => 999}),
          line(%{
            "item_id" => "it-1",
            "probe" => "separate",
            "packed" => false,
            "latency_ms" => 999
          })
        ]

    # nearest rank: p50 → ceil(0.50 · 10) = 5th, p95 → ceil(0.95 · 10) = 10th
    assert Score.latency(lines) == %{"p50_ms" => 5, "p95_ms" => 10, "n" => 10}
  end

  test "latency/1 nearest-rank p95 of 20 requests is the 19th value" do
    lines = Enum.flat_map(1..20, &request_lines("it-#{&1}", &1 * 10))

    assert Score.latency(lines) == %{"p50_ms" => 100, "p95_ms" => 190, "n" => 20}
  end

  test "latency/1 of no requests has nil percentiles" do
    assert Score.latency([]) == %{"p50_ms" => nil, "p95_ms" => nil, "n" => 0}
  end

  # ---------- coverage/2 ----------

  test "coverage/2 counts answered, errors and missing lines against the expected count" do
    lines = [
      line(%{"item_id" => "it-0001"}),
      noul_line(%{"item_id" => "it-0001"}),
      score_line(%{"item_id" => "it-0001", "result" => nil, "error" => ":timeout"})
    ]

    # 5 expected: 2 answered, 1 error, 2 missing
    assert Score.coverage(lines, 5) == %{
             "expected" => 5,
             "answered" => 2,
             "errors" => 1,
             "in_schema" => 2
           }
  end

  test "coverage/2 re-checks every answer against the schema" do
    halved = Enum.map(probs(@categories, "business", 0.97), fn [label, p] -> [label, p / 2] end)
    bad_sum = %{choice_result(@categories, "business") | "probs" => halved}
    not_in_options = %{choice_result(@categories, "business") | "label" => "invoice"}

    lines = [
      line(%{"item_id" => "it-0001", "result" => bad_sum}),
      line(%{"item_id" => "it-0002", "result" => not_in_options}),
      score_line(%{"item_id" => "it-0003", "result" => score_result(4.5, "4")}),
      noul_line(%{"item_id" => "it-0004", "result" => noul_result(1.2)}),
      line(%{"item_id" => "it-0005"})
    ]

    assert %{"answered" => 5, "errors" => 0, "in_schema" => 1} = Score.coverage(lines, 5)
  end

  test "coverage/2 does not count a question answered twice in one request as answered" do
    lines = [line(%{"item_id" => "it-0001"}), line(%{"item_id" => "it-0001"}), noul_line(%{})]

    assert %{"answered" => 1, "errors" => 0} = Score.coverage(lines, 2)
  end

  # ---------- contrastive/2 ----------

  defp pair_items do
    [
      item("it-0001", %{pair_id: "pair-01", labels: labels(%{"category" => "spam"})}),
      item("it-0002", %{
        doc_id: nil,
        pair_id: "pair-01",
        labels: labels(%{"category" => "business"})
      }),
      item("it-0003")
    ]
  end

  defp pair_lines(predicted_a, predicted_b) do
    [
      line(%{"item_id" => "it-0001", "result" => choice_result(@categories, predicted_a)}),
      line(%{"item_id" => "it-0002", "result" => choice_result(@categories, predicted_b)})
    ]
  end

  test "contrastive/2 passes a pair when both sides of the flipped question are predicted right" do
    assert Score.contrastive(pair_lines("spam", "business"), pair_items()) ==
             %{"pairs" => 1, "passed" => 1, "rate" => 1.0}
  end

  test "contrastive/2 fails a pair when either side of the flipped question is wrong" do
    assert %{"passed" => 0} = Score.contrastive(pair_lines("spam", "spam"), pair_items())
    assert %{"passed" => 0} = Score.contrastive(pair_lines("business", "business"), pair_items())
  end

  test "contrastive/2 ignores questions whose gold is the same on both sides" do
    wrong_needs_reply = [
      noul_line(%{"item_id" => "it-0001", "result" => noul_result(0.1)}),
      noul_line(%{"item_id" => "it-0002", "result" => noul_result(0.1)})
    ]

    assert %{"passed" => 1} =
             Score.contrastive(pair_lines("spam", "business") ++ wrong_needs_reply, pair_items())
  end

  test "contrastive/2 uses only main order-0 predictions and fails a pair with a missing one" do
    shuffled_wrong =
      line(%{
        "item_id" => "it-0002",
        "order_index" => 3,
        "result" => choice_result(@categories, "spam")
      })

    assert %{"passed" => 1} =
             Score.contrastive(pair_lines("spam", "business") ++ [shuffled_wrong], pair_items())

    assert %{"pairs" => 1, "passed" => 0} =
             Score.contrastive([hd(pair_lines("spam", "business"))], pair_items())
  end

  test "contrastive/2 rate over several pairs, nil with no pairs" do
    items =
      pair_items() ++
        [
          item("it-0004", %{pair_id: "pair-02", labels: labels(%{"needs_reply" => true})}),
          item("it-0005", %{
            doc_id: nil,
            pair_id: "pair-02",
            labels: labels(%{"needs_reply" => false})
          })
        ]

    lines =
      pair_lines("spam", "business") ++
        [
          noul_line(%{"item_id" => "it-0004", "result" => noul_result(0.9)}),
          noul_line(%{"item_id" => "it-0005", "result" => noul_result(0.9)})
        ]

    assert Score.contrastive(lines, items) == %{"pairs" => 2, "passed" => 1, "rate" => 0.5}

    assert Score.contrastive(lines, [item("it-0001")]) == %{
             "pairs" => 0,
             "passed" => 0,
             "rate" => nil
           }
  end

  test "contrastive/2 reads struct items (no Access on the item)" do
    structs = Enum.map(pair_items(), &struct(FakeItem, &1))

    assert Score.contrastive(pair_lines("spam", "business"), structs) ==
             %{"pairs" => 1, "passed" => 1, "rate" => 1.0}
  end

  # ---------- histograms/1 ----------

  test "histograms/1 gives 10 bins per question with the model_id and the edge rule" do
    input = %{
      model_id: "eval-oracle",
      confidences: %{"category" => [1.0, 0.95, 0.1, 0.05], "needs_reply" => []}
    }

    assert Score.histograms(input) == %{
             "category" => %{
               "model_id" => "eval-oracle",
               "bins" => [1, 1, 0, 0, 0, 0, 0, 0, 0, 2],
               "n" => 4
             },
             "needs_reply" => %{
               "model_id" => "eval-oracle",
               "bins" => List.duplicate(0, 10),
               "n" => 0
             }
           }
  end

  # ---------- gates/1 ----------

  defp passing_report(run_overrides \\ %{}) do
    %{
      "schema_version" => 1,
      "run" =>
        Map.merge(
          %{
            "model_id" => "m",
            "limit" => nil,
            "latency_skipped" => false,
            "baseline_accuracy" => 0.5,
            "host_class" => "decoder",
            "started_at" => "2026-10-22T10:00:00Z"
          },
          run_overrides
        ),
      "accuracy" => %{
        "category" => %{
          "overall" => 0.95,
          "by_tier" => %{"easy" => 0.97, "hard" => 0.9},
          "by_language" => %{"nl" => 0.95},
          "n" => 100
        }
      },
      "ece" => %{
        "category" => %{"raw" => 0.1, "scaled" => 0.05, "n" => 100},
        "needs_reply" => %{"raw" => 0.2, "scaled" => 0.07, "n" => 100}
      },
      "temperature" => %{"category" => 1.2, "needs_reply" => 0.9},
      "flip_rate" => %{
        "overall" => 0.02,
        "by_tier" => %{"easy" => 0.0, "hard" => 0.08},
        "by_question" => %{"category" => 0.02}
      },
      "isolation" => %{
        "sibling_mean_p_yes" => 0.05,
        "state_mean_p_yes" => 0.95,
        "packed_separate_agreement" => 0.99,
        "n" => 30
      },
      "latency" => %{"p50_ms" => 40, "p95_ms" => 120, "n" => 200},
      "coverage" => %{"expected" => 100, "answered" => 100, "errors" => 0, "in_schema" => 100},
      "contrastive" => %{"pairs" => 20, "passed" => 18, "rate" => 0.9},
      "histograms" => %{}
    }
  end

  defp gate_status(report, id), do: Score.gates(report)[id]["status"]

  test "gates/1 returns F09.1..F09.7, each with status, value, threshold and detail" do
    gates = Score.gates(passing_report())

    assert gates |> Map.keys() |> Enum.sort() == @gate_ids

    for {_id, gate} <- gates,
        do: assert(gate |> Map.keys() |> Enum.sort() == ~w(detail status threshold value))
  end

  test "gates/1 passes every gate on a passing report" do
    assert statuses(Score.gates(passing_report())) == Map.new(@gate_ids, &{&1, "pass"})
  end

  test "gates/1 marks every gate pending when the run has a limit" do
    gates = Score.gates(passing_report(%{"limit" => 20}))

    assert statuses(gates) == Map.new(@gate_ids, &{&1, "pending"})
  end

  test "gates/1 F09.1 is pending without a baseline accuracy when category easy >= 0.90" do
    assert gate_status(passing_report(%{"baseline_accuracy" => nil}), "F09.1") == "pending"
  end

  test "gates/1 F09.1 fails on category easy < 0.90 even without a baseline accuracy" do
    report =
      put_in(
        passing_report(%{"baseline_accuracy" => nil})["accuracy"]["category"]["by_tier"]["easy"],
        0.89
      )

    assert gate_status(report, "F09.1") == "fail"
  end

  test "gates/1 F09.1 needs category easy >= 0.90 and overall >= the baseline" do
    at_edge = put_in(passing_report()["accuracy"]["category"]["by_tier"]["easy"], 0.90)
    easy_low = put_in(passing_report()["accuracy"]["category"]["by_tier"]["easy"], 0.89)
    below_baseline = passing_report(%{"baseline_accuracy" => 0.96})

    assert gate_status(at_edge, "F09.1") == "pass"
    assert gate_status(easy_low, "F09.1") == "fail"
    assert gate_status(below_baseline, "F09.1") == "fail"
  end

  test "gates/1 F09.2 fails when any Noul or Choice question's scaled ECE exceeds 0.08" do
    report = put_in(passing_report()["ece"]["needs_reply"]["scaled"], 0.09)

    assert gate_status(report, "F09.2") == "fail"
    assert Score.gates(passing_report())["F09.2"]["threshold"] == 0.08
  end

  test "gates/1 F09.3 needs flip rate <= 0.05 overall and <= 0.10 on the hard tier" do
    hard_high = put_in(passing_report()["flip_rate"]["by_tier"]["hard"], 0.11)
    overall_high = put_in(passing_report()["flip_rate"]["overall"], 0.06)

    assert gate_status(hard_high, "F09.3") == "fail"
    assert gate_status(overall_high, "F09.3") == "fail"
  end

  test "gates/1 F09.4 needs sibling <= 0.10, state >= 0.90 and agreement >= 0.98" do
    for {key, value} <- [
          {"sibling_mean_p_yes", 0.11},
          {"state_mean_p_yes", 0.89},
          {"packed_separate_agreement", 0.97}
        ] do
      report = put_in(passing_report()["isolation"][key], value)

      assert gate_status(report, "F09.4") == "fail"
    end
  end

  test "gates/1 F09.5 uses 150 ms for a decoder host and 30 ms for an encoder host" do
    decoder = Score.gates(passing_report(%{"host_class" => "decoder"}))["F09.5"]
    encoder = Score.gates(passing_report(%{"host_class" => "encoder"}))["F09.5"]

    assert {decoder["status"], decoder["threshold"]} == {"pass", 150}
    assert {encoder["status"], encoder["threshold"]} == {"fail", 30}
  end

  test "gates/1 F09.5 is skipped when latency was skipped and pending without a host class" do
    skipped = %{passing_report(%{"latency_skipped" => true}) | "latency" => nil}

    assert gate_status(skipped, "F09.5") == "skipped"
    assert gate_status(passing_report(%{"host_class" => nil}), "F09.5") == "pending"
  end

  test "gates/1 F09.6 needs every expected line answered, in schema and error-free" do
    missing = put_in(passing_report()["coverage"]["answered"], 99)
    errored = put_in(passing_report()["coverage"]["errors"], 1)
    off_schema = put_in(passing_report()["coverage"]["in_schema"], 99)

    for report <- [missing, errored, off_schema],
        do: assert(gate_status(report, "F09.6") == "fail")
  end

  test "gates/1 F09.7 needs a contrastive rate >= 0.85" do
    at_edge = put_in(passing_report()["contrastive"]["rate"], 0.85)
    below = put_in(passing_report()["contrastive"]["rate"], 0.84)

    no_pairs = %{
      passing_report()
      | "contrastive" => %{"pairs" => 0, "passed" => 0, "rate" => nil}
    }

    assert gate_status(at_edge, "F09.7") == "pass"
    assert gate_status(below, "F09.7") == "fail"
    assert gate_status(no_pairs, "F09.7") == "fail"
  end

  # ---------- score/4 over a whole run ----------

  test "score/4 returns exactly the plan 2.4 top-level keys and schema_version 1" do
    report = oracle_report()

    assert report |> Map.keys() |> Enum.sort() == @report_keys
    assert report["schema_version"] == 1
  end

  test "score/4 run section carries the header facts and opts, never run_id or host" do
    run = oracle_report()["run"]

    assert %{
             "adapter" => "Kerf.Eval.Adapters.Oracle",
             "model_id" => "eval-oracle",
             "set_id" => "decide-v1",
             "seed" => 1,
             "limit" => nil,
             "latency_skipped" => true,
             "baseline_accuracy" => 0.5,
             "host_class" => "decoder",
             "started_at" => "2026-10-22T10:00:00Z"
           } = run

    refute Map.has_key?(run, "run_id")
    refute Map.has_key?(run, "host")
  end

  test "score/4 of an oracle run passes every gate except F09.5, which is skipped" do
    assert statuses(oracle_report()["gates"]) == %{
             "F09.1" => "pass",
             "F09.2" => "pass",
             "F09.3" => "pass",
             "F09.4" => "pass",
             "F09.5" => "skipped",
             "F09.6" => "pass",
             "F09.7" => "pass"
           }
  end

  test "score/4 accuracy covers the four eval items for every Phase B question" do
    accuracy = oracle_report()["accuracy"]

    assert accuracy |> Map.keys() |> Enum.sort() == Enum.sort(Enum.map(@phase_b, &elem(&1, 0)))

    for {_question, entry} <- accuracy, do: assert(%{"overall" => 1.0, "n" => 4} = entry)
    assert accuracy["category"]["by_tier"] == %{"easy" => 1.0, "standard" => 1.0, "hard" => 1.0}
  end

  test "score/4 raw ECE uses gold-is-true frequency for a Noul and correctness for a Choice" do
    ece = oracle_report()["ece"]

    assert ece |> Map.keys() |> Enum.sort() == ~w(category client deadline_present needs_reply)
    assert_in_delta ece["needs_reply"]["raw"], 0.03, 1.0e-9
    assert_in_delta ece["category"]["raw"], 0.03, 1.0e-9
    assert ece["category"]["n"] == 4
  end

  test "score/4 scaled ECE applies the calibration temperature to the eval split" do
    report = oracle_report()

    # calibration answers are all right at 0.97, so T sharpens (T < 1) and eval ECE drops
    assert report["temperature"]["category"] < 1
    assert report["ece"]["category"]["scaled"] < report["ece"]["category"]["raw"]

    assert report["temperature"] |> Map.keys() |> Enum.sort() ==
             Enum.sort(Map.keys(report["ece"]))
  end

  test "score/4 fits temperatures on the calibration split only" do
    items = run_items()
    split = Map.new(items, &{&1.id, &1.split})
    base = oracle_run(items)

    # eval category answers keep their label but drop to 0.6
    soften_eval =
      Enum.map(base, fn
        %{"question" => "category", "item_id" => id, "order" => order, "gold" => gold} = l ->
          if split[id] == "eval", do: %{l | "result" => choice_result(order, gold, 0.6)}, else: l

        l ->
          l
      end)

    # one calibration category answer is confidently wrong
    mislabel_calibration =
      Enum.map(base, fn
        %{"question" => "category", "item_id" => "it-0005", "order" => order} = l ->
          %{l | "result" => choice_result(order, "spam")}

        l ->
          l
      end)

    t = fn lines -> Score.score(header(), lines, items, [])["temperature"]["category"] end

    assert t.(soften_eval) == t.(base)
    refute t.(mislabel_calibration) == t.(base)
  end

  test "score/4 histograms are the raw eval-split confidences per Noul/Choice question" do
    histograms = oracle_report()["histograms"]

    assert histograms |> Map.keys() |> Enum.sort() ==
             ~w(category client deadline_present needs_reply)

    assert histograms["category"] == %{
             "model_id" => "eval-oracle",
             "bins" => [0, 0, 0, 0, 0, 0, 0, 0, 0, 4],
             "n" => 4
           }

    # needs_reply eval gold: true, false, false, false → p_yes 0.97 once, 0.03 three times
    assert histograms["needs_reply"]["bins"] == [3, 0, 0, 0, 0, 0, 0, 0, 0, 1]
  end

  test "score/4 coverage expects n × (permutations × 5 + 5) + 2 × min(isolation_items, eval)" do
    # 6 items × 35 + 2 × min(30, 4)
    assert oracle_report()["coverage"] == %{
             "expected" => 218,
             "answered" => 218,
             "errors" => 0,
             "in_schema" => 218
           }
  end

  test "score/4 flip rate, isolation and contrastive of an oracle run" do
    report = oracle_report()

    assert %{"overall" => +0.0, "by_question" => %{"category" => +0.0, "client" => +0.0}} =
             report["flip_rate"]

    assert %{"packed_separate_agreement" => 1.0, "n" => 4} = report["isolation"]
    assert_in_delta report["isolation"]["sibling_mean_p_yes"], 0.03, 1.0e-9
    assert_in_delta report["isolation"]["state_mean_p_yes"], 0.97, 1.0e-9
    assert report["contrastive"] == %{"pairs" => 1, "passed" => 1, "rate" => 1.0}
  end

  test "score/4 latency is null when the header says latency was skipped" do
    assert oracle_report()["latency"] == nil
  end

  test "score/4 latency is measured when the header does not skip it" do
    items = run_items()

    report =
      Score.score(header(%{"latency_skipped" => false}), oracle_run(items), items,
        host_class: :encoder
      )

    assert %{"p50_ms" => 0, "p95_ms" => 0, "n" => 6} = report["latency"]
    assert report["gates"]["F09.5"]["status"] == "pass"
  end

  test "score/4 F09.1 is pending without a baseline and every gate is pending with a limit" do
    items = run_items()
    lines = oracle_run(items)

    no_baseline = Score.score(header(), lines, items, host_class: :decoder)
    limited = Score.score(header(%{"limit" => 2}), oracle_run(Enum.take(items, 2)), items, [])

    assert no_baseline["gates"]["F09.1"]["status"] == "pending"
    assert statuses(limited["gates"]) == Map.new(@gate_ids, &{&1, "pending"})
    # the first 2 items: 2 × 35 + 2 × min(30, 2)
    assert %{"expected" => 74, "answered" => 74} = limited["coverage"]
  end

  test "score/4 F09.1 fails without a baseline when the easy-tier category answer is wrong" do
    items = run_items()

    # it-0001 is the only eval easy item: its main order-0 category answer goes wrong
    lines =
      Enum.map(oracle_run(items), fn
        %{"item_id" => "it-0001", "probe" => "main", "order_index" => 0, "question" => "category"} =
            l ->
          %{l | "result" => choice_result(l["order"], "spam")}

        l ->
          l
      end)

    report = Score.score(header(), lines, items, host_class: :decoder)

    assert report["gates"]["F09.1"]["status"] == "fail"
  end

  test "score/4 counts an error line and a missing line against coverage and fails F09.6" do
    items = run_items()
    [first, second | rest] = oracle_run(items)
    errored = %{first | "result" => nil, "error" => ":timeout"}

    with_error = Score.score(header(), [errored, second | rest], items, baseline_accuracy: 0.5)
    with_gap = Score.score(header(), [second | rest], items, baseline_accuracy: 0.5)

    assert %{"expected" => 218, "answered" => 217, "errors" => 1} = with_error["coverage"]
    assert %{"expected" => 218, "answered" => 217, "errors" => 0} = with_gap["coverage"]
    assert with_error["gates"]["F09.6"]["status"] == "fail"
    assert with_gap["gates"]["F09.6"]["status"] == "fail"
  end

  test "score/4 reads struct items exactly like maps" do
    items = run_items()
    structs = Enum.map(items, &struct(FakeItem, &1))
    lines = oracle_run(items)
    opts = [baseline_accuracy: 0.5, host_class: :decoder]

    assert Score.score(header(), lines, structs, opts) ==
             Score.score(header(), lines, items, opts)
  end

  test "score/4 of two runs differing only in run_id, host, started_at and latency differ only in run.started_at" do
    items = run_items()
    lines = oracle_run(items)
    slower = Enum.map(lines, &%{&1 | "latency_ms" => 42})

    a = Score.score(header(), lines, items, baseline_accuracy: 0.5)

    b =
      Score.score(
        header(%{
          "run_id" => "decide-v1-oracle-s1-2026-10-23T08:00:00Z",
          "host" => "otherhost",
          "started_at" => "2026-10-23T08:00:00Z"
        }),
        slower,
        items,
        baseline_accuracy: 0.5
      )

    drop = fn report -> update_in(report["run"], &Map.delete(&1, "started_at")) end

    refute a == b
    assert drop.(a) == drop.(b)
  end
end
