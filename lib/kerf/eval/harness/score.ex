defmodule Kerf.Eval.Harness.Score do
  @moduledoc """
  SPEC_H F09.1–F09.7 (scoring side) and F07.3 (histogram shape) — turns a run
  (header + answer lines, plan §2.3) and the manifest items into the report
  map of plan §2.4.

  Lines are the string-keyed maps `Kerf.Eval.Harness.Run.read/1` returns.
  Manifest items are read with `Map.get/2` only, so plain maps and the
  `%Kerf.Eval.Manifest.Item{}` struct both work. The report is string-keyed
  throughout (JSON-shaped).
  """

  alias Kerf.Eval.Harness.{Questions, Run}

  @type report :: %{String.t() => term()}
  @type item :: map()

  @schema_version 1
  @bins 10
  @epsilon 1.0e-12
  @probs_tolerance 1.0e-3
  @log_t_range {-4.0, 4.0}
  @golden_iterations 100
  @flip_orders 1..5
  @calibrated_qtypes ~w(noul choice)

  @spec score(Run.line(), [Run.line()], [item()], keyword()) :: report()
  def score(header, lines, items, opts) do
    answers = Enum.filter(lines, &(&1["type"] == "answer"))
    by_id = Map.new(items, &{Map.get(&1, :id), &1})
    main0 = Enum.filter(answers, &main0?/1)
    model_id = get_in(header, ["info", "model_id"])

    eval_main0 = Enum.filter(main0, &(split_of(by_id, &1) == "eval"))
    calibration_main0 = Enum.filter(main0, &(split_of(by_id, &1) == "calibration"))

    temperature = temperatures(calibration_main0, by_id)

    report = %{
      "schema_version" => @schema_version,
      "run" => run_section(header, opts),
      "accuracy" => accuracy(answers, items),
      "ece" => ece_section(eval_main0, by_id, temperature),
      "temperature" => temperature,
      "flip_rate" => flip_rate(answers),
      "isolation" => isolation(answers),
      "latency" => if(header["latency_skipped"], do: nil, else: latency(answers)),
      "coverage" => coverage(answers, expected_lines(header, items)),
      "contrastive" => contrastive(answers, items),
      "histograms" =>
        histograms(%{model_id: model_id, confidences: confidences(eval_main0, by_id)})
    }

    Map.put(report, "gates", gates(report))
  end

  @spec accuracy([Run.line()], [item()]) :: %{String.t() => map()}
  def accuracy(lines, items) do
    by_id = Map.new(items, &{Map.get(&1, :id), &1})

    lines
    |> Enum.filter(&(main0?(&1) and split_of(by_id, &1) == "eval"))
    |> Enum.flat_map(fn line ->
      item = by_id[line["item_id"]]

      case gold(item, line["question"]) do
        {:ok, gold} -> [{line["question"], item, correct?(line, gold)}]
        :error -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {question, rows} ->
      {question,
       %{
         "overall" => rate(rows),
         "by_tier" => by(rows, &Map.get(&1, :tier)),
         "by_language" => by(rows, &Map.get(&1, :language)),
         "n" => length(rows)
       }}
    end)
  end

  @spec ece([{float(), boolean()}]) :: float() | nil
  def ece([]), do: nil

  def ece(samples) do
    n = length(samples)

    samples
    |> Enum.group_by(fn {p, _hit} -> bin(p) end)
    |> Enum.sort()
    |> Enum.map(fn {_bin, members} ->
      n_b = length(members)
      acc = Enum.count(members, &elem(&1, 1)) / n_b
      conf = (members |> Enum.map(&elem(&1, 0)) |> Enum.sum()) / n_b
      n_b / n * abs(acc - conf)
    end)
    |> Enum.sum()
  end

  @spec fit_temperature([{[float()], non_neg_integer()}]) :: float()
  def fit_temperature([]), do: 1.0

  def fit_temperature(samples) do
    logs =
      Enum.map(samples, fn {probs, gold} -> {Enum.map(probs, &:math.log(&1 + @epsilon)), gold} end)

    nll = fn log_t -> nll(logs, :math.exp(log_t)) end
    {lo, hi} = @log_t_range
    :math.exp(golden_section(nll, lo, hi, @golden_iterations))
  end

  @spec fit_diagnostics([{[float()], non_neg_integer()}]) :: %{
          fitted_t: float(),
          calibration_n: non_neg_integer(),
          calibration_nll: float() | nil,
          lr_statistic: float() | nil,
          fit_better: boolean()
        }
  def fit_diagnostics(_samples),
    do:
      apply(:erlang, :error, [
        RuntimeError.exception("Score.fit_diagnostics/1 not implemented (RED)")
      ])

  @spec fit_better?(float() | nil) :: boolean()
  def fit_better?(_lr_statistic),
    do:
      apply(:erlang, :error, [RuntimeError.exception("Score.fit_better?/1 not implemented (RED)")])

  @spec apply_temperature([float()], float()) :: [float()]
  def apply_temperature(probs, t) do
    probs |> Enum.map(&(:math.log(&1 + @epsilon) / t)) |> softmax()
  end

  @spec flip_rate([Run.line()]) :: map()
  def flip_rate(lines) do
    rows =
      lines
      |> Enum.filter(
        &(&1["probe"] == "main" and &1["qtype"] == "choice" and is_map(&1["result"]))
      )
      |> Enum.group_by(&{&1["item_id"], &1["question"]})
      |> Enum.sort()
      |> Enum.flat_map(fn {{_item, question}, group} ->
        case Enum.find(group, &(&1["order_index"] == 0)) do
          nil ->
            []

          base ->
            for l <- group,
                l["order_index"] in @flip_orders,
                do: {question, base["tier"], l["result"]["label"] != base["result"]["label"]}
        end
      end)

    %{
      "overall" => rate(rows, 2),
      "by_tier" => by(rows, 1, 2),
      "by_question" => by(rows, 0, 2)
    }
  end

  @spec isolation([Run.line()]) :: map()
  def isolation(lines) do
    probes = Enum.filter(lines, &(&1["probe"] in ["isolation_sibling", "isolation_state"]))

    %{
      "sibling_mean_p_yes" => mean_p_yes(probes, "isolation_sibling"),
      "state_mean_p_yes" => mean_p_yes(probes, "isolation_state"),
      "packed_separate_agreement" => agreement(lines),
      "n" => probes |> Enum.map(& &1["item_id"]) |> Enum.uniq() |> length()
    }
  end

  @spec latency([Run.line()]) :: map()
  def latency(lines) do
    values =
      lines
      |> Enum.filter(&(main0?(&1) and is_number(&1["latency_ms"])))
      |> Enum.uniq_by(& &1["item_id"])
      |> Enum.map(& &1["latency_ms"])
      |> Enum.sort()

    %{
      "p50_ms" => nearest_rank(values, 50),
      "p95_ms" => nearest_rank(values, 95),
      "n" => length(values)
    }
  end

  @spec coverage([Run.line()], non_neg_integer()) :: map()
  def coverage(lines, expected) do
    {errored, ok} = Enum.split_with(lines, &(is_nil(&1["result"]) or not is_nil(&1["error"])))

    once =
      ok
      |> Enum.group_by(&{&1["item_id"], &1["probe"], &1["order_index"], &1["question"]})
      |> Enum.flat_map(fn
        {_key, [line]} -> [line]
        {_key, _twice} -> []
      end)

    %{
      "expected" => expected,
      "answered" => length(once),
      "errors" => length(errored),
      "in_schema" => Enum.count(once, &in_schema?/1)
    }
  end

  @spec contrastive([Run.line()], [item()]) :: map()
  def contrastive(lines, items) do
    predictions =
      lines |> Enum.filter(&main0?/1) |> Map.new(&{{&1["item_id"], &1["question"]}, &1})

    results =
      items
      |> Enum.filter(&Map.get(&1, :pair_id))
      |> Enum.group_by(&Map.get(&1, :pair_id))
      |> Enum.sort()
      |> Enum.flat_map(fn
        {_pair, [a, b]} -> [pair_passes?(a, b, predictions)]
        {_pair, _other} -> []
      end)

    passed = Enum.count(results, & &1)
    pairs = length(results)
    %{"pairs" => pairs, "passed" => passed, "rate" => if(pairs > 0, do: passed / pairs)}
  end

  @spec histograms(%{model_id: String.t(), confidences: %{String.t() => [float()]}}) ::
          %{String.t() => map()}
  def histograms(%{model_id: model_id, confidences: confidences}) do
    Map.new(confidences, fn {question, ps} ->
      counts = Enum.frequencies_by(ps, &bin/1)

      {question,
       %{
         "model_id" => model_id,
         "bins" => Enum.map(0..(@bins - 1), &Map.get(counts, &1, 0)),
         "n" => length(ps)
       }}
    end)
  end

  @spec gates(report()) :: %{String.t() => map()}
  def gates(report) do
    run = report["run"] || %{}

    gates = %{
      "F09.1" => gate_accuracy(report["accuracy"], run["baseline_accuracy"]),
      "F09.2" => gate_ece(report["ece"]),
      "F09.3" => gate_flip(report["flip_rate"]),
      "F09.4" => gate_isolation(report["isolation"]),
      "F09.5" => gate_latency(report["latency"], run),
      "F09.6" => gate_coverage(report["coverage"]),
      "F09.7" => gate_contrastive(report["contrastive"])
    }

    if run["limit"],
      do:
        Map.new(gates, fn {id, g} ->
          {id, %{g | "status" => "pending", "detail" => "limit set"}}
        end),
      else: gates
  end

  # ---------- gates ----------

  defp gate(status, value, threshold, detail \\ nil),
    do: %{"status" => status, "value" => value, "threshold" => threshold, "detail" => detail}

  defp pass_fail(true), do: "pass"
  defp pass_fail(false), do: "fail"

  defp le?(x, t), do: is_number(x) and x <= t
  defp ge?(x, t), do: is_number(x) and x >= t

  defp gate_accuracy(accuracy, baseline) do
    category = (accuracy || %{})["category"] || %{}
    easy = get_in(category, ["by_tier", "easy"])
    overall = category["overall"]
    value = %{"easy" => easy, "overall" => overall}
    threshold = %{"easy" => 0.90, "overall" => baseline}

    cond do
      not ge?(easy, 0.90) -> gate("fail", value, threshold)
      is_nil(baseline) -> gate("pending", value, threshold, "no baseline accuracy")
      true -> gate(pass_fail(ge?(overall, baseline)), value, threshold)
    end
  end

  defp gate_ece(ece) do
    value = Map.new(ece || %{}, fn {q, e} -> {q, e["scaled"]} end)

    gate(
      pass_fail(value != %{} and Enum.all?(value, fn {_q, s} -> le?(s, 0.08) end)),
      value,
      0.08
    )
  end

  defp gate_flip(flip) do
    value = %{"overall" => flip["overall"], "hard" => get_in(flip, ["by_tier", "hard"])}

    gate(
      pass_fail(le?(value["overall"], 0.05) and le?(value["hard"], 0.10)),
      value,
      %{"overall" => 0.05, "hard" => 0.10}
    )
  end

  defp gate_isolation(iso) do
    value = %{
      "sibling" => iso["sibling_mean_p_yes"],
      "state" => iso["state_mean_p_yes"],
      "agreement" => iso["packed_separate_agreement"]
    }

    gate(
      pass_fail(
        le?(value["sibling"], 0.10) and ge?(value["state"], 0.90) and
          ge?(value["agreement"], 0.98)
      ),
      value,
      %{"sibling" => 0.10, "state" => 0.90, "agreement" => 0.98}
    )
  end

  defp gate_latency(latency, run) do
    threshold =
      case run["host_class"] do
        "decoder" -> 150
        "encoder" -> 30
        _ -> nil
      end

    p95 = latency && latency["p95_ms"]

    cond do
      run["latency_skipped"] -> gate("skipped", nil, threshold, "latency skipped")
      is_nil(threshold) -> gate("pending", p95, nil, "no host class")
      true -> gate(pass_fail(le?(p95, threshold)), p95, threshold)
    end
  end

  defp gate_coverage(c) do
    expected = c["expected"]
    value = if expected > 0, do: c["in_schema"] / expected

    gate(
      pass_fail(
        expected > 0 and c["answered"] == expected and c["errors"] == 0 and
          c["in_schema"] == expected
      ),
      value,
      1.0
    )
  end

  defp gate_contrastive(c), do: gate(pass_fail(ge?(c["rate"], 0.85)), c["rate"], 0.85)

  # ---------- report sections ----------

  defp run_section(header, opts) do
    %{
      "adapter" => header["adapter"],
      "model_id" => get_in(header, ["info", "model_id"]),
      "set_id" => header["set_id"],
      "manifest_sha256" => header["manifest_sha256"],
      "seed" => header["seed"],
      "permutations" => header["permutations"],
      "isolation_items" => header["isolation_items"],
      "limit" => header["limit"],
      "latency_skipped" => header["latency_skipped"],
      "kerf_git_sha" => header["kerf_git_sha"],
      "started_at" => header["started_at"],
      "baseline_accuracy" => opts[:baseline_accuracy],
      "host_class" => opts[:host_class] && Atom.to_string(opts[:host_class])
    }
  end

  defp expected_lines(header, items) do
    items = if header["limit"], do: Enum.take(items, header["limit"]), else: items
    q = length(Questions.order())
    n_eval = Enum.count(items, &(Map.get(&1, :split) == "eval"))
    length(items) * (header["permutations"] * q + q) + 2 * min(header["isolation_items"], n_eval)
  end

  # Calibration metrics read only in-schema answers; coverage reports the rest.
  defp calibrated(lines),
    do: Enum.filter(lines, &(&1["qtype"] in @calibrated_qtypes and in_schema?(&1)))

  defp temperatures(lines, by_id) do
    lines
    |> calibrated()
    |> Enum.group_by(& &1["question"])
    |> Map.new(fn {question, group} ->
      samples =
        Enum.flat_map(group, fn line ->
          with {:ok, gold} <- gold(by_id[line["item_id"]], question),
               {:ok, sample} <- fit_sample(line, gold),
               do: [sample],
               else: (_ -> [])
        end)

      {question, fit_temperature(samples)}
    end)
  end

  defp ece_section(lines, by_id, temperature) do
    lines
    |> calibrated()
    |> Enum.group_by(& &1["question"])
    |> Map.new(fn {question, group} ->
      t = Map.get(temperature, question, 1.0)

      pairs =
        Enum.flat_map(group, fn line ->
          case gold(by_id[line["item_id"]], question) do
            {:ok, gold} -> [{ece_sample(line, gold, :raw), ece_sample(line, gold, t)}]
            :error -> []
          end
        end)

      {question,
       %{
         "raw" => ece(Enum.map(pairs, &elem(&1, 0))),
         "scaled" => ece(Enum.map(pairs, &elem(&1, 1))),
         "n" => length(pairs)
       }}
    end)
  end

  defp confidences(lines, by_id) do
    lines
    |> calibrated()
    |> Enum.filter(&match?({:ok, _}, gold(by_id[&1["item_id"]], &1["question"])))
    |> Enum.group_by(& &1["question"], &confidence/1)
  end

  defp confidence(%{"qtype" => "noul", "result" => %{"p_yes" => p}}), do: p
  defp confidence(%{"result" => %{"probs" => probs}}), do: probs |> values() |> Enum.max()

  defp fit_sample(%{"qtype" => "noul", "result" => %{"p_yes" => p}}, gold),
    do: {:ok, {[p, 1 - p], if(gold, do: 0, else: 1)}}

  defp fit_sample(%{"qtype" => "choice", "result" => %{"probs" => probs}}, gold) do
    case Enum.find_index(labels(probs), &(&1 == gold)) do
      nil -> :error
      index -> {:ok, {values(probs), index}}
    end
  end

  defp fit_sample(_line, _gold), do: :error

  # A Noul's ECE outcome is "gold is yes" (p is p_yes); a Choice's is "label is gold"
  # (p is p_max). Temperature scaling never changes a Choice's argmax.
  defp ece_sample(%{"qtype" => "noul", "result" => %{"p_yes" => p}}, gold, t) do
    [p_yes, _] = scale([p, 1 - p], t)
    {p_yes, gold == true}
  end

  defp ece_sample(
         %{"qtype" => "choice", "result" => %{"label" => label, "probs" => probs}},
         gold,
         t
       ),
       do: {probs |> values() |> scale(t) |> Enum.max(), label == gold}

  defp scale(ps, :raw), do: ps
  defp scale(ps, t), do: apply_temperature(ps, t)

  # ---------- predictions ----------

  defp main0?(line), do: line["probe"] == "main" and line["order_index"] == 0

  defp split_of(by_id, line) do
    case Map.get(by_id, line["item_id"]) do
      nil -> nil
      item -> Map.get(item, :split)
    end
  end

  defp gold(nil, _question), do: :error

  defp gold(item, question) do
    case Map.get(item, :labels) do
      %{^question => gold} -> {:ok, gold}
      _ -> :error
    end
  end

  # Only an in-schema answer has a prediction; an error or malformed answer is wrong.
  defp predicted(line), do: if(in_schema?(line), do: {:ok, prediction(line)}, else: :error)

  defp prediction(%{"qtype" => "choice", "result" => %{"label" => label}}), do: label
  defp prediction(%{"qtype" => "noul", "result" => %{"p_yes" => p}}), do: p >= 0.5

  defp prediction(%{"qtype" => "score", "result" => %{"expected" => e, "probs" => probs}}),
    do: probs |> labels() |> Enum.at(round(e))

  defp normalize_gold(gold) when is_integer(gold), do: Integer.to_string(gold)
  defp normalize_gold(gold), do: gold

  defp correct?(line, gold), do: predicted(line) == {:ok, normalize_gold(gold)}

  defp pair_passes?(a, b, predictions) do
    la = Map.get(a, :labels) || %{}
    lb = Map.get(b, :labels) || %{}

    Questions.order()
    |> Enum.filter(&(Map.get(la, &1) != Map.get(lb, &1)))
    |> Enum.all?(fn q ->
      side_ok?(predictions[{Map.get(a, :id), q}], la[q]) and
        side_ok?(predictions[{Map.get(b, :id), q}], lb[q])
    end)
  end

  defp side_ok?(nil, _gold), do: false
  defp side_ok?(line, gold), do: correct?(line, gold)

  defp agreement(lines) do
    keyed = fn probe ->
      lines
      |> Enum.filter(&(&1["probe"] == probe and &1["order_index"] == 0 and is_map(&1["result"])))
      |> Map.new(&{{&1["item_id"], &1["question"]}, predicted(&1)})
    end

    main = keyed.("main")
    separate = keyed.("separate")
    shared = main |> Map.keys() |> Enum.filter(&Map.has_key?(separate, &1)) |> Enum.sort()

    case shared do
      [] -> nil
      keys -> Enum.count(keys, &(main[&1] == separate[&1])) / length(keys)
    end
  end

  defp mean_p_yes(probes, probe) do
    ps = for %{"probe" => ^probe, "result" => %{"p_yes" => p}} <- probes, is_number(p), do: p
    if ps == [], do: nil, else: Enum.sum(ps) / length(ps)
  end

  # ---------- arithmetic ----------

  defp bin(p), do: min(trunc(p * @bins), @bins - 1)

  defp rate(rows), do: rate(rows, 2)

  defp rate([], _pos), do: nil
  defp rate(rows, pos), do: Enum.count(rows, &elem(&1, pos)) / length(rows)

  defp by(rows, key_fun) when is_function(key_fun),
    do:
      rows
      |> Enum.group_by(&(key_fun.(elem(&1, 1)) || "unknown"))
      |> Map.new(fn {k, r} -> {k, rate(r)} end)

  defp by(rows, key_pos, hit_pos),
    do:
      rows |> Enum.group_by(&elem(&1, key_pos)) |> Map.new(fn {k, r} -> {k, rate(r, hit_pos)} end)

  defp nearest_rank([], _p), do: nil
  defp nearest_rank(sorted, p), do: Enum.at(sorted, max(div(p * length(sorted) + 99, 100), 1) - 1)

  defp softmax(xs) do
    m = Enum.max(xs)
    exps = Enum.map(xs, &:math.exp(&1 - m))
    total = Enum.sum(exps)
    Enum.map(exps, &(&1 / total))
  end

  defp nll(logs, t) do
    logs
    |> Enum.map(fn {ls, gold} ->
      scaled = Enum.map(ls, &(&1 / t))
      m = Enum.max(scaled)
      lse = m + :math.log(scaled |> Enum.map(&:math.exp(&1 - m)) |> Enum.sum())
      lse - Enum.at(scaled, gold)
    end)
    |> Enum.sum()
  end

  @inv_phi (:math.sqrt(5) - 1) / 2

  defp golden_section(_f, lo, hi, 0), do: (lo + hi) / 2

  defp golden_section(f, lo, hi, n) do
    c = hi - @inv_phi * (hi - lo)
    d = lo + @inv_phi * (hi - lo)
    if f.(c) < f.(d), do: golden_section(f, lo, d, n - 1), else: golden_section(f, c, hi, n - 1)
  end

  defp in_schema?(%{"qtype" => "noul", "result" => %{"p_yes" => p}}),
    do: is_number(p) and p >= 0 and p <= 1

  defp in_schema?(%{
         "qtype" => "choice",
         "order" => order,
         "result" => %{"label" => label, "probs" => probs}
       }) do
    labels = labels(probs)

    probs_ok?(probs) and label in labels and
      (is_nil(order) or Enum.sort(labels) == Enum.sort(order))
  end

  defp in_schema?(%{
         "qtype" => "score",
         "result" => %{"expected" => e, "probs" => probs, "confidence" => c}
       }) do
    probs_ok?(probs) and is_number(e) and e >= 0 and e <= length(probs) - 1 and is_number(c) and
      c >= 0 and
      c <= 1
  end

  defp in_schema?(_line), do: false

  defp probs_ok?(probs) when is_list(probs) and probs != [] do
    if Enum.all?(probs, &match?([label, p] when is_binary(label) and is_number(p), &1)) do
      labels = labels(probs)
      ps = values(probs)

      length(Enum.uniq(labels)) == length(labels) and Enum.all?(ps, &(&1 >= 0 and &1 <= 1)) and
        abs(Enum.sum(ps) - 1) <= @probs_tolerance
    else
      false
    end
  end

  defp probs_ok?(_probs), do: false

  # probs come from JSON as [label, p] pairs
  defp labels(probs), do: Enum.map(probs, fn [label, _p] -> label end)
  defp values(probs), do: Enum.map(probs, fn [_label, p] -> p end)
end
