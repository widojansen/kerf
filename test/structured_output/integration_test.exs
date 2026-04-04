defmodule ExClaw.StructuredOutput.IntegrationTest do
  use ExUnit.Case, async: true

  alias ExClaw.StructuredOutput
  alias ExClaw.StructuredOutput.SchemaRegistry

  # --- Helpers ---

  defp start_registry_with_builtins do
    name = :"so_int_reg_#{System.unique_integer([:positive])}"
    {:ok, _pid} = SchemaRegistry.start_link(name: name, register_builtins: true)
    name
  end

  defp make_provider(response_content) do
    fn _model, _messages, _opts ->
      {:ok, %{type: :text, content: response_content, usage: %{input_tokens: 10, output_tokens: 20}}}
    end
  end

  describe "built-in schemas" do
    test ":yes_no is registered at startup with register_builtins: true" do
      reg = start_registry_with_builtins()
      assert {:ok, schema} = SchemaRegistry.get(reg, :yes_no)
      assert schema.description =~ "yes/no"
    end

    test ":priority_score is registered at startup" do
      reg = start_registry_with_builtins()
      assert {:ok, schema} = SchemaRegistry.get(reg, :priority_score)
      assert schema.description =~ "priority"
    end

    test ":entity_extraction is registered at startup" do
      reg = start_registry_with_builtins()
      assert {:ok, schema} = SchemaRegistry.get(reg, :entity_extraction)
      assert schema.description =~ "entities"
    end

    test "all built-in schemas are registered" do
      reg = start_registry_with_builtins()
      schemas = SchemaRegistry.list(reg)
      names = Enum.map(schemas, fn {name, _} -> name end) |> Enum.sort()
      assert names == [:email_classification, :entity_extraction, :priority_score, :yes_no]
    end
  end

  describe "full lifecycle" do
    test "register → complete → validate → coerce → return with :yes_no" do
      reg = start_registry_with_builtins()

      provider = make_provider(~s({"decision": "yes", "reason": "confirmed"}))

      assert {:ok, %{"decision" => "yes", "reason" => "confirmed"}} =
               StructuredOutput.complete(
                 :yes_no,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "Is the sky blue?"}],
                 registry: reg,
                 provider_fn: provider
               )
    end

    test "full lifecycle with :priority_score and coercion" do
      reg = start_registry_with_builtins()

      provider =
        make_provider(
          ~s({"score": "8", "factors": ["urgency", "impact"], "explanation": "high priority item"})
        )

      assert {:ok, result} =
               StructuredOutput.complete(
                 :priority_score,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "Rate this ticket"}],
                 registry: reg,
                 provider_fn: provider
               )

      assert result["score"] == 8
      assert is_integer(result["score"])
      assert result["factors"] == ["urgency", "impact"]
    end

    test "full lifecycle with :entity_extraction" do
      reg = start_registry_with_builtins()

      provider =
        make_provider(
          ~s({"entities": [{"name": "Alice", "type": "person", "value": "Alice Smith"}]})
        )

      assert {:ok, result} =
               StructuredOutput.complete(
                 :entity_extraction,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "Alice Smith sent an invoice"}],
                 registry: reg,
                 provider_fn: provider
               )

      assert length(result["entities"]) == 1
      assert hd(result["entities"])["name"] == "Alice"
    end

    test "registry without builtins starts empty" do
      name = :"so_no_builtins_#{System.unique_integer([:positive])}"
      {:ok, _pid} = SchemaRegistry.start_link(name: name, register_builtins: false)
      assert SchemaRegistry.list(name) == []
    end
  end
end
