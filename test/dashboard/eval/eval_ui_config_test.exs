defmodule Kerf.Dashboard.Eval.EvalUIConfigTest do
  @moduledoc """
  SPEC_H plan §2.8 and §6 D4b (S-36) — the labelling page is mounted by a
  compile-time boolean `:eval_ui`, never in a release; the manifest path is the
  separate runtime key `:eval_manifest_path`. These read the files, so a later
  edit that leaks either key into prod or runtime config, or that makes the
  router compile-read the path again, fails here.
  """
  use ExUnit.Case, async: true

  defp config_lines(file, key),
    do: file |> File.read!() |> String.split("\n") |> Enum.filter(&(&1 =~ "config :kerf, #{key}"))

  test "config/prod.exs and config/runtime.exs mention neither :eval_ui nor :eval_manifest_path" do
    for file <- ["config/prod.exs", "config/runtime.exs"],
        key <- ["eval_ui", "eval_manifest_path"] do
      refute File.read!(file) =~ key, "#{file} must not mention :#{key}"
    end
  end

  test "router.ex's only compile_env call is compile_env(:kerf, :eval_ui)" do
    router = File.read!("lib/kerf/dashboard/router.ex")

    assert Regex.scan(~r/compile_env\(([^)]*)\)/, router, capture: :all_but_first) ==
             [[":kerf, :eval_ui"]]

    assert router =~ "eval_label: Kerf.Dashboard.Live.Eval.LabelPage"
  end

  test "router.ex never mentions :eval_manifest_path" do
    refute File.read!("lib/kerf/dashboard/router.ex") =~ "eval_manifest_path"
  end

  for file <- ["config/dev.exs", "config/test.exs"] do
    test "#{file} sets :eval_ui to the literal true, with no System.get_env on that line" do
      assert [line] = config_lines(unquote(file), ":eval_ui")
      assert String.trim(line) == "config :kerf, :eval_ui, true"
      refute line =~ "System.get_env"
    end
  end

  test "dev.exs sets :eval_manifest_path from KERF_EVAL_MANIFEST" do
    assert [line] = config_lines("config/dev.exs", ":eval_manifest_path")
    assert line =~ ~s|System.get_env("KERF_EVAL_MANIFEST")|
  end

  test "test.exs sets :eval_manifest_path to nil or leaves it absent" do
    lines = config_lines("config/test.exs", ":eval_manifest_path")

    assert Enum.all?(lines, &(String.trim(&1) == "config :kerf, :eval_manifest_path, nil"))
  end
end
