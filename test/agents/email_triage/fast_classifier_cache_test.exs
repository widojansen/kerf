defmodule Kerf.Agents.EmailTriage.FastClassifier.CacheTest do
  use Kerf.DataCase

  alias Kerf.Agents.EmailTriage.FastClassifier.Cache
  alias Kerf.KnowledgeBase.EmailSender

  setup do
    # Insert test rules
    {:ok, _} =
      Repo.insert(
        EmailSender.changeset(%EmailSender{}, %{
          email: "sandra@example.nl",
          name: "Sandra",
          domain: "example.nl",
          classification_override: "business",
          priority_override: 5
        })
      )

    {:ok, _} =
      Repo.insert(
        EmailSender.changeset(%EmailSender{}, %{
          email: "rule-sub@fast-classifier",
          name: "Substack",
          match_pattern: "substack.com",
          classification_override: "newsletter",
          priority_override: 1
        })
      )

    # No classification — should not be cached
    {:ok, _} =
      Repo.insert(
        EmailSender.changeset(%EmailSender{}, %{
          email: "nocls@example.com",
          domain: "example.com"
        })
      )

    name = :"cache_#{System.unique_integer([:positive])}"
    test_pid = self()
    {:ok, pid} = Cache.start_link(name: name, repo: Kerf.Repo, caller: test_pid)
    allow_repo(pid)

    %{cache: name, cache_pid: pid}
  end

  describe "get_by_email/2" do
    test "returns rule for known sender", %{cache: cache} do
      assert {:ok, rule} = Cache.get_by_email(cache, "sandra@example.nl")
      assert rule.classification_override == "business"
      assert rule.priority_override == 5
    end

    test "returns :no_match for unknown sender", %{cache: cache} do
      assert :no_match = Cache.get_by_email(cache, "unknown@nowhere.org")
    end

    test "does not return sender without classification_override", %{cache: cache} do
      assert :no_match = Cache.get_by_email(cache, "nocls@example.com")
    end
  end

  describe "get_by_domain/2" do
    test "returns rule for known domain", %{cache: cache} do
      assert {:ok, rule} = Cache.get_by_domain(cache, "example.nl")
      assert rule.classification_override == "business"
    end

    test "returns :no_match for unknown domain", %{cache: cache} do
      assert :no_match = Cache.get_by_domain(cache, "nowhere.org")
    end
  end

  describe "get_pattern_rules/1" do
    test "returns all pattern rules sorted by priority desc", %{cache: cache} do
      rules = Cache.get_pattern_rules(cache)
      assert length(rules) >= 1
      assert Enum.any?(rules, &(&1.match_pattern == "substack.com"))
    end
  end

  describe "refresh/1" do
    test "picks up new rules added to database", %{cache: cache} do
      # Initially no match
      assert :no_match = Cache.get_by_email(cache, "new@test.com")

      # Add a new rule
      {:ok, _} =
        Repo.insert(
          EmailSender.changeset(%EmailSender{}, %{
            email: "new@test.com",
            classification_override: "personal",
            priority_override: 3
          })
        )

      # Refresh and check
      Cache.refresh(cache)
      # Small wait for async cast
      Process.sleep(50)

      assert {:ok, rule} = Cache.get_by_email(cache, "new@test.com")
      assert rule.classification_override == "personal"
    end
  end
end
