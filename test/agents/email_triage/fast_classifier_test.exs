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
    test "returns :no_match for unknown sender" do
      email = %{
        from: "Unknown Person <unknown@nowhere.org>",
        subject: "Hello",
        labels: []
      }

      assert :no_match = FastClassifier.classify(email)
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

    test "does not match sender without classification_override" do
      email = %{
        from: "No Classification <noclass@example.com>",
        subject: "Hello",
        labels: []
      }

      assert :no_match = FastClassifier.classify(email)
    end

    test "classification map has all required fields" do
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
    end
  end
end
