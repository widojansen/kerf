defmodule Kerf.KnowledgeBase.GraphTest do
  use Kerf.DataCase

  alias Kerf.KnowledgeBase.Graph

  # AGE graph tests need the graph loaded
  # These tests exercise the Graph module's wrapping of AGE SQL queries

  describe "ensure_age_loaded/1" do
    test "loads AGE extension without error" do
      assert :ok = Graph.ensure_age_loaded(Repo)
    end
  end

  describe "upsert_sender_node/3" do
    test "creates sender node in graph" do
      Graph.ensure_age_loaded(Repo)
      assert :ok = Graph.upsert_sender_node(Repo, "alice@example.com", %{name: "Alice", priority_score: 0.5})
    end

    test "is idempotent" do
      Graph.ensure_age_loaded(Repo)
      assert :ok = Graph.upsert_sender_node(Repo, "bob@example.com", %{name: "Bob"})
      assert :ok = Graph.upsert_sender_node(Repo, "bob@example.com", %{name: "Bob Updated"})
    end
  end

  describe "upsert_thread_node/3" do
    test "creates thread node in graph" do
      Graph.ensure_age_loaded(Repo)
      assert :ok = Graph.upsert_thread_node(Repo, "thread_001", %{subject: "Test Thread"})
    end
  end

  describe "create_sent_edge/3" do
    test "creates SENT edge from sender to document" do
      Graph.ensure_age_loaded(Repo)
      Graph.upsert_sender_node(Repo, "carol@example.com", %{name: "Carol"})
      assert :ok = Graph.create_sent_edge(Repo, "carol@example.com", "doc_001")
    end
  end

  describe "create_participates_edge/3" do
    test "creates PARTICIPATES_IN edge from sender to thread" do
      Graph.ensure_age_loaded(Repo)
      Graph.upsert_sender_node(Repo, "dave@example.com", %{name: "Dave"})
      Graph.upsert_thread_node(Repo, "thread_002", %{subject: "Meeting"})
      assert :ok = Graph.create_participates_edge(Repo, "dave@example.com", "thread_002")
    end
  end

  describe "priority_senders_in_thread/2" do
    test "returns priority senders participating in a thread" do
      Graph.ensure_age_loaded(Repo)
      Graph.upsert_sender_node(Repo, "priority@example.com", %{name: "Priority", priority_score: 0.9})
      Graph.upsert_sender_node(Repo, "normal@example.com", %{name: "Normal", priority_score: 0.1})
      Graph.upsert_thread_node(Repo, "thread_prio", %{subject: "Prio Thread"})
      Graph.create_participates_edge(Repo, "priority@example.com", "thread_prio")
      Graph.create_participates_edge(Repo, "normal@example.com", "thread_prio")

      {:ok, results} = Graph.priority_senders_in_thread(Repo, "thread_prio", min_score: 0.5)
      emails = Enum.map(results, & &1.email)
      assert "priority@example.com" in emails
      refute "normal@example.com" in emails
    end

    test "returns empty for thread with no priority senders" do
      Graph.ensure_age_loaded(Repo)
      Graph.upsert_thread_node(Repo, "thread_empty", %{subject: "Empty"})
      assert {:ok, []} = Graph.priority_senders_in_thread(Repo, "thread_empty", min_score: 0.5)
    end
  end
end
