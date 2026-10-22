defmodule Kerf.Dashboard.Eval.EvalUIConfigTest do
  @moduledoc """
  SPEC_H plan §2.8 — the labelling page is mounted by config, never in a
  release. These read the files, so a later edit that leaks `:eval_ui` into
  prod or runtime config fails here.
  """
  use ExUnit.Case, async: true

  test "config/prod.exs and config/runtime.exs never mention :eval_ui" do
    for file <- ["config/prod.exs", "config/runtime.exs"] do
      refute File.read!(file) =~ "eval_ui", "#{file} must not mention :eval_ui"
    end
  end

  test "router.ex mounts the page only under compile_env(:kerf, :eval_ui)" do
    router = File.read!("lib/kerf/dashboard/router.ex")

    assert router =~ "compile_env(:kerf, :eval_ui)"
    assert router =~ "eval_label: Kerf.Dashboard.Live.Eval.LabelPage"
  end

  test "dev.exs reads the manifest path from KERF_EVAL_MANIFEST" do
    dev = File.read!("config/dev.exs")

    assert dev =~ "config :kerf, :eval_ui"
    assert dev =~ ~s|System.get_env("KERF_EVAL_MANIFEST")|
  end

  test "test.exs sets :eval_ui with no manifest path" do
    test_config = File.read!("config/test.exs")

    assert test_config =~ "config :kerf, :eval_ui, manifest_path: nil"
  end
end
