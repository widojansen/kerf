defmodule Kerf.Eval.Harness.SelftestTest do
  @moduledoc """
  SPEC_H F09.9 — the harness self-test itself, run in CI (plan §7 H4, S-2,
  addendum 03): over `Synthetic.build(n: 60, pairs: 6)` (66 items, 11
  calibration) a random run must fail F09.1, F09.7 and raw F09.2 (ECE > 0.08
  on every noul/choice question; scaled F09.2 is reported, not asserted), and
  two oracle runs must pass every gate except F09.5 (skipped), be
  normalized-identical and give byte-identical reports. Every score uses
  `baseline_accuracy: 0.5`.

  Artefacts, all under `out_dir`: `<run>.jsonl`, `<run>.norm.jsonl`,
  `<run>.report.json`, `<run>.report.md` for `random`, `oracle-1`, `oracle-2`,
  and `temperatures.json` (each run's fitted temperatures keyed by run name).
  With `opts[:manifest]` the given file is used as is (not copied); otherwise
  `Synthetic.build(seed: opts[:seed] || 1)` is saved as `out_dir/manifest.json`.
  """
  use ExUnit.Case, async: true

  alias Kerf.Eval.Harness.{Run, Selftest}
  alias Kerf.Eval.Manifest
  alias Kerf.Eval.Manifest.Synthetic

  @runs [random: "random", oracle_1: "oracle-1", oracle_2: "oracle-2"]
  @gates ~w(F09.1 F09.2 F09.3 F09.4 F09.5 F09.6 F09.7)
  @calibrated ~w(category needs_reply deadline_present client)

  defp tmp_dir!(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kerf_eval_selftest_#{label}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  setup_all do
    manifest_dir = tmp_dir!("manifest")
    out_dir = tmp_dir!("out")
    manifest = Path.join(manifest_dir, "manifest.json")
    :ok = Manifest.save(Synthetic.build(n: 60, pairs: 6), manifest)

    on_exit(fn ->
      File.rm_rf!(manifest_dir)
      File.rm_rf!(out_dir)
    end)

    %{manifest: manifest, out_dir: out_dir, result: Selftest.run(out_dir, manifest: manifest)}
  end

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp report(out_dir, name),
    do: out_dir |> Path.join("#{name}.report.json") |> File.read!() |> Jason.decode!()

  test "the self-test passes", %{result: result} do
    assert {:ok, %{} = _summary} = result
  end

  test "the summary names the manifest and the three runs", %{result: result, manifest: manifest} do
    assert {:ok, summary} = result
    assert summary.manifest == manifest
    assert summary.runs |> Map.keys() |> Enum.sort() == Keyword.keys(@runs) |> Enum.sort()

    for {key, _name} <- @runs do
      run = summary.runs[key]
      assert run.gates |> Map.keys() |> Enum.sort() == @gates, "#{key}"
      assert run.report_sha256 =~ ~r/\A[0-9a-f]{64}\z/, "#{key}"
    end
  end

  test "random fails F09.1 and F09.7", %{result: {:ok, summary}} do
    assert summary.runs.random.gates["F09.1"] == "fail"
    assert summary.runs.random.gates["F09.7"] == "fail"
  end

  test "random's raw ECE exceeds 0.08 on every noul/choice question; scaled F09.2 is reported",
       %{result: {:ok, summary}, out_dir: out_dir} do
    assert summary.random_raw_ece |> Map.keys() |> Enum.sort() == Enum.sort(@calibrated)

    for question <- @calibrated do
      assert summary.random_raw_ece[question] > 0.08, question
      assert summary.random_raw_ece[question] == report(out_dir, "random")["ece"][question]["raw"]
    end

    assert summary.random_scaled_f09_2 in ~w(pass fail)
    assert summary.random_scaled_f09_2 == summary.runs.random.gates["F09.2"]
  end

  test "both oracle runs pass every gate except F09.5, which is skipped", %{
    result: {:ok, summary}
  } do
    for key <- [:oracle_1, :oracle_2] do
      gates = summary.runs[key].gates
      assert gates["F09.5"] == "skipped", "#{key}"

      for gate <- @gates -- ["F09.5"] do
        assert gates[gate] == "pass", "#{key} #{gate}"
      end
    end
  end

  test "the two oracle runs are normalized-identical and their reports byte-identical",
       %{result: {:ok, summary}, out_dir: out_dir} do
    assert summary.oracle_normalized_identical == true
    assert summary.oracle_reports_identical == true
    assert summary.runs.oracle_1.report_sha256 == summary.runs.oracle_2.report_sha256

    assert File.read!(Path.join(out_dir, "oracle-1.norm.jsonl")) ==
             File.read!(Path.join(out_dir, "oracle-2.norm.jsonl"))
  end

  test "every artefact is written under out_dir", %{result: {:ok, summary}, out_dir: out_dir} do
    expected =
      for {_key, name} <- @runs,
          suffix <- ~w(.jsonl .norm.jsonl .report.json .report.md),
          do: name <> suffix

    assert Enum.sort(File.ls!(out_dir)) == Enum.sort(["temperatures.json" | expected])

    for {key, name} <- @runs do
      assert summary.runs[key].report_sha256 == sha256(Path.join(out_dir, "#{name}.report.json"))
    end
  end

  test "the run files are the harness format over the given manifest",
       %{out_dir: out_dir, manifest: manifest} do
    for {_key, name} <- @runs do
      path = Path.join(out_dir, "#{name}.jsonl")
      assert {:ok, {header, lines, run_end}} = Run.read(path)
      assert header["manifest_path"] == manifest
      assert header["latency_skipped"] == true
      assert header["limit"] == nil
      assert run_end["answers"] == length(lines)
      assert {:ok, normalized} = Run.normalize(File.read!(path))
      assert File.read!(Path.join(out_dir, "#{name}.norm.jsonl")) == normalized
    end
  end

  test "every report is scored with baseline_accuracy 0.5", %{out_dir: out_dir} do
    for {_key, name} <- @runs do
      assert report(out_dir, name)["run"]["baseline_accuracy"] == 0.5, name
    end
  end

  test "temperatures.json holds each run's fitted temperatures", %{out_dir: out_dir} do
    temperatures = out_dir |> Path.join("temperatures.json") |> File.read!() |> Jason.decode!()
    assert temperatures |> Map.keys() |> Enum.sort() == ~w(oracle-1 oracle-2 random)

    for {_key, name} <- @runs do
      assert temperatures[name] == report(out_dir, name)["temperature"], name
    end
  end

  test "an unready manifest is a failure list, never a raise" do
    manifest_dir = tmp_dir!("unready")
    out_dir = tmp_dir!("unready_out")
    on_exit(fn -> Enum.each([manifest_dir, out_dir], &File.rm_rf!/1) end)

    manifest = Path.join(manifest_dir, "manifest.json")
    :ok = Manifest.save(Synthetic.build(n: 8, pairs: 2, frozen: false), manifest)

    assert {:error, [_ | _]} = Selftest.run(out_dir, manifest: manifest)
  end

  test "a missing manifest file is a failure list, never a raise" do
    out_dir = tmp_dir!("missing_out")
    on_exit(fn -> File.rm_rf!(out_dir) end)
    missing = Path.join(out_dir, "no-manifest.json")

    assert {:error, [_ | _]} = Selftest.run(out_dir, manifest: missing)
  end
end
