defmodule Kerf.Agents.EmailTriage.EnricherBuildInputTest do
  # DB-free unit tests for the Enricher's body-preparation step. `build_input/2`
  # is pure (reads struct fields only, no Repo), so these run without a database.
  #
  # RED phase: these pin the NEW behavior — boilerplate stripped via
  # Kerf.Agents.EmailTriage.BodyPrep and a raised (~4000-byte) budget — which the
  # current `truncate_body/1` (2000-byte positional slice) does not satisfy.
  use ExUnit.Case, async: true

  alias Kerf.Agents.EmailTriage.{Enricher, TriageRecord}
  alias Kerf.KnowledgeBase.Document

  defp doc(raw_text, overrides \\ %{}) do
    base = %Document{
      title: "Test Subject",
      raw_text: raw_text,
      source_metadata: %{
        "sender" => "alice@example.com",
        "sender_name" => "Alice",
        "subject" => "Test Subject"
      }
    }

    struct(base, overrides)
  end

  defp record, do: %TriageRecord{sender_type: "known_routine"}

  test "passes a clean body larger than the old 2000-byte cap through (raised budget)" do
    body = String.duplicate("x", 3000)

    input = Enricher.build_input(doc(body), record())

    # Old behaviour truncated this to 2000 bytes; the new budget keeps it.
    assert byte_size(input.body_text) == 3000
    assert input.subject == "Test Subject"
  end

  test "strips boilerplate so substantive content past the old 2000-byte cut survives" do
    header = """
    Newsletter Edition 999
    ======================

    INHOUD VAN DEZE NIEUWSBRIEF
    ---------------------------

    1. NEWS
    2. SPORTS
    3. WEATHER
    """

    # >2000 bytes of tracking-URL chrome that front-loads the body, pushing the
    # real content past the old positional cut.
    url_block =
      String.duplicate(
        "https://track.example.com/click/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
        50
      )

    marker_line = "SUBSTANCE_MARKER The quarterly board meeting moved to Thursday at three.\n"

    input = Enricher.build_input(doc(header <> url_block <> marker_line), record())

    assert input.body_text =~ "SUBSTANCE_MARKER"
    refute input.body_text =~ "track.example.com"
    refute input.body_text =~ "INHOUD VAN DEZE NIEUWSBRIEF"
  end

  test "empty body still yields \"\" so the adapter's synthetic-body fallback engages" do
    input = Enricher.build_input(doc(""), record())
    assert input.body_text == ""
  end
end
