defmodule Kerf.Agents.EmailTriage.SocialCategoryTest do
  @moduledoc """
  SPEC_C §3 T2 — docs/superpowers/specs/SPEC_C_triage_enum_fix.md

  End-to-end: an LLM classification of category "social" must survive real
  schema validation (Kerf.StructuredOutput.complete/4 against the live
  :email_classification schema — no stub bypasses it), land in a `kb_feedback`
  row with decision "classified", and route the same way Stage 1's read-back
  traced Router.handle_record to today (category "social" matches no specific
  rule in priv/email_routing.exs and falls to the "default_digest" catch-all,
  action :telegram_digest).
  """
  use Kerf.DataCase
  use Oban.Testing, repo: Kerf.Repo

  import Ecto.Query

  alias Kerf.Agents.EmailTriage.{Classifier, EmailTriage, Router, RoutingConfig, RoutingDecision, TriageRecord}
  alias Kerf.KnowledgeBase.{Document, Feedback}

  setup do
    {:ok, doc} =
      Repo.insert(
        Document.changeset(%Document{}, %{
          source_type: "email",
          source_id: "msg_social_category_1",
          title: "New comment on your post",
          raw_text: "Someone reacted to your update.",
          source_metadata: %{
            "sender" => "notify@social-example.com",
            "sender_name" => "Social Example",
            "subject" => "New comment on your post",
            # Deliberately NOT "CATEGORY_SOCIAL" — this must exercise the LLM
            # fallback path (FastClassifier cascade exhausts to :no_match),
            # not the pre-existing Gmail-label producer traced in Stage 1.
            "labels" => ["INBOX"]
          }
        })
      )

    %{doc: doc}
  end

  # Explicit wrapper only — never a bare &complete/3 capture (VLLMProvider's
  # nested-default-args gotcha, per CLAUDE.md). Stubs the raw LLM text at the
  # StructuredOutput.complete/4 provider_fn seam so the REAL schema (resolved
  # from the app-wide SchemaRegistry, register_builtins: true per config.exs)
  # validates the "social" category — this is what makes T2 fail today for
  # the same reason T1 does, not for an unrelated reason.
  defp social_llm_stub do
    fn _model, _messages, _opts ->
      {:ok,
       %{
         type: :text,
         content:
           Jason.encode!(%{
             "category" => "social",
             "priority" => 1,
             "action" => "archive",
             "confidence" => 0.85,
             "summary" => "Social notification"
           })
       }}
    end
  end

  defp classifier_fn_with_social_stub do
    wrapped_provider_fn = fn schema_name, model, messages, opts ->
      Kerf.StructuredOutput.complete(
        schema_name,
        model,
        messages,
        Keyword.put(opts, :provider_fn, social_llm_stub())
      )
    end

    fn email, opts ->
      Classifier.classify(email, Keyword.put(opts, :provider_fn, wrapped_provider_fn))
    end
  end

  defp start_triage_agent!(overrides \\ []) do
    name = :"social_triage_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          name: name,
          repo: Kerf.Repo,
          classifier_fn: classifier_fn_with_social_stub(),
          telegram_fn: fn _chat_id, _text, _opts -> :ok end,
          graph_enabled: false,
          interest_threshold: 0.0,
          high_priority_threshold: 4
        ],
        overrides
      )

    {:ok, pid} = EmailTriage.start_link(opts)
    allow_repo(pid)
    name
  end

  # Points RoutingConfig at the real, shipped priv/email_routing.exs — the
  # exact rule set Stage 1's read-back traced — rather than a hand-copied
  # fixture that could drift from production.
  defp start_production_routing_config! do
    tmp_dir =
      Path.join(System.tmp_dir!(), "kerf_social_category_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    # Nonexistent on purpose: RoutingConfig falls back to default_path when
    # override_path doesn't exist (mirrors production when no operator
    # override has been installed at /opt/kerf/email_routing.exs).
    override_path = Path.join(tmp_dir, "override.exs")
    default_path = Application.app_dir(:kerf, "priv/email_routing.exs")

    name = :"social_category_rc_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      RoutingConfig.start_link(name: name, default_path: default_path, override_path: override_path)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    name
  end

  defp set_router_config(rc_name) do
    previous = Application.get_env(:kerf, Router, [])

    Application.put_env(
      :kerf,
      Router,
      Keyword.merge(previous, routing_config_name: rc_name, telegram_sender: fn _chat_id, _text -> :ok end)
    )

    on_exit(fn -> Application.put_env(:kerf, Router, previous) end)
  end

  test "category: social — classified kb_feedback row and routes to default_digest / :telegram_digest", ctx do
    agent = start_triage_agent!()

    assert {:ok, _results} = EmailTriage.triage(agent, [ctx.doc.id])

    feedback = Repo.get_by!(Feedback, document_id: ctx.doc.id, feedback_type: "triage")

    # Today's 5-value schema rejects "social" (Validator.validate fails against
    # builtins.ex's category enum), so Classifier.classify/2 returns
    # {:error, {:validation_failed, ...}}; EmailTriage's error branch records
    # decision "unclassified" with an "error" context key instead. This
    # assertion is where T2 fails pre-GREEN — the same enum gap T1 pins.
    assert feedback.decision == "classified"
    assert feedback.context["category"] == "social"

    triage_record = Repo.get_by!(TriageRecord, document_id: ctx.doc.id)
    assert triage_record.category == "social"

    {:ok, enriched} =
      triage_record
      |> TriageRecord.enrich_changeset(%{
        urgency: "low",
        action: "archive",
        topic: ["kerf"],
        summary: "test enrichment"
      })
      |> Repo.update()

    rc_name = start_production_routing_config!()
    set_router_config(rc_name)

    assert :ok = perform_job(Router, %{"triage_record_id" => enriched.id})

    [decision] =
      Repo.all(from d in RoutingDecision, where: d.email_triage_id == ^enriched.id)

    assert decision.rule_name == "default_digest"
    assert decision.action_taken == "telegram_digest"
  end
end
