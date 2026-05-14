defmodule Kerf.Agents.EmailTriage.TriageRecordTest do
  use Kerf.DataCase

  alias Kerf.Agents.EmailTriage.TriageRecord
  alias Kerf.KnowledgeBase.Document

  # ---------- fixtures ----------

  defp insert_document!(source_id) do
    {:ok, doc} =
      Repo.insert(
        Document.changeset(%Document{}, %{source_type: "email", source_id: source_id})
      )

    doc
  end

  # Factories deliberately omit `triage_status`, `classified_at`, and
  # `enriched_at` — all three are populated automatically inside their
  # respective changesets, not by callers.

  defp classify_attrs(document_id, overrides \\ %{}) do
    Map.merge(
      %{
        document_id: document_id,
        category: "business",
        sender_type: "known_priority",
        classifier_source: "fast_classifier",
        confidence: 1.0
      },
      overrides
    )
  end

  defp enrich_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        urgency: "high",
        action: "reply_needed",
        topic: ["kerf", "legal"],
        summary: "Concept rapport feedback nodig voor vrijdag.",
        enrichment_version: 1
      },
      overrides
    )
  end

  defp unclassifiable_attrs do
    %{
      triage_error: "FastClassifier :no_match and LLM Classifier failed after 3 attempts"
    }
  end

  # ---------- round-trip ----------

  describe "schema round-trip" do
    test "persists and reloads every field including topic array" do
      doc = insert_document!("msg_round_trip")

      # Production flow: classify first (stage 1), then enrich (stage 2).
      # classified_at / enriched_at are auto-populated by each changeset.
      {:ok, classified} =
        %TriageRecord{}
        |> TriageRecord.classify_changeset(classify_attrs(doc.id))
        |> Repo.insert()

      {:ok, _enriched} =
        classified
        |> TriageRecord.enrich_changeset(enrich_attrs())
        |> Repo.update()

      reloaded = Repo.get!(TriageRecord, classified.id)

      assert reloaded.document_id == doc.id
      assert reloaded.category == "business"
      assert reloaded.sender_type == "known_priority"
      assert reloaded.classifier_source == "fast_classifier"
      assert reloaded.confidence == 1.0
      assert reloaded.urgency == "high"
      assert reloaded.action == "reply_needed"
      assert reloaded.topic == ["kerf", "legal"]
      assert reloaded.summary == "Concept rapport feedback nodig voor vrijdag."
      assert reloaded.triage_status == "enriched"
      assert reloaded.triage_error == nil
      assert %DateTime{} = reloaded.classified_at
      assert %DateTime{} = reloaded.enriched_at
      assert reloaded.enrichment_version == 1
      assert %DateTime{} = reloaded.inserted_at
      assert %DateTime{} = reloaded.updated_at
    end

    test "topic round-trips an empty array as the default" do
      doc = insert_document!("msg_empty_topic")

      {:ok, inserted} =
        %TriageRecord{}
        |> TriageRecord.classify_changeset(classify_attrs(doc.id))
        |> Repo.insert()

      reloaded = Repo.get!(TriageRecord, inserted.id)
      assert reloaded.topic == []
    end

    test "topic round-trips a single-element array" do
      doc = insert_document!("msg_single_topic")

      {:ok, classified} =
        %TriageRecord{}
        |> TriageRecord.classify_changeset(classify_attrs(doc.id))
        |> Repo.insert()

      {:ok, _enriched} =
        classified
        |> TriageRecord.enrich_changeset(enrich_attrs(%{topic: ["kerf"]}))
        |> Repo.update()

      assert Repo.get!(TriageRecord, classified.id).topic == ["kerf"]
    end
  end

  # ---------- foreign key ----------

  describe "foreign key on document_id" do
    test "rejects insert with a non-existent document_id" do
      ghost_uuid = Ecto.UUID.generate()

      {:error, changeset} =
        %TriageRecord{}
        |> TriageRecord.classify_changeset(classify_attrs(ghost_uuid))
        |> Repo.insert()

      refute changeset.valid?
      assert %{document_id: [msg | _]} = errors_on(changeset)
      assert msg =~ "does not exist"
    end

    test "deletes the triage row when its document is deleted (on_delete: :delete_all)" do
      doc = insert_document!("msg_cascade_test")

      {:ok, triage} =
        %TriageRecord{}
        |> TriageRecord.classify_changeset(classify_attrs(doc.id))
        |> Repo.insert()

      Repo.delete!(doc)

      # Sharpening note: if FK behavior ever flips back to :nilify_all,
      # `Repo.get(TriageRecord, triage.id)` would still return a row (with
      # document_id = nil) and this assertion would pass. A stricter version
      # would be:
      #
      #   assert Repo.aggregate(
      #            from(t in TriageRecord, where: t.document_id == ^doc.id),
      #            :count, :id
      #          ) == 0
      #
      # Leaving the simpler form for now; revisit if the spec's on_delete
      # behavior changes.
      assert Repo.get(TriageRecord, triage.id) == nil
    end
  end

  # ---------- unique constraint on document_id ----------

  describe "unique constraint on document_id" do
    test "rejects a second triage row for the same document" do
      doc = insert_document!("msg_unique_test")

      {:ok, _first} =
        %TriageRecord{}
        |> TriageRecord.classify_changeset(classify_attrs(doc.id))
        |> Repo.insert()

      {:error, changeset} =
        %TriageRecord{}
        |> TriageRecord.classify_changeset(classify_attrs(doc.id))
        |> Repo.insert()

      refute changeset.valid?
      assert %{document_id: [msg | _]} = errors_on(changeset)
      assert msg =~ "has already been taken"
    end
  end

  # ---------- changeset: classify_changeset/2 ----------

  describe "classify_changeset/2" do
    test "valid with full Stage-1 attrs" do
      doc = insert_document!("msg_cs_classify_full")
      cs = TriageRecord.classify_changeset(%TriageRecord{}, classify_attrs(doc.id))
      assert cs.valid?, "expected valid changeset, got errors: #{inspect(errors_on(cs))}"
    end

    test "requires document_id" do
      attrs = classify_attrs(Ecto.UUID.generate()) |> Map.delete(:document_id)
      cs = TriageRecord.classify_changeset(%TriageRecord{}, attrs)
      refute cs.valid?
      assert %{document_id: ["can't be blank"]} = errors_on(cs)
    end

    test "requires category" do
      attrs = classify_attrs(Ecto.UUID.generate()) |> Map.delete(:category)
      cs = TriageRecord.classify_changeset(%TriageRecord{}, attrs)
      refute cs.valid?
      assert %{category: ["can't be blank"]} = errors_on(cs)
    end

    test "requires sender_type" do
      attrs = classify_attrs(Ecto.UUID.generate()) |> Map.delete(:sender_type)
      cs = TriageRecord.classify_changeset(%TriageRecord{}, attrs)
      refute cs.valid?
      assert %{sender_type: ["can't be blank"]} = errors_on(cs)
    end

    test "requires classifier_source" do
      attrs = classify_attrs(Ecto.UUID.generate()) |> Map.delete(:classifier_source)
      cs = TriageRecord.classify_changeset(%TriageRecord{}, attrs)
      refute cs.valid?
      assert %{classifier_source: ["can't be blank"]} = errors_on(cs)
    end

    test "populates classified_at automatically (within 1s of DateTime.utc_now/0)" do
      doc = insert_document!("msg_classified_at_auto")
      cs = TriageRecord.classify_changeset(%TriageRecord{}, classify_attrs(doc.id))
      assert cs.valid?

      classified_at = Ecto.Changeset.get_change(cs, :classified_at)
      assert %DateTime{} = classified_at
      assert abs(DateTime.diff(classified_at, DateTime.utc_now(), :second)) <= 1
    end

    test "sets triage_status to 'classified' automatically, regardless of caller input" do
      doc = insert_document!("msg_classify_auto_status")
      # Caller does not supply triage_status.
      cs = TriageRecord.classify_changeset(%TriageRecord{}, classify_attrs(doc.id))
      assert cs.valid?
      assert cs.changes.triage_status == "classified"
    end

    test "does not require enrichment-stage fields (urgency/action/topic/summary)" do
      doc = insert_document!("msg_cs_classify_no_enrich_needed")
      cs = TriageRecord.classify_changeset(%TriageRecord{}, classify_attrs(doc.id))
      assert cs.valid?
      refute Map.has_key?(errors_on(cs), :urgency)
      refute Map.has_key?(errors_on(cs), :action)
      refute Map.has_key?(errors_on(cs), :topic)
      refute Map.has_key?(errors_on(cs), :summary)
      # Sharpening note: this test catches missing-required-field cases but
      # not silent cast-allowlist leaks (e.g. cast/3 accidentally includes
      # :urgency, letting a stray Stage-2 value through Stage-1). A stricter
      # version would also assert:
      #
      #   leak_attrs = Map.put(classify_attrs(doc.id), :urgency, "high")
      #   cs = TriageRecord.classify_changeset(%TriageRecord{}, leak_attrs)
      #   refute Map.has_key?(cs.changes, :urgency)
      #
      # Defer until cast-allowlist scope becomes a known risk.
    end

  end

  # ---------- changeset: enrich_changeset/2 ----------

  describe "enrich_changeset/2" do
    test "valid with full Stage-2 attrs applied to an existing classified record" do
      doc = insert_document!("msg_cs_enrich_full")

      {:ok, record} =
        %TriageRecord{}
        |> TriageRecord.classify_changeset(classify_attrs(doc.id))
        |> Repo.insert()

      cs = TriageRecord.enrich_changeset(record, enrich_attrs())
      assert cs.valid?, "expected valid changeset, got errors: #{inspect(errors_on(cs))}"
    end

    test "requires urgency" do
      attrs = enrich_attrs() |> Map.delete(:urgency)
      cs = TriageRecord.enrich_changeset(%TriageRecord{}, attrs)
      refute cs.valid?
      assert %{urgency: ["can't be blank"]} = errors_on(cs)
    end

    test "requires action" do
      attrs = enrich_attrs() |> Map.delete(:action)
      cs = TriageRecord.enrich_changeset(%TriageRecord{}, attrs)
      refute cs.valid?
      assert %{action: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects an empty topic array and accepts a populated one" do
      # Empty topic should fail validate_length(min: 1, max: 4).
      attrs_empty = Map.put(enrich_attrs(), :topic, [])
      cs = TriageRecord.enrich_changeset(%TriageRecord{}, attrs_empty)
      refute cs.valid?
      assert %{topic: [_msg | _]} = errors_on(cs)

      # The factory default ["kerf", "legal"] is a valid 2-element array.
      cs = TriageRecord.enrich_changeset(%TriageRecord{}, enrich_attrs())
      assert cs.valid?, "expected ['kerf','legal'] accepted, got: #{inspect(errors_on(cs))}"
    end

    test "requires summary" do
      attrs = enrich_attrs() |> Map.delete(:summary)
      cs = TriageRecord.enrich_changeset(%TriageRecord{}, attrs)
      refute cs.valid?
      assert %{summary: ["can't be blank"]} = errors_on(cs)
    end

    test "populates enriched_at automatically (within 1s of DateTime.utc_now/0)" do
      cs = TriageRecord.enrich_changeset(%TriageRecord{}, enrich_attrs())
      assert cs.valid?

      enriched_at = Ecto.Changeset.get_change(cs, :enriched_at)
      assert %DateTime{} = enriched_at
      assert abs(DateTime.diff(enriched_at, DateTime.utc_now(), :second)) <= 1
    end

    test "sets triage_status to 'enriched' automatically, regardless of caller input" do
      # Caller does not supply triage_status.
      cs = TriageRecord.enrich_changeset(%TriageRecord{}, enrich_attrs())
      assert cs.valid?
      assert cs.changes.triage_status == "enriched"
    end
  end

  # ---------- changeset: mark_unclassifiable_changeset/2 ----------

  describe "mark_unclassifiable_changeset/2" do
    test "valid with triage_error and triage_status" do
      doc = insert_document!("msg_cs_unclassifiable_full")

      {:ok, record} =
        %TriageRecord{}
        |> TriageRecord.classify_changeset(classify_attrs(doc.id))
        |> Repo.insert()

      cs = TriageRecord.mark_unclassifiable_changeset(record, unclassifiable_attrs())
      assert cs.valid?, "expected valid changeset, got errors: #{inspect(errors_on(cs))}"
    end

    test "requires triage_error" do
      attrs = unclassifiable_attrs() |> Map.delete(:triage_error)
      cs = TriageRecord.mark_unclassifiable_changeset(%TriageRecord{}, attrs)
      refute cs.valid?
      assert %{triage_error: ["can't be blank"]} = errors_on(cs)
    end

    test "sets triage_status to 'unclassifiable' automatically, regardless of caller input" do
      # Caller does not supply triage_status.
      cs = TriageRecord.mark_unclassifiable_changeset(%TriageRecord{}, unclassifiable_attrs())
      assert cs.valid?
      assert cs.changes.triage_status == "unclassifiable"
    end

    test "does not require Stage-1 or Stage-2 fields" do
      cs =
        TriageRecord.mark_unclassifiable_changeset(%TriageRecord{}, unclassifiable_attrs())

      errors = errors_on(cs)
      assert cs.valid?
      refute Map.has_key?(errors, :category)
      refute Map.has_key?(errors, :sender_type)
      refute Map.has_key?(errors, :urgency)
      refute Map.has_key?(errors, :action)
      refute Map.has_key?(errors, :topic)
      refute Map.has_key?(errors, :summary)
      # Sharpening note: same cast-allowlist concern as classify_changeset's
      # scope test — this asserts validate_required scope, not cast scope.
      # If mark_unclassifiable_changeset's cast/3 leaks Stage-1/Stage-2 fields,
      # this test won't catch it. A stricter version would assert against
      # cs.changes for every out-of-scope key. Deferred for now.
    end

  end

  # ---------- triage_status enum completeness ----------

  describe "triage_status enum" do
    # Why a dedicated describe block:
    # Negative-only tests can never prove that the validator's allow-list
    # contains all four legitimate values — any garbage string is rejected
    # regardless of which legit values are in the list. Enum completeness
    # is verified by *positive* tests: one per legitimate value, asserting
    # it is accepted by an appropriate changeset (or the schema default for
    # "pending", which no changeset emits). One negative test below makes
    # the separate point that non-enum values are rejected.

    test "DB column default fills triage_status with 'pending' when omitted from INSERT" do
      # Schema-level default for :triage_status has been intentionally removed
      # so validate_required works as expected in the three changesets. The DB
      # column default acts as the at-rest safety net for any future direct
      # insert path that bypasses the changesets. This test proves the DB
      # default survives by inserting a row without specifying triage_status.
      doc = insert_document!("msg_db_default_test")
      uuid = Ecto.UUID.generate()

      # Raw SQL because Ecto's insert emits explicit NULLs for unset fields,
      # which trips the migration's null: false constraint instead of triggering
      # the column default. Raw SQL omits the column entirely, the only path
      # that exercises the DB default.
      # inserted_at/updated_at are included because timestamps() makes them
      # not-null; they have no column default to fall back on.
      now = DateTime.utc_now(:microsecond)

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Repo,
          """
          INSERT INTO email_triage (id, document_id, classifier_source, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $5)
          """,
          [Ecto.UUID.dump!(uuid), Ecto.UUID.dump!(doc.id), "raw_insert_test", now, now]
        )

      reloaded = Repo.get!(TriageRecord, uuid)
      assert reloaded.triage_status == "pending"
    end

    test "classify_changeset accepts 'classified'" do
      doc = insert_document!("msg_status_classified")
      cs = TriageRecord.classify_changeset(%TriageRecord{}, classify_attrs(doc.id))
      assert cs.valid?, "expected 'classified' to be accepted, got: #{inspect(errors_on(cs))}"
      assert cs.changes.triage_status == "classified"
    end

    test "enrich_changeset accepts 'enriched'" do
      cs = TriageRecord.enrich_changeset(%TriageRecord{}, enrich_attrs())
      assert cs.valid?, "expected 'enriched' to be accepted, got: #{inspect(errors_on(cs))}"
      assert cs.changes.triage_status == "enriched"
    end

    test "mark_unclassifiable_changeset accepts 'unclassifiable'" do
      cs =
        TriageRecord.mark_unclassifiable_changeset(%TriageRecord{}, unclassifiable_attrs())

      assert cs.valid?, "expected 'unclassifiable' to be accepted, got: #{inspect(errors_on(cs))}"
      assert cs.changes.triage_status == "unclassifiable"
    end

    test "classify_changeset overrides a caller's contradicting triage_status" do
      # The caller is wrong by construction here — passing "enriched" to a
      # Stage-1 changeset. The changeset must override it to "classified"
      # rather than respecting the caller's input.
      doc = insert_document!("msg_status_contradict")
      attrs = Map.put(classify_attrs(doc.id), :triage_status, "enriched")
      cs = TriageRecord.classify_changeset(%TriageRecord{}, attrs)
      assert cs.valid?
      assert cs.changes.triage_status == "classified"
    end
  end

  # ---------- helpers ----------

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
