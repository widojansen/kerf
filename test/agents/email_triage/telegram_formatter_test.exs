defmodule ExClaw.Agents.EmailTriage.TelegramFormatterTest do
  use ExUnit.Case, async: true

  alias ExClaw.Agents.EmailTriage.TelegramFormatter

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
end
