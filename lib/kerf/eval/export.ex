defmodule Kerf.Eval.Export do
  @moduledoc """
  SPEC_H F08.1 / F08.7 — read-only export of the Decide labelled-set candidates
  from the Spark over ssh + psql, selection toward the language mix, and the
  seeded `Kerf.Eval.Manifest` (plan §6 D2).

  Nothing here writes to the database: the only remote statement is the
  `SELECT` built by `query/1`. Rows hold PII (addresses, subjects, bodies), so
  they only ever land in the private tree; `parse_args/1` refuses output paths
  inside the repo root.
  """

  alias Kerf.Eval.Manifest
  alias Kerf.Eval.Manifest.{Item, Language, Overrides, PII, QuestionSet}

  @type row :: %{
          doc_id: String.t(),
          source_id: String.t() | nil,
          from: String.t() | nil,
          from_name: String.t() | nil,
          subject: String.t() | nil,
          date: String.t() | nil,
          body: String.t(),
          inserted_at: String.t() | nil
        }

  @type config :: %{
          out: Path.t(),
          overrides: Path.t(),
          clients: Path.t(),
          since: String.t(),
          limit: pos_integer(),
          target: pos_integer(),
          host: String.t(),
          db: String.t(),
          raw: Path.t() | nil,
          hashes_out: Path.t() | nil
        }

  @default_since "180d"
  @default_limit 600
  @default_target 220
  @default_host "spark"
  @default_db "kerf_prod"
  @default_set_id "decide-v1"

  # A leading dash would let ssh read the value as an option (S-30).
  @name_pattern ~r/\A[A-Za-z0-9][\w.-]*\z/
  @since_pattern ~r/\A([1-9][0-9]*)d\z/
  @uuid_pattern ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  # NL ≥ 40 %, DE ≥ 25 %, EN ≥ 20 % of the target (F08.1).
  @language_mix [{"nl", 0.40}, {"de", 0.25}, {"en", 0.20}]

  @row_keys ~w(doc_id source_id from from_name subject date body inserted_at)a

  # -- query / ssh ------------------------------------------------------------

  @doc """
  The export `SELECT`, wrapped in `row_to_json`. Options: `:since` (`"180d"`),
  `:limit`, `:override_ids`. Anything that is not a well-formed value is
  replaced by its default or dropped, so no caller input reaches the SQL text
  unchecked.
  """
  @spec query(keyword()) :: String.t()
  def query(opts) do
    days = opts |> Keyword.get(:since) |> since_days()
    limit = positive_or(Keyword.get(opts, :limit), @default_limit)

    ids =
      opts
      |> Keyword.get(:override_ids, [])
      |> Enum.filter(&(is_binary(&1) and Regex.match?(@uuid_pattern, &1)))
      |> Enum.join(",")

    """
    SELECT row_to_json(t) FROM (
    SELECT id AS doc_id, source_id,
      source_metadata->>'sender' AS "from",
      source_metadata->>'sender_name' AS from_name,
      source_metadata->>'subject' AS subject,
      source_metadata->>'date' AS date,
      raw_text AS body, inserted_at
    FROM kb_documents
    WHERE source_type = 'email'
    AND raw_text IS NOT NULL
    AND (inserted_at >= (now() at time zone 'UTC') - interval '#{days} days' OR id = ANY('{#{ids}}'::uuid[]))
    ORDER BY inserted_at DESC, id
    LIMIT #{limit}
    ) t
    """
  end

  @spec ssh_command(String.t(), String.t(), String.t()) :: [String.t()] | {:error, term()}
  def ssh_command(host, db, sql) do
    with :ok <- check_name(:host, host),
         :ok <- check_name(:db, db) do
      [
        "ssh",
        host,
        ~s(export PATH="$HOME/.asdf/shims:$PATH"; psql -d #{db} -At <<'SQL'\n#{sql}\nSQL)
      ]
    end
  end

  @doc """
  Runs the export over ssh. `opts[:runner]` (`([String.t()] -> {String.t(), integer})`)
  defaults to `System.cmd/2`; `opts[:query_fn]` defaults to `query/1`. A failure never echoes the command output, which
  may contain mail.
  """
  @spec fetch_rows(keyword()) :: {:ok, [row()]} | {:error, term()}
  def fetch_rows(opts) do
    host = Keyword.get(opts, :host, @default_host)
    db = Keyword.get(opts, :db, @default_db)
    runner = Keyword.get(opts, :runner, &run_command/1)
    query_fn = Keyword.get(opts, :query_fn, &query/1)

    with argv when is_list(argv) <- ssh_command(host, db, query_fn.(opts)),
         {:ok, output} <- exec(runner, argv) do
      parse_rows(output)
    end
  end

  defp exec(runner, argv) do
    case runner.(argv) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, {:exit_status, status}}
    end
  rescue
    error -> {:error, {:runner_failed, error.__struct__}}
  end

  defp run_command([command | args]) do
    System.cmd(command, args)
  end

  defp check_name(key, value) when is_binary(value) do
    if Regex.match?(@name_pattern, value), do: :ok, else: {:error, {:invalid_name, key}}
  end

  defp check_name(key, _value), do: {:error, {:invalid_name, key}}

  # -- parse ------------------------------------------------------------------

  @spec parse_rows(String.t()) :: {:ok, [row()]} | {:error, term()}
  def parse_rows(jsonl) when is_binary(jsonl) do
    rows =
      jsonl
      |> String.split("\n")
      |> Enum.flat_map(&parse_line/1)

    case rows do
      [] -> {:error, :no_rows}
      rows -> {:ok, rows}
    end
  end

  def parse_rows(_other), do: {:error, :no_rows}

  defp parse_line(line) do
    with line when line != "" <- String.trim(line),
         {:ok, %{"doc_id" => doc_id, "body" => body} = json}
         when is_binary(doc_id) and doc_id != "" and is_binary(body) <- Jason.decode(line) do
      [row_from_json(json)]
    else
      _ -> []
    end
  end

  defp row_from_json(json) do
    Map.new(@row_keys, fn key -> {key, Map.get(json, Atom.to_string(key))} end)
  end

  # -- select -----------------------------------------------------------------

  @doc """
  Picks `opts[:target]` (220) rows: every row that has an override first, then
  newest rows, with per-language minimums filled before the rest. Independent
  of the input order. Overrides are kept even when they exceed the target.
  """
  @spec select([row()], %{String.t() => String.t()}, keyword()) :: [row()]
  def select(rows, overrides, opts) do
    target = positive_or(Keyword.get(opts, :target), @default_target)

    canonical =
      rows
      |> Enum.uniq_by(& &1.doc_id)
      |> Enum.sort_by(& &1.doc_id)
      |> Enum.sort_by(&(&1.inserted_at || ""), :desc)

    {forced, rest} = Enum.split_with(canonical, &Map.has_key?(overrides, &1.doc_id))
    slots = max(target - length(forced), 0)

    already = Enum.frequencies_by(forced, &Language.guess(&1.body))
    {quota_rows, rest} = fill_mix(rest, already, target, slots)
    filler = Enum.take(rest, max(slots - length(quota_rows), 0))

    chosen = MapSet.new(quota_rows ++ filler, & &1.doc_id)
    forced ++ Enum.filter(canonical, &MapSet.member?(chosen, &1.doc_id))
  end

  # Takes, per language in mix order, the newest rows still missing from that
  # language's minimum, never more than the free slots.
  defp fill_mix(rest, already, target, slots) do
    Enum.reduce(@language_mix, {[], rest}, fn {lang, share}, {taken, remaining} ->
      need = ceil(share * target) - Map.get(already, lang, 0)
      room = slots - length(taken)
      count = max(min(need, room), 0)

      {picked, _} =
        remaining
        |> Enum.filter(&(Language.guess(&1.body) == lang))
        |> Enum.split(count)

      ids = MapSet.new(picked, & &1.doc_id)
      {taken ++ picked, Enum.reject(remaining, &MapSet.member?(ids, &1.doc_id))}
    end)
  end

  # -- manifest ---------------------------------------------------------------

  @doc """
  Builds the unfrozen manifest. Options: `:clients`, `:now`, `:host`,
  `:query_sha256`, `:overrides_sha256`, `:set_id`. An item whose `doc_id` has an
  override carries it as `seed_category` with `label_sources["category"] =
  "adjudicated"` (S-29); `labels` stay nil until the owner labels it.
  """
  @spec build_manifest([row()], %{String.t() => String.t()}, keyword()) :: Manifest.t()
  def build_manifest(rows, overrides, opts) do
    now = Keyword.fetch!(opts, :now)
    items = rows |> Enum.with_index(1) |> Enum.map(fn {row, i} -> item(row, i, overrides) end)

    %Manifest{
      set_id: Keyword.get(opts, :set_id, @default_set_id),
      created_at: now,
      export: %{
        host: Keyword.fetch!(opts, :host),
        exported_at: now,
        query_sha256: Keyword.fetch!(opts, :query_sha256),
        overrides_sha256: Keyword.get(opts, :overrides_sha256),
        row_count: length(rows),
        mix_shortfall_acknowledged: false
      },
      question_set: QuestionSet.phase_b(Keyword.fetch!(opts, :clients)),
      counts: counts(items),
      items: items
    }
  end

  defp item(row, i, overrides) do
    seed = Map.get(overrides, row.doc_id)

    %Item{
      id: "it-" <> String.pad_leading(Integer.to_string(i), 4, "0"),
      doc_id: row.doc_id,
      source_id: row.source_id,
      seed_category: seed,
      language: Language.guess(row.body),
      language_source: "heuristic",
      state: %{
        from: row.from || "",
        from_name: row.from_name,
        subject: row.subject || "",
        date: row.date || "",
        body: row.body
      },
      label_sources: if(seed, do: %{"category" => "adjudicated"}, else: %{})
    }
  end

  # Nothing is labelled, tiered, split or paired yet.
  defp counts(items) do
    %{
      total: length(items),
      labelled: 0,
      tiered: 0,
      held_out: 0,
      pairs: 0,
      by_language: Enum.frequencies_by(items, & &1.language),
      by_tier: %{}
    }
  end

  # -- run --------------------------------------------------------------------

  @doc """
  The export end to end, as `mix kerf.eval.export` runs it: parse argv, load the
  overrides and clients, fetch, select, build and save the manifest. `argv` is
  parsed here (S-33), so a bad `--host`/`--db` is an error before the runner or
  `query/1` is reached. Seams: `opts[:runner]`, `opts[:query_fn]`.
  """
  @spec run([String.t()], keyword()) ::
          {:ok, map()} | {:error, String.t() | term()}
  def run(argv, opts) do
    runner = Keyword.get(opts, :runner, &run_command/1)
    query_fn = Keyword.get(opts, :query_fn, &query/1)

    with {:ok, config} <- parse_args(argv),
         :ok <- ensure_absent(config.out),
         {:ok, overrides} <- Overrides.load(config.overrides),
         {:ok, clients} <- read_clients(config.clients),
         {:ok, overrides_sha} <- Manifest.sha256(config.overrides) do
      query_opts = [since: config.since, limit: config.limit, override_ids: Map.keys(overrides)]
      sql = query_fn.(query_opts)

      fetch_opts =
        [host: config.host, db: config.db, runner: runner, query_fn: fn _ -> sql end] ++
          query_opts

      with {:ok, rows} <- fetch_rows(fetch_opts),
           :ok <- write_raw(config.raw, rows) do
        selected = select(rows, overrides, target: config.target)

        manifest =
          build_manifest(selected, overrides,
            clients: clients,
            now: now(),
            host: config.host,
            query_sha256: sha256(sql),
            overrides_sha256: overrides_sha
          )

        with :ok <- write_hashes(config.hashes_out, selected),
             :ok <- Manifest.save(manifest, config.out) do
          {:ok,
           %{
             manifest_path: config.out,
             rows: length(rows),
             selected: length(selected),
             overrides: map_size(overrides),
             hashes_out: config.hashes_out
           }}
        end
      end
    end
  end

  # The hash list lets the PII guard find these senders in tracked files; the
  # path was already checked against the repo root.
  defp write_hashes(nil, _rows), do: :ok

  defp write_hashes(path, rows) do
    case rows |> Enum.map(& &1.from) |> PII.hash_addresses() |> PII.write_hashes(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:hashes_write_failed, reason}}
    end
  end

  # An existing manifest may hold labels, so it is never overwritten.
  defp ensure_absent(path) do
    if File.exists?(path), do: {:error, "#{path} exists; refusing to overwrite it"}, else: :ok
  end

  defp read_clients(path) do
    case File.read(path) do
      {:ok, text} ->
        case text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
          [] -> {:error, "#{path} lists no clients"}
          clients -> {:ok, clients}
        end

      {:error, reason} ->
        {:error, {:clients_unreadable, reason}}
    end
  end

  # The raw rows hold mail; the path was already checked against the repo root.
  defp write_raw(nil, _rows), do: :ok

  defp write_raw(path, rows) do
    lines = Enum.map_join(rows, "", &(Jason.encode!(&1) <> "\n"))

    case File.write(path, lines) do
      :ok -> :ok
      {:error, reason} -> {:error, {:raw_write_failed, reason}}
    end
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # -- argv -------------------------------------------------------------------

  @switches [
    out: :string,
    overrides: :string,
    clients: :string,
    since: :string,
    limit: :integer,
    target: :integer,
    host: :string,
    db: :string,
    raw: :string,
    hashes_out: :string
  ]

  @spec parse_args([String.t()]) :: {:ok, config()} | {:error, String.t()}
  def parse_args(argv) when is_list(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    cond do
      invalid != [] -> {:error, "invalid option(s): " <> invalid_flags(invalid)}
      rest != [] -> {:error, "unexpected argument(s); only --flags are accepted"}
      true -> opts |> Map.new() |> build_config()
    end
  end

  def parse_args(_other), do: {:error, "argv must be a list of strings"}

  defp invalid_flags(invalid), do: invalid |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")

  defp build_config(opts) do
    config = %{
      out: opts[:out],
      overrides: opts[:overrides],
      clients: opts[:clients],
      since: Map.get(opts, :since, @default_since),
      limit: Map.get(opts, :limit, @default_limit),
      target: Map.get(opts, :target, @default_target),
      host: Map.get(opts, :host, @default_host),
      db: Map.get(opts, :db, @default_db),
      raw: opts[:raw],
      hashes_out: opts[:hashes_out]
    }

    with :ok <- required(config, [:out, :overrides, :clients]),
         :ok <- positive(config, [:limit, :target]),
         :ok <- pattern(config.since, @since_pattern, "--since", "like 180d"),
         :ok <- pattern(config.host, @name_pattern, "--host", "a plain host name"),
         :ok <- pattern(config.db, @name_pattern, "--db", "a plain database name"),
         :ok <- outside_repo(config, [:out, :raw, :hashes_out]) do
      {:ok, config}
    end
  end

  defp required(config, keys) do
    case Enum.find(keys, &(config[&1] == nil)) do
      nil -> :ok
      key -> {:error, "missing required #{flag(key)}"}
    end
  end

  defp positive(config, keys) do
    case Enum.find(keys, &(config[&1] < 1)) do
      nil -> :ok
      key -> {:error, "#{flag(key)} must be a positive integer"}
    end
  end

  defp pattern(value, regex, flag, hint) do
    if Regex.match?(regex, value), do: :ok, else: {:error, "#{flag} must be #{hint}"}
  end

  # Exports hold mail; output paths are refused inside the repo root (§3).
  defp outside_repo(config, keys) do
    root = File.cwd!()

    case Enum.find(keys, fn key -> inside?(config[key], root) end) do
      nil -> :ok
      key -> {:error, "#{flag(key)} must not be inside the repo root (#{root})"}
    end
  end

  defp inside?(nil, _root), do: false

  defp inside?(path, root) do
    expanded = Path.expand(path)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  defp flag(key), do: "--" <> (key |> Atom.to_string() |> String.replace("_", "-"))

  # -- small helpers ----------------------------------------------------------

  defp since_days(since) when is_binary(since) do
    case Regex.run(@since_pattern, since) do
      [_, days] -> days
      nil -> since_days(@default_since)
    end
  end

  defp since_days(_other), do: since_days(@default_since)

  defp positive_or(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_or(_value, default), do: default
end
