defmodule Kerf.Eval.Harness.Report do
  @moduledoc """
  SPEC_H F09.8 / F07.3 — renders the `Kerf.Eval.Harness.Score` report map
  (plan §2.4) as JSON with keys sorted at every depth, so two reports of the
  same run are byte-identical, and as a deterministic Markdown summary whose
  only timestamp is `run.started_at`.
  """

  alias Jason.OrderedObject
  alias Kerf.Eval.Harness.Score

  @gate_ids ~w(F09.1 F09.2 F09.3 F09.4 F09.5 F09.6 F09.7)

  @spec to_json(Score.report()) :: iodata()
  def to_json(report), do: report |> sorted() |> Jason.encode_to_iodata!()

  @spec to_markdown(Score.report()) :: String.t()
  def to_markdown(report) do
    run = report["run"] || %{}

    [
      "# Decide eval report — #{run["set_id"]} / #{run["model_id"]}",
      "",
      "- adapter: #{run["adapter"]}",
      "- started: #{run["started_at"]}",
      "- seed: #{fmt(run["seed"])}, limit: #{fmt(run["limit"])}, " <>
        "baseline accuracy: #{fmt(run["baseline_accuracy"])}, host class: #{fmt(run["host_class"])}",
      "",
      "## Gates",
      "",
      "| gate | status | value | threshold | detail |",
      "|---|---|---|---|---|"
    ]
    |> Kernel.++(Enum.map(@gate_ids, &gate_row(&1, (report["gates"] || %{})[&1] || %{})))
    |> Kernel.++(["", "## Accuracy", "", "| question | overall | n |", "|---|---|---|"])
    |> Kernel.++(rows(report["accuracy"], &"| #{&1} | #{fmt(&2["overall"])} | #{fmt(&2["n"])} |"))
    |> Kernel.++([
      "",
      "## ECE",
      "",
      "| question | raw | scaled | T | n |",
      "|---|---|---|---|---|"
    ])
    |> Kernel.++(
      rows(report["ece"], fn q, e ->
        "| #{q} | #{fmt(e["raw"])} | #{fmt(e["scaled"])} | " <>
          "#{fmt((report["temperature"] || %{})[q])} | #{fmt(e["n"])} |"
      end)
    )
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp gate_row(id, gate) do
    "| #{id} | #{gate["status"]} | #{fmt(gate["value"])} | #{fmt(gate["threshold"])} | " <>
      "#{fmt(gate["detail"])} |"
  end

  defp rows(nil, _fun), do: []
  defp rows(section, fun), do: section |> Enum.sort() |> Enum.map(fn {k, v} -> fun.(k, v) end)

  # Keys sorted at every depth; list order is kept.
  defp sorted(%{} = map) when not is_struct(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> {key, sorted(value)} end)
    |> OrderedObject.new()
  end

  defp sorted(list) when is_list(list), do: Enum.map(list, &sorted/1)
  defp sorted(value), do: value

  defp fmt(nil), do: "—"
  defp fmt(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 4)

  defp fmt(%{} = map),
    do: map |> Enum.sort() |> Enum.map_join(", ", fn {k, v} -> "#{k} #{fmt(v)}" end)

  defp fmt(x), do: to_string(x)
end
