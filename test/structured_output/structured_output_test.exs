defmodule Kerf.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias Kerf.StructuredOutput
  alias Kerf.StructuredOutput.SchemaRegistry

  # --- Helpers ---

  defp start_registry do
    name = :"so_reg_#{System.unique_integer([:positive])}"
    {:ok, _pid} = SchemaRegistry.start_link(name: name)
    name
  end

  defp yes_no_schema do
    %{
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "decision" => %{"type" => "string", "enum" => ["yes", "no"]},
          "reason" => %{"type" => "string"}
        },
        "required" => ["decision", "reason"]
      },
      coercions: [],
      description: "A yes/no decision with reasoning",
      max_tokens: 256
    }
  end

  defp priority_schema do
    %{
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "score" => %{"type" => "integer", "minimum" => 1, "maximum" => 10},
          "explanation" => %{"type" => "string"}
        },
        "required" => ["score", "explanation"]
      },
      coercions: [score: :integer],
      description: "A priority score from 1-10",
      max_tokens: 512
    }
  end

  # Fake provider that returns a canned response
  defp make_provider(response_content) do
    fn _model, _messages, _opts ->
      {:ok, %{type: :text, content: response_content, usage: %{input_tokens: 10, output_tokens: 20}}}
    end
  end

  defp make_failing_provider(error) do
    fn _model, _messages, _opts ->
      {:error, error}
    end
  end

  # Provider that returns different responses on successive calls
  defp make_retry_provider(responses) do
    agent = start_supervised!({Agent, fn -> responses end})

    fn _model, _messages, _opts ->
      response = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
      {:ok, %{type: :text, content: response, usage: %{input_tokens: 10, output_tokens: 20}}}
    end
  end

  describe "complete/4 — happy path" do
    test "returns validated data for valid LLM response" do
      reg = start_registry()
      :ok = SchemaRegistry.register(reg, :yes_no, yes_no_schema())

      provider = make_provider(~s({"decision": "yes", "reason": "looks good"}))

      assert {:ok, %{"decision" => "yes", "reason" => "looks good"}} =
               StructuredOutput.complete(
                 :yes_no,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "Is this good?"}],
                 registry: reg,
                 provider_fn: provider
               )
    end

    test "applies coercions after validation" do
      reg = start_registry()
      :ok = SchemaRegistry.register(reg, :priority, priority_schema())

      provider = make_provider(~s({"score": "7", "explanation": "high priority"}))

      assert {:ok, %{"score" => 7, "explanation" => "high priority"}} =
               StructuredOutput.complete(
                 :priority,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "Rate this"}],
                 registry: reg,
                 provider_fn: provider
               )
    end

    test "parses JSON from fenced code block" do
      reg = start_registry()
      :ok = SchemaRegistry.register(reg, :yes_no, yes_no_schema())

      response = """
      ```json
      {"decision": "no", "reason": "not enough info"}
      ```
      """

      provider = make_provider(response)

      assert {:ok, %{"decision" => "no"}} =
               StructuredOutput.complete(
                 :yes_no,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "test"}],
                 registry: reg,
                 provider_fn: provider
               )
    end

    test "parses JSON after <think> tags" do
      reg = start_registry()
      :ok = SchemaRegistry.register(reg, :yes_no, yes_no_schema())

      response = """
      <think>
      Let me analyze this carefully.
      </think>
      {"decision": "yes", "reason": "clear evidence"}
      """

      provider = make_provider(response)

      assert {:ok, %{"decision" => "yes"}} =
               StructuredOutput.complete(
                 :yes_no,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "test"}],
                 registry: reg,
                 provider_fn: provider
               )
    end
  end

  describe "complete/4 — error handling" do
    test "returns error for unregistered schema" do
      reg = start_registry()

      provider = make_provider("irrelevant")

      assert {:error, :schema_not_found} =
               StructuredOutput.complete(
                 :nonexistent,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "hi"}],
                 registry: reg,
                 provider_fn: provider
               )
    end

    test "returns error when provider fails" do
      reg = start_registry()
      :ok = SchemaRegistry.register(reg, :yes_no, yes_no_schema())

      provider = make_failing_provider("API error 500: internal error")

      assert {:error, "API error 500: internal error"} =
               StructuredOutput.complete(
                 :yes_no,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "hi"}],
                 registry: reg,
                 provider_fn: provider
               )
    end
  end

  describe "complete/4 — retry on validation failure" do
    test "retries on JSON parse failure and succeeds" do
      reg = start_registry()
      :ok = SchemaRegistry.register(reg, :yes_no, yes_no_schema())

      # First call returns unparseable text, second call returns valid JSON
      provider =
        make_retry_provider([
          "I think the answer is yes.",
          ~s({"decision": "yes", "reason": "confirmed"})
        ])

      assert {:ok, %{"decision" => "yes"}} =
               StructuredOutput.complete(
                 :yes_no,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "test"}],
                 registry: reg,
                 provider_fn: provider,
                 max_retries: 2
               )
    end

    test "retries on validation failure and succeeds" do
      reg = start_registry()
      :ok = SchemaRegistry.register(reg, :yes_no, yes_no_schema())

      # First call returns invalid enum value, second returns valid
      provider =
        make_retry_provider([
          ~s({"decision": "maybe", "reason": "unsure"}),
          ~s({"decision": "yes", "reason": "confirmed"})
        ])

      assert {:ok, %{"decision" => "yes"}} =
               StructuredOutput.complete(
                 :yes_no,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "test"}],
                 registry: reg,
                 provider_fn: provider,
                 max_retries: 2
               )
    end

    test "exhausts max_retries and returns error" do
      reg = start_registry()
      :ok = SchemaRegistry.register(reg, :yes_no, yes_no_schema())

      # All responses are invalid
      provider =
        make_retry_provider([
          "not json at all",
          "still not json",
          "nope"
        ])

      assert {:error, {:validation_failed, _}} =
               StructuredOutput.complete(
                 :yes_no,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "test"}],
                 registry: reg,
                 provider_fn: provider,
                 max_retries: 2
               )
    end

    test "default max_retries is 2 (3 total attempts)" do
      reg = start_registry()
      :ok = SchemaRegistry.register(reg, :yes_no, yes_no_schema())

      call_count = start_supervised!({Agent, fn -> 0 end})

      provider = fn _model, _messages, _opts ->
        Agent.update(call_count, &(&1 + 1))
        {:ok, %{type: :text, content: "invalid", usage: %{input_tokens: 10, output_tokens: 20}}}
      end

      StructuredOutput.complete(
        :yes_no,
        "nvidia/Qwen3-32B-NVFP4",
        [%{role: "user", content: "test"}],
        registry: reg,
        provider_fn: provider
      )

      assert Agent.get(call_count, & &1) == 3
    end
  end

  describe "complete/4 — provider detection" do
    test "passes guided_json for vLLM-style models" do
      reg = start_registry()
      :ok = SchemaRegistry.register(reg, :yes_no, yes_no_schema())

      call_opts = start_supervised!({Agent, fn -> nil end})

      provider = fn _model, _messages, opts ->
        Agent.update(call_opts, fn _ -> opts end)
        {:ok, %{type: :text, content: ~s({"decision": "yes", "reason": "ok"}), usage: %{input_tokens: 10, output_tokens: 20}}}
      end

      StructuredOutput.complete(
        :yes_no,
        "nvidia/Qwen3-32B-NVFP4",
        [%{role: "user", content: "test"}],
        registry: reg,
        provider_fn: provider,
        provider_type: :vllm
      )

      opts = Agent.get(call_opts, & &1)
      assert opts[:guided_json] != nil
    end

    test "augments system prompt for non-vLLM providers" do
      reg = start_registry()
      :ok = SchemaRegistry.register(reg, :yes_no, yes_no_schema())

      call_opts = start_supervised!({Agent, fn -> nil end})

      provider = fn _model, _messages, opts ->
        Agent.update(call_opts, fn _ -> opts end)
        {:ok, %{type: :text, content: ~s({"decision": "yes", "reason": "ok"}), usage: %{input_tokens: 10, output_tokens: 20}}}
      end

      StructuredOutput.complete(
        :yes_no,
        "claude-sonnet-4-20250514",
        [%{role: "user", content: "test"}],
        registry: reg,
        provider_fn: provider,
        provider_type: :anthropic,
        system: "Be helpful."
      )

      opts = Agent.get(call_opts, & &1)
      assert opts[:system] =~ "JSON"
      refute Keyword.has_key?(opts, :guided_json)
    end
  end

  describe "complete/4 — temperature default" do
    test "defaults temperature to 0.1" do
      reg = start_registry()
      :ok = SchemaRegistry.register(reg, :yes_no, yes_no_schema())

      call_opts = start_supervised!({Agent, fn -> nil end})

      provider = fn _model, _messages, opts ->
        Agent.update(call_opts, fn _ -> opts end)
        {:ok, %{type: :text, content: ~s({"decision": "yes", "reason": "ok"}), usage: %{input_tokens: 10, output_tokens: 20}}}
      end

      StructuredOutput.complete(
        :yes_no,
        "nvidia/Qwen3-32B-NVFP4",
        [%{role: "user", content: "test"}],
        registry: reg,
        provider_fn: provider
      )

      opts = Agent.get(call_opts, & &1)
      assert opts[:temperature] == 0.1
    end
  end

  describe "complete_with_schema/4" do
    test "works with inline schema (no registration)" do
      inline_schema = yes_no_schema()
      provider = make_provider(~s({"decision": "no", "reason": "nope"}))

      assert {:ok, %{"decision" => "no"}} =
               StructuredOutput.complete_with_schema(
                 inline_schema,
                 "nvidia/Qwen3-32B-NVFP4",
                 [%{role: "user", content: "test"}],
                 provider_fn: provider
               )
    end
  end
end
