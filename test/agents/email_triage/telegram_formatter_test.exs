defmodule Kerf.Agents.EmailTriage.TelegramFormatterTest do
  use ExUnit.Case, async: true

  alias Kerf.Agents.EmailTriage.TelegramFormatter

  @high_priority_result %{
    document_id: "doc_001",
    classification: %{
      category: "business",
      priority: 4,
      action: "follow_up",
      confidence: 0.92,
      summary: "Q2 results show 98.3% accuracy on invoice processing.",
      interest_matches: [
        %{topic: "Invoice Processing", score: 0.89},
        %{topic: "Automotive", score: 0.72}
      ]
    },
    sender_info: %{
      email: "john@example.com",
      name: "John Doe",
      is_priority: true,
      priority_score: 0.8
    },
    subject: "Q2 Invoice Processing Update"
  }

  @low_priority_results [
    %{classification: %{category: "newsletter", priority: 1, summary: "TechCrunch daily"},
      sender_info: %{email: "news@tc.com", name: "TechCrunch"}},
    %{classification: %{category: "newsletter", priority: 1, summary: "HN Weekly"},
      sender_info: %{email: "hn@news.com", name: "Hacker News"}},
    %{classification: %{category: "transactional", priority: 2, summary: "GitHub notification"},
      sender_info: %{email: "noreply@github.com", name: "GitHub"}},
    %{classification: %{category: "spam", priority: 1, summary: "Buy now!"},
      sender_info: %{email: "spam@bad.com", name: "Spammer"}}
  ]

  describe "format_high_priority/1" do
    test "renders full summary with sender, subject, priority, interests" do
      text = TelegramFormatter.format_high_priority(@high_priority_result)

      assert text =~ "John Doe"
      assert text =~ "john@example.com"
      assert text =~ "Q2 Invoice Processing Update"
      assert text =~ "4/5"
      assert text =~ "Business"
      assert text =~ "Invoice Processing"
      assert text =~ "98.3% accuracy"
    end

    test "includes priority stars" do
      text = TelegramFormatter.format_high_priority(@high_priority_result)
      # 4 stars for priority 4
      assert String.contains?(text, String.duplicate("⭐", 4))
    end
  end

  describe "format_digest/1" do
    test "groups by category" do
      text = TelegramFormatter.format_digest(@low_priority_results)

      assert text =~ "Digest"
      assert text =~ "Newsletter"
      assert text =~ "Transactional"
      assert text =~ "Spam"
    end

    test "shows count per category" do
      text = TelegramFormatter.format_digest(@low_priority_results)

      # 2 newsletters, 1 transactional, 1 spam
      assert text =~ "2"
    end

    test "handles empty list" do
      assert TelegramFormatter.format_digest([]) == nil
    end
  end

  describe "approval_buttons/1" do
    test "returns button specs for high priority" do
      buttons = TelegramFormatter.approval_buttons(@high_priority_result)

      labels = Enum.map(buttons, & &1.label)
      assert "Follow up" in labels
      assert "Archive" in labels
      assert "Add sender to priority" in labels
    end

    test "includes document_id in callback data" do
      buttons = TelegramFormatter.approval_buttons(@high_priority_result)

      for button <- buttons do
        assert button.callback_data =~ "doc_001"
      end
    end
  end

  describe "format_routing_ping/1 (Step 12)" do
    # New formatter for the Router-triggered Telegram delivery path.
    # Takes a flat map the Router builds at the call site
    # (TriageRecord + Document + email_senders → projection).
    # Uses the new vocabulary: urgency / topic / sender_type
    # (vs format_high_priority/1's priority / interest_matches).

    @ping_input %{
      sender: "bob@example-firm.nl",
      sender_name: "Bob",
      subject: "Concept rapport - feedback nodig voor vrijdag",
      urgency: "high",
      summary: "Bob vraagt om feedback op concept overeenkomst voor vrijdag.",
      topic: ["legal", "kerf"],
      sender_type: "known_priority"
    }

    test "renders sender, subject, urgency, summary, topic in the message body" do
      text = TelegramFormatter.format_routing_ping(@ping_input)

      assert is_binary(text)
      assert text =~ "Bob"
      assert text =~ "bob@example-firm.nl"
      assert text =~ "Concept rapport - feedback nodig voor vrijdag"
      assert text =~ "high"
      assert text =~ "Bob vraagt om feedback"
      assert text =~ "legal"
      assert text =~ "kerf"
      # sender_type is humanized for display: known_priority → "Priority sender"
      assert text =~ "Priority sender"
    end

    test "handles missing optional fields gracefully" do
      # sender_name nil → fall back to email only (no "<email>" decoration);
      # topic [] → omit the topic line entirely.
      input = %{
        sender: "anon@example.com",
        sender_name: nil,
        subject: "Untitled",
        urgency: "low",
        summary: "An email arrived.",
        topic: [],
        sender_type: "unknown_human"
      }

      text = TelegramFormatter.format_routing_ping(input)

      assert is_binary(text)
      assert text =~ "anon@example.com"
      assert text =~ "Untitled"
      assert text =~ "low"
      assert text =~ "An email arrived."
      # unknown_human → humanized as "New sender"
      assert text =~ "New sender"
      # No "Topic:" line in the output since topic is empty.
      refute text =~ "Topic:"
    end
  end

  describe "format_routing_digest/2 (Step 13)" do
    # Compact format: groups items by category, lists up to 3 names per
    # category with "+N more" overflow, references the future /digest_full
    # Tina command (see deferred-work item L).

    test "produces compact format with header, category groups, footer" do
      items = [
        %{name: "TechCrunch", category: "newsletter"},
        %{name: "NewsletterCo", category: "newsletter"},
        %{name: "Bob", category: "business"},
        %{name: "Charlie", category: "business"},
        %{name: "GitHub", category: "notification"}
      ]

      text = TelegramFormatter.format_routing_digest(items, since_label: "14h")

      assert is_binary(text)
      # Header references the total count and the since-label.
      assert text =~ "📬"
      assert text =~ "5"
      assert text =~ "14h"
      # Each category appears with its count.
      assert text =~ ~r/newsletter.*\(2\)/i
      assert text =~ ~r/business.*\(2\)/i
      assert text =~ ~r/notification.*\(1\)/i
      # All names appear (no truncation triggered at category counts ≤ 3).
      assert text =~ "TechCrunch"
      assert text =~ "NewsletterCo"
      assert text =~ "Bob"
      assert text =~ "Charlie"
      assert text =~ "GitHub"
      # Footer references the future Tina command (deferred-work item L).
      assert text =~ "/digest_full"
    end

    test "category with more than 3 items shows '+N more' truncation" do
      items =
        for n <- 1..8,
            do: %{name: "Sender#{n}", category: "newsletter"}

      text = TelegramFormatter.format_routing_digest(items, since_label: "24h")

      # Up to 3 names listed; remaining 5 collapsed to "+5 more".
      assert text =~ "Sender1"
      assert text =~ "Sender2"
      assert text =~ "Sender3"
      assert text =~ ~r/\+\s*5\s+more/
      # Names beyond the truncation cap should NOT appear in the digest body.
      refute text =~ "Sender8"
    end

    test "empty input list returns nil (signal to worker: skip the send)" do
      assert TelegramFormatter.format_routing_digest([], since_label: "24h") == nil
    end
  end
end
