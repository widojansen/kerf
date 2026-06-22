defmodule Kerf.Agents.EmailTriage.BodyPrepTest do
  # RED phase: defines the contract for the not-yet-implemented pure
  # body-preparation function. The skeleton in lib/.../body_prep.ex is a
  # pass-through placeholder, so every test here is expected to FAIL until
  # the GREEN implementation lands (separate, authorised step).
  use ExUnit.Case, async: true

  alias Kerf.Agents.EmailTriage.BodyPrep

  # ---------------------------------------------------------------------------
  # Fixtures — modelled on the audit's real failing cases (tweakers /
  # selfpublishing / dtdg). Pasted verbatim-ish, NOT fetched.
  # ---------------------------------------------------------------------------

  # Tweakers-style: an edition/TOC header front-loads the body; the substantive
  # article named in the subject ("Hermen Hulst") sits AFTER the table of
  # contents — i.e. past the old 2000-byte positional cut.
  @toc_newsletter """
  Tweakers Nieuwsbrief - Editie 245287 - zondag 21 juni 2026 19:00
  ----------------------------------------------------------------

  INHOUD VAN DEZE NIEUWSBRIEF
  ---------------------------

  1. REVIEWS
  2. NIEUWS
  3. DOWNLOADS
  4. PRICEWATCH
  5. JOBS
  6. PRODUCTREVIEWS
  7. FORUM


  2. NIEUWS
  ---------

  Sony-topman Hermen Hulst van Guerilla Games: pc-ports leveren te weinig op
  Hermen Hulst stelt dat de pc-ports voor Sony teleurstellend zijn en dat de
  focus weer op exclusives moet liggen.
  """

  # Otherwise-clean short body wrapped in newsletter chrome: a "view in browser"
  # header and an unsubscribe/address footer that must be stripped, leaving the
  # one substantive paragraph intact.
  @clean_short_with_chrome """
  View this email in your browser

  Hi Wido, our Q2 invoice-processing pilot hit 98.3% extraction accuracy on
  automotive parts catalogs. Can we schedule 30 minutes next week to review the
  rollout plan?

  Unsubscribe | Manage preferences
  123 Market St, Springfield
  """

  # Tracking/URL-dominant lines (hubspot redirect, datadog profile links) that
  # carry no readable content and should be dropped.
  @tracking_heavy """
  Happening Tuesday: Free training

  SP Logo Hubspot Email (https://cvLh304.na1.hubspotlinks.com/Ctc/S+113/cvLh304/VWZn1_1dfhQ3W3CNB_64bg1pQW78L4Hk5Qz9nrN5bb0hn34WdRW69sMD-6lZ3lpW7plQcz8LLS0dW14FgwP91y1TN)

  What if your book succeeded even if nobody read it? The smartest entrepreneurs
  write books to win clients, not royalties.

  https://app.datadoghq.eu/account/profile/b7dfd935-7015-11ef-ab26-7e4863d62115
  """

  # Repeated separator / rule lines that should not survive cleaning.
  @separator_heavy """
  Headline that matters.
  ======================
  ----------------------
  ______________________
  Body sentence with the real content about automotive parts.
  """

  # Blank-line and intra-line whitespace runs to collapse.
  @whitespace_noisy "First paragraph here.\n\n\n\n\nSecond    paragraph    here."

  # Clean, single-spaced ASCII with no boilerplate: cleaning is a no-op on the
  # content, so byte budgeting can be asserted exactly.
  @boundary_body "Quarterly revenue rose twelve percent and churn dropped to four percent overall."

  # ---------------------------------------------------------------------------
  # 1. Leading edition/TOC header stripped; substantive content surfaced.
  # ---------------------------------------------------------------------------
  test "strips the leading edition/TOC header and surfaces the substantive article" do
    out = BodyPrep.prepare(@toc_newsletter)

    # substantive markers survive
    assert out =~ "Hermen Hulst"
    assert out =~ "pc-ports leveren te weinig op"

    # TOC / edition boilerplate is gone
    refute out =~ "Editie 245287"
    refute out =~ "INHOUD VAN DEZE NIEUWSBRIEF"
    refute out =~ "PRICEWATCH"
  end

  # ---------------------------------------------------------------------------
  # 2. Clean short body passes through, minus the surrounding chrome.
  # ---------------------------------------------------------------------------
  test "removes view-in-browser/unsubscribe/footer chrome from a short clean body" do
    out = BodyPrep.prepare(@clean_short_with_chrome)

    assert out =~ "98.3% extraction accuracy"
    assert out =~ "schedule 30 minutes next week"

    refute out =~ "View this email in your browser"
    refute out =~ "Unsubscribe"
    refute out =~ "Manage preferences"
    refute out =~ "123 Market St"
  end

  # ---------------------------------------------------------------------------
  # 3. URL / tracking-dominant lines dropped.
  # ---------------------------------------------------------------------------
  test "drops URL- and tracking-dominant lines while keeping prose" do
    out = BodyPrep.prepare(@tracking_heavy)

    assert out =~ "smartest entrepreneurs"
    assert out =~ "win clients"

    refute out =~ "hubspotlinks.com"
    refute out =~ "datadoghq.eu/account/profile"
  end

  # ---------------------------------------------------------------------------
  # 4. Repeated separator / rule lines removed.
  # ---------------------------------------------------------------------------
  test "removes repeated separator/rule lines" do
    out = BodyPrep.prepare(@separator_heavy)

    assert out =~ "real content about automotive parts"
    refute out =~ "======"
    refute out =~ "------"
    refute out =~ "______"
  end

  # ---------------------------------------------------------------------------
  # 5. Whitespace / blank-line runs collapsed.
  # ---------------------------------------------------------------------------
  test "collapses runs of blank lines and intra-line whitespace" do
    out = BodyPrep.prepare(@whitespace_noisy)

    assert out =~ "Second paragraph here."
    refute out =~ "\n\n\n"
    refute out =~ "    "
  end

  # ---------------------------------------------------------------------------
  # 6. Empty / whitespace-only degrades gracefully to "".
  # ---------------------------------------------------------------------------
  test "returns empty string for empty or whitespace-only input" do
    assert BodyPrep.prepare("") == ""
    assert BodyPrep.prepare("   \n\t  \r\n ") == ""
  end

  # ---------------------------------------------------------------------------
  # 7. Byte budget respected exactly at the boundary.
  # ---------------------------------------------------------------------------
  test "caps output at the byte budget and passes through at exact fit" do
    full = byte_size(@boundary_body)

    # exact fit: whole clean body passes through untouched
    assert BodyPrep.prepare(@boundary_body, budget: full) == @boundary_body

    # one byte under budget: content exceeds the cap, so output must be capped
    out = BodyPrep.prepare(@boundary_body, budget: full - 1)
    assert byte_size(out) <= full - 1
  end

  # ---------------------------------------------------------------------------
  # 8. Budget is a parameter, with a ~4000-byte default.
  # ---------------------------------------------------------------------------
  test "budget is a parameter with a ~4000-byte default" do
    line = "Operational metrics remained within target ranges across all regions this quarter.\n"
    long = String.duplicate(line, 80) <> "ZZEND_MARKER\n"
    # sanity: the marker sits well beyond the 4000-byte default cut
    assert byte_size(long) > 6000

    # default budget (~4000) excludes the tail marker
    refute BodyPrep.prepare(long) =~ "ZZEND_MARKER"
    assert byte_size(BodyPrep.prepare(long)) <= 4000

    # a larger explicit budget includes it
    assert BodyPrep.prepare(long, budget: 8000) =~ "ZZEND_MARKER"
  end
end
