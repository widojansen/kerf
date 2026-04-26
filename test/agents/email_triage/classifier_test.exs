defmodule Kerf.Agents.EmailTriage.ClassifierTest do
  use ExUnit.Case, async: true

  alias Kerf.Agents.EmailTriage.Classifier

  describe "classify/2" do
    test "returns classification from structured output" do
      provider_fn = fn _schema, _model, _messages, _opts ->
        {:ok,
         %{
           "category" => "business",
           "priority" => 4,
           "action" => "follow_up",
           "confidence" => 0.92,
           "summary" => "Important business email about Q2 results."
         }}
      end

      email = %{
        subject: "Q2 Results",
        body_text: "Here are the Q2 results for the team.",
        from: %{email: "boss@acme.com", name: "Boss"}
      }

      assert {:ok, result} = Classifier.classify(email, provider_fn: provider_fn)
      assert result.category == "business"
      assert result.priority == 4
      assert result.action == "follow_up"
      assert result.confidence == 0.92
      assert result.summary =~ "Q2 results"
    end

    test "passes sender and interest context to prompt" do
      test_pid = self()

      provider_fn = fn _schema, _model, messages, _opts ->
        send(test_pid, {:messages, messages})

        {:ok,
         %{
           "category" => "newsletter",
           "priority" => 2,
           "action" => "archive",
           "confidence" => 0.85,
           "summary" => "Weekly newsletter."
         }}
      end

      email = %{
        subject: "Weekly Digest",
        body_text: "This week in tech...",
        from: %{email: "news@example.com", name: "Newsletter"}
      }

      context = %{
        sender_info: %{is_priority: false, priority_score: 0.1},
        interest_matches: [%{topic: "AI/ML", score: 0.8}]
      }

      Classifier.classify(email, provider_fn: provider_fn, context: context)

      assert_receive {:messages, messages}
      user_msg = List.last(messages)
      assert user_msg["content"] =~ "Weekly Digest"
      assert user_msg["content"] =~ "AI/ML"
    end

    test "prepends /no_think to prompt for thinking models" do
      test_pid = self()

      provider_fn = fn _schema, _model, messages, _opts ->
        send(test_pid, {:messages, messages})

        {:ok,
         %{
           "category" => "newsletter",
           "priority" => 2,
           "action" => "archive",
           "confidence" => 0.8,
           "summary" => "Test."
         }}
      end

      email = %{subject: "Test", body_text: "Body", from: %{email: "a@b.com", name: "A"}}
      Classifier.classify(email, provider_fn: provider_fn)

      assert_receive {:messages, messages}
      user_msg = List.last(messages)
      assert String.starts_with?(user_msg["content"], "/no_think")
    end

    test "handles provider error" do
      provider_fn = fn _schema, _model, _messages, _opts ->
        {:error, "API timeout"}
      end

      email = %{subject: "Test", body_text: "Test", from: %{email: "a@b.com", name: "A"}}
      assert {:error, "API timeout"} = Classifier.classify(email, provider_fn: provider_fn)
    end
  end

  describe "schema_definition/0" do
    test "returns a valid JSON schema" do
      schema = Classifier.schema_definition()
      assert schema["type"] == "object"
      assert "category" in Map.keys(schema["properties"])
      assert "priority" in Map.keys(schema["properties"])
      assert "action" in Map.keys(schema["properties"])
      assert "summary" in Map.keys(schema["properties"])
    end
  end
end
