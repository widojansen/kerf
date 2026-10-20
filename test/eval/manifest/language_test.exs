defmodule Kerf.Eval.Manifest.LanguageTest do
  @moduledoc """
  SPEC_H F08.1 / A3.5 — stopword-ratio language heuristic (plan §2.1).
  Sample sentences are invented; no mail content.
  """
  use ExUnit.Case, async: true

  alias Kerf.Eval.Manifest.Language

  test "Dutch" do
    text =
      "Kunnen we morgen om tien uur een afspraak maken? Ik heb de stukken voor de " <>
        "vergadering al naar je gestuurd en het is niet dringend."

    assert Language.guess(text) == "nl"
  end

  test "German" do
    text =
      "Können wir uns morgen um zehn Uhr treffen? Ich habe die Unterlagen für die " <>
        "Besprechung schon geschickt und es ist nicht dringend."

    assert Language.guess(text) == "de"
  end

  test "English" do
    text =
      "Can we meet tomorrow at ten? I have already sent the documents for the " <>
        "meeting and it is not urgent."

    assert Language.guess(text) == "en"
  end

  test "empty text is und" do
    assert Language.guess("") == "und"
  end

  test "text without any stopword is und" do
    assert Language.guess("12345 67890 !!!") == "und"
  end
end
