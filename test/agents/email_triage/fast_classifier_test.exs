defmodule Kerf.Agents.EmailTriage.FastClassifierTest do
  use Kerf.DataCase

  alias Kerf.Agents.EmailTriage.FastClassifier
  alias Kerf.KnowledgeBase.EmailSender

  setup do
    # Insert senders with classification overrides
    {:ok, _} =
      Repo.insert(
        EmailSender.changeset(%EmailSender{}, %{
          email: "former-colleague@example.com",
          name: "Sandra Beckers",
          domain: "example.nl",
          classification_override: "business",
          priority_override: 5
        })
      )

    {:ok, _} =
      Repo.insert(
        EmailSender.changeset(%EmailSender{}, %{
          email: "rule-pattern@fast-classifier",
          name: "Substack",
          match_pattern: "substack.com",
          classification_override: "newsletter",
          priority_override: 1
        })
      )

    {:ok, _} =
      Repo.insert(
        EmailSender.changeset(%EmailSender{}, %{
          email: "rule-domain@fast-classifier",
          name: "NVIDIA",
          domain: "nvidia.com",
          classification_override: "newsletter",
          priority_override: 1
        })
      )

    # Sender without classification override — should NOT match
    {:ok, _} =
      Repo.insert(
        EmailSender.changeset(%EmailSender{}, %{
          email: "noclass@example.com",
          name: "No Classification"
        })
      )

    :ok
  end

  describe "classify/1" do
    test "returns {:no_match, %{sender_type: \"unknown_human\"}} for unknown sender" do
      email = %{
        from: "Unknown Person <unknown@nowhere.org>",
        subject: "Hello",
        labels: []
      }

      assert {:no_match, %{sender_type: "unknown_human"}} = FastClassifier.classify(email)
    end

    test "matches by exact email" do
      email = %{
        from: "Sandra Beckers <former-colleague@example.com>",
        subject: "Fwd: voorstel web",
        labels: []
      }

      assert {:ok, classification} = FastClassifier.classify(email)
      assert classification.category == "business"
      assert classification.priority == 5
      assert classification.source == :fast_classifier
      assert classification.confidence == 1.0
    end

    test "matches by pattern substring" do
      email = %{
        from: "Newsletter <digest@substack.com>",
        subject: "Weekly roundup",
        labels: []
      }

      assert {:ok, classification} = FastClassifier.classify(email)
      assert classification.category == "newsletter"
      assert classification.priority == 1
    end

    test "pattern match is case-insensitive" do
      email = %{
        from: "News <digest@SUBSTACK.COM>",
        subject: "Test",
        labels: []
      }

      assert {:ok, classification} = FastClassifier.classify(email)
      assert classification.category == "newsletter"
    end

    test "matches by domain" do
      email = %{
        from: "Jensen Huang <ceo@nvidia.com>",
        subject: "GTC Keynote",
        labels: []
      }

      assert {:ok, classification} = FastClassifier.classify(email)
      assert classification.category == "newsletter"
    end

    test "matches by Gmail category label" do
      email = %{
        from: "Shop <deals@randomshop.com>",
        subject: "50% off",
        labels: ["INBOX", "CATEGORY_PROMOTIONS"]
      }

      assert {:ok, classification} = FastClassifier.classify(email)
      assert classification.category == "marketing"
      assert classification.action == "archive"
    end

    test "email match takes priority over pattern match" do
      # Add a pattern that would also match Sandra's domain
      {:ok, _} =
        Repo.insert(
          EmailSender.changeset(%EmailSender{}, %{
            email: "rule-home@fast-classifier",
            match_pattern: "example.nl",
            classification_override: "personal",
            priority_override: 2
          })
        )

      email = %{
        from: "Sandra Beckers <former-colleague@example.com>",
        subject: "Test",
        labels: []
      }

      assert {:ok, classification} = FastClassifier.classify(email)
      # Email match (business/5) wins over pattern match (personal/2)
      assert classification.category == "business"
      assert classification.priority == 5
    end

    test "does not match sender without classification_override (returns :no_match with sender_type)" do
      email = %{
        from: "No Classification <noclass@example.com>",
        subject: "Hello",
        labels: []
      }

      # noclass@example.com row exists in setup but has no priority_override
      # and no total_emails — falls through to unknown_human.
      assert {:no_match, %{sender_type: "unknown_human"}} = FastClassifier.classify(email)
    end

    test "classification map has all required fields including sender_type" do
      email = %{
        from: "Sandra <former-colleague@example.com>",
        subject: "Test",
        labels: []
      }

      assert {:ok, c} = FastClassifier.classify(email)
      assert is_binary(c.category)
      assert is_integer(c.priority)
      assert is_binary(c.summary)
      assert is_binary(c.action)
      assert is_float(c.confidence) or is_integer(c.confidence)
      assert c.source == :fast_classifier
      assert is_binary(c.sender_type)
      assert c.sender_type in ~w(known_priority known_routine automated_system unknown_human)
    end
  end

  # ---------- sender_type derivation (one positive test per value) ----------

  describe "sender_type derivation" do
    test "known_priority — sender row with priority_override returns sender_type 'known_priority'" do
      {:ok, _} =
        Repo.insert(
          EmailSender.changeset(%EmailSender{}, %{
            email: "priority-sender@example-law.test",
            name: "Priority Sender",
            classification_override: "business",
            priority_override: 5
          })
        )

      email = %{
        from: "Priority Sender <priority-sender@example-law.test>",
        subject: "Test",
        labels: []
      }

      assert {:ok, c} = FastClassifier.classify(email)
      assert c.sender_type == "known_priority"
    end

    test "known_routine — sender seen >= 3 times with no overrides returns 'known_routine'" do
      {:ok, _} =
        Repo.insert(
          EmailSender.changeset(%EmailSender{}, %{
            email: "frequent@regular-correspondent.com",
            name: "Frequent Correspondent",
            total_emails: 5
          })
        )

      email = %{
        from: "Frequent Correspondent <frequent@regular-correspondent.com>",
        subject: "Hello again",
        labels: []
      }

      # No classification_override → category cascade returns :no_match,
      # but sender_type derivation produces known_routine.
      assert {:no_match, %{sender_type: "known_routine"}} = FastClassifier.classify(email)
    end

    test "automated_system — From noreply@... with no senders row returns 'automated_system'" do
      email = %{
        from: "GitHub <noreply@github.com>",
        subject: "PR merged",
        labels: []
      }

      assert {:no_match, %{sender_type: "automated_system"}} = FastClassifier.classify(email)
    end

    test "automated_system also matches non-noreply prefixes (mailer-daemon, bounce, etc.)" do
      # Variant coverage of the widened automated-prefix list.
      for prefix <- ~w(no-reply donotreply do-not-reply mailer-daemon bounce bounces) do
        email = %{
          from: "Auto <#{prefix}@somewhere.example>",
          subject: "Auto",
          labels: []
        }

        assert {:no_match, %{sender_type: "automated_system"}} =
                 FastClassifier.classify(email),
               "expected #{prefix}@ to be classified as automated_system"
      end
    end

    test "unknown_human — fresh sender with no senders row and no automated pattern returns 'unknown_human'" do
      email = %{
        from: "Jane New <jane-new@randomdomain.org>",
        subject: "First contact",
        labels: []
      }

      assert {:no_match, %{sender_type: "unknown_human"}} = FastClassifier.classify(email)
    end
  end

  # ---------- sender_type precedence ----------

  describe "sender_type precedence" do
    test "priority wins over routine when both signals are present on the same sender row" do
      {:ok, _} =
        Repo.insert(
          EmailSender.changeset(%EmailSender{}, %{
            email: "vip-frequent@example-law.test",
            name: "VIP Frequent",
            priority_override: 5,
            total_emails: 5
          })
        )

      email = %{
        from: "VIP Frequent <vip-frequent@example-law.test>",
        subject: "Test",
        labels: []
      }

      assert {:no_match, %{sender_type: "known_priority"}} = FastClassifier.classify(email)
    end

    test "automated_system wins over unknown_human when noreply@ is present" do
      # No senders row at all — automated pattern in From is the only signal.
      email = %{
        from: "No-Reply Notifier <noreply@brand-new.com>",
        subject: "Notification",
        labels: []
      }

      assert {:no_match, %{sender_type: "automated_system"}} = FastClassifier.classify(email)
    end
  end

  # ---------- :no_match still returns sender_type ----------

  describe ":no_match flow" do
    test "sender with priority_override but no classification_override returns {:no_match, %{sender_type: 'known_priority'}}" do
      # Proves sender_type flows through even when the category cascade fails.
      {:ok, _} =
        Repo.insert(
          EmailSender.changeset(%EmailSender{}, %{
            email: "priority-no-cat@example.com",
            name: "Priority No Category",
            priority_override: 5
          })
        )

      email = %{
        from: "Priority No Category <priority-no-cat@example.com>",
        subject: "Test",
        labels: []
      }

      assert {:no_match, %{sender_type: "known_priority"}} = FastClassifier.classify(email)
    end
  end
end
