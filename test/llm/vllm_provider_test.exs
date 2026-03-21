defmodule ExClaw.LLM.VLLMProviderTest do
  use ExUnit.Case, async: true

  alias ExClaw.LLM.VLLMProvider

  defp start_provider(adapter) do
    suffix = System.unique_integer([:positive])
    name = :"vllm_test_#{suffix}"
    rl_name = :"vllm_rl_#{suffix}"

    {:ok, _} =
      ExClaw.LLM.RateLimiter.start_link(
        name: rl_name,
        max_requests_per_minute: 1000,
        max_tokens_per_minute: 1_000_000
      )

    {:ok, pid} =
      VLLMProvider.start_link(
        name: name,
        base_url: "http://localhost:8000",
        adapter: adapter,
        rate_limiter: rl_name
      )

    {name, pid}
  end

  defp openai_response(content, opts \\ []) do
    %{
      "id" => "chatcmpl-test",
      "object" => "chat.completion",
      "model" => Keyword.get(opts, :model, "nvidia/Qwen3-32B-NVFP4"),
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => content
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => Keyword.get(opts, :input_tokens, 10),
        "completion_tokens" => Keyword.get(opts, :output_tokens, 20),
        "total_tokens" => Keyword.get(opts, :input_tokens, 10) + Keyword.get(opts, :output_tokens, 20)
      }
    }
  end

  defp openai_tool_response(tool_calls, opts \\ []) do
    %{
      "id" => "chatcmpl-test",
      "object" => "chat.completion",
      "model" => Keyword.get(opts, :model, "nvidia/Qwen3-32B-NVFP4"),
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => tool_calls
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 10,
        "completion_tokens" => 20,
        "total_tokens" => 30
      }
    }
  end

  describe "complete/4" do
    test "returns text response from OpenAI format" do
      adapter = fn request ->
        body = openai_response("Hello from vLLM")
        {request, Req.Response.json(body)}
      end

      {name, _pid} = start_provider(adapter)

      {:ok, result} =
        VLLMProvider.complete(name, "nvidia/Qwen3-32B-NVFP4", [
          %{role: "user", content: "hi"}
        ])

      assert result.type == :text
      assert result.content == "Hello from vLLM"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 20
    end

    test "sends correct OpenAI chat format" do
      test_pid = self()

      adapter = fn request ->
        send(test_pid, {:request, request})
        {request, Req.Response.json(openai_response("ok"))}
      end

      {name, _} = start_provider(adapter)

      VLLMProvider.complete(name, "nvidia/Qwen3-32B-NVFP4", [
        %{role: "user", content: "Hello"}
      ])

      assert_receive {:request, req}
      body = Jason.decode!(req.body)

      assert body["model"] == "nvidia/Qwen3-32B-NVFP4"
      assert is_list(body["messages"])
      assert body["stream"] == false
      assert is_integer(body["max_tokens"])
    end

    test "passes system prompt as system message" do
      test_pid = self()

      adapter = fn request ->
        send(test_pid, {:request, request})
        {request, Req.Response.json(openai_response("ok"))}
      end

      {name, _} = start_provider(adapter)

      VLLMProvider.complete(
        name,
        "nvidia/Qwen3-32B-NVFP4",
        [%{role: "user", content: "hi"}],
        system: "You are a helpful assistant."
      )

      assert_receive {:request, req}
      body = Jason.decode!(req.body)
      messages = body["messages"]

      assert hd(messages)["role"] == "system"
      assert hd(messages)["content"] == "You are a helpful assistant."
    end

    test "passes tool definitions when provided" do
      test_pid = self()

      adapter = fn request ->
        send(test_pid, {:request, request})
        {request, Req.Response.json(openai_response("ok"))}
      end

      tools = [
        %{
          "type" => "function",
          "function" => %{
            "name" => "get_weather",
            "description" => "Get current weather",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        }
      ]

      {name, _} = start_provider(adapter)

      VLLMProvider.complete(
        name,
        "nvidia/Qwen3-32B-NVFP4",
        [%{role: "user", content: "weather?"}],
        tools: tools
      )

      assert_receive {:request, req}
      body = Jason.decode!(req.body)
      assert body["tools"] == tools
    end

    test "parses tool call response" do
      tool_calls = [
        %{
          "id" => "call_abc123",
          "type" => "function",
          "function" => %{
            "name" => "get_weather",
            "arguments" => "{\"city\": \"Amsterdam\"}"
          }
        }
      ]

      adapter = fn request ->
        body = openai_tool_response(tool_calls)
        {request, Req.Response.json(body)}
      end

      {name, _} = start_provider(adapter)

      {:ok, result} =
        VLLMProvider.complete(name, "nvidia/Qwen3-32B-NVFP4", [
          %{role: "user", content: "weather?"}
        ])

      assert result.type == :tool_use
      assert length(result.calls) == 1
      [call] = result.calls
      assert call.name == "get_weather"
      assert call.arguments == %{"city" => "Amsterdam"}
    end

    test "handles API error response" do
      adapter = fn request ->
        {request, %Req.Response{status: 500, body: "internal error"}}
      end

      {name, _} = start_provider(adapter)
      {:error, reason} = VLLMProvider.complete(name, "nvidia/Qwen3-32B-NVFP4", [])

      assert reason =~ "500"
    end

    test "handles network error" do
      adapter = fn _request ->
        raise "connection refused"
      end

      {name, _} = start_provider(adapter)
      {:error, reason} = VLLMProvider.complete(name, "nvidia/Qwen3-32B-NVFP4", [])

      assert is_binary(reason)
    end

    test "respects rate limiter" do
      {:ok, rl} =
        ExClaw.LLM.RateLimiter.start_link(
          name: :"rl_zero_vllm_#{System.unique_integer([:positive])}",
          max_requests_per_minute: 0,
          max_tokens_per_minute: 0
        )

      suffix = System.unique_integer([:positive])
      name = :"vllm_rl_test_#{suffix}"

      {:ok, _} =
        VLLMProvider.start_link(
          name: name,
          base_url: "http://localhost:8000",
          rate_limiter: rl
        )

      assert {:denied, _} = VLLMProvider.complete(name, "nvidia/Qwen3-32B-NVFP4", [])
    end
  end
end
