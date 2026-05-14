defmodule Kerf.LLM.EnrichTest do
  use ExUnit.Case, async: true

  alias Kerf.LLM.Enrich

  # Minimal input map shape consumed by Kerf.LLM.Enrich.enrich/2.
  defp sample_input(overrides \\ %{}) do
    Map.merge(
      %{
        from: %{email: "alice@example.com", name: "Alice"},
        subject: "Hello there",
        body_text: "This is the body of a test email.",
        sender_type: "unknown_human",
        source_metadata: %{
          "sender" => "alice@example.com",
          "sender_name" => "Alice",
          "labels" => ["INBOX"]
        }
      },
      overrides
    )
  end

  # Builds a provider_fn that returns a tool_call response matching the
  # VLLMProvider :tool_use shape (input is the parsed args map).
  defp tool_call_provider(args, capture_pid \\ nil) do
    fn model, messages, opts ->
      if capture_pid, do: send(capture_pid, {:provider_called, model, messages, opts})

      {:ok,
       %{
         type: :tool_use,
         calls: [
           %{id: "call_test", name: "enrich_email", input: args}
         ],
         usage: %{input_tokens: 100, output_tokens: 40}
       }}
    end
  end

  describe "enrich/2 happy path" do
    test "returns parsed dimensions and empty proposals when all values are in vocab" do
      provider =
        tool_call_provider(%{
          "urgency" => "low",
          "action" => "fyi",
          "topic" => ["kerf"],
          "summary" => "Test summary.",
          "topic_proposed_new" => [],
          "action_proposed_new" => false
        })

      assert {:ok, result} =
               Enrich.enrich(sample_input(),
                 provider_fn: provider,
                 accepted_topics: ["kerf", "legal"],
                 accepted_actions: ["fyi", "reply_needed"]
               )

      assert result.urgency == "low"
      assert result.action == "fyi"
      assert result.topic == ["kerf"]
      assert result.summary == "Test summary."
      assert result.proposals == %{topic: [], action: []}
    end
  end

  describe "enrich/2 taxonomy proposals" do
    test "all-accepted topic + action values produce no proposals" do
      provider =
        tool_call_provider(%{
          "urgency" => "medium",
          "action" => "reply_needed",
          "topic" => ["kerf", "legal"],
          "summary" => "..."
        })

      {:ok, result} =
        Enrich.enrich(sample_input(),
          provider_fn: provider,
          accepted_topics: ["kerf", "legal", "financial"],
          accepted_actions: ["fyi", "reply_needed", "review"]
        )

      assert result.proposals.topic == []
      assert result.proposals.action == []
    end

    test "off-taxonomy topic creates a proposal; value still flows through into result.topic with order preserved" do
      # Order matters: mock returns ["kerf", "brand_new_topic"] (kerf first).
      # Alphabetical order would be ["brand_new_topic", "kerf"]. Asserting
      # the original order proves the adapter doesn't sort.
      provider =
        tool_call_provider(%{
          "urgency" => "low",
          "action" => "fyi",
          "topic" => ["kerf", "brand_new_topic"],
          "summary" => "..."
        })

      {:ok, result} =
        Enrich.enrich(sample_input(),
          provider_fn: provider,
          accepted_topics: ["kerf"],
          accepted_actions: ["fyi"]
        )

      # Permissive: the LLM-supplied topic is preserved verbatim, original order.
      assert result.topic == ["kerf", "brand_new_topic"]
      # And surfaced as a proposal for human review.
      assert result.proposals.topic == ["brand_new_topic"]
    end

    test "off-taxonomy action creates a proposal; value still flows through into result.action" do
      provider =
        tool_call_provider(%{
          "urgency" => "low",
          "action" => "novel_action",
          "topic" => ["kerf"],
          "summary" => "..."
        })

      {:ok, result} =
        Enrich.enrich(sample_input(),
          provider_fn: provider,
          accepted_topics: ["kerf"],
          accepted_actions: ["fyi"]
        )

      assert result.action == "novel_action"
      assert result.proposals.action == ["novel_action"]
    end
  end

  describe "enrich/2 opt propagation" do
    test "temperature opt is forwarded to provider_fn" do
      provider = tool_call_provider(
        %{"urgency" => "low", "action" => "fyi", "topic" => ["kerf"], "summary" => "..."},
        self()
      )

      Enrich.enrich(sample_input(),
        provider_fn: provider,
        accepted_topics: ["kerf"],
        accepted_actions: ["fyi"],
        temperature: 0
      )

      assert_receive {:provider_called, _model, _messages, opts}
      assert opts[:temperature] == 0
    end
  end

  describe "enrich/2 error propagation" do
    test "returns provider's {:error, reason} unchanged" do
      provider = fn _model, _messages, _opts -> {:error, "vLLM unreachable"} end

      assert {:error, "vLLM unreachable"} =
               Enrich.enrich(sample_input(),
                 provider_fn: provider,
                 accepted_topics: [],
                 accepted_actions: []
               )
    end
  end
end
