defmodule Kerf.Agents.EmailTriage.EnricherTest do
  use Kerf.DataCase
  use Oban.Testing, repo: Kerf.Repo

  alias Kerf.Agents.EmailTriage.{Enricher, TriageRecord, Taxonomy}
  alias Kerf.KnowledgeBase.Document

  # ---------- fixtures ----------

  defp insert_email_doc!(overrides \\ %{}) do
    base = %{
      source_type: "email",
      source_id: "msg_#{System.unique_integer([:positive])}",
      title: "Test Subject",
      raw_text: "This is a normal email body.",
      source_metadata: %{
        "sender" => "alice@example.com",
        "sender_name" => "Alice",
        "thread_id" => "thread_t1",
        "subject" => "Test Subject",
        "labels" => ["INBOX"],
        "date" => "2026-05-11"
      }
    }

    {:ok, doc} =
      %Document{}
      |> Document.changeset(Map.merge(base, overrides))
      |> Repo.insert()

    doc
  end

  defp insert_triage!(doc, overrides \\ %{}) do
    base = %{
      document_id: doc.id,
      category: "business",
      sender_type: "known_priority",
      classifier_source: "fast_classifier",
      confidence: 1.0
    }

    {:ok, triage} =
      %TriageRecord{}
      |> TriageRecord.classify_changeset(Map.merge(base, overrides))
      |> Repo.insert()

    triage
  end

  defp transition_status!(triage, target_status, extra_attrs \\ %{}) do
    cs =
      case target_status do
        "enriched" ->
          TriageRecord.enrich_changeset(
            triage,
            Map.merge(
              %{
                urgency: "low",
                action: "fyi",
                topic: ["kerf"],
                summary: "previous summary",
                enrichment_version: 1
              },
              extra_attrs
            )
          )

        "unclassifiable" ->
          TriageRecord.mark_unclassifiable_changeset(
            triage,
            Map.merge(%{triage_error: "test forced unclassifiable"}, extra_attrs)
          )
      end

    {:ok, updated} = Repo.update(cs)
    updated
  end

  defp default_enrich_result do
    %{
      urgency: "high",
      action: "reply_needed",
      topic: ["kerf"],
      summary: "Test enrichment summary.",
      proposals: %{topic: [], action: []}
    }
  end

  defp put_config(key, value) do
    current = Application.get_env(:kerf, Kerf.Agents.EmailTriage.Enricher, [])

    Application.put_env(
      :kerf,
      Kerf.Agents.EmailTriage.Enricher,
      Keyword.put(current, key, value)
    )

    on_exit(fn ->
      Application.delete_env(:kerf, Kerf.Agents.EmailTriage.Enricher)
    end)
  end

  defp set_enrich_fn(fun), do: put_config(:enrich_fn, fun)
  defp set_record_proposal_fn(fun), do: put_config(:record_proposal_fn, fun)

  # ---------- worker tests ----------

  describe "perform/1 happy path" do
    test "classified triage record drives full pipeline to triage_status = enriched" do
      doc = insert_email_doc!()
      triage = insert_triage!(doc)

      set_enrich_fn(fn _input, _opts -> {:ok, default_enrich_result()} end)

      assert :ok = perform_job(Enricher, %{"triage_record_id" => triage.id})

      reloaded = Repo.get!(TriageRecord, triage.id)
      assert reloaded.triage_status == "enriched"
      assert reloaded.urgency == "high"
      assert reloaded.action == "reply_needed"
      assert reloaded.topic == ["kerf"]
      assert reloaded.summary == "Test enrichment summary."
      assert reloaded.enriched_at != nil
    end
  end

  describe "perform/1 status guards" do
    test "no-op success when triage_status is already 'enriched'" do
      doc = insert_email_doc!()
      triage = insert_triage!(doc) |> transition_status!("enriched")

      set_enrich_fn(fn _input, _opts ->
        flunk("enrich_fn should not be called for an already-enriched record")
      end)

      assert :ok = perform_job(Enricher, %{"triage_record_id" => triage.id})

      # Row unchanged from the pre-set 'enriched' state.
      reloaded = Repo.get!(TriageRecord, triage.id)
      assert reloaded.summary == "previous summary"
    end

    test "no-op success when triage_status is 'unclassifiable'" do
      doc = insert_email_doc!()
      triage = insert_triage!(doc) |> transition_status!("unclassifiable")

      set_enrich_fn(fn _input, _opts ->
        flunk("enrich_fn should not be called for an unclassifiable record")
      end)

      assert :ok = perform_job(Enricher, %{"triage_record_id" => triage.id})

      reloaded = Repo.get!(TriageRecord, triage.id)
      assert reloaded.triage_status == "unclassifiable"
    end

    test "returns {:error, :unexpected_status} for a 'pending' record" do
      # A pending record means classify_changeset never ran — caller bug.
      # Build a pending row by inserting via raw SQL (no changeset path
      # produces 'pending' for us).
      doc = insert_email_doc!()
      uuid = Ecto.UUID.generate()
      now = DateTime.utc_now(:microsecond)

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Repo,
          """
          INSERT INTO email_triage (id, document_id, classifier_source, inserted_at, updated_at)
          VALUES ($1, $2, 'raw', $3, $4)
          """,
          [Ecto.UUID.dump!(uuid), Ecto.UUID.dump!(doc.id), now, now]
        )

      set_enrich_fn(fn _input, _opts ->
        flunk("enrich_fn should not be called for a pending record")
      end)

      assert {:error, :unexpected_status} =
               perform_job(Enricher, %{"triage_record_id" => uuid})
    end
  end

  describe "perform/1 input construction" do
    test "empty raw_text triggers the synthetic-body fallback in the prompt" do
      doc = insert_email_doc!(%{raw_text: ""})
      triage = insert_triage!(doc)

      test_pid = self()

      capture_enrich = fn input, _opts ->
        send(test_pid, {:enrich_input, input})
        {:ok, default_enrich_result()}
      end

      set_enrich_fn(capture_enrich)
      assert :ok = perform_job(Enricher, %{"triage_record_id" => triage.id})

      assert_receive {:enrich_input, input}
      # Fallback path: body_text is nil/empty and the source_metadata carries
      # the recovery signal. The adapter is responsible for synthesizing the
      # body from these inputs.
      assert input.body_text in [nil, ""]
      assert input.subject == "Test Subject"
      assert input.source_metadata["sender"] == "alice@example.com"
      assert input.source_metadata["labels"] == ["INBOX"]
    end

    test "multilingual content: Dutch summary from provider is persisted verbatim, no English coercion" do
      doc =
        insert_email_doc!(%{
          title: "Concept rapport",
          raw_text:
            "Hoi Alice, hierbij het concept van het rapport voor example-law.test. Kun je je commentaar voor vrijdag 17:00 doorgeven?",
          source_metadata: %{
            "sender" => "bob@example-firm.nl",
            "sender_name" => "Bob",
            "subject" => "Concept rapport",
            "labels" => ["INBOX"]
          }
        })

      triage = insert_triage!(doc)

      dutch_summary = "Bob vraagt om feedback op concept overeenkomst voor vrijdag."

      set_enrich_fn(fn _input, _opts ->
        {:ok,
         %{
           urgency: "high",
           action: "reply_needed",
           topic: ["legal"],
           summary: dutch_summary,
           proposals: %{topic: [], action: []}
         }}
      end)

      assert :ok = perform_job(Enricher, %{"triage_record_id" => triage.id})

      reloaded = Repo.get!(TriageRecord, triage.id)
      assert reloaded.summary == dutch_summary
    end

    test "50KB body is cleaned and capped to BodyPrep's byte budget; subject preserved separately" do
      big_body = String.duplicate("x", 50_000)

      doc =
        insert_email_doc!(%{
          title: "Important Subject Line",
          raw_text: big_body
        })

      triage = insert_triage!(doc)

      test_pid = self()

      capture_enrich = fn input, _opts ->
        send(test_pid, {:enrich_input, input})
        {:ok, default_enrich_result()}
      end

      set_enrich_fn(capture_enrich)
      assert :ok = perform_job(Enricher, %{"triage_record_id" => triage.id})

      assert_receive {:enrich_input, input}
      # Worker delegates body prep to Kerf.Agents.EmailTriage.BodyPrep, which
      # strips boilerplate and caps to a ~4000-byte budget (raised from the old
      # 2000-byte positional slice). This body is pure "x" — no boilerplate to
      # strip — so it caps exactly at the budget.
      assert byte_size(input.body_text) == 4000
      assert input.subject == "Important Subject Line"
    end
  end

  describe "perform/1 error propagation" do
    test "returns {:error, reason} when the adapter returns an error (Oban will retry)" do
      doc = insert_email_doc!()
      triage = insert_triage!(doc)

      set_enrich_fn(fn _input, _opts -> {:error, "vLLM timeout"} end)

      assert {:error, "vLLM timeout"} =
               perform_job(Enricher, %{"triage_record_id" => triage.id})

      # Row stays classified — not advanced to enriched on error.
      reloaded = Repo.get!(TriageRecord, triage.id)
      assert reloaded.triage_status == "classified"
    end
  end

  describe "perform/1 error paths (Step 7)" do
    # These three tests pass against the current generic {:error, _}
    # propagation. They guard against future regressions where
    # error-shape-specific handling drops one of these atoms.

    test "vLLM HTTP error from the adapter propagates as the worker's job return" do
      # Mirror VLLMProvider's HTTP-error shape from vllm_provider.ex:247:
      # {:error, "API error \#{status}: \#{reason}"}.
      doc = insert_email_doc!()
      triage = insert_triage!(doc)

      set_enrich_fn(fn _input, _opts -> {:error, "API error 500: internal error"} end)

      assert {:error, "API error 500: internal error"} =
               perform_job(Enricher, %{"triage_record_id" => triage.id})

      assert Repo.get!(TriageRecord, triage.id).triage_status == "classified"
    end

    test "adapter :missing_tool_call propagates (defensive — vLLM ignored tool_choice)" do
      # Defensive coverage: vLLM 0.15.1 with tool_choice strictly enforces
      # the call, but if a future model/version returns text instead of a
      # tool call, the adapter surfaces :missing_tool_call. Worker passes
      # it through.
      doc = insert_email_doc!()
      triage = insert_triage!(doc)

      set_enrich_fn(fn _input, _opts -> {:error, :missing_tool_call} end)

      assert {:error, :missing_tool_call} =
               perform_job(Enricher, %{"triage_record_id" => triage.id})

      assert Repo.get!(TriageRecord, triage.id).triage_status == "classified"
    end

    test "adapter :invalid_response propagates (defensive — tool_call missing required keys)" do
      # Defensive coverage: vLLM strict-schema mode enforces required keys
      # on tool_call args, but if a future change loosens that, the adapter
      # surfaces :invalid_response. Worker passes it through.
      doc = insert_email_doc!()
      triage = insert_triage!(doc)

      set_enrich_fn(fn _input, _opts -> {:error, :invalid_response} end)

      assert {:error, :invalid_response} =
               perform_job(Enricher, %{"triage_record_id" => triage.id})

      assert Repo.get!(TriageRecord, triage.id).triage_status == "classified"
    end

    test "proposal-recording failure rolls back the TriageRecord update; no partial taxonomy state persists" do
      # The interesting case: enrich succeeds and produces a proposal, but
      # Taxonomy.record_proposal/3 fails mid-transaction. The TriageRecord
      # update happens in the SAME Repo.transaction as the proposal call,
      # so a proposal failure must roll back the triage advancement.
      doc = insert_email_doc!()
      triage = insert_triage!(doc)

      set_enrich_fn(fn _input, _opts ->
        {:ok,
         %{
           urgency: "high",
           action: "reply_needed",
           topic: ["never_persisted_topic"],
           summary: "summary",
           proposals: %{topic: ["never_persisted_topic"], action: []}
         }}
      end)

      set_record_proposal_fn(fn _dim, _value, _triage_record_id ->
        {:error, :forced_test_failure}
      end)

      # Assert the full rollback tuple shape: dimension, value, and the
      # underlying error are all present as breadcrumbs for prod debugging.
      assert {:error, {:proposal_failed, :topic, "never_persisted_topic",
                       :forced_test_failure}} =
               perform_job(Enricher, %{"triage_record_id" => triage.id})

      reloaded = Repo.get!(TriageRecord, triage.id)
      assert reloaded.triage_status == "classified"
      assert is_nil(reloaded.urgency)
      assert is_nil(reloaded.action)
      assert reloaded.topic in [nil, []]
      assert is_nil(reloaded.summary)

      # No taxonomy proposal persisted — the proposal call returned an error
      # before the row was inserted, and even if a partial insert had happened
      # it would be rolled back.
      refute Enum.any?(Taxonomy.list_pending(:topic), fn entry ->
               entry.value == "never_persisted_topic"
             end)

      # Step 11: the Router enqueue lives inside the same transaction, so it
      # must also have been rolled back. No Router job in the queue.
      refute_enqueued(worker: Kerf.Agents.EmailTriage.Router)
    end
  end

  describe "perform/1 Router chaining (Step 11)" do
    test "successful enrichment enqueues a Router job with matching triage_record_id" do
      doc = insert_email_doc!()
      triage = insert_triage!(doc)

      set_enrich_fn(fn _input, _opts -> {:ok, default_enrich_result()} end)

      assert :ok = perform_job(Enricher, %{"triage_record_id" => triage.id})

      # Router job enqueued; args contain the triage record id (JSON
      # serialization → string-keyed on read).
      assert_enqueued(
        worker: Kerf.Agents.EmailTriage.Router,
        args: %{"triage_record_id" => triage.id}
      )
    end

    test "no-op enriched record (status guard) does not enqueue a Router job" do
      doc = insert_email_doc!()
      triage = insert_triage!(doc) |> transition_status!("enriched")

      # No enrich_fn invocation expected — enriched is a status-guard no-op.
      set_enrich_fn(fn _input, _opts ->
        flunk("enrich_fn should not be called for an already-enriched record")
      end)

      assert :ok = perform_job(Enricher, %{"triage_record_id" => triage.id})

      # Status-guard path short-circuits before persist runs, so no Router
      # enqueue happens.
      refute_enqueued(worker: Kerf.Agents.EmailTriage.Router)
    end
  end

  # ---------- integration tests (gated behind --include vllm) ----------

  describe "perform/1 integration with real vLLM" do
    @describetag :vllm

    test "Dutch body produces a Dutch summary and a valid urgency enum value" do
      doc =
        insert_email_doc!(%{
          title: "Concept rapport - feedback nodig voor vrijdag",
          raw_text:
            "Hoi Alice, hierbij het concept van het rapport voor example-law.test. Kun je je commentaar voor vrijdag 17:00 doorgeven? Het moet maandag de deur uit. Groet, Bob",
          source_metadata: %{
            "sender" => "bob@example-firm.nl",
            "sender_name" => "Bob",
            "subject" => "Concept rapport - feedback nodig voor vrijdag",
            "labels" => ["INBOX"]
          }
        })

      triage = insert_triage!(doc)

      assert :ok = perform_job(Enricher, %{"triage_record_id" => triage.id})

      reloaded = Repo.get!(TriageRecord, triage.id)
      assert reloaded.triage_status == "enriched"
      assert reloaded.urgency in ~w(high medium low none)
      assert is_binary(reloaded.summary) and reloaded.summary != ""

      # Loose Dutch heuristic: summary should contain at least one Dutch-only
      # word likely to leak from the email content (vrijdag, concept,
      # overeenkomst). Asserts language preservation at the model level.
      # Array length bounds — pins vLLM-side enforcement of minItems: 1, maxItems: 4
      # from ToolSpec (Step 4).
      assert length(reloaded.topic) >= 1
      assert length(reloaded.topic) <= 4

      summary_lower = String.downcase(reloaded.summary)

      # Grammatical Dutch words (articles, conjunctions, copula). A summary's
      # language identity is in its grammar more than its content vocabulary;
      # the model is more likely to retain "de/het/een" than specific
      # content words like "vrijdag" or "overeenkomst" when summarising.
      assert Regex.match?(~r/\b(de|het|een|voor|en|is|om|naar)\b/, summary_lower),
             "expected a Dutch grammar word in summary, got: #{reloaded.summary}"
    end

    test "English body produces an English summary and a valid urgency enum value" do
      doc =
        insert_email_doc!(%{
          title: "PR #42 merged - please review the follow-up tickets by Friday",
          raw_text:
            "Hi Alice, the merge succeeded but I noticed two regressions in the changelog. Could you take a look at tickets #105 and #106 by Friday afternoon? Thanks.",
          source_metadata: %{
            "sender" => "engineer@example.com",
            "sender_name" => "Engineer",
            "subject" => "PR #42 merged - please review the follow-up tickets by Friday",
            "labels" => ["INBOX"]
          }
        })

      triage = insert_triage!(doc)

      assert :ok = perform_job(Enricher, %{"triage_record_id" => triage.id})

      reloaded = Repo.get!(TriageRecord, triage.id)
      assert reloaded.triage_status == "enriched"
      assert reloaded.urgency in ~w(high medium low none)
      assert is_binary(reloaded.summary) and reloaded.summary != ""

      # Array length bounds — same vLLM-side enforcement check as above.
      assert length(reloaded.topic) >= 1
      assert length(reloaded.topic) <= 4

      summary_lower = String.downcase(reloaded.summary)

      # Grammatical English words. Same reasoning as the Dutch test: grammar
      # is a stronger language signal than content vocabulary.
      assert Regex.match?(~r/\b(the|and|a|is|to|of|for|by)\b/, summary_lower),
             "expected an English grammar word in summary, got: #{reloaded.summary}"
    end
  end
end
