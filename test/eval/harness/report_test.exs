defmodule Kerf.Eval.Harness.ReportTest do
  @moduledoc """
  SPEC_H F09.8 (byte-identical reports) and F07.3 (the JSON the drift worker
  reads) — plan §2.4 / §7 H2.

  `to_json/1` returns iodata with object keys sorted at every depth; the
  report decodes back to the same map. `to_markdown/1` is deterministic and
  carries exactly one timestamp, `run.started_at`. Synthetic values only.
  """
  use ExUnit.Case, async: true

  alias Kerf.Eval.Harness.Report

  @report_keys ~w(accuracy contrastive coverage ece flip_rate gates histograms isolation
                  latency run schema_version temperature)
  @gate_ids ~w(F09.1 F09.2 F09.3 F09.4 F09.5 F09.6 F09.7)

  defp gate(status, value, threshold, detail \\ nil),
    do: %{"status" => status, "value" => value, "threshold" => threshold, "detail" => detail}

  # 40 questions push the histograms map past 32 keys (a hash map, not a flat map).
  defp many_histograms do
    Map.new(1..40, fn i ->
      {"q#{String.pad_leading(Integer.to_string(i), 2, "0")}",
       %{"model_id" => "eval-oracle", "bins" => [i, 0, 0, 0, 0, 0, 0, 0, 0, 1], "n" => i + 1}}
    end)
  end

  defp report do
    %{
      "schema_version" => 1,
      "run" => %{
        "adapter" => "Kerf.Eval.Adapters.Oracle",
        "model_id" => "eval-oracle",
        "set_id" => "decide-v1",
        "manifest_sha256" => String.duplicate("a", 64),
        "seed" => 1,
        "permutations" => 6,
        "isolation_items" => 30,
        "limit" => nil,
        "latency_skipped" => true,
        "baseline_accuracy" => 0.5,
        "host_class" => "decoder",
        "kerf_git_sha" => "abc1234",
        "started_at" => "2026-10-22T10:00:00Z"
      },
      "accuracy" => %{
        "category" => %{
          "overall" => 0.95,
          "by_tier" => %{"easy" => 1.0, "hard" => 0.875},
          "by_language" => %{"nl" => 0.95, "de" => 0.9, "en" => 1.0},
          "n" => 40
        }
      },
      "ece" => %{"category" => %{"raw" => 0.03, "scaled" => 0.001, "n" => 40}},
      "temperature" => %{"category" => 0.25},
      "flip_rate" => %{
        "overall" => 0.0,
        "by_tier" => %{"easy" => 0.0, "hard" => 0.0},
        "by_question" => %{"category" => 0.0}
      },
      "isolation" => %{
        "sibling_mean_p_yes" => 0.03,
        "state_mean_p_yes" => 0.97,
        "packed_separate_agreement" => 1.0,
        "n" => 30
      },
      "latency" => nil,
      "coverage" => %{"expected" => 218, "answered" => 218, "errors" => 0, "in_schema" => 218},
      "contrastive" => %{"pairs" => 1, "passed" => 1, "rate" => 1.0},
      "histograms" => many_histograms(),
      "gates" => %{
        "F09.1" =>
          gate("pass", %{"easy" => 1.0, "overall" => 0.95}, %{"easy" => 0.9, "overall" => 0.5}),
        "F09.2" => gate("pass", %{"category" => 0.001}, 0.08),
        "F09.3" =>
          gate("pass", %{"overall" => 0.0, "hard" => 0.0}, %{"overall" => 0.05, "hard" => 0.1}),
        "F09.4" =>
          gate(
            "pass",
            %{"sibling" => 0.03, "state" => 0.97, "agreement" => 1.0},
            %{"sibling" => 0.1, "state" => 0.9, "agreement" => 0.98}
          ),
        "F09.5" => gate("skipped", nil, 150, "latency skipped"),
        "F09.6" => gate("pass", 1.0, 1.0),
        "F09.7" => gate("pass", 1.0, 0.85)
      }
    }
  end

  # The same report with every map rebuilt from its pairs in reverse order.
  defp rebuilt_reversed(%{} = map),
    do: map |> Enum.reverse() |> Map.new(fn {key, value} -> {key, rebuilt_reversed(value)} end)

  defp rebuilt_reversed(list) when is_list(list), do: Enum.map(list, &rebuilt_reversed/1)
  defp rebuilt_reversed(value), do: value

  defp json(report), do: report |> Report.to_json() |> IO.iodata_to_binary()

  defp assert_sorted_at_every_depth(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))
    assert keys == Enum.sort(keys)
    Enum.each(values, fn {_key, value} -> assert_sorted_at_every_depth(value) end)
  end

  defp assert_sorted_at_every_depth(list) when is_list(list),
    do: Enum.each(list, &assert_sorted_at_every_depth/1)

  defp assert_sorted_at_every_depth(_value), do: :ok

  # ---------- to_json/1 ----------

  test "to_json/1 is byte-identical for the same report built in different key orders" do
    assert json(report()) == json(rebuilt_reversed(report()))
  end

  test "to_json/1 writes the plan 2.4 top-level keys in sorted order" do
    %Jason.OrderedObject{values: values} =
      Jason.decode!(json(report()), objects: :ordered_objects)

    assert Enum.map(values, &elem(&1, 0)) == @report_keys
  end

  test "to_json/1 sorts object keys at every depth" do
    report()
    |> json()
    |> Jason.decode!(objects: :ordered_objects)
    |> assert_sorted_at_every_depth()
  end

  test "to_json/1 decodes back to the same report" do
    assert Jason.decode!(json(report())) == report()
  end

  test "to_json/1 keeps list order (histogram bins are not sorted)" do
    decoded = Jason.decode!(json(report()))

    assert decoded["histograms"]["q07"]["bins"] == [7, 0, 0, 0, 0, 0, 0, 0, 0, 1]
  end

  # ---------- to_markdown/1 ----------

  test "to_markdown/1 is deterministic for the same report built in different key orders" do
    assert Report.to_markdown(report()) == Report.to_markdown(rebuilt_reversed(report()))
  end

  test "to_markdown/1 carries run.started_at as its only timestamp" do
    markdown = Report.to_markdown(report())

    assert markdown =~ "2026-10-22T10:00:00Z"
    assert length(Regex.scan(~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/, markdown)) == 1
  end

  test "to_markdown/1 names the model and every gate with its status" do
    markdown = Report.to_markdown(report())

    assert markdown =~ "eval-oracle"

    for id <- @gate_ids do
      [line] = markdown |> String.split("\n") |> Enum.filter(&String.contains?(&1, id))
      assert line =~ report()["gates"][id]["status"]
    end
  end

  test "to_markdown/1 changes when a gate status changes" do
    failing = put_in(report()["gates"]["F09.7"]["status"], "fail")

    refute Report.to_markdown(failing) == Report.to_markdown(report())
  end
end
