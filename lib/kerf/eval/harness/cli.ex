defmodule Kerf.Eval.Harness.CLI do
  @moduledoc """
  SPEC_H F09.8 / F09.9 — argv parsing and dispatch for `mix kerf.eval.decide`
  (plan §2.7, §3, §7 H4, S-34).

  `parse_args/1` never raises. Output paths (`--out`, `--report`, `--summary`,
  `--temperature-out`, `--out-dir`) that resolve inside the repo root
  (`File.cwd!()`) are refused: run files and reports hold model answers about
  real mail. `--base-url` follows the HTTP adapter's own host policy —
  loopback or tailnet, compared on the parsed host — unless `--allow-remote`,
  which is forwarded to the adapter as `allow_remote: true`. `run/1` takes raw
  argv and does the work; the mix task only prints and raises.
  """

  alias Kerf.Eval.Harness
  alias Kerf.Eval.Harness.{Report, Run, Score, Selftest}
  alias Kerf.Eval.Manifest

  @type command :: :run | :score | :normalize | :selftest

  @commands %{
    "run" => :run,
    "score" => :score,
    "normalize" => :normalize,
    "selftest" => :selftest
  }

  @aliases %{
    "http" => Kerf.Decide.Adapter.HTTP,
    "random" => Kerf.Eval.Adapters.Random,
    "oracle" => Kerf.Eval.Adapters.Oracle
  }

  # The in-process eval adapters take no options (plan §2.6).
  @optionless [Kerf.Eval.Adapters.Random, Kerf.Eval.Adapters.Oracle]
  @adapter_flags [:base_url, :timeout, :allow_remote]

  @switches %{
    run: [
      manifest: :string,
      out: :string,
      adapter: :string,
      seed: :integer,
      base_url: :string,
      allow_remote: :boolean,
      timeout: :string,
      permutations: :integer,
      isolation_items: :integer,
      limit: :integer,
      skip_latency: :boolean
    ],
    score: [
      manifest: :string,
      run: :string,
      report: :string,
      summary: :string,
      baseline_accuracy: :float,
      host_class: :string,
      temperature_out: :string
    ],
    normalize: [run: :string, out: :string],
    selftest: [out_dir: :string, manifest: :string, seed: :integer]
  }

  @required %{
    run: [:manifest, :out, :adapter, :seed],
    score: [:manifest, :run, :report, :summary],
    normalize: [:run, :out],
    selftest: [:out_dir]
  }

  @outputs %{
    run: [:out],
    score: [:report, :summary, :temperature_out],
    normalize: [:out],
    selftest: [:out_dir]
  }

  # ---------- parsing ----------

  @spec parse_args(term()) ::
          {:ok, %{required(:command) => command(), optional(atom()) => term()}}
          | {:error, String.t()}
  def parse_args([command | argv]) when is_binary(command) do
    with {:ok, command} <- command(command),
         :ok <- all_strings(argv) do
      case OptionParser.parse(argv, strict: @switches[command]) do
        {opts, [], []} ->
          build(command, Map.new(opts))

        {_opts, [_ | _], _invalid} ->
          {:error, "unexpected argument(s); only --flags are accepted"}

        {_opts, [], invalid} ->
          {:error, "invalid option(s): " <> invalid_flags(invalid)}
      end
    end
  end

  def parse_args(_argv), do: {:error, usage()}

  defp command(name) do
    case Map.fetch(@commands, name) do
      {:ok, command} -> {:ok, command}
      :error -> {:error, "unknown command #{inspect(name)}; " <> usage()}
    end
  end

  defp all_strings(argv) do
    if Enum.all?(argv, &is_binary/1), do: :ok, else: {:error, "argv must be a list of strings"}
  end

  defp invalid_flags(invalid), do: Enum.map_join(invalid, ", ", &elem(&1, 0))

  defp usage, do: "usage: mix kerf.eval.decide run|score|normalize|selftest [flags]"

  defp build(command, opts) do
    with :ok <- required(command, opts),
         :ok <- outside_repo(command, opts) do
      config(command, opts)
    end
  end

  defp required(command, opts) do
    case Enum.find(@required[command], &(opts[&1] == nil)) do
      nil -> :ok
      key -> {:error, "missing required #{flag(key)}"}
    end
  end

  # Run files and reports describe real mail; they never land inside the repo (§3).
  defp outside_repo(command, opts) do
    root = File.cwd!()

    case Enum.find(@outputs[command], &inside?(opts[&1], root)) do
      nil -> :ok
      key -> {:error, "#{flag(key)} must not be inside the repo root (#{root})"}
    end
  end

  defp inside?(nil, _root), do: false

  defp inside?(path, root) do
    expanded = Path.expand(path)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  defp config(:run, opts) do
    with {:ok, adapter} <- adapter(opts.adapter),
         {:ok, adapter_opts} <- adapter_opts(adapter, opts) do
      {:ok,
       %{
         command: :run,
         manifest: opts.manifest,
         out: opts.out,
         adapter: adapter,
         adapter_opts: adapter_opts,
         seed: opts.seed,
         permutations: Map.get(opts, :permutations, 6),
         isolation_items: Map.get(opts, :isolation_items, 30),
         limit: opts[:limit],
         skip_latency: Map.get(opts, :skip_latency, false)
       }}
    end
  end

  defp config(:score, opts) do
    with {:ok, host_class} <- host_class(opts[:host_class]) do
      {:ok,
       %{
         command: :score,
         manifest: opts.manifest,
         run: opts.run,
         report: opts.report,
         summary: opts.summary,
         baseline_accuracy: opts[:baseline_accuracy],
         host_class: host_class,
         temperature_out: opts[:temperature_out]
       }}
    end
  end

  defp config(:normalize, opts), do: {:ok, %{command: :normalize, run: opts.run, out: opts.out}}

  defp config(:selftest, opts) do
    manifest = if opts[:manifest] == "synthetic", do: nil, else: opts[:manifest]

    {:ok,
     %{
       command: :selftest,
       out_dir: opts.out_dir,
       manifest: manifest,
       seed: Map.get(opts, :seed, 1)
     }}
  end

  defp host_class(nil), do: {:ok, nil}
  defp host_class("decoder"), do: {:ok, :decoder}
  defp host_class("encoder"), do: {:ok, :encoder}
  defp host_class(_other), do: {:error, "--host-class must be decoder or encoder"}

  # ---------- adapters ----------

  # Module.safe_concat/1 only resolves existing atoms; an unknown name never
  # creates one.
  defp adapter("Elixir." <> _ = name) do
    module = Module.safe_concat([name])

    if adapter_module?(module),
      do: {:ok, module},
      else: {:error, "--adapter #{name} is not a Kerf.Decide adapter"}
  rescue
    ArgumentError -> {:error, "--adapter #{name}: no such module"}
  end

  defp adapter(name) do
    case Map.fetch(@aliases, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "--adapter must be http, random, oracle or Elixir.<Module>"}
    end
  end

  defp adapter_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :ask, 3) and
      function_exported?(module, :info, 0)
  end

  defp adapter_opts(adapter, opts) when adapter in @optionless do
    case Enum.find(@adapter_flags, &Map.has_key?(opts, &1)) do
      nil -> {:ok, []}
      key -> {:error, "#{flag(key)} is not accepted with --adapter #{inspect(adapter)}"}
    end
  end

  defp adapter_opts(_adapter, opts) do
    allow_remote? = Map.get(opts, :allow_remote, false) == true

    with {:ok, base_url} <- base_url(opts[:base_url], allow_remote?),
         {:ok, timeout} <- timeout(opts[:timeout]) do
      remote = if allow_remote?, do: [allow_remote: true], else: []
      {:ok, base_url ++ timeout ++ remote}
    end
  end

  defp base_url(nil, _allow_remote?), do: {:ok, []}

  defp base_url(url, allow_remote?) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] or uri.host in [nil, ""] ->
        {:error, "--base-url must be an http(s) URL with a host"}

      allow_remote? or local_host?(uri.host) ->
        {:ok, [base_url: url]}

      true ->
        {:error,
         "--base-url host #{uri.host} is not loopback or tailnet; pass --allow-remote to use it"}
    end
  end

  # Mirrors Kerf.Decide.Adapter.HTTP's host policy (S-34): the exact name
  # "localhost", or a parsed address in 127.0.0.0/8, 100.64.0.0/10 or ::1.
  defp local_host?("localhost"), do: true

  defp local_host?(host) do
    address = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {100, b, _, _}} when b in 64..127 -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _other -> false
    end
  end

  defp timeout(nil), do: {:ok, []}

  defp timeout(value) do
    case Integer.parse(value) do
      {ms, ""} when ms > 0 -> {:ok, [timeout: ms]}
      _other -> {:error, "--timeout must be a positive integer (milliseconds)"}
    end
  end

  defp flag(key), do: "--" <> (key |> Atom.to_string() |> String.replace("_", "-"))

  # ---------- help ----------

  @spec help(command()) :: String.t()
  def help(:run) do
    """
    mix kerf.eval.decide run --manifest M --out run.jsonl --seed N
                             --adapter http|random|oracle|Elixir.Module
                             [--base-url URL] [--allow-remote] [--timeout MS]
                             [--permutations 6] [--isolation-items 30] [--limit N] [--skip-latency]

    Runs a frozen manifest through the adapter and writes the run JSONL to exactly --out.
    --limit N runs the first N items in manifest order;
    isolation items are chosen from the eval items in that scope.
    A limited run marks every gate "pending".
    --base-url must be loopback or tailnet unless --allow-remote. random and oracle take
    no adapter flags and imply latency_skipped; --skip-latency sets it for other adapters.
    """
  end

  def help(:score) do
    """
    mix kerf.eval.decide score --manifest M --run run.jsonl --report report.json --summary report.md
                               [--baseline-accuracy F] [--host-class decoder|encoder]
                               [--temperature-out temperatures.json]

    Scores a run file and prints the report's sha256.
    """
  end

  def help(:normalize) do
    """
    mix kerf.eval.decide normalize --run run.jsonl --out run.norm.jsonl

    Drops latency_ms, started_at, finished_at and run_id so two runs compare byte-for-byte.
    """
  end

  def help(:selftest) do
    """
    mix kerf.eval.decide selftest --out-dir DIR [--manifest M|synthetic] [--seed N]

    F09.9: a random run and two oracle runs, scored and checked; artefacts under --out-dir.
    """
  end

  # ---------- dispatch ----------

  @spec run(term()) :: {:ok, map()} | {:error, term()}
  def run(argv) do
    with {:ok, config} <- parse_args(argv), do: execute(config)
  end

  defp execute(%{command: :run} = config) do
    with {:ok, manifest} <- Manifest.load(config.manifest),
         :ok <- Manifest.ready_for_run?(manifest),
         {:ok, file} <- File.open(config.out, [:write, :binary]) do
      result =
        try do
          Harness.run(manifest, harness_opts(config, file))
        after
          File.close(file)
        end

      case result do
        {:ok, %{end: run_end}} ->
          {:ok,
           %{
             command: :run,
             out: config.out,
             answers: run_end["answers"],
             errors: run_end["errors"]
           }}

        {:error, _reason} = error ->
          _ = File.rm(config.out)
          error
      end
    end
  end

  defp execute(%{command: :score} = config) do
    with {:ok, manifest} <- Manifest.load(config.manifest),
         {:ok, {header, lines, _run_end}} <- Run.read(config.run) do
      report =
        Score.score(header, lines, manifest.items,
          baseline_accuracy: config.baseline_accuracy,
          host_class: config.host_class
        )

      json = IO.iodata_to_binary(Report.to_json(report))

      with :ok <- File.write(config.report, json),
           :ok <- File.write(config.summary, Report.to_markdown(report)),
           :ok <- write_temperatures(config.temperature_out, report) do
        {:ok, %{command: :score, report: config.report, report_sha256: sha256(json)}}
      end
    end
  end

  defp execute(%{command: :normalize} = config) do
    with {:ok, text} <- File.read(config.run),
         {:ok, normalized} <- Run.normalize(text),
         :ok <- File.write(config.out, normalized) do
      {:ok, %{command: :normalize, out: config.out}}
    end
  end

  defp execute(%{command: :selftest} = config) do
    manifest = if config.manifest, do: [manifest: config.manifest], else: []
    Selftest.run(config.out_dir, [seed: config.seed] ++ manifest)
  end

  # Lines are streamed to --out as they are produced (plan §2.7).
  defp harness_opts(config, file) do
    [
      adapter: config.adapter,
      adapter_opts: config.adapter_opts,
      manifest_path: config.manifest,
      seed: config.seed,
      permutations: config.permutations,
      isolation_items: config.isolation_items,
      limit: config.limit,
      skip_latency: config.skip_latency,
      sink: fn line -> IO.binwrite(file, Run.encode(line) <> "\n") end
    ]
  end

  defp write_temperatures(nil, _report), do: :ok

  defp write_temperatures(path, report),
    do: File.write(path, Jason.encode!(report["temperature"]))

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
