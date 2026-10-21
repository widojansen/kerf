defmodule Kerf.Eval.ExportTest do
  @moduledoc """
  SPEC_H F08.1 (export with From/Subject/Date from source_metadata) and F08.7
  (seeding from golden-overrides) — plan §6 D2
  (docs/superpowers/plans/2026-10-20-decide-eval-step2-3.md), rulings S-27
  (`--db` default) and S-29 (`Item.seed_category`).

  Rows and overrides are hand-built; no real data. Struct-level assertions on
  the fields that land in GREEN (`source_id`, `seed_category`) are map-pattern
  matches, never `%Item{...}` literals, so the RED compiles and fails in-body.
  """
  use ExUnit.Case, async: true

  alias Kerf.Decide.OptionSet
  alias Kerf.Eval.Export
  alias Kerf.Eval.Manifest
  alias Kerf.Eval.Manifest.{Language, QuestionSet}
  alias Mix.Tasks.Kerf.Eval.Freeze

  @now "2026-10-21T09:00:00Z"

  @bodies %{
    "nl" =>
      "Hallo, ik heb een vraag over de planning van het project. Kun je me laten weten wat de stand is?",
    "de" =>
      "Hallo, ich habe eine Frage zur Planung des Projekts. Kannst du mir den Stand mitteilen?",
    "en" =>
      "Hello, I have a question about the planning of the project. Could you let me know the status?"
  }

  # -- helpers ---------------------------------------------------------------

  defp uuid(i),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(i), 12, "0")

  defp row(i, lang) do
    %{
      doc_id: uuid(i),
      source_id: "msg-#{i}",
      from: "user#{i}@example.invalid",
      from_name: if(rem(i, 2) == 0, do: "User #{i}", else: nil),
      subject: "Subject #{i}",
      date: "2026-10-01T08:00:00Z",
      body: @bodies[lang],
      inserted_at: "2026-10-01T08:00:00"
    }
  end

  # newest first: 120 nl, then 60 de, then 60 en — a plain "take the newest N"
  # would be all Dutch.
  defp pool do
    Enum.map(1..120, &row(&1, "nl")) ++
      Enum.map(121..180, &row(&1, "de")) ++
      Enum.map(181..240, &row(&1, "en"))
  end

  defp category, do: hd(OptionSet.labels(OptionSet.triage_categories()))

  defp lang_counts(rows), do: Enum.frequencies_by(rows, &Language.guess(&1.body))

  defp tmp_dir! do
    dir =
      Path.join(System.tmp_dir!(), "kerf_eval_export_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp json_line(i, lang), do: i |> row(lang) |> Jason.encode!()

  defp overrides, do: %{uuid(5) => category(), uuid(130) => category(), uuid(200) => category()}

  defp drop_flag(args, flag) do
    args |> Enum.chunk_every(2) |> Enum.reject(&(hd(&1) == flag)) |> List.flatten()
  end

  defp replace_flag(args, flag, value) do
    args
    |> Enum.chunk_every(2)
    |> Enum.map(fn [f, v] -> if f == flag, do: [f, value], else: [f, v] end)
    |> List.flatten()
  end

  # -- query/1 ---------------------------------------------------------------

  describe "query/1 (F08.1)" do
    defp sql(extra \\ []) do
      Export.query(
        Keyword.merge([since: "180d", limit: 600, override_ids: [uuid(1), uuid(2)]], extra)
      )
    end

    test "is wrapped as row_to_json over the inner select" do
      s = String.trim(sql())
      assert String.starts_with?(s, "SELECT row_to_json(t) FROM (")
      assert String.ends_with?(s, ") t")
    end

    test "selects email documents that have a body" do
      assert sql() =~ "source_type = 'email'"
      assert sql() =~ "raw_text IS NOT NULL"
    end

    test "selects the export columns, including source_id and source_metadata fields" do
      s = sql()
      assert s =~ "id AS doc_id"
      assert s =~ "source_id"
      assert s =~ ~r/source_metadata->>'sender' AS "?from"?\b/
      assert s =~ ~r/source_metadata->>'sender_name' AS "?from_name"?\b/
      assert s =~ ~r/source_metadata->>'subject' AS "?subject"?\b/
      assert s =~ ~r/source_metadata->>'date' AS "?date"?\b/
      assert s =~ "raw_text AS body"
      assert s =~ "inserted_at"
    end

    test "uses the naive-UTC interval and never a bare now()" do
      assert sql() =~ "(now() at time zone 'UTC') - interval '180 days'"

      assert length(Regex.scan(~r/now\(\)/, sql())) ==
               length(Regex.scan(~r/\(now\(\) at time zone 'UTC'\)/, sql()))
    end

    test "honours since and limit" do
      s = sql(since: "30d", limit: 50)
      assert s =~ "interval '30 days'"
      assert s =~ "LIMIT 50"
      refute s =~ "LIMIT 600"
    end

    test "orders newest first with id as tie-break" do
      assert sql() =~ "ORDER BY inserted_at DESC, id"
    end

    test "the override OR is parenthesised inside the AND chain" do
      s = sql()
      assert s =~ ~r/AND \(inserted_at >= .*? OR id = ANY\(.*?\)\)/s

      outside = String.replace(s, ~r/AND \(inserted_at >= .*? OR id = ANY\(.*?\)\)/s, "AND TRUE")
      refute outside =~ ~r/\sOR\s/
    end

    test "override ids are cast to uuid[]" do
      assert sql() =~ "'{#{uuid(1)},#{uuid(2)}}'::uuid[]"
    end

    test "no override ids yields an empty uuid array" do
      assert sql(override_ids: []) =~ "'{}'::uuid[]"
    end

    test "a non-uuid override id never reaches the SQL" do
      s = sql(override_ids: ["x'); injected statement; --", uuid(1)])
      refute s =~ "injected"
      assert s =~ uuid(1)
    end

    test "an invalid since never reaches the SQL and falls back to 180 days" do
      s = sql(since: "1d'; injected statement; --")
      refute s =~ "injected"
      assert s =~ "interval '180 days'"
    end
  end

  # -- ssh_command/3 ---------------------------------------------------------

  describe "ssh_command/3 (F08.1)" do
    test "runs psql on the host with the asdf PATH prefix and a quoted heredoc" do
      assert ["ssh", "spark", remote] = Export.ssh_command("spark", "other_db", "SELECT 1")
      assert remote =~ ~s(export PATH="$HOME/.asdf/shims:$PATH")
      assert remote =~ "psql -d other_db -At"
      assert remote =~ "<<'SQL'\nSELECT 1\nSQL"
    end

    test "uses exactly the db argument" do
      assert [_, _, remote] = Export.ssh_command("h", "another_name", "SELECT 1")
      assert remote =~ "-d another_name"
      refute remote =~ "other_db"
    end
  end

  # -- fetch_rows/1 ----------------------------------------------------------

  describe "fetch_rows/1 (F08.1)" do
    defp fetch_opts(runner),
      do: [
        host: "spark",
        db: "other_db",
        since: "180d",
        limit: 5,
        override_ids: [uuid(1)],
        runner: runner
      ]

    test "runs the ssh argv through the injected runner and parses its output" do
      parent = self()

      runner = fn argv ->
        send(parent, {:argv, argv})
        {json_line(1, "nl") <> "\n" <> json_line(2, "de") <> "\n", 0}
      end

      assert {:ok, [first, second]} = Export.fetch_rows(fetch_opts(runner))
      assert first.doc_id == uuid(1)
      assert first.source_id == "msg-1"
      assert second.doc_id == uuid(2)
      assert_received {:argv, ["ssh", "spark", remote]}
      assert remote =~ "psql -d other_db"
    end

    test "a non-zero exit is an error that does not carry the command output" do
      runner = fn _argv -> {"stderr with some private text", 255} end
      assert {:error, reason} = Export.fetch_rows(fetch_opts(runner))
      assert reason == {:exit_status, 255}
      refute inspect(reason) =~ "private"
    end

    test "empty output is an error, not an empty manifest input" do
      assert {:error, :no_rows} = Export.fetch_rows(fetch_opts(fn _ -> {"", 0} end))
    end
  end

  # -- parse_rows/1 ----------------------------------------------------------

  describe "parse_rows/1 (F08.1)" do
    test "parses JSONL into atom-keyed rows carrying doc_id and source_id" do
      assert {:ok, [r1, r2]} =
               Export.parse_rows(json_line(1, "nl") <> "\n" <> json_line(2, "en") <> "\n")

      assert r1.doc_id == uuid(1)
      assert r1.source_id == "msg-1"
      assert r1.from == "user1@example.invalid"
      assert r1.subject == "Subject 1"
      assert r1.body == @bodies["nl"]
      assert r2.doc_id == uuid(2)
    end

    test "tolerates a bad line, a blank line and a line without doc_id" do
      input =
        Enum.join(
          [json_line(1, "nl"), "this is not json", "", ~s({"body": "x"}), json_line(2, "de")],
          "\n"
        )

      assert {:ok, rows} = Export.parse_rows(input)
      assert Enum.map(rows, & &1.doc_id) == [uuid(1), uuid(2)]
    end

    test "no usable line is {:error, :no_rows}" do
      assert {:error, :no_rows} = Export.parse_rows("")
      assert {:error, :no_rows} = Export.parse_rows("garbage\nmore garbage\n")
    end
  end

  # -- select/3 --------------------------------------------------------------

  describe "select/3 (F08.1, F08.7)" do
    test "puts every override row first, then fills to the target" do
      result = Export.select(pool(), overrides(), target: 100)
      assert length(result) == 100

      assert result |> Enum.take(3) |> Enum.map(& &1.doc_id) |> Enum.sort() ==
               Enum.sort([uuid(5), uuid(130), uuid(200)])
    end

    test "has no duplicate rows" do
      result = Export.select(pool(), overrides(), target: 100)
      assert result |> Enum.map(& &1.doc_id) |> Enum.uniq() |> length() == 100
    end

    test "fills toward NL ≥ 40 %, DE ≥ 25 %, EN ≥ 20 % even when the newest rows are all Dutch" do
      counts = lang_counts(Export.select(pool(), overrides(), target: 100))
      assert counts["nl"] >= 40
      assert counts["de"] >= 25
      assert counts["en"] >= 20
    end

    test "is deterministic and independent of input order" do
      first = Export.select(pool(), overrides(), target: 100)
      assert Export.select(pool(), overrides(), target: 100) == first
      assert Export.select(Enum.reverse(pool()), overrides(), target: 100) == first
    end

    test "keeps every override even when they exceed the target" do
      result = Export.select(pool(), overrides(), target: 2)
      assert length(result) == 3
    end

    test "an override id absent from the rows is ignored" do
      result = Export.select(pool(), %{uuid(999) => category()}, target: 10)
      assert length(result) == 10
    end

    test "a pool smaller than the target is returned whole" do
      small = Enum.map(1..7, &row(&1, "nl"))
      assert length(Export.select(small, %{}, target: 50)) == 7
    end
  end

  # -- build_manifest/3 ------------------------------------------------------

  describe "build_manifest/3 (F08.1, F08.7, S-29)" do
    defp build(opts \\ []) do
      rows = Export.select(pool(), overrides(), target: 12)

      opts =
        Keyword.merge(
          [
            clients: ["client-a", "client-b"],
            now: @now,
            host: "spark",
            query_sha256: String.duplicate("a", 64),
            overrides_sha256: String.duplicate("b", 64)
          ],
          opts
        )

      {rows, Export.build_manifest(rows, overrides(), opts)}
    end

    test "returns a manifest that validates, unfrozen" do
      {_rows, m} = build()
      assert :ok = Manifest.validate(m)
      assert m.frozen_at == nil
      assert m.created_at == @now
      assert m.set_id == "decide-v1"
    end

    test "numbers the items it-0001… in row order" do
      {rows, m} = build()
      ids = Enum.map(1..12, &"it-#{String.pad_leading("#{&1}", 4, "0")}")
      assert Enum.map(m.items, & &1.id) == ids
      assert Enum.map(m.items, & &1.doc_id) == Enum.map(rows, & &1.doc_id)
    end

    test "copies doc_id, source_id and the email state onto each item" do
      {rows, m} = build()

      for {row, item} <- Enum.zip(rows, m.items) do
        assert %{source_id: source_id} = item
        assert source_id == row.source_id

        assert item.state == %{
                 from: row.from,
                 from_name: row.from_name,
                 subject: row.subject,
                 date: row.date,
                 body: row.body
               }
      end
    end

    test "guesses the language and marks it heuristic" do
      {_rows, m} = build()

      for item <- m.items do
        assert item.language == Language.guess(item.state.body)
        assert item.language_source == "heuristic"
      end
    end

    test "seeds the category as adjudicated only where an override exists" do
      {_rows, m} = build()
      {seeded, plain} = Enum.split_with(m.items, &Map.has_key?(overrides(), &1.doc_id))
      assert length(seeded) == 3

      for item <- seeded do
        cat = category()
        assert %{seed_category: ^cat} = item
        assert item.label_sources == %{"category" => "adjudicated"}
      end

      for item <- plain do
        assert %{seed_category: nil} = item
        assert item.label_sources == %{}
      end
    end

    test "leaves labels, tier, split and pair fields empty on every item" do
      {_rows, m} = build()

      for item <- m.items do
        assert item.labels == nil
        assert item.tier == nil
        assert item.split == nil
        assert item.pair_id == nil
        assert item.doc_id != nil
      end
    end

    test "carries the Phase B question set over the given clients" do
      {_rows, m} = build()
      assert m.question_set == QuestionSet.phase_b(["client-a", "client-b"])
    end

    test "records the export header" do
      {rows, m} = build()
      assert m.export.host == "spark"
      assert m.export.exported_at == @now
      assert m.export.row_count == length(rows)
      assert m.export.query_sha256 == String.duplicate("a", 64)
      assert m.export.overrides_sha256 == String.duplicate("b", 64)
      assert m.export.mix_shortfall_acknowledged == false
    end

    test "counts agree: nothing labelled, nothing tiered, no pairs" do
      {_rows, m} = build()
      assert m.counts.total == 12
      assert m.counts.labelled == 0
      assert m.counts.tiered == 0
      assert m.counts.pairs == 0
    end

    test "seed_category and source_id survive save/2 → load/1" do
      {_rows, m} = build()
      path = Path.join(tmp_dir!(), "manifest.json")
      assert :ok = Manifest.save(m, path)
      assert {:ok, loaded} = Manifest.load(path)

      seeded = Enum.find(loaded.items, &Map.has_key?(overrides(), &1.doc_id))
      cat = category()
      assert %{seed_category: ^cat, source_id: "msg-" <> _} = seeded
    end
  end

  # -- parse_args/1 (mix kerf.eval.export) -----------------------------------

  describe "Export.parse_args/1 (F08.1, S-27)" do
    defp base_args do
      dir = tmp_dir!()

      [
        "--out",
        Path.join(dir, "manifest.json"),
        "--overrides",
        Path.join(dir, "overrides.jsonl"),
        "--clients",
        Path.join(dir, "clients.txt")
      ]
    end

    test "defaults: since 180d, limit 600, target 220, host spark, db kerf_prod" do
      args = base_args()
      assert {:ok, cfg} = Export.parse_args(args)
      assert cfg.out == Enum.at(args, 1)
      assert cfg.overrides == Enum.at(args, 3)
      assert cfg.clients == Enum.at(args, 5)
      assert cfg.since == "180d"
      assert cfg.limit == 600
      assert cfg.target == 220
      assert cfg.host == "spark"
      assert cfg.db == "kerf_prod"
      assert cfg.raw == nil
      assert cfg.hashes_out == nil
    end

    test "--db overrides the default" do
      assert {:ok, cfg} = Export.parse_args(base_args() ++ ["--db", "other_db"])
      assert cfg.db == "other_db"
    end

    test "the default database name appears exactly once in lib/kerf/eval/export.ex" do
      source = File.read!("lib/kerf/eval/export.ex")
      assert length(String.split(source, "kerf_prod")) == 2
    end

    test "parses every optional flag" do
      dir = tmp_dir!()

      extra = [
        "--since",
        "90d",
        "--limit",
        "50",
        "--target",
        "30",
        "--host",
        "other-host",
        "--raw",
        Path.join(dir, "raw.jsonl"),
        "--hashes-out",
        Path.join(dir, "hashes.txt")
      ]

      assert {:ok, cfg} = Export.parse_args(base_args() ++ extra)
      assert {cfg.since, cfg.limit, cfg.target, cfg.host} == {"90d", 50, 30, "other-host"}
      assert cfg.raw == Path.join(dir, "raw.jsonl")
      assert cfg.hashes_out == Path.join(dir, "hashes.txt")
    end

    test "each required flag is required" do
      args = base_args()

      for flag <- ["--out", "--overrides", "--clients"] do
        assert {:error, msg} = Export.parse_args(drop_flag(args, flag))
        assert msg =~ flag
      end
    end

    test "refuses --out inside the repo root" do
      args = replace_flag(base_args(), "--out", Path.join(File.cwd!(), "manifest.json"))
      assert {:error, msg} = Export.parse_args(args)
      assert msg =~ "--out"
    end

    test "refuses a relative --out (it resolves inside the repo root)" do
      args = replace_flag(base_args(), "--out", "manifest.json")
      assert {:error, msg} = Export.parse_args(args)
      assert msg =~ "--out"
    end

    test "refuses --hashes-out inside the repo root" do
      args = base_args() ++ ["--hashes-out", Path.join(File.cwd!(), "hashes.txt")]
      assert {:error, msg} = Export.parse_args(args)
      assert msg =~ "--hashes-out"
    end

    test "never raises on malformed argv" do
      for argv <- [
            [],
            ["--bogus"],
            ["--out"],
            ["--limit"],
            ["--limit", "abc"],
            ["--target", "0"],
            ["--limit", "-5"],
            ["positional"],
            base_args() ++ ["--limit", "ten"]
          ] do
        assert {:error, msg} = Export.parse_args(argv)
        assert is_binary(msg)
      end
    end
  end

  describe "Export.parse_args/1 validation (F08.1, S-30)" do
    test "refuses --raw inside the repo root" do
      args = base_args() ++ ["--raw", Path.join(File.cwd!(), "raw.jsonl")]
      assert {:error, msg} = Export.parse_args(args)
      assert msg =~ "--raw"
    end

    test "refuses a relative --raw (it resolves inside the repo root)" do
      assert {:error, msg} = Export.parse_args(base_args() ++ ["--raw", "raw.jsonl"])
      assert msg =~ "--raw"
    end

    test "accepts --raw under the tmp dir" do
      raw = Path.join(tmp_dir!(), "raw.jsonl")
      assert {:ok, cfg} = Export.parse_args(base_args() ++ ["--raw", raw])
      assert cfg.raw == raw
    end

    test "rejects a --host or --db that would reach ssh or the remote shell" do
      for {flag, value} <- [
            {"--db", "x; rm -rf"},
            {"--db", "-x"},
            {"--host", "a b"},
            {"--host", "-oProxyCommand=x"}
          ] do
        assert {:error, msg} = Export.parse_args(base_args() ++ [flag, value])
        assert is_binary(msg)
        assert msg =~ flag
      end
    end

    test "still accepts benign host and db names" do
      for {host, db} <- [{"spark", "kerf_prod"}, {"db-1.local", "other_db"}] do
        assert {:ok, cfg} = Export.parse_args(base_args() ++ ["--host", host, "--db", db])
        assert {cfg.host, cfg.db} == {host, db}
      end
    end

    test "rejects a malformed --since" do
      for since <- ["yesterday", "180", "-5d", "d", ""] do
        assert {:error, msg} = Export.parse_args(base_args() ++ ["--since", since])
        assert is_binary(msg)
      end
    end

    test "accepts a well-formed --since" do
      for since <- ["180d", "30d"] do
        assert {:ok, cfg} = Export.parse_args(base_args() ++ ["--since", since])
        assert cfg.since == since
      end
    end
  end

  describe "ssh_command/3 refuses unsafe host and db (S-30)" do
    test "a host that ssh would read as an option is an error" do
      assert {:error, _} = Export.ssh_command("-oProxyCommand=x", "kerf_prod", "SELECT 1")
    end

    test "a db that would break out of the remote command is an error" do
      assert {:error, _} = Export.ssh_command("spark", "x; rm -rf", "SELECT 1")
    end

    test "a host with whitespace is an error" do
      assert {:error, _} = Export.ssh_command("a b", "kerf_prod", "SELECT 1")
    end
  end

  describe "Export.run/2 (F08.1, S-30, S-33)" do
    # Both seams record into one Agent, so a test can prove that neither the
    # runner (ssh) nor query/1 was reached.
    defp recorders do
      {:ok, agent} = Agent.start_link(fn -> %{runner: [], query: 0} end)

      runner = fn argv ->
        Agent.update(agent, &%{&1 | runner: &1.runner ++ [argv]})
        {json_line(1, "nl") <> "\n" <> json_line(2, "de") <> "\n", 0}
      end

      query_fn = fn opts ->
        Agent.update(agent, &%{&1 | query: &1.query + 1})
        Export.query(opts)
      end

      {agent, [runner: runner, query_fn: query_fn]}
    end

    defp ready_args do
      dir = tmp_dir!()

      File.write!(
        Path.join(dir, "overrides.jsonl"),
        ~s({"doc_id":"#{uuid(1)}","label_true":"#{category()}","note":"n"}\n)
      )

      File.write!(Path.join(dir, "clients.txt"), "client-a\nclient-b\n")

      {dir,
       [
         "--out",
         Path.join(dir, "manifest.json"),
         "--overrides",
         Path.join(dir, "overrides.jsonl"),
         "--clients",
         Path.join(dir, "clients.txt")
       ]}
    end

    test "a bad --host or --db never reaches the runner or query/1" do
      for {flag, value} <- [
            {"--db", "x; rm -rf"},
            {"--host", "a b"},
            {"--host", "-oProxyCommand=x"}
          ] do
        {_dir, args} = ready_args()
        {agent, opts} = recorders()

        assert {:error, _} = Export.run(args ++ [flag, value], opts)
        assert %{runner: [], query: 0} = Agent.get(agent, & &1)
      end
    end

    test "a benign argv runs once through both seams and writes a loadable manifest" do
      {dir, args} = ready_args()
      {agent, opts} = recorders()
      out = Path.join(dir, "manifest.json")

      assert {:ok, %{manifest_path: ^out, rows: 2}} =
               Export.run(args ++ ["--host", "spark2", "--db", "other_db"], opts)

      assert %{runner: [["ssh", "spark2", remote]], query: 1} = Agent.get(agent, & &1)
      assert remote =~ "-d other_db"
      assert {:ok, manifest} = Manifest.load(out)
      assert length(manifest.items) == 2
    end

    test "--hashes-out writes the header and the SHA-256 of the exported senders (F08.6)" do
      {dir, args} = ready_args()
      {_agent, opts} = recorders()
      hashes_out = Path.join(dir, "hashes.txt")

      assert {:ok, %{hashes_out: ^hashes_out}} =
               Export.run(args ++ ["--hashes-out", hashes_out], opts)

      assert [header | lines] = hashes_out |> File.read!() |> String.split("\n", trim: true)
      assert header == "# sha256 of addresses in the decide set"

      expected =
        ["user1@example.invalid", "user2@example.invalid"]
        |> Enum.map(&(:crypto.hash(:sha256, &1) |> Base.encode16(case: :lower)))
        |> Enum.sort()

      assert lines == expected
    end

    test "without --hashes-out no hash file is written" do
      {dir, args} = ready_args()
      {_agent, opts} = recorders()

      assert {:ok, _} = Export.run(args, opts)
      refute File.exists?(Path.join(dir, "hashes.txt"))
    end

    test "a malformed argv is an error before any seam is reached" do
      {agent, opts} = recorders()
      assert {:error, _} = Export.run(["--bogus"], opts)
      assert %{runner: [], query: 0} = Agent.get(agent, & &1)
    end
  end

  # -- mix kerf.eval.freeze argv ---------------------------------------------

  describe "Mix.Tasks.Kerf.Eval.Freeze.parse_args/1 (F08.4)" do
    test "parses manifest and seed; shortfall acknowledgement defaults to false" do
      assert {:ok, cfg} = Freeze.parse_args(["--manifest", "/tmp/m.json", "--seed", "7"])
      assert cfg == %{manifest: "/tmp/m.json", seed: 7, allow_mix_shortfall: false}
    end

    test "--allow-mix-shortfall sets the acknowledgement" do
      argv = ["--manifest", "/tmp/m.json", "--seed", "7", "--allow-mix-shortfall"]
      assert {:ok, cfg} = Freeze.parse_args(argv)
      assert cfg.allow_mix_shortfall == true
    end

    test "manifest and seed are required" do
      assert {:error, msg} = Freeze.parse_args(["--seed", "7"])
      assert msg =~ "--manifest"
      assert {:error, msg} = Freeze.parse_args(["--manifest", "/tmp/m.json"])
      assert msg =~ "--seed"
    end

    test "never raises on malformed argv" do
      for argv <- [
            [],
            ["--bogus"],
            ["--manifest"],
            ["--seed"],
            ["--manifest", "/tmp/m.json", "--seed", "seven"],
            ["--manifest", "/tmp/m.json", "--seed", "1.5"],
            ["positional"]
          ] do
        assert {:error, msg} = Freeze.parse_args(argv)
        assert is_binary(msg)
      end
    end
  end
end
