defmodule Kerf.Agents.EmailTriage.TaxonomyTest do
  use Kerf.DataCase

  import ExUnit.CaptureLog
  require Logger

  alias Kerf.Agents.EmailTriage.Taxonomy
  alias Kerf.Agents.EmailTriage.TriageRecord
  alias Kerf.KnowledgeBase.Document

  # ---------- design decisions captured by these tests ----------
  #
  # reject/2: DELETE the pending row entirely. No `rejected_at` column.
  #   Trade-off: simpler; an LLM that re-proposes a rejected value will recreate
  #   the pending row (acceptable churn — surfaces in list_pending again).
  #
  # rename/3: atomic UPDATE in Repo.transaction over both the taxonomy row
  #   and every TriageRecord that references the old value.
  #   Trade-off: touches many rows in one tx; required for correctness —
  #   stale "ghost values" silently break routing rules and queries.
  #
  # record_proposal/3: increments usage_count for PENDING rows only.
  #   usage_count is a review-period metric (how many times proposed while
  #   pending), not a lifetime popularity metric. Once accepted, the column
  #   is frozen as historical "how popular during review".
  #   The triage_record_id parameter is consumed for log observability only —
  #   no schema column for it in v1. Logged via journald rather than stored;
  #   promote to a join table if forensic queries become frequent.
  #
  # Function return shape extends spec §4.7 slightly: `:ok | {:error, atom()}`
  # (spec only specifies `:ok`; error tuples make error paths testable).

  # ---------- fixtures ----------

  # Base vocabularies from spec §2.4 and §2.5.
  @seed_topics ~w(kerf legal financial automotive agency_partner family infrastructure ai_industry dev_tools)
  @seed_actions ~w(reply_needed review schedule pay file delete_candidate fyi)

  defp insert_document!(source_id) do
    {:ok, doc} =
      Repo.insert(
        Document.changeset(%Document{}, %{source_type: "email", source_id: source_id})
      )

    doc
  end

  defp insert_classified_triage!(source_id, classify_overrides \\ %{}) do
    doc = insert_document!(source_id)

    attrs =
      Map.merge(
        %{
          document_id: doc.id,
          category: "business",
          sender_type: "known_priority",
          classifier_source: "fast_classifier",
          confidence: 1.0
        },
        classify_overrides
      )

    {:ok, triage} =
      %TriageRecord{}
      |> TriageRecord.classify_changeset(attrs)
      |> Repo.insert()

    triage
  end

  defp enrich!(triage, enrich_overrides) do
    attrs =
      Map.merge(
        %{
          urgency: "low",
          action: "fyi",
          topic: ["kerf"],
          summary: "test enrichment",
          enrichment_version: 1
        },
        enrich_overrides
      )

    {:ok, enriched} =
      triage
      |> TriageRecord.enrich_changeset(attrs)
      |> Repo.update()

    enriched
  end

  # ---------- seed migration ----------

  describe "seed migration" do
    test "list_accepted(:topic) returns the 9 base topic values from spec §2.5" do
      accepted = Taxonomy.list_accepted(:topic)
      assert Enum.sort(accepted) == Enum.sort(@seed_topics)
    end

    test "list_accepted(:action) returns the 7 base action values from spec §2.4" do
      accepted = Taxonomy.list_accepted(:action)
      assert Enum.sort(accepted) == Enum.sort(@seed_actions)
    end

    test "every seeded row has proposed_by = 'seed' and accepted_at != nil" do
      # Direct table queries — bypasses the module to verify seed-migration metadata.
      {:ok, topic_res} =
        Ecto.Adapters.SQL.query(
          Repo,
          "SELECT value, proposed_by, accepted_at FROM email_topic_taxonomy WHERE accepted = TRUE",
          []
        )

      assert length(topic_res.rows) == length(@seed_topics)

      Enum.each(topic_res.rows, fn [_value, proposed_by, accepted_at] ->
        assert proposed_by == "seed"
        refute is_nil(accepted_at)
      end)

      {:ok, action_res} =
        Ecto.Adapters.SQL.query(
          Repo,
          "SELECT value, proposed_by, accepted_at FROM email_action_taxonomy WHERE accepted = TRUE",
          []
        )

      assert length(action_res.rows) == length(@seed_actions)

      Enum.each(action_res.rows, fn [_value, proposed_by, accepted_at] ->
        assert proposed_by == "seed"
        refute is_nil(accepted_at)
      end)
    end
  end

  # ---------- list_accepted/1 ----------

  describe "list_accepted/1" do
    test "excludes pending rows" do
      triage = insert_classified_triage!("msg_list_accepted_excludes_pending")
      :ok = Taxonomy.record_proposal(:topic, "experimental_topic", triage.id)

      accepted = Taxonomy.list_accepted(:topic)
      refute "experimental_topic" in accepted
      # Seed values still present.
      assert "kerf" in accepted
    end

    test "returns only string values" do
      Enum.each(Taxonomy.list_accepted(:topic), fn v -> assert is_binary(v) end)
      Enum.each(Taxonomy.list_accepted(:action), fn v -> assert is_binary(v) end)
    end
  end

  # ---------- list_pending/1 ----------

  describe "list_pending/1" do
    test "returns [] when no pending proposals exist" do
      assert Taxonomy.list_pending(:topic) == []
      assert Taxonomy.list_pending(:action) == []
    end

    test "returns pending rows with value, usage_count, proposed_at, proposed_by" do
      triage = insert_classified_triage!("msg_list_pending_shape")
      :ok = Taxonomy.record_proposal(:topic, "new_topic_xyz", triage.id)

      [entry] = Taxonomy.list_pending(:topic)

      assert entry.value == "new_topic_xyz"
      assert entry.usage_count == 1
      assert %DateTime{} = entry.proposed_at
      assert entry.proposed_by == "llm"
    end

    test "excludes accepted rows" do
      # The seed has 9 accepted topics; none should appear in pending.
      assert Taxonomy.list_pending(:topic) == []
      assert Taxonomy.list_pending(:action) == []
    end
  end

  # ---------- record_proposal/3 ----------

  describe "record_proposal/3" do
    test "first call inserts a pending row with usage_count=1 and proposed_by='llm'" do
      triage = insert_classified_triage!("msg_record_proposal_first")
      :ok = Taxonomy.record_proposal(:topic, "brand_new_topic", triage.id)

      [entry] = Taxonomy.list_pending(:topic)
      assert entry.value == "brand_new_topic"
      assert entry.usage_count == 1
      assert entry.proposed_by == "llm"
    end

    test "second call with the same value bumps usage_count" do
      triage_a = insert_classified_triage!("msg_record_proposal_bump_a")
      triage_b = insert_classified_triage!("msg_record_proposal_bump_b")

      :ok = Taxonomy.record_proposal(:topic, "frequent_topic", triage_a.id)
      :ok = Taxonomy.record_proposal(:topic, "frequent_topic", triage_b.id)

      [entry] = Taxonomy.list_pending(:topic)
      assert entry.value == "frequent_topic"
      assert entry.usage_count == 2
    end

    test "third call with the same value bumps usage_count to 3" do
      triage_a = insert_classified_triage!("msg_record_proposal_triple_a")
      triage_b = insert_classified_triage!("msg_record_proposal_triple_b")
      triage_c = insert_classified_triage!("msg_record_proposal_triple_c")

      :ok = Taxonomy.record_proposal(:topic, "triple_topic", triage_a.id)
      :ok = Taxonomy.record_proposal(:topic, "triple_topic", triage_b.id)
      :ok = Taxonomy.record_proposal(:topic, "triple_topic", triage_c.id)

      [entry] = Taxonomy.list_pending(:topic)
      assert entry.usage_count == 3
    end

    test "proposing a value already in accepted vocab is a no-op (usage_count unchanged)" do
      # usage_count is a review-period metric (how many times proposed while
      # pending), not a lifetime popularity metric. Once accepted, the column
      # is frozen as historical "how popular during review".
      triage = insert_classified_triage!("msg_record_proposal_on_accepted")

      assert :ok = Taxonomy.record_proposal(:topic, "kerf", triage.id)

      {:ok, %{rows: [[count]]}} =
        Ecto.Adapters.SQL.query(
          Repo,
          "SELECT usage_count FROM email_topic_taxonomy WHERE value = 'kerf'",
          []
        )

      # Seed inserts usage_count = 0 (default); proposal on accepted is a no-op.
      assert count == 0
      # And "kerf" remains accepted, not flipped back to pending.
      assert "kerf" in Taxonomy.list_accepted(:topic)
      refute Enum.any?(Taxonomy.list_pending(:topic), fn e -> e.value == "kerf" end)
    end

    test "emits a Logger.info event carrying triage_record_id, value, and dimension" do
      # Logged via journald rather than stored — promote to a join table if
      # forensic queries become frequent.
      triage = insert_classified_triage!("msg_record_proposal_observability")

      # config/test.exs sets Logger level to :warning, which suppresses info
      # at the source before capture_log sees it. Temporarily raise the level
      # for this test only (DataCase is sync, so no test-isolation concerns).
      previous_level = Logger.level()
      Logger.configure(level: :info)

      log =
        try do
          capture_log(fn ->
            :ok = Taxonomy.record_proposal(:topic, "observed_topic", triage.id)
          end)
        after
          Logger.configure(level: previous_level)
        end

      # Loose contract: the id, value, and dimension must flow somewhere
      # observable in the log output. Implementation may use message text,
      # metadata, or both.
      assert log =~ triage.id
      assert log =~ "observed_topic"
      assert log =~ "topic"
    end
  end

  # ---------- accept/2 ----------

  describe "accept/2" do
    test "flips a pending row to accepted=true and sets accepted_at" do
      triage = insert_classified_triage!("msg_accept_flip")
      :ok = Taxonomy.record_proposal(:topic, "ready_to_accept", triage.id)

      :ok = Taxonomy.accept(:topic, "ready_to_accept")

      assert "ready_to_accept" in Taxonomy.list_accepted(:topic)
      refute Enum.any?(Taxonomy.list_pending(:topic), fn e -> e.value == "ready_to_accept" end)

      {:ok, %{rows: [[accepted_at]]}} =
        Ecto.Adapters.SQL.query(
          Repo,
          "SELECT accepted_at FROM email_topic_taxonomy WHERE value = 'ready_to_accept'",
          []
        )

      refute is_nil(accepted_at)
    end

    test "accept on already-accepted value is idempotent (no error)" do
      # 'kerf' is a seed value, already accepted.
      assert :ok = Taxonomy.accept(:topic, "kerf")
      assert "kerf" in Taxonomy.list_accepted(:topic)
    end

    test "accept on non-existent value returns {:error, :not_found}" do
      assert {:error, :not_found} = Taxonomy.accept(:topic, "does_not_exist")
    end
  end

  # ---------- reject/2 ----------

  describe "reject/2" do
    # Design: DELETE the row. See module-level comment for tradeoff.

    test "reject deletes a pending row entirely" do
      triage = insert_classified_triage!("msg_reject_pending")
      :ok = Taxonomy.record_proposal(:topic, "doomed_value", triage.id)
      assert Enum.any?(Taxonomy.list_pending(:topic), fn e -> e.value == "doomed_value" end)

      :ok = Taxonomy.reject(:topic, "doomed_value")

      refute Enum.any?(Taxonomy.list_pending(:topic), fn e -> e.value == "doomed_value" end)
      refute "doomed_value" in Taxonomy.list_accepted(:topic)

      # Direct row check.
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          Repo,
          "SELECT value FROM email_topic_taxonomy WHERE value = 'doomed_value'",
          []
        )

      assert rows == []
    end

    test "reject refuses to remove accepted vocab (returns {:error, :cannot_reject_accepted})" do
      # Seed values are accepted; reject must not delete them.
      assert {:error, :cannot_reject_accepted} = Taxonomy.reject(:topic, "kerf")
      assert "kerf" in Taxonomy.list_accepted(:topic)
    end

    test "reject on non-existent value returns :ok (idempotent)" do
      assert :ok = Taxonomy.reject(:topic, "never_existed_anywhere")
    end
  end

  # ---------- rename/3 ----------

  describe "rename/3" do
    # Design: atomic Repo.transaction. Renames the taxonomy row AND every
    # TriageRecord row referencing the old value. See module-level comment.
    # TODO: explicit fault-injection test for mid-transaction failure deferred
    # — relying on Repo.transaction semantics (commit-all-or-rollback-all) for
    # now. If a partial-rename incident ever happens, add a test that forces
    # a failure between the taxonomy UPDATE and the TriageRecord UPDATE and
    # asserts both rolled back together.

    test "renames an accepted topic value in the taxonomy table" do
      :ok = Taxonomy.rename(:topic, "ai_industry", "ai_news")

      accepted = Taxonomy.list_accepted(:topic)
      refute "ai_industry" in accepted
      assert "ai_news" in accepted
    end

    test "atomically updates TriageRecord.topic arrays containing the old value" do
      triage_a = insert_classified_triage!("msg_rename_topic_a") |> enrich!(%{topic: ["ai_industry"]})
      triage_b = insert_classified_triage!("msg_rename_topic_b") |> enrich!(%{topic: ["ai_industry", "kerf"]})
      triage_c = insert_classified_triage!("msg_rename_topic_c") |> enrich!(%{topic: ["legal"]})

      :ok = Taxonomy.rename(:topic, "ai_industry", "ai_news")

      assert Repo.get!(TriageRecord, triage_a.id).topic == ["ai_news"]
      assert Repo.get!(TriageRecord, triage_b.id).topic == ["ai_news", "kerf"]
      # Unrelated row left alone.
      assert Repo.get!(TriageRecord, triage_c.id).topic == ["legal"]
    end

    test "for :action, updates TriageRecord.action scalar field on matching rows" do
      triage_a = insert_classified_triage!("msg_rename_action_a") |> enrich!(%{action: "schedule"})
      triage_b = insert_classified_triage!("msg_rename_action_b") |> enrich!(%{action: "review"})

      :ok = Taxonomy.rename(:action, "schedule", "calendar_book")

      assert Repo.get!(TriageRecord, triage_a.id).action == "calendar_book"
      assert Repo.get!(TriageRecord, triage_b.id).action == "review"
    end

    test "rename with non-existent source returns {:error, :not_found}" do
      assert {:error, :not_found} = Taxonomy.rename(:topic, "never_was", "never_will_be")
    end

    test "rename where target already exists in the same dimension returns {:error, :conflict}" do
      # Both "kerf" and "legal" are accepted seeds; renaming kerf → legal should fail.
      assert {:error, :conflict} = Taxonomy.rename(:topic, "kerf", "legal")

      # Verify nothing changed.
      accepted = Taxonomy.list_accepted(:topic)
      assert "kerf" in accepted
      assert "legal" in accepted
    end
  end
end
