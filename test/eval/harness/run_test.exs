defmodule Kerf.Eval.Harness.RunTest do
  @moduledoc """
  SPEC_H F09.8 (determinism) and F09.6 (result shape) — the run JSONL of
  docs/superpowers/plans/2026-10-20-decide-eval-step2-3.md §2.3.

  Contract pinned here (the plan names the functions, not their shapes):
  `header/1`, `answer_line/1`, `end_line/1` take an atom- or string-keyed map
  and return a deep string-keyed map with `"type"` set; `encode/1` renders one
  line with keys in the §2.3 order; `write/3` writes header, then lines (the
  answers followed by the run_end line); `read/1` returns
  `{:ok, {header, answers, run_end}}`; `normalize/1` takes JSONL text.
  Files live under System.tmp_dir!() only; no real addresses.
  """
  use ExUnit.Case, async: true

  alias Kerf.Eval.Harness.Run

  @dropped ~w(latency_ms started_at finished_at run_id)

  @header_order ~w(type schema_version run_id set_id manifest_path manifest_sha256
                   manifest_frozen_at adapter adapter_opts info seed permutations
                   isolation_items limit latency_skipped host kerf_git_sha started_at)
  @answer_order ~w(type item_id doc_id language tier split pair_id question qtype probe
                   packed order_index order gold result latency_ms error)
  @end_order ~w(type finished_at answers errors)

  setup do
    path =
      Path.join(System.tmp_dir!(), "kerf-eval-run-#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  # ---------- fixtures ----------

  defp header_fields(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: "decide-v1-random-s1-2026-10-22T10:00:00Z",
        set_id: "decide-v1",
        manifest_path: "/tmp/manifest.json",
        manifest_sha256: String.duplicate("a", 64),
        manifest_frozen_at: "2026-10-21T09:00:00Z",
        adapter: "Kerf.Eval.Adapters.Random",
        adapter_opts: %{base_url: "http://127.0.0.1:8900"},
        info: %{
          model_id: "eval-random",
          types: ["noul", "choice", "score"],
          max_state_tokens: 8192,
          languages: ["nl", "de", "en"]
        },
        seed: 1,
        permutations: 6,
        isolation_items: 30,
        limit: nil,
        latency_skipped: true,
        host: "testhost",
        kerf_git_sha: "abc1234",
        started_at: "2026-10-22T10:00:00Z"
      },
      overrides
    )
  end

  defp noul_answer(overrides \\ %{}) do
    Map.merge(
      %{
        item_id: "it-0002",
        doc_id: nil,
        language: "de",
        tier: "hard",
        split: "eval",
        pair_id: nil,
        question: "needs_reply",
        qtype: "noul",
        probe: "main",
        packed: true,
        order_index: 0,
        order: nil,
        gold: true,
        result: %{p_yes: 0.75},
        latency_ms: 12,
        error: nil
      },
      overrides
    )
  end

  defp choice_answer(overrides \\ %{}) do
    Map.merge(
      noul_answer(),
      Map.merge(
        %{
          item_id: "it-0001",
          doc_id: "doc-1",
          language: "nl",
          tier: "easy",
          question: "category",
          qtype: "choice",
          order: ["business", "personal", "newsletter"],
          gold: "business",
          result: %{
            label: "business",
            probs: [{"business", 0.5}, {"personal", 0.25}, {"newsletter", 0.25}],
            confidence: 0.25
          }
        },
        overrides
      )
    )
  end

  defp end_fields(overrides \\ %{}),
    do: Map.merge(%{finished_at: "2026-10-22T10:05:00Z", answers: 2, errors: 0}, overrides)

  defp keys_in_order(line) do
    %Jason.OrderedObject{values: values} = Jason.decode!(line, objects: :ordered_objects)
    Enum.map(values, &elem(&1, 0))
  end

  defp run_jsonl(header_overrides, answer_overrides, end_overrides) do
    [
      Run.encode(Run.header(header_fields(header_overrides))),
      Run.encode(Run.answer_line(choice_answer(answer_overrides))),
      Run.encode(Run.answer_line(noul_answer(answer_overrides))),
      Run.encode(Run.end_line(end_fields(end_overrides)))
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # ---------- line builders ----------

  test "header/1 sets type and schema_version and stringifies keys at every depth" do
    header = Run.header(header_fields())

    assert header["type"] == "run_manifest"
    assert header["schema_version"] == 1
    assert header["info"]["model_id"] == "eval-random"
    assert header["adapter_opts"] == %{"base_url" => "http://127.0.0.1:8900"}
    assert header["limit"] == nil
  end

  test "answer_line/1 sets type answer and turns {label, p} tuples into [label, p] pairs" do
    line = Run.answer_line(choice_answer())

    assert line["type"] == "answer"

    assert line["result"]["probs"] == [
             ["business", 0.5],
             ["personal", 0.25],
             ["newsletter", 0.25]
           ]
  end

  test "answer_line/1 keeps exactly the Decide result keys per qtype (no backend, latency_ms, provenance)" do
    extras = %{
      backend: Kerf.Eval.Adapters.Random,
      latency_ms: 3,
      provenance: %{taint: :tainted, origin: :derived, sources: ["it-0001"]}
    }

    choice = Run.answer_line(choice_answer(%{result: Map.merge(choice_answer().result, extras)}))
    noul = Run.answer_line(noul_answer(%{result: Map.merge(%{p_yes: 0.75}, extras)}))

    score =
      Run.answer_line(
        noul_answer(%{
          qtype: "score",
          question: "urgency",
          result:
            Map.merge(
              %{expected: 1.5, probs: [{"1", 0.5}, {"2", 0.5}], confidence: 0.4},
              extras
            )
        })
      )

    assert choice["result"] |> Map.keys() |> Enum.sort() == ["confidence", "label", "probs"]
    assert noul["result"] |> Map.keys() |> Enum.sort() == ["p_yes"]
    assert score["result"] |> Map.keys() |> Enum.sort() == ["confidence", "expected", "probs"]
  end

  test "answer_line/1 on an adapter error carries result null and the error text" do
    line = Run.answer_line(noul_answer(%{result: nil, error: ":timeout"}))

    assert line["result"] == nil
    assert line["error"] == ":timeout"
  end

  test "end_line/1 sets type run_end and keeps the counts" do
    line = Run.end_line(end_fields(%{answers: 7700, errors: 3}))

    assert line["type"] == "run_end"
    assert line["answers"] == 7700
    assert line["errors"] == 3
  end

  # ---------- deterministic encoding ----------

  test "encode/1 renders an answer line byte-for-byte in the plan 2.3 key order" do
    expected =
      ~s({"type":"answer","item_id":"it-0002","doc_id":null,"language":"de","tier":"hard",) <>
        ~s("split":"eval","pair_id":null,"question":"needs_reply","qtype":"noul",) <>
        ~s("probe":"main","packed":true,"order_index":0,"order":null,"gold":true,) <>
        ~s("result":{"p_yes":0.75},"latency_ms":12,"error":null})

    assert Run.encode(Run.answer_line(noul_answer())) == expected
  end

  test "encode/1 orders header, answer and run_end keys as in plan 2.3" do
    assert keys_in_order(Run.encode(Run.header(header_fields()))) == @header_order
    assert keys_in_order(Run.encode(Run.answer_line(noul_answer()))) == @answer_order
    assert keys_in_order(Run.encode(Run.end_line(end_fields()))) == @end_order
  end

  test "encode/1 orders choice result keys label, probs, confidence" do
    line = Run.encode(Run.answer_line(choice_answer()))

    %Jason.OrderedObject{values: values} = Jason.decode!(line, objects: :ordered_objects)
    {"result", %Jason.OrderedObject{values: result}} = List.keyfind(values, "result", 0)

    assert Enum.map(result, &elem(&1, 0)) == ["label", "probs", "confidence"]
  end

  test "encode/1 is independent of input key order and of atom versus string keys" do
    atoms = noul_answer()
    strings = Map.new(atoms, fn {key, value} -> {Atom.to_string(key), value} end)

    reversed =
      atoms |> Map.to_list() |> Enum.reverse() |> Map.new()

    assert Run.encode(Run.answer_line(atoms)) == Run.encode(Run.answer_line(strings))
    assert Run.encode(Run.answer_line(atoms)) == Run.encode(Run.answer_line(reversed))
  end

  test "encode/1 sorts the keys of nested adapter_opts" do
    opts = %{b: 1, a: 2, c: %{z: 1, y: 2}}
    line = Run.encode(Run.header(header_fields(%{adapter_opts: opts})))

    assert line =~ ~s("adapter_opts":{"a":2,"b":1,"c":{"y":2,"z":1}})
  end

  # ---------- write / read ----------

  test "write/3 then read/1 round-trips header, answers and run_end", %{path: path} do
    header = Run.header(header_fields())
    answers = [Run.answer_line(choice_answer()), Run.answer_line(noul_answer())]
    run_end = Run.end_line(end_fields())

    assert :ok = Run.write(path, header, answers ++ [run_end])
    assert {:ok, {^header, ^answers, ^run_end}} = Run.read(path)
  end

  test "write/3 writes one line per record, header first and run_end last, newline-terminated",
       %{path: path} do
    header = Run.header(header_fields())
    answers = [Run.answer_line(choice_answer()), Run.answer_line(noul_answer())]
    run_end = Run.end_line(end_fields())

    :ok = Run.write(path, header, answers ++ [run_end])

    contents = File.read!(path)
    lines = String.split(contents, "\n", trim: true)

    assert String.ends_with?(contents, "\n")
    assert length(lines) == 4
    assert hd(lines) == Run.encode(header)
    assert List.last(lines) == Run.encode(run_end)
  end

  test "write/3 twice with the same input produces identical bytes", %{path: path} do
    header = Run.header(header_fields())
    lines = [Run.answer_line(noul_answer()), Run.end_line(end_fields())]

    :ok = Run.write(path, header, lines)
    first = File.read!(path)
    :ok = Run.write(path, header, lines)

    assert File.read!(path) == first
  end

  # ---------- normalize ----------

  test "normalize/1 makes two runs that differ only in latency, timestamps and run_id identical" do
    run_a = run_jsonl(%{}, %{}, %{})

    run_b =
      run_jsonl(
        %{run_id: "decide-v1-random-s1-2026-10-23T08:00:00Z", started_at: "2026-10-23T08:00:00Z"},
        %{latency_ms: 987},
        %{finished_at: "2026-10-23T08:09:00Z"}
      )

    refute run_a == run_b
    assert {:ok, normalized_a} = Run.normalize(run_a)
    assert {:ok, normalized_b} = Run.normalize(run_b)
    assert normalized_a == normalized_b
  end

  test "normalize/1 drops exactly latency_ms, started_at, finished_at and run_id" do
    run = run_jsonl(%{}, %{}, %{})
    {:ok, normalized} = Run.normalize(run)

    original_lines = run |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    normalized_lines = normalized |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert length(normalized_lines) == length(original_lines)

    for {before, after_} <- Enum.zip(original_lines, normalized_lines) do
      assert Map.keys(after_) |> Enum.sort() ==
               (Map.keys(before) -- @dropped) |> Enum.sort()

      for key <- Map.keys(after_), do: assert(after_[key] == before[key])
    end
  end

  test "normalize/1 still tells runs apart when anything else differs" do
    {:ok, a} = Run.normalize(run_jsonl(%{}, %{}, %{}))
    {:ok, b} = Run.normalize(run_jsonl(%{}, %{gold: false}, %{}))

    refute a == b
  end

  test "normalize/1 of malformed JSONL is an error" do
    assert {:error, _} = Run.normalize("{\"type\":\"run_manifest\"\nnot json\n")
  end

  # ---------- malformed files ----------

  @valid_header ~s({"type":"run_manifest","schema_version":1,"run_id":"r","seed":1})
  @valid_answer ~s({"type":"answer","item_id":"it-0001","question":"category"})
  @valid_end ~s({"type":"run_end","finished_at":"2026-10-22T10:05:00Z","answers":1,"errors":0})

  defp read_text(path, text) do
    File.write!(path, text)
    Run.read(path)
  end

  test "read/1 of a missing file is an error" do
    path =
      Path.join(System.tmp_dir!(), "kerf-eval-run-missing-#{System.unique_integer([:positive])}")

    assert {:error, _} = Run.read(path)
  end

  test "read/1 of an empty file is an error", %{path: path} do
    assert {:error, _} = read_text(path, "")
  end

  test "read/1 of a truncated file (no run_end line) is an error", %{path: path} do
    assert {:error, _} = read_text(path, @valid_header <> "\n" <> @valid_answer <> "\n")
  end

  test "read/1 of a file with a non-JSON line is an error", %{path: path} do
    text = Enum.join([@valid_header, "{not json", @valid_end], "\n") <> "\n"

    assert {:error, _} = read_text(path, text)
  end

  test "read/1 of a file whose first line is not the run_manifest header is an error",
       %{path: path} do
    text = Enum.join([@valid_answer, @valid_end], "\n") <> "\n"

    assert {:error, _} = read_text(path, text)
  end

  test "read/1 of a file with an unknown line type is an error", %{path: path} do
    text = Enum.join([@valid_header, ~s({"type":"mystery"}), @valid_end], "\n") <> "\n"

    assert {:error, _} = read_text(path, text)
  end

  test "read/1 accepts a header plus run_end with no answers", %{path: path} do
    text = Enum.join([@valid_header, @valid_end], "\n") <> "\n"

    assert {:ok, {%{"type" => "run_manifest"}, [], %{"type" => "run_end"}}} =
             read_text(path, text)
  end
end
