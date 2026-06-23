%{
  version: "2026-06-22.1",
  rules: [
    # Silence spam FIRST — before any ping rule — so a spam "invoice" (a scam
    # with action: "pay") can never trip invoice_to_pay below.
    %{
      name: "spam_silent",
      match: %{category: "spam"},
      action: :silent
    },

    # Private messages to the user.
    %{
      name: "personal_ping",
      match: %{category: "personal"},
      action: :telegram_ping
    },

    # Bills needing payment, any category (spam already excluded above).
    %{
      name: "invoice_to_pay",
      match: %{action: "pay"},
      action: :telegram_ping
    },

    # Business invoices / receipts / financial mail.
    %{
      name: "business_financial",
      match: %{category: "business", topic: {:contains, "financial"}},
      action: :telegram_ping
    },

    # Invoices / receipts that arrive classified as transactional.
    %{
      name: "transactional_financial",
      match: %{category: "transactional", topic: {:contains, "financial"}},
      action: :telegram_ping
    },

    # Business awaiting a reply from the user.
    %{
      name: "business_reply_needed",
      match: %{category: "business", action: "reply_needed"},
      action: :telegram_ping
    },

    # Time-sensitive business (e.g. the Datadog production alert).
    %{
      name: "business_high",
      match: %{category: "business", urgency: "high"},
      action: :telegram_ping
    },

    # Moderately time-sensitive business.
    %{
      name: "business_medium",
      match: %{category: "business", urgency: "medium"},
      action: :telegram_ping
    },

    # Catch-all: everything else (newsletters, marketing, social, non-financial
    # transactional, low-urgency/cold business) is batched into the digest.
    %{
      name: "default_digest",
      match: %{},
      action: :telegram_digest
    }
  ]
}
