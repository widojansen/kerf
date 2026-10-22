defmodule Mix.Tasks.Kerf.Eval.DecideTest do
  @moduledoc """
  SPEC_H F09.8 / S-35 (c) — `mix kerf.eval.decide` starting `:req` (plan §7 H4b).

  `Mix.Tasks.Kerf.Eval.Decide.run/2` takes `opts[:starter]` (default
  `&Application.ensure_all_started/1`) and `run/1` is `run(argv, [])`. A starter
  `{:error, reason}` raises `Mix.Error` naming `inspect(reason)` before
  `CLI.run/1` is reached; `Mix.raise/1` is the only raise. Output paths live
  under `System.tmp_dir!()`; the manifest comes from `Manifest.Synthetic`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kerf.Eval.Harness.Run
  alias Kerf.Eval.Manifest
  alias Kerf.Eval.Manifest.Synthetic
  alias Mix.Tasks.Kerf.Eval.Decide

  defp tmp_dir! do
    dir =
      Path.join(System.tmp_dir!(), "kerf_eval_decide_task_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp run_argv do
    dir = tmp_dir!()
    manifest = Path.join(dir, "manifest.json")
    :ok = Manifest.save(Synthetic.build(n: 8, pairs: 2), manifest)
    out = Path.join(dir, "run.jsonl")
    {["run", "--manifest", manifest, "--out", out, "--adapter", "oracle", "--seed", "7"], out}
  end

  test "a starter error raises Mix.Error naming the reason; the CLI is not reached" do
    {argv, out} = run_argv()
    reason = {:req, {:boom, :finch}}

    error =
      assert_raise Mix.Error, fn ->
        Decide.run(argv, starter: fn :req -> {:error, reason} end)
      end

    assert error.message =~ inspect(reason)
    refute File.exists?(out)
  end

  test "the starter is given :req; on {:ok, apps} the run goes ahead" do
    {argv, out} = run_argv()
    parent = self()

    starter = fn app ->
      send(parent, {:started, app})
      {:ok, []}
    end

    output = capture_io(fn -> Decide.run(argv, starter: starter) end)

    assert_received {:started, :req}
    assert {:ok, {_header, lines, run_end}} = Run.read(out)
    assert run_end["answers"] == length(lines)
    assert output =~ out
  end
end
