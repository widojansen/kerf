defmodule Kerf.Eval.Manifest.OverridesTest do
  @moduledoc """
  SPEC_H F08.7 / A3.8 — golden-overrides.jsonl, line shape {doc_id, label_true,
  note} per SPEC_D §7; label_true must be in the SPEC_C 6-value enum (A1.9).
  Fixture lines are synthetic.
  """
  use ExUnit.Case, async: true

  alias Kerf.Eval.Manifest.Overrides

  defp write!(lines) do
    path =
      Path.join(
        System.tmp_dir!(),
        "kerf_eval_overrides_test_#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, lines)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp line(doc_id, label, note \\ "ruling"),
    do: Jason.encode!(%{"doc_id" => doc_id, "label_true" => label, "note" => note})

  test "loads doc_id => category for SPEC_D §7 lines" do
    path = write!(Enum.join([line("doc-0001", "business"), line("doc-0002", "social")], "\n"))
    assert {:ok, %{"doc-0001" => "business", "doc-0002" => "social"} = map} = Overrides.load(path)
    assert map_size(map) == 2
  end

  test "accepts every SPEC_C category and tolerates a trailing newline" do
    cats = ~w(business personal newsletter transactional spam social)
    lines = cats |> Enum.with_index() |> Enum.map(fn {c, i} -> line("doc-#{i}", c) end)
    assert {:ok, map} = Overrides.load(write!(Enum.join(lines, "\n") <> "\n"))
    assert map |> Map.values() |> Enum.sort() == Enum.sort(cats)
  end

  test "label_true outside the 6-value enum is an error" do
    path = write!(Enum.join([line("doc-0001", "business"), line("doc-0002", "invoice")], "\n"))
    assert {:error, _} = Overrides.load(path)
  end

  test "a malformed line is an error" do
    path = write!(Enum.join([line("doc-0001", "business"), "{not json"], "\n"))
    assert {:error, _} = Overrides.load(path)
  end

  test "a line without label_true is an error" do
    path = write!(Jason.encode!(%{"doc_id" => "doc-0001", "note" => "x"}))
    assert {:error, _} = Overrides.load(path)
  end

  test "a missing file is an error" do
    assert {:error, _} =
             Overrides.load(Path.join(System.tmp_dir!(), "kerf_no_such_overrides.jsonl"))
  end
end
