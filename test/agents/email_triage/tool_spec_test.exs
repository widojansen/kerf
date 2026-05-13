defmodule Kerf.Agents.EmailTriage.ToolSpecTest do
  use ExUnit.Case, async: true

  alias Kerf.Agents.EmailTriage.ToolSpec

  # Sample inputs used across tests. Two-element vocabularies are enough to
  # exercise comma-separated interpolation; the exact values don't matter
  # beyond being the spec's seed vocab.
  @sample_topics ~w(kerf legal)
  @sample_actions ~w(reply_needed file)

  defp build, do: ToolSpec.build(@sample_topics, @sample_actions)

  defp params, do: build().function.parameters
  defp props, do: params().properties

  # ---------- top-level shape ----------

  describe "build/2 top-level shape" do
    test "type, function.name, parameters.type, parameters.additionalProperties" do
      spec = build()
      assert spec.type == "function"
      assert spec.function.name == "enrich_email"
      assert spec.function.parameters.type == "object"
      assert spec.function.parameters.additionalProperties == false
    end

    test "required is exactly [urgency, action, topic, summary] (sorted comparison)" do
      assert Enum.sort(params().required) ==
               Enum.sort(["urgency", "action", "topic", "summary"])
    end
  end

  # ---------- per-parameter contracts ----------

  describe "urgency parameter" do
    test "is a string with enum locked to the four urgency values" do
      urgency = props().urgency
      assert urgency.type == "string"
      assert Enum.sort(urgency.enum) == Enum.sort(["high", "medium", "low", "none"])
    end
  end

  describe "action parameter" do
    test "is a string and description lists each accepted action" do
      action = props().action
      assert action.type == "string"

      for value <- @sample_actions do
        assert action.description =~ value,
               "expected action description to contain #{inspect(value)}, got: #{inspect(action.description)}"
      end
    end

    test "has no :enum key — caller retains proposal freedom" do
      # The whole point of action being open-vocab: LLM may propose new values.
      # If we lock the enum, that path is dead. Keep it loose.
      refute Map.has_key?(props().action, :enum)
    end
  end

  describe "action_proposed_new parameter" do
    test "is a boolean" do
      assert props().action_proposed_new.type == "boolean"
    end
  end

  describe "topic parameter" do
    test "is an array of strings with minItems 1 and maxItems 4" do
      topic = props().topic
      assert topic.type == "array"
      assert topic.items.type == "string"
      assert topic.minItems == 1
      assert topic.maxItems == 4
    end

    test "description lists each accepted topic" do
      desc = props().topic.description

      for value <- @sample_topics do
        assert desc =~ value,
               "expected topic description to contain #{inspect(value)}, got: #{inspect(desc)}"
      end
    end
  end

  describe "topic_proposed_new parameter" do
    test "is an array of strings (empty array allowed — no minItems)" do
      tpn = props().topic_proposed_new
      assert tpn.type == "array"
      assert tpn.items.type == "string"
      # No minItems — caller may send [].
      refute Map.has_key?(tpn, :minItems)
    end
  end

  describe "summary parameter" do
    test "is a string with maxLength 200" do
      summary = props().summary
      assert summary.type == "string"
      assert summary.maxLength == 200
    end

    test "description carries the language-preservation instruction (Step 0b finding)" do
      # Spec §2.6 and §4.4: summary must be written in the email's original
      # language. Step 0b empirically observed that without explicit
      # instruction the model translates Dutch → English. This test pins that
      # the tool description includes the language guidance.
      assert props().summary.description =~ "same language"
    end
  end

  # ---------- vocab interpolation format ----------

  describe "vocab interpolation" do
    test "topic + action descriptions contain the comma-space-separated vocab list" do
      # Spec §4.4 shows description: "Prefer these values: #{Enum.join(values, ", ")}".
      # Pin the comma-space format so a refactor that changes the separator
      # (e.g. pipes) breaks loudly.
      spec = ToolSpec.build(["kerf", "legal"], ["reply_needed", "file"])
      assert spec.function.parameters.properties.topic.description =~ "kerf, legal"
      assert spec.function.parameters.properties.action.description =~ "reply_needed, file"
    end
  end

  # ---------- determinism ----------

  describe "determinism" do
    test "two calls with identical inputs return structurally identical maps" do
      assert ToolSpec.build(["kerf", "legal"], ["reply_needed", "file"]) ==
               ToolSpec.build(["kerf", "legal"], ["reply_needed", "file"])
    end
  end
end
