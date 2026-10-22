defmodule Kerf.Eval.HarnessTest do
  @moduledoc """
  SPEC_H F09.3 / F09.4 / F09.6 / F09.8 / F08.4 — `Kerf.Eval.Harness.run/2` over a
  frozen manifest (plan §2.3, §2.6, §7 H3, rulings S-16, S-23b, S-28).

  Every test uses `Synthetic.build(n: 8, pairs: 2)`: 10 items in manifest order
  it-0001..it-0010, one calibration item, nine eval items. A request is
  observed as the adapter receives it from `Kerf.Decide.ask/3`, by call-tracing
  `adapter.ask/3` in a process that runs `Harness.run/2` (a process cannot be
  its own call tracer), so the real Oracle and Random adapters are recorded
  with exactly the opts the harness gives them. `item_index` is the item's
  0-based position in `manifest.items`.
  """
  use ExUnit.Case, async: true

  alias Kerf.Decide.{OptionSet, State}
  alias Kerf.Decide.Question.Choice
  alias Kerf.Eval.Adapters.{Oracle, Random}
  alias Kerf.Eval.Harness
  alias Kerf.Eval.Harness.{Questions, Run, Score}
  alias Kerf.Eval.Manifest
  alias Kerf.Eval.Manifest.{QuestionSet, Synthetic}

  @moduletag :tmp_dir

  @seed 7
  @order ~w(category needs_reply urgency deadline_present client)
  @names [:category, :needs_reply, :urgency, :deadline_present, :client]
  @header_keys ~w(type schema_version run_id set_id manifest_path manifest_sha256
                  manifest_frozen_at adapter adapter_opts info seed permutations
                  isolation_items limit latency_skipped host kerf_git_sha started_at)
  @answer_keys ~w(type item_id doc_id language tier split pair_id question qtype probe
                  packed order_index order gold result latency_ms error)

  # ---------- stub adapters ----------

  defmodule Uniform do
    @moduledoc false
    alias Kerf.Decide.OptionSet
    alias Kerf.Decide.Question.{Choice, Noul, Score}

    def answers(questions) do
      Map.new(questions, fn
        %Noul{name: name} ->
          {name, %{p_yes: 0.5}}

        %Choice{name: name, options: options} ->
          {name, %{probs: uniform(OptionSet.labels(options))}}

        %Score{name: name, levels: levels} ->
          {name, %{expected: (length(levels) - 1) / 2, probs: uniform(levels), confidence: 0.0}}
      end)
    end

    def info,
      do: %{
        model_id: "eval-stub",
        types: [:noul, :choice, :score],
        max_state_tokens: 8192,
        languages: ["nl", "de", "en"]
      }

    defp uniform(labels), do: Enum.map(labels, &{&1, 1 / length(labels)})
  end

  defmodule StubAdapter do
    @moduledoc false
    @behaviour Kerf.Decide.Adapter
    alias Kerf.Eval.HarnessTest.Uniform

    @impl true
    def ask(_state, questions, _opts), do: {:ok, Uniform.answers(questions)}

    @impl true
    def info, do: Uniform.info()
  end

  # it-0003 raises, it-0005 exits, it-0007 returns an error; every other item answers.
  defmodule CrashAdapter do
    @moduledoc false
    @behaviour Kerf.Decide.Adapter
    alias Kerf.Eval.HarnessTest.Uniform

    @impl true
    def ask(%{provenance: %{sources: sources}}, questions, _opts) do
      cond do
        "it-0003" in sources -> raise "stub boom"
        "it-0005" in sources -> exit({:shutdown, :stub_exit})
        "it-0007" in sources -> {:error, :stub_refused}
        true -> {:ok, Uniform.answers(questions)}
      end
    end

    @impl true
    def info, do: Uniform.info()
  end

  defmodule StructInfoAdapter do
    @moduledoc false
    alias Kerf.Eval.HarnessTest.Uniform

    def ask(_state, questions, _opts), do: {:ok, Uniform.answers(questions)}

    def info, do: URI.parse("http://127.0.0.1:8900")
  end

  defmodule ListInfoAdapter do
    @moduledoc false
    alias Kerf.Eval.HarnessTest.Uniform

    def ask(_state, questions, _opts), do: {:ok, Uniform.answers(questions)}

    def info, do: Map.to_list(Uniform.info())
  end

  # ---------- helpers ----------

  defp manifest, do: Synthetic.build(n: 8, pairs: 2)

  defp saved(manifest, tmp_dir) do
    path = Path.join(tmp_dir, "manifest.json")
    :ok = Manifest.save(manifest, path)
    path
  end

  defp opts(path, overrides) do
    Keyword.merge(
      [manifest_path: path, seed: @seed, permutations: 6, isolation_items: 30],
      overrides
    )
  end

  # Runs fun in a fresh process traced for calls to adapter.ask/3 (and anything it
  # spawns); returns {fun's result, [{state, questions, opts}]} in call order.
  defp traced(adapter, fun) do
    Code.ensure_loaded!(adapter)
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :go -> send(parent, {:traced_result, self(), fun.()})
        end
      end)

    1 = :erlang.trace_pattern({adapter, :ask, 3}, true, [])
    1 = :erlang.trace(pid, true, [:call, :set_on_spawn])

    try do
      send(pid, :go)

      result =
        receive do
          {:traced_result, ^pid, result} -> result
          {:DOWN, ^monitor, :process, ^pid, reason} -> flunk("run crashed: #{inspect(reason)}")
        after
          60_000 -> flunk("run timed out")
        end

      ref = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^ref} -> :ok
      end

      {result, collect(adapter, [])}
    after
      :erlang.trace_pattern({adapter, :ask, 3}, false, [])
    end
  end

  defp collect(adapter, acc) do
    receive do
      {:trace, _pid, :call, {^adapter, :ask, [state, questions, opts]}} ->
        collect(adapter, [{state, questions, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp traced_run(manifest, path, adapter, overrides \\ []) do
    traced(adapter, fn -> Harness.run(manifest, opts(path, [adapter: adapter] ++ overrides)) end)
  end

  defp token(seed) do
    hex = :crypto.hash(:sha256, Integer.to_string(seed)) |> Base.encode16(case: :lower)
    "KERF-" <> binary_part(hex, 0, 12)
  end

  defp key(line), do: {line["item_id"], line["probe"], line["order_index"], line["question"]}

  # §2.3 line order with S-28(2) isolation placement.
  defp expected_keys(items, isolation_ids) do
    Enum.flat_map(items, fn item ->
      main = for order_index <- 0..5, q <- @order, do: {item.id, "main", order_index, q}
      separate = for q <- @order, do: {item.id, "separate", 0, q}

      isolation =
        if item.id in isolation_ids,
          do: [
            {item.id, "isolation_sibling", 0, "secret_present"},
            {item.id, "isolation_state", 0, "secret_present"}
          ],
          else: []

      main ++ separate ++ isolation
    end)
  end

  defp eval_ids(items), do: for(item <- items, item.split == "eval", do: item.id)

  # The request sequence one item produces: main 0..5, separate per question, isolation.
  defp request_kinds(items, isolation_ids) do
    Enum.flat_map(Enum.with_index(items), fn {item, index} ->
      main = for order_index <- 0..5, do: {item, index, {:main, order_index}}
      separate = for q <- 0..4, do: {item, index, {:separate, q}}

      isolation =
        if item.id in isolation_ids,
          do: [{item, index, :isolation_sibling}, {item, index, :isolation_state}],
          else: []

      main ++ separate ++ isolation
    end)
  end

  defp gold(item) do
    Map.new(Enum.zip(@names, @order), fn {name, key} -> {name, item.labels[key]} end)
  end

  defp jsonl(%{header: header, lines: lines, end: run_end}),
    do: Enum.map_join([header | lines] ++ [run_end], "", &(Run.encode(&1) <> "\n"))

  defp normalized(result) do
    {:ok, text} = Run.normalize(jsonl(result))
    text
  end

  defp labels_of(%Choice{options: options}), do: OptionSet.labels(options)
  defp labels_of(_question), do: nil

  defp questions_by_name(manifest) do
    {:ok, questions} = Questions.from_question_set(manifest.question_set)
    Map.new(questions, &{&1.name, &1})
  end

  defp content_regex(item) do
    s = item.state

    ~r/\AFrom: [^\n]*#{Regex.escape(s.from)}[^\n]*\nSubject: #{Regex.escape(s.subject)}\nDate: #{Regex.escape(s.date)}\n\n#{Regex.escape(s.body)}\z/
  end

  defp sunk(acc) do
    receive do
      {:sunk, line} -> sunk([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp probe?(question), do: question.name == :secret_present

  # ---------- S-16 and source guards ----------

  test "Questions.order/0 equals Manifest.QuestionSet.order/0 (S-16)" do
    assert Questions.order() == QuestionSet.order()
  end

  test "harness.ex calls no adapter directly: the only .ask( is Kerf.Decide.ask(" do
    source = File.read!("lib/kerf/eval/harness.ex")
    asks = Regex.scan(~r/[\w.]*\.ask\(/, source) |> List.flatten()

    assert Enum.all?(asks, &(&1 == "Kerf.Decide.ask(" or &1 == "Decide.ask("))
    refute source =~ "String.to_atom("
  end

  # ---------- line set and order ----------

  test "Synthetic n: 8, pairs: 2 with isolation_items 30 gives 368 answer lines", %{tmp_dir: dir} do
    m = manifest()
    assert length(m.items) == 10
    assert length(eval_ids(m.items)) == 9

    assert {:ok, %{header: header, lines: lines, end: run_end}} =
             Harness.run(m, opts(saved(m, dir), adapter: Oracle))

    assert header["type"] == "run_manifest"
    assert length(lines) == 368
    assert Enum.all?(lines, &(&1["type"] == "answer"))
    assert run_end["type"] == "run_end"
    assert run_end["answers"] == 368
    assert run_end["errors"] == 0
  end

  test "lines follow §2.3 order with isolation inside each selected item's block (S-28(2))",
       %{tmp_dir: dir} do
    m = manifest()
    {:ok, %{lines: lines}} = Harness.run(m, opts(saved(m, dir), adapter: Oracle))

    assert Enum.map(lines, &key/1) == expected_keys(m.items, eval_ids(m.items))
  end

  test "isolation items are the first isolation_items eval items by id, emitted in manifest order",
       %{tmp_dir: dir} do
    m = %{manifest() | items: Enum.reverse(manifest().items)}
    selected = m.items |> eval_ids() |> Enum.sort() |> Enum.take(2)
    assert selected == ["it-0001", "it-0002"]

    {:ok, %{lines: lines}} =
      Harness.run(m, opts(saved(m, dir), adapter: Oracle, isolation_items: 2))

    assert length(lines) == 350 + 4
    assert Enum.map(lines, &key/1) == expected_keys(m.items, selected)
  end

  test "every answer line carries exactly the §2.3 keys and the item's fields", %{tmp_dir: dir} do
    m = manifest()
    {:ok, %{lines: lines}} = Harness.run(m, opts(saved(m, dir), adapter: Oracle))
    by_id = Map.new(m.items, &{&1.id, &1})

    for line <- lines do
      item = by_id[line["item_id"]]
      assert line |> Map.keys() |> Enum.sort() == Enum.sort(@answer_keys)
      assert line["doc_id"] == item.doc_id
      assert line["language"] == item.language
      assert line["tier"] == item.tier
      assert line["split"] == item.split
      assert line["pair_id"] == item.pair_id
      assert line["error"] == nil
    end
  end

  test "main lines: packed, order_index 0 is identity, orders 1..5 come from Questions.orders_for/5",
       %{tmp_dir: dir} do
    m = manifest()
    {:ok, %{lines: lines}} = Harness.run(m, opts(saved(m, dir), adapter: Oracle))
    questions = questions_by_name(m)
    index_of = m.items |> Enum.with_index() |> Map.new(fn {item, i} -> {item.id, i} end)

    for line <- lines, line["probe"] == "main" do
      q = Enum.find_index(@order, &(&1 == line["question"]))
      question = questions[Enum.at(@names, q)]
      assert line["packed"] == true

      expected =
        case question do
          %Choice{} ->
            Questions.orders_for(question, @seed, index_of[line["item_id"]], q, 6)
            |> Enum.at(line["order_index"])

          _ ->
            nil
        end

      assert line["order"] == expected
    end

    for line <- lines, line["probe"] == "main", line["order_index"] == 0 do
      if line["question"] in ["category", "client"],
        do: assert(line["order"] == m.question_set[line["question"]]["options"])
    end
  end

  test "main and separate lines carry qtype and the manifest gold", %{tmp_dir: dir} do
    m = manifest()
    {:ok, %{lines: lines}} = Harness.run(m, opts(saved(m, dir), adapter: Oracle))
    by_id = Map.new(m.items, &{&1.id, &1})

    for line <- lines, line["probe"] in ["main", "separate"] do
      assert line["qtype"] == m.question_set[line["question"]]["type"]
      assert line["gold"] == by_id[line["item_id"]].labels[line["question"]]
    end
  end

  test "separate lines: one per question, unpacked, identity order", %{tmp_dir: dir} do
    m = manifest()
    {:ok, %{lines: lines}} = Harness.run(m, opts(saved(m, dir), adapter: Oracle))

    for line <- lines, line["probe"] == "separate" do
      assert line["packed"] == false
      assert line["order_index"] == 0

      if line["question"] in ["category", "client"],
        do: assert(line["order"] == m.question_set[line["question"]]["options"]),
        else: assert(line["order"] == nil)
    end
  end

  test "isolation lines: secret_present noul, gold false for sibling and true for state",
       %{tmp_dir: dir} do
    m = manifest()
    {:ok, %{lines: lines}} = Harness.run(m, opts(saved(m, dir), adapter: Oracle))
    isolation = Enum.filter(lines, &(&1["probe"] in ["isolation_sibling", "isolation_state"]))

    assert length(isolation) == 18

    for line <- isolation do
      assert line["question"] == "secret_present"
      assert line["qtype"] == "noul"
      assert line["packed"] == false
      assert line["order"] == nil
      assert line["gold"] == (line["probe"] == "isolation_state")
    end
  end

  test "the oracle run answers every line with the gold (no request failed)", %{tmp_dir: dir} do
    m = manifest()
    {:ok, %{lines: lines}} = Harness.run(m, opts(saved(m, dir), adapter: Oracle))

    for line <- lines, line["qtype"] == "noul" do
      assert line["result"]["p_yes"] >= 0.9 == line["gold"]
    end

    for line <- lines,
        line["qtype"] == "choice",
        do: assert(line["result"]["label"] == line["gold"])
  end

  # ---------- requests (traced adapter.ask/3) ----------

  test "each request's state is the item's From/Subject/Date/body with ingress provenance (§2.6)",
       %{tmp_dir: dir} do
    m = manifest()
    {{:ok, _}, calls} = traced_run(m, saved(m, dir), StubAdapter, skip_latency: true)
    kinds = request_kinds(m.items, eval_ids(m.items))

    assert length(calls) == length(kinds)

    for {{state, _questions, _opts}, {item, _index, kind}} <- Enum.zip(calls, kinds) do
      assert %State{} = state
      assert state.provenance == %{taint: :tainted, origin: :ingress, sources: [item.id]}

      if kind != :isolation_state, do: assert(state.content =~ content_regex(item))
    end
  end

  test "main requests are packed in Questions.order/0 with the permuted options; separate requests ask one question",
       %{tmp_dir: dir} do
    m = manifest()
    {{:ok, _}, calls} = traced_run(m, saved(m, dir), StubAdapter, skip_latency: true)
    assert length(calls) == length(request_kinds(m.items, eval_ids(m.items)))
    questions = questions_by_name(m)

    for {{_state, asked, _opts}, {_item, index, kind}} <-
          Enum.zip(calls, request_kinds(m.items, eval_ids(m.items))) do
      case kind do
        {:main, order_index} ->
          assert Enum.map(asked, & &1.name) == @names

          for {question, q} <- Enum.with_index(asked), match?(%Choice{}, question) do
            expected =
              Questions.orders_for(questions[question.name], @seed, index, q, 6)
              |> Enum.at(order_index)

            assert labels_of(question) == expected
          end

        {:separate, q} ->
          name = Enum.at(@names, q)
          assert [question] = asked
          assert question.name == name
          assert labels_of(question) == labels_of(questions[name])

        _isolation ->
          :ok
      end
    end
  end

  test "isolation probes: token in a sibling's instructions, then in the state (F09.4, A3.12)",
       %{tmp_dir: dir} do
    m = manifest()
    {{:ok, _}, calls} = traced_run(m, saved(m, dir), StubAdapter, skip_latency: true)
    assert length(calls) == length(request_kinds(m.items, eval_ids(m.items)))
    token = token(@seed)
    assert token =~ ~r/\AKERF-[0-9a-f]{12}\z/

    pairs =
      Enum.zip(calls, request_kinds(m.items, eval_ids(m.items)))
      |> Enum.filter(fn {_call, {_item, _index, kind}} ->
        kind in [:isolation_sibling, :isolation_state]
      end)

    assert length(pairs) == 18

    for {{state, asked, _opts}, {item, _index, kind}} <- pairs do
      assert [probe] = Enum.filter(asked, &probe?/1)
      assert probe == Questions.secret_probe(token)
      others = Enum.reject(asked, &probe?/1)

      case kind do
        :isolation_sibling ->
          assert state.content =~ content_regex(item)
          refute String.contains?(state.content, token)
          assert Enum.any?(others, &String.contains?(&1.instructions, token))

        :isolation_state ->
          assert String.contains?(state.content, token)
          refute Enum.any?(others, &String.contains?(&1.instructions, token))
      end
    end
  end

  test "Oracle gets harness_gold atom-keyed through the Phase B list (+ secret_present on probes) and no harness_seed",
       %{tmp_dir: dir} do
    m = manifest()
    {{:ok, _}, calls} = traced_run(m, saved(m, dir), Oracle)
    assert length(calls) == length(request_kinds(m.items, eval_ids(m.items)))

    for {{_state, _asked, opts}, {item, _index, kind}} <-
          Enum.zip(calls, request_kinds(m.items, eval_ids(m.items))) do
      refute Keyword.has_key?(opts, :harness_seed)

      expected =
        case kind do
          :isolation_sibling -> Map.put(gold(item), :secret_present, false)
          :isolation_state -> Map.put(gold(item), :secret_present, true)
          _ -> gold(item)
        end

      assert Keyword.fetch!(opts, :harness_gold) == expected
    end
  end

  test "Random gets the S-28(6) harness_seed 3-tuple per request and no harness_gold",
       %{tmp_dir: dir} do
    m = manifest()
    {{:ok, _}, calls} = traced_run(m, saved(m, dir), Random)
    assert length(calls) == length(request_kinds(m.items, eval_ids(m.items)))

    for {{_state, _asked, opts}, {_item, index, kind}} <-
          Enum.zip(calls, request_kinds(m.items, eval_ids(m.items))) do
      refute Keyword.has_key?(opts, :harness_gold)

      expected =
        case kind do
          {:main, order_index} -> {@seed, index * 64 + 6, order_index}
          {:separate, q} -> {@seed, index * 64 + q, 0}
          :isolation_sibling -> {@seed, index * 64 + 5, 0}
          :isolation_state -> {@seed, index * 64 + 5, 1}
        end

      assert Keyword.fetch!(opts, :harness_seed) == expected
    end
  end

  test "a non-harness adapter receives neither harness_gold nor harness_seed", %{tmp_dir: dir} do
    m = manifest()
    {{:ok, _}, calls} = traced_run(m, saved(m, dir), StubAdapter, skip_latency: true)

    assert length(calls) == length(request_kinds(m.items, eval_ids(m.items)))

    for {_state, _asked, opts} <- calls do
      refute Keyword.has_key?(opts, :harness_gold)
      refute Keyword.has_key?(opts, :harness_seed)
    end
  end

  # ---------- header ----------

  test "header: §2.3 keys, inspect/1 adapter string, manifest_path and its sha256 (S-23b)",
       %{tmp_dir: dir} do
    m = manifest()
    path = saved(m, dir)
    {:ok, hex} = Manifest.sha256(path)
    {:ok, %{header: header}} = Harness.run(m, opts(path, adapter: Random))

    assert header |> Map.keys() |> Enum.sort() == Enum.sort(@header_keys)
    assert header["adapter"] == "Kerf.Eval.Adapters.Random"
    refute String.starts_with?(header["adapter"], "Elixir.")
    assert header["manifest_path"] == path
    assert header["manifest_sha256"] == hex
    assert header["manifest_frozen_at"] == m.frozen_at
    assert header["set_id"] == m.set_id
    assert header["seed"] == @seed
    assert header["permutations"] == 6
    assert header["isolation_items"] == 30
    assert header["limit"] == nil
    assert header["latency_skipped"] == true
    assert header["info"]["model_id"] == "eval-random"
  end

  test "header for a stub adapter names it with inspect/1 and is a plain JSON-encodable map",
       %{tmp_dir: dir} do
    m = manifest()

    {:ok, %{header: header}} =
      Harness.run(m, opts(saved(m, dir), adapter: StubAdapter, skip_latency: true))

    assert header["adapter"] == "Kerf.Eval.HarnessTest.StubAdapter"
    refute Map.has_key?(header, :__struct__)
    assert is_binary(Run.encode(header))
  end

  test "info/0 returning a struct → {:error, {:invalid_header, _}}, zero requests (S-28(4))",
       %{tmp_dir: dir} do
    m = manifest()
    {result, calls} = traced_run(m, saved(m, dir), StructInfoAdapter, skip_latency: true)

    assert {:error, {:invalid_header, _}} = result
    assert calls == []
  end

  test "info/0 returning a non-map → {:error, {:invalid_header, _}}, zero requests (S-28(4))",
       %{tmp_dir: dir} do
    m = manifest()
    {result, calls} = traced_run(m, saved(m, dir), ListInfoAdapter, skip_latency: true)

    assert {:error, {:invalid_header, _}} = result
    assert calls == []
  end

  test "unreadable manifest_path aborts with {:error, {:manifest_sha256, reason}} before any request",
       %{tmp_dir: dir} do
    missing = Path.join(dir, "missing.json")
    {result, calls} = traced_run(manifest(), missing, StubAdapter, skip_latency: true)

    assert result == {:error, {:manifest_sha256, :enoent}}
    assert calls == []
  end

  # ---------- F08.4 ----------

  test "an unfrozen manifest is refused before any request (F08.4)", %{tmp_dir: dir} do
    m = Synthetic.build(n: 8, pairs: 2, frozen: false)
    {result, calls} = traced_run(m, saved(m, dir), StubAdapter, skip_latency: true)

    assert {:error, _} = result
    assert calls == []
  end

  test "a manifest tiered after its freeze is refused before any request (F08.4)",
       %{tmp_dir: dir} do
    m = manifest()
    late = %{m | items: List.update_at(m.items, 0, &%{&1 | tiered_at: "2026-10-20T13:00:00Z"})}
    {result, calls} = traced_run(late, saved(m, dir), StubAdapter, skip_latency: true)

    assert {:error, _} = result
    assert calls == []
  end

  # ---------- adapter failures (S-28(5), plan §4 item 5) ----------

  test "a raising, exiting or erroring adapter yields error lines for that item and the run completes",
       %{tmp_dir: dir} do
    m = manifest()

    assert {:ok, %{lines: lines, end: run_end}} =
             Harness.run(m, opts(saved(m, dir), adapter: CrashAdapter, skip_latency: true))

    assert Enum.map(lines, &key/1) == expected_keys(m.items, eval_ids(m.items))

    {failed, answered} =
      Enum.split_with(lines, &(&1["item_id"] in ["it-0003", "it-0005", "it-0007"]))

    assert length(failed) == 3 * (6 * 5 + 5 + 2)
    assert Enum.all?(failed, &is_nil(&1["result"]))
    assert Enum.all?(answered, &(is_map(&1["result"]) and is_nil(&1["error"])))

    errors = fn id -> for l <- failed, l["item_id"] == id, uniq: true, do: l["error"] end
    assert [raised] = errors.("it-0003")
    assert raised =~ "stub boom"
    assert [exited] = errors.("it-0005")
    assert exited =~ "stub_exit"
    assert errors.("it-0007") == [inspect(:stub_refused)]

    assert run_end["answers"] == 368
    assert run_end["errors"] == length(failed)
  end

  # ---------- F09.8 determinism ----------

  test "same seed → identical normalized output over two runs (F09.8)", %{tmp_dir: dir} do
    m = manifest()
    path = saved(m, dir)
    {:ok, first} = Harness.run(m, opts(path, adapter: Random))
    {:ok, second} = Harness.run(m, opts(path, adapter: Random))

    assert normalized(first) == normalized(second)
  end

  test "a different seed changes the normalized output", %{tmp_dir: dir} do
    m = manifest()
    path = saved(m, dir)
    {:ok, first} = Harness.run(m, opts(path, adapter: Random))
    {:ok, other} = Harness.run(m, opts(path, adapter: Random, seed: @seed + 1))

    refute normalized(first) == normalized(other)
  end

  # ---------- limit and sink ----------

  test "limit is recorded and scopes the run to the first limit items (S-28(3))",
       %{tmp_dir: dir} do
    m = manifest()

    {:ok, %{header: header, lines: lines}} =
      Harness.run(m, opts(saved(m, dir), adapter: Oracle, limit: 3))

    scope = Enum.take(m.items, 3)
    assert header["limit"] == 3
    assert Enum.map(lines, &key/1) == expected_keys(scope, eval_ids(scope))
  end

  # Reversed manifest, limit 3: the scope is it-0010, it-0009, it-0008 (calibration),
  # so the one isolation item is it-0009, not the manifest-wide lowest eval id it-0001.
  test "a limited run passes Score coverage: expected == answered (S-28(3))", %{tmp_dir: dir} do
    m = %{manifest() | items: Enum.reverse(manifest().items)}

    {:ok, %{header: header, lines: lines}} =
      Harness.run(m, opts(saved(m, dir), adapter: Oracle, limit: 3, isolation_items: 1))

    coverage = Score.score(header, lines, m.items, [])["coverage"]

    assert coverage["expected"] == 3 * 35 + 2
    assert coverage["answered"] == coverage["expected"]
    assert coverage["errors"] == 0
    assert Enum.map(lines, &key/1) == expected_keys(Enum.take(m.items, 3), ["it-0009"])
  end

  test "sink receives the header, every answer line and run_end in order", %{tmp_dir: dir} do
    m = manifest()
    parent = self()

    sink = fn line ->
      send(parent, {:sunk, line})
      :ok
    end

    {:ok, %{header: header, lines: lines, end: run_end}} =
      Harness.run(m, opts(saved(m, dir), adapter: Oracle, sink: sink))

    assert sunk([]) == [header | lines] ++ [run_end]
  end

  # ---------- sink write errors (S-35 (b), F09.6, F09.8) ----------
  #
  # Sink contract: (map -> :ok | {:error, term}). The first {:error, reason}
  # ends run/2 with {:error, reason}: no further sink call, and run_end is never
  # passed, so a truncated run file never carries run_end.

  describe "a sink {:error, reason} aborts the run (S-35 (b))" do
    @write_failed {:error, {:write_failed, "/x", :enospc}}

    test "an error on the third call is returned as is; exactly three calls, none run_end",
         %{tmp_dir: dir} do
      m = manifest()

      assert Harness.run(m, opts(saved(m, dir), adapter: Oracle, sink: failing_sink(3))) ==
               @write_failed

      lines = sunk([])
      assert length(lines) == 3
      refute Enum.any?(lines, &(&1["type"] == "run_end"))
    end

    test "an error on the header ends the run after that one call", %{tmp_dir: dir} do
      m = manifest()

      assert Harness.run(m, opts(saved(m, dir), adapter: Oracle, sink: failing_sink(1))) ==
               @write_failed

      assert [%{"type" => "run_manifest"}] = sunk([])
    end

    test "an error on run_end itself is returned too", %{tmp_dir: dir} do
      m = manifest()
      path = saved(m, dir)
      {:ok, %{lines: lines}} = Harness.run(m, opts(path, adapter: Oracle))
      calls = length(lines) + 2

      assert Harness.run(m, opts(path, adapter: Oracle, sink: failing_sink(calls))) ==
               @write_failed

      assert %{"type" => "run_end"} = List.last(sunk([]))
    end
  end

  # Forwards every line to the test process; returns @write_failed on call n, :ok otherwise.
  defp failing_sink(n) do
    parent = self()
    calls = :counters.new(1, [])

    fn line ->
      :counters.add(calls, 1, 1)
      send(parent, {:sunk, line})
      if :counters.get(calls, 1) == n, do: @write_failed, else: :ok
    end
  end
end
