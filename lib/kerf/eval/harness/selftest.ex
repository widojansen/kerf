defmodule Kerf.Eval.Harness.Selftest do
  @moduledoc """
  SPEC_H F09.9 — the harness self-test: a random run and two oracle runs over
  one manifest, scored with `baseline_accuracy: 0.5` and checked against the
  S-2 expectations (plan §7 H4, addendum 03).

  Random must fail F09.1, F09.7 and raw F09.2 (ECE > 0.08 on every noul/choice
  question); its scaled F09.2 is reported, not asserted. Both oracle runs must
  pass every gate except F09.5 (skipped), be normalized-identical and give
  byte-identical reports.

  Artefacts, all under `out_dir`: `<run>.jsonl`, `<run>.norm.jsonl`,
  `<run>.report.json`, `<run>.report.md` for `random`, `oracle-1`, `oracle-2`,
  and `temperatures.json`. With `opts[:manifest]` that file is used as is;
  otherwise `Synthetic.build(seed: opts[:seed] || 1)` is saved as
  `out_dir/manifest.json`. `run/2` returns every failed expectation and never
  raises.
  """

  alias Kerf.Eval.Adapters.{Oracle, Random}
  alias Kerf.Eval.Harness
  alias Kerf.Eval.Harness.{Report, Run, Score}
  alias Kerf.Eval.Manifest
  alias Kerf.Eval.Manifest.Synthetic

  @runs [
    random: {"random", Random},
    oracle_1: {"oracle-1", Oracle},
    oracle_2: {"oracle-2", Oracle}
  ]
  @calibrated ~w(category needs_reply deadline_present client)
  @baseline_accuracy 0.5
  @raw_ece_floor 0.08

  @spec run(Path.t(), keyword()) :: {:ok, map()} | {:error, [term()]}
  def run(out_dir, opts) do
    seed = opts[:seed] || 1

    with :ok <- File.mkdir_p(out_dir),
         {:ok, path} <- manifest_path(out_dir, opts[:manifest], seed),
         {:ok, manifest} <- Manifest.load(path),
         :ok <- Manifest.ready_for_run?(manifest),
         {:ok, runs} <- run_all(out_dir, manifest, path, seed),
         :ok <- write_temperatures(out_dir, runs) do
      check(summary(path, runs))
    else
      {:error, [_ | _] = failures} -> {:error, failures}
      {:error, reason} -> {:error, [reason]}
    end
  rescue
    exception -> {:error, [exception]}
  end

  defp manifest_path(out_dir, nil, seed) do
    path = Path.join(out_dir, "manifest.json")

    with :ok <- Manifest.save(Synthetic.build(seed: seed), path), do: {:ok, path}
  end

  defp manifest_path(_out_dir, path, _seed), do: {:ok, path}

  # ---------- runs ----------

  defp run_all(out_dir, manifest, path, seed) do
    Enum.reduce_while(@runs, {:ok, %{}}, fn {key, {name, adapter}}, {:ok, acc} ->
      case run_one(out_dir, manifest, path, seed, name, adapter) do
        {:ok, run} -> {:cont, {:ok, Map.put(acc, key, run)}}
        {:error, reason} -> {:halt, {:error, [{name, reason}]}}
      end
    end)
  end

  # The report scores the normalized run file read back from disk: it carries no
  # run_id, started_at or latency, so two oracle runs give byte-identical reports
  # whichever second each one started in (F09.8).
  defp run_one(out_dir, manifest, path, seed, name, adapter) do
    files = files(out_dir, name)

    with {:ok, %{header: header, lines: lines, end: run_end}} <-
           Harness.run(manifest, adapter: adapter, manifest_path: path, seed: seed),
         :ok <- Run.write(files.run, header, lines ++ [run_end]),
         {:ok, text} <- File.read(files.run),
         {:ok, normalized} <- Run.normalize(text),
         :ok <- File.write(files.normalized, normalized),
         {:ok, {header, lines, _run_end}} <- Run.read(files.normalized) do
      report = Score.score(header, lines, manifest.items, baseline_accuracy: @baseline_accuracy)
      json = IO.iodata_to_binary(Report.to_json(report))

      with :ok <- File.write(files.report, json),
           :ok <- File.write(files.summary, Report.to_markdown(report)) do
        {:ok, %{report: report, normalized: normalized, sha256: sha256(json), files: files}}
      end
    end
  end

  defp files(out_dir, name) do
    %{
      run: Path.join(out_dir, name <> ".jsonl"),
      normalized: Path.join(out_dir, name <> ".norm.jsonl"),
      report: Path.join(out_dir, name <> ".report.json"),
      summary: Path.join(out_dir, name <> ".report.md")
    }
  end

  defp write_temperatures(out_dir, runs) do
    temperatures =
      Map.new(@runs, fn {key, {name, _adapter}} -> {name, runs[key].report["temperature"]} end)

    File.write(Path.join(out_dir, "temperatures.json"), Jason.encode!(temperatures))
  end

  # ---------- summary and expectations ----------

  defp summary(path, runs) do
    %{
      manifest: path,
      runs: Map.new(runs, fn {key, run} -> {key, run_summary(run)} end),
      random_raw_ece: Map.new(@calibrated, &{&1, get_in(runs.random.report, ["ece", &1, "raw"])}),
      random_scaled_f09_2: runs.random.report["gates"]["F09.2"]["status"],
      oracle_normalized_identical: runs.oracle_1.normalized == runs.oracle_2.normalized,
      oracle_reports_identical: runs.oracle_1.sha256 == runs.oracle_2.sha256
    }
  end

  defp run_summary(run) do
    %{
      gates: Map.new(run.report["gates"], fn {id, gate} -> {id, gate["status"]} end),
      report_sha256: run.sha256,
      files: run.files
    }
  end

  defp check(summary) do
    failures =
      random_failures(summary) ++
        oracle_failures(summary) ++
        identity_failures(summary)

    if failures == [], do: {:ok, summary}, else: {:error, failures}
  end

  defp random_failures(%{runs: %{random: random}, random_raw_ece: raw_ece}) do
    gates =
      for id <- ~w(F09.1 F09.7), random.gates[id] != "fail" do
        {:random_gate, id, random.gates[id]}
      end

    ece =
      for question <- @calibrated,
          not (is_number(raw_ece[question]) and raw_ece[question] > @raw_ece_floor) do
        {:random_raw_ece, question, raw_ece[question]}
      end

    gates ++ ece
  end

  defp oracle_failures(%{runs: runs}) do
    for key <- [:oracle_1, :oracle_2],
        {id, status} <- Enum.sort(runs[key].gates),
        status != expected_oracle_status(id) do
      {:oracle_gate, key, id, status}
    end
  end

  defp expected_oracle_status("F09.5"), do: "skipped"
  defp expected_oracle_status(_id), do: "pass"

  defp identity_failures(summary) do
    normalized = if summary.oracle_normalized_identical, do: [], else: [:oracle_runs_differ]
    reports = if summary.oracle_reports_identical, do: [], else: [:oracle_reports_differ]
    normalized ++ reports
  end

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
