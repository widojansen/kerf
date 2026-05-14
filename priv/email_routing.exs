%{
  version: "2026-05-11.1",
  rules: [
    # Ping for anything urgent from a priority sender.
    %{
      name: "priority_high_urgency",
      match: %{sender_type: "known_priority", urgency: "high"},
      action: :telegram_ping
    },

    # Ping on security category regardless of sender.
    %{
      name: "security_alerts",
      match: %{category: "security"},
      action: :telegram_ping
    },

    # Ping when a priority sender expects a reply (any urgency).
    %{
      name: "priority_reply_needed",
      match: %{sender_type: "known_priority", action: "reply_needed"},
      action: :telegram_ping
    },

    # Ping for anything tagged kerf — keeps platform work visible.
    %{
      name: "kerf_topic_anything",
      match: %{topic: {:contains, "kerf"}},
      action: :telegram_ping
    },

    # Batch medium-urgency business mail into a daily digest.
    %{
      name: "business_medium",
      match: %{category: "business", urgency: "medium"},
      action: :telegram_digest
    },

    # Catch-all: silence everything not matched above.
    %{
      name: "default_silent",
      match: %{},
      action: :silent
    }
  ]
}
