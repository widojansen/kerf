defmodule Kerf.Eval.Harness.CLITest do
  @moduledoc """
  SPEC_H F09.8 / F09.9 / F09.5 — `mix kerf.eval.decide` argv parsing, the §3
  repo-root refusal, the `--limit` help text and the CLI dispatch
  (plan §2.7, §3, §7 H4; lead pins 1–8 of the H4 dispatch, S-34).

  `CLI.run/1` takes raw argv and does the work; the mix task only wires
  `Mix.raise/1` and printing (S-33 precedent). Output paths always live under
  `System.tmp_dir!()`: anything under `File.cwd!()` is refused by design.
  Manifests come from `Manifest.Synthetic` only.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kerf.Eval.Adapters.{Oracle, Random}
  alias Kerf.Eval.Harness
  alias Kerf.Eval.Harness.{CLI, Report, Run, Score}
  alias Kerf.Eval.Manifest
  alias Kerf.Eval.Manifest.Synthetic

  @stub "Elixir.Kerf.Eval.Harness.CLITest.StubAdapter"

  # ---------- stub adapter ----------

  defmodule StubAdapter do
    @moduledoc false
    @behaviour Kerf.Decide.Adapter

    alias Kerf.Decide.OptionSet
    alias Kerf.Decide.Question.{Choice, Noul, Score}

    @impl true
    def ask(_state, questions, _opts) do
      {:ok,
       Map.new(questions, fn
         %Noul{name: name} ->
           {name, %{p_yes: 0.5}}

         %Choice{name: name, options: options} ->
           {name, %{probs: uniform(OptionSet.labels(options))}}

         %Score{name: name, levels: levels} ->
           {name, %{expected: (length(levels) - 1) / 2, probs: uniform(levels), confidence: 0.0}}
       end)}
    end

    @impl true
    def info,
      do: %{
        model_id: "eval-stub",
        types: [:noul, :choice, :score],
        max_state_tokens: 8192,
        languages: ["nl", "de", "en"]
      }

    defp uniform(labels), do: Enum.map(labels, &{&1, 1 / length(labels)})
  end

  # ---------- helpers ----------

  defp tmp_dir! do
    dir =
      Path.join(System.tmp_dir!(), "kerf_eval_cli_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp saved_manifest(opts \\ [n: 8, pairs: 2]) do
    path = Path.join(tmp_dir!(), "manifest.json")
    :ok = Manifest.save(Synthetic.build(opts), path)
    path
  end

  defp run_argv(manifest, out, extra \\ []) do
    ["run", "--manifest", manifest, "--out", out, "--adapter", "oracle", "--seed", "7"] ++ extra
  end

  defp score_argv(manifest, run, dir, extra \\ []) do
    [
      "score",
      "--manifest",
      manifest,
      "--run",
      run,
      "--report",
      Path.join(dir, "report.json"),
      "--summary",
      Path.join(dir, "report.md")
    ] ++ extra
  end

  defp http_argv(extra) do
    run_argv("/nonexistent/manifest.json", Path.join(System.tmp_dir!(), "run.jsonl"))
    |> replace_flag("--adapter", "http")
    |> Kernel.++(extra)
  end

  defp replace_flag(argv, flag, value) do
    index = Enum.find_index(argv, &(&1 == flag))
    List.replace_at(argv, index + 1, value)
  end

  defp drop_flag(argv, flag) do
    index = Enum.find_index(argv, &(&1 == flag))
    List.delete_at(List.delete_at(argv, index + 1), index)
  end

  defp written_run(extra \\ []) do
    manifest = saved_manifest()
    out = Path.join(tmp_dir!(), "run.jsonl")
    assert {:ok, _} = CLI.run(run_argv(manifest, out, extra))
    {manifest, out}
  end

  defp output_flag_cases do
    tmp = System.tmp_dir!()

    [
      {run_argv("/m/manifest.json", Path.join(tmp, "run.jsonl")), "--out"},
      {score_argv("/m/manifest.json", "/r/run.jsonl", tmp), "--report"},
      {score_argv("/m/manifest.json", "/r/run.jsonl", tmp), "--summary"},
      {score_argv("/m/manifest.json", "/r/run.jsonl", tmp, [
         "--temperature-out",
         Path.join(tmp, "temperatures.json")
       ]), "--temperature-out"},
      {["normalize", "--run", "/r/run.jsonl", "--out", Path.join(tmp, "n.jsonl")], "--out"},
      {["selftest", "--out-dir", Path.join(tmp, "selftest")], "--out-dir"}
    ]
  end

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  # ---------- parse_args/1: run ----------

  describe "parse_args/1 — run (§2.7)" do
    test "parses every run flag" do
      argv =
        run_argv("/m/manifest.json", "/o/run.jsonl", [
          "--permutations",
          "2",
          "--isolation-items",
          "4",
          "--limit",
          "3",
          "--skip-latency"
        ])

      assert {:ok, config} = CLI.parse_args(argv)
      assert config.command == :run
      assert config.manifest == "/m/manifest.json"
      assert config.out == "/o/run.jsonl"
      assert config.adapter == Oracle
      assert config.seed == 7
      assert config.permutations == 2
      assert config.isolation_items == 4
      assert config.limit == 3
      assert config.skip_latency == true
    end

    test "defaults: 6 permutations, 30 isolation items, no limit, latency kept, no adapter opts" do
      assert {:ok, config} = CLI.parse_args(run_argv("/m/manifest.json", "/o/run.jsonl"))
      assert config.permutations == 6
      assert config.isolation_items == 30
      assert config.limit == nil
      assert config.skip_latency == false
      assert config.adapter_opts == []
    end

    test "each missing required flag is an error naming the flag" do
      argv = run_argv("/m/manifest.json", "/o/run.jsonl")

      for flag <- ~w(--manifest --out --adapter --seed) do
        assert {:error, message} = CLI.parse_args(drop_flag(argv, flag)), flag
        assert message =~ flag
      end
    end

    test "a non-integer --seed is an error naming --seed" do
      argv = replace_flag(run_argv("/m/manifest.json", "/o/run.jsonl"), "--seed", "abc")
      assert {:error, message} = CLI.parse_args(argv)
      assert message =~ "--seed"
    end

    test "the adapter alias table" do
      argv = run_argv("/m/manifest.json", "/o/run.jsonl")

      for {alias_name, module} <- [
            {"http", Kerf.Decide.Adapter.HTTP},
            {"random", Random},
            {"oracle", Oracle},
            {@stub, StubAdapter}
          ] do
        assert {:ok, %{adapter: ^module}} =
                 CLI.parse_args(replace_flag(argv, "--adapter", alias_name)),
               alias_name
      end
    end

    test "an unknown alias is an error" do
      argv = replace_flag(run_argv("/m/manifest.json", "/o/run.jsonl"), "--adapter", "gpt")
      assert {:error, message} = CLI.parse_args(argv)
      assert message =~ "--adapter"
    end

    test "an Elixir.* name of no existing module is an error and creates no atom" do
      name = "Elixir.Kerf.Eval.NoSuchAdapter#{System.unique_integer([:positive])}"
      argv = replace_flag(run_argv("/m/manifest.json", "/o/run.jsonl"), "--adapter", name)

      assert {:error, _message} = CLI.parse_args(argv)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "an existing module that is not a Decide adapter is an error" do
      argv =
        replace_flag(run_argv("/m/manifest.json", "/o/run.jsonl"), "--adapter", "Elixir.Enum")

      assert {:error, message} = CLI.parse_args(argv)
      assert message =~ "--adapter"
    end
  end

  # ---------- parse_args/1: --base-url, --timeout, --allow-remote (pin 7, S-34) ----------

  describe "parse_args/1 — HTTP adapter options (pin 7, S-34)" do
    test "loopback and tailnet hosts are accepted and passed as adapter_opts base_url" do
      for url <- ~w(http://127.0.0.1:8900 http://localhost:8900 http://[::1]:8900
                    http://100.100.1.2:8900) do
        assert {:ok, config} = CLI.parse_args(http_argv(["--base-url", url])), url
        assert config.adapter_opts[:base_url] == url
        refute Keyword.has_key?(config.adapter_opts, :allow_remote)
      end
    end

    test "any other host is refused without --allow-remote — exact host, no prefix match" do
      for url <- ~w(http://localhost.evil.example:8900 http://127.0.0.1.example.invalid:8900
                    http://example.invalid:8900 http://10.0.0.5:8900 http://100.128.0.1:8900) do
        assert {:error, message} = CLI.parse_args(http_argv(["--base-url", url])), url
        assert message =~ "--allow-remote"
      end
    end

    test "--allow-remote accepts a remote host and is passed to the adapter" do
      argv = http_argv(["--base-url", "http://example.invalid:8900", "--allow-remote"])
      assert {:ok, config} = CLI.parse_args(argv)
      assert config.adapter_opts[:base_url] == "http://example.invalid:8900"
      assert config.adapter_opts[:allow_remote] == true
    end

    test "a --base-url without an http(s) scheme and host is an error" do
      for url <- ~w(127.0.0.1:8900 ftp://127.0.0.1:8900 http://) do
        assert {:error, message} = CLI.parse_args(http_argv(["--base-url", url])), url
        assert message =~ "--base-url"
      end
    end

    test "--timeout is passed as adapter_opts timeout and must be a positive integer" do
      assert {:ok, config} = CLI.parse_args(http_argv(["--timeout", "500"]))
      assert config.adapter_opts[:timeout] == 500

      for bad <- ~w(0 -5 soon) do
        assert {:error, message} = CLI.parse_args(http_argv(["--timeout", bad])), bad
        assert message =~ "--timeout"
      end
    end

    test "http without --base-url leaves base_url to the adapter's config" do
      assert {:ok, config} = CLI.parse_args(http_argv([]))
      refute Keyword.has_key?(config.adapter_opts, :base_url)
    end

    test "random and oracle take no adapter options" do
      for adapter <- ~w(random oracle),
          extra <- [
            ["--base-url", "http://127.0.0.1:8900"],
            ["--timeout", "500"],
            ["--allow-remote"]
          ] do
        argv = replace_flag(http_argv(extra), "--adapter", adapter)
        assert {:error, message} = CLI.parse_args(argv), "#{adapter} #{inspect(extra)}"
        assert message =~ hd(extra)
      end
    end

    test "a custom adapter module receives --base-url and --timeout" do
      argv =
        replace_flag(
          http_argv(["--base-url", "http://127.0.0.1:8900", "--timeout", "250"]),
          "--adapter",
          @stub
        )

      assert {:ok, config} = CLI.parse_args(argv)
      assert config.adapter_opts[:base_url] == "http://127.0.0.1:8900"
      assert config.adapter_opts[:timeout] == 250
    end
  end

  # ---------- parse_args/1: score, normalize, selftest, malformed argv ----------

  describe "parse_args/1 — score, normalize, selftest (§2.7)" do
    test "score parses its flags; --host-class becomes an atom" do
      argv =
        score_argv("/m/manifest.json", "/r/run.jsonl", "/o", [
          "--baseline-accuracy",
          "0.5",
          "--host-class",
          "decoder",
          "--temperature-out",
          "/o/temperatures.json"
        ])

      assert {:ok, config} = CLI.parse_args(argv)
      assert config.command == :score
      assert config.manifest == "/m/manifest.json"
      assert config.run == "/r/run.jsonl"
      assert config.report == "/o/report.json"
      assert config.summary == "/o/report.md"
      assert config.baseline_accuracy == 0.5
      assert config.host_class == :decoder
      assert config.temperature_out == "/o/temperatures.json"

      assert {:ok, %{host_class: :encoder}} =
               CLI.parse_args(replace_flag(argv, "--host-class", "encoder"))
    end

    test "score defaults: no baseline, no host class, no temperature file" do
      assert {:ok, config} = CLI.parse_args(score_argv("/m/manifest.json", "/r/run.jsonl", "/o"))
      assert config.baseline_accuracy == nil
      assert config.host_class == nil
      assert config.temperature_out == nil
    end

    test "an unknown --host-class is an error" do
      argv = score_argv("/m/manifest.json", "/r/run.jsonl", "/o", ["--host-class", "gpu"])
      assert {:error, message} = CLI.parse_args(argv)
      assert message =~ "--host-class"
    end

    test "score: each missing required flag is an error naming the flag" do
      argv = score_argv("/m/manifest.json", "/r/run.jsonl", "/o")

      for flag <- ~w(--manifest --run --report --summary) do
        assert {:error, message} = CLI.parse_args(drop_flag(argv, flag)), flag
        assert message =~ flag
      end
    end

    test "normalize parses --run and --out, both required" do
      argv = ["normalize", "--run", "/r/run.jsonl", "--out", "/o/run.norm.jsonl"]

      assert {:ok, %{command: :normalize, run: "/r/run.jsonl", out: "/o/run.norm.jsonl"}} =
               CLI.parse_args(argv)

      for flag <- ~w(--run --out) do
        assert {:error, message} = CLI.parse_args(drop_flag(argv, flag)), flag
        assert message =~ flag
      end
    end

    test "selftest requires --out-dir; --manifest and --seed are optional" do
      assert {:ok, config} = CLI.parse_args(["selftest", "--out-dir", "/o/selftest"])
      assert config.command == :selftest
      assert config.out_dir == "/o/selftest"
      assert config.manifest == nil
      assert config.seed == 1

      assert {:ok, %{manifest: "/m/manifest.json", seed: 4}} =
               CLI.parse_args(
                 ~w(selftest --out-dir /o/selftest --manifest /m/manifest.json --seed 4)
               )

      assert {:error, message} = CLI.parse_args(["selftest"])
      assert message =~ "--out-dir"
    end

    test "selftest --manifest synthetic equals the default" do
      assert CLI.parse_args(~w(selftest --out-dir /o/selftest --manifest synthetic)) ==
               CLI.parse_args(~w(selftest --out-dir /o/selftest))
    end

    test "malformed argv is an error, never a raise" do
      for argv <- [
            [],
            ["frobnicate"],
            ["run", "stray"] ++ tl(run_argv("/m/manifest.json", "/o/run.jsonl")),
            run_argv("/m/manifest.json", "/o/run.jsonl", ["--no-such-flag"]),
            :not_a_list,
            [:not_a_string]
          ] do
        assert {:error, message} = CLI.parse_args(argv), inspect(argv)
        assert is_binary(message)
      end
    end
  end

  # ---------- repo-root refusal (pin 2, §3) ----------

  describe "parse_args/1 — output paths inside the repo root are refused (pin 2, §3)" do
    test "a System.tmp_dir!() path is accepted for every output flag" do
      for {argv, flag} <- output_flag_cases() do
        assert {:ok, _config} = CLI.parse_args(argv), flag
      end
    end

    test "an absolute path inside File.cwd!() is refused, naming the flag" do
      inside = Path.join([File.cwd!(), "tmp", "eval_out"])

      for {argv, flag} <- output_flag_cases() do
        assert {:error, message} = CLI.parse_args(replace_flag(argv, flag, inside)), flag
        assert message =~ flag
      end
    end

    test "a relative path (it resolves inside File.cwd!()) is refused, naming the flag" do
      for {argv, flag} <- output_flag_cases() do
        assert {:error, message} = CLI.parse_args(replace_flag(argv, flag, "out.jsonl")), flag
        assert message =~ flag
      end
    end

    test "File.cwd!() itself is refused" do
      argv = ["selftest", "--out-dir", File.cwd!()]
      assert {:error, message} = CLI.parse_args(argv)
      assert message =~ "--out-dir"
    end
  end

  # ---------- help/1 (pin 1) ----------

  describe "help/1 (pin 1)" do
    test "run help states --limit's scope semantics" do
      text = CLI.help(:run)
      assert text =~ "--limit"
      assert text =~ ~r/first N items in manifest order/i
      assert text =~ ~r/isolation items are chosen from the eval items in that scope/i
    end

    test "each command's help names its required flags" do
      for {command, flags} <- [
            run: ~w(--manifest --out --adapter --seed),
            score: ~w(--manifest --run --report --summary),
            normalize: ~w(--run --out),
            selftest: ~w(--out-dir)
          ],
          flag <- flags do
        assert CLI.help(command) =~ flag, "#{command} #{flag}"
      end
    end
  end

  # ---------- Harness.run/2 option errors (pin 3) ----------

  # harness.ex:37 `adapter = Keyword.fetch!(opts, :adapter)`, :84
  # `seed = Keyword.fetch!(opts, :seed)` and `Manifest.sha256(nil)` (File.read(nil))
  # raise at 8e7db9b; the CLI always passes them, Harness.run/2 must not rely on it.
  describe "Harness.run/2 with missing options (pin 3)" do
    setup do
      path = saved_manifest()
      {:ok, manifest} = Manifest.load(path)
      %{manifest: manifest, path: path}
    end

    test "manifest_path nil → {:error, {:manifest_sha256, _}}", %{manifest: manifest} do
      assert {:error, {:manifest_sha256, _reason}} =
               Harness.run(manifest, adapter: Oracle, seed: 7, manifest_path: nil)
    end

    test "no :manifest_path → {:error, {:manifest_sha256, _}}", %{manifest: manifest} do
      assert {:error, {:manifest_sha256, _reason}} =
               Harness.run(manifest, adapter: Oracle, seed: 7)
    end

    test "no :adapter → {:error, {:missing_option, :adapter}}", %{manifest: m, path: path} do
      assert {:error, {:missing_option, :adapter}} = Harness.run(m, seed: 7, manifest_path: path)
    end

    test "no :seed → {:error, {:missing_option, :seed}}", %{manifest: m, path: path} do
      assert {:error, {:missing_option, :seed}} =
               Harness.run(m, adapter: Oracle, manifest_path: path)
    end
  end

  # ---------- run/1: the subcommands end to end ----------

  describe "run/1 — run (pins 4, 5, 6)" do
    test "the run file is written at exactly --out and nothing else is created" do
      manifest = saved_manifest()
      dir = tmp_dir!()
      out = Path.join(dir, "decide-run.jsonl")

      assert {:ok, _result} = CLI.run(run_argv(manifest, out))
      assert File.ls!(dir) == ["decide-run.jsonl"]

      assert {:ok, {header, lines, run_end}} = Run.read(out)
      assert header["manifest_path"] == manifest
      assert header["adapter"] == inspect(Oracle)
      assert length(lines) == 368
      assert run_end["answers"] == 368
    end

    test "--limit is recorded in the header and every gate of its report is pending" do
      {manifest, out} = written_run(["--limit", "3"])
      assert {:ok, {header, _lines, _end}} = Run.read(out)
      assert header["limit"] == 3

      dir = tmp_dir!()
      assert {:ok, _} = CLI.run(score_argv(manifest, out, dir, ["--baseline-accuracy", "0.5"]))
      report = dir |> Path.join("report.json") |> File.read!() |> Jason.decode!()

      assert map_size(report["gates"]) == 7
      assert Enum.all?(report["gates"], fn {_id, gate} -> gate["status"] == "pending" end)
    end

    test "an unready manifest is refused and no run file is written (F08.4)" do
      manifest = saved_manifest(n: 8, pairs: 2, frozen: false)
      out = Path.join(tmp_dir!(), "run.jsonl")

      assert {:error, _reason} = CLI.run(run_argv(manifest, out))
      refute File.exists?(out)
    end

    test "random and oracle imply latency_skipped; --skip-latency sets it for others" do
      for {adapter, extra, expected} <- [
            {"random", [], true},
            {"oracle", [], true},
            {@stub, [], false},
            {@stub, ["--skip-latency"], true}
          ] do
        manifest = saved_manifest()
        out = Path.join(tmp_dir!(), "run.jsonl")
        argv = replace_flag(run_argv(manifest, out, extra), "--adapter", adapter)

        assert {:ok, _} = CLI.run(argv), adapter
        assert {:ok, {header, _lines, _end}} = Run.read(out)
        assert header["latency_skipped"] == expected, "#{adapter} #{inspect(extra)}"
      end
    end

    test "a refused argv writes nothing" do
      manifest = saved_manifest()
      out = Path.join(File.cwd!(), "refused-run-#{System.unique_integer([:positive])}.jsonl")

      assert {:error, _message} = CLI.run(run_argv(manifest, out))
      refute File.exists?(out)
    end
  end

  describe "run/1 — score and normalize" do
    test "score writes the report, the summary and the temperatures; returns the report sha256" do
      {manifest, out} = written_run()
      dir = tmp_dir!()
      temperatures = Path.join(dir, "temperatures.json")

      argv =
        score_argv(manifest, out, dir, [
          "--baseline-accuracy",
          "0.5",
          "--host-class",
          "decoder",
          "--temperature-out",
          temperatures
        ])

      assert {:ok, result} = CLI.run(argv)
      report_path = Path.join(dir, "report.json")
      assert result.report_sha256 == sha256(report_path)

      {:ok, loaded} = Manifest.load(manifest)
      {:ok, {header, lines, _end}} = Run.read(out)

      expected =
        Score.score(header, lines, loaded.items, baseline_accuracy: 0.5, host_class: :decoder)

      assert File.read!(report_path) == IO.iodata_to_binary(Report.to_json(expected))
      assert File.read!(Path.join(dir, "report.md")) == Report.to_markdown(expected)
      assert Jason.decode!(File.read!(temperatures)) == expected["temperature"]
    end

    test "normalize writes Run.normalize/1 of the run file at --out" do
      {_manifest, out} = written_run()
      norm = Path.join(tmp_dir!(), "run.norm.jsonl")

      assert {:ok, _} = CLI.run(["normalize", "--run", out, "--out", norm])
      assert {:ok, expected} = Run.normalize(File.read!(out))
      assert File.read!(norm) == expected
    end

    test "a missing --run file is an error, never a raise" do
      norm = Path.join(tmp_dir!(), "run.norm.jsonl")
      missing = Path.join(tmp_dir!(), "missing.jsonl")
      assert {:error, _reason} = CLI.run(["normalize", "--run", missing, "--out", norm])
    end
  end

  # ---------- the mix task ----------

  describe "mix kerf.eval.decide" do
    test "a refused argv raises Mix.Error with the message" do
      error =
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Kerf.Eval.Decide.run(["selftest", "--out-dir", File.cwd!()])
        end

      assert error.message =~ "--out-dir"
    end

    test "score prints the report's sha256" do
      {manifest, out} = written_run()
      dir = tmp_dir!()

      output =
        capture_io(fn ->
          Mix.Tasks.Kerf.Eval.Decide.run(score_argv(manifest, out, dir))
        end)

      assert output =~ sha256(Path.join(dir, "report.json"))
    end
  end
end
