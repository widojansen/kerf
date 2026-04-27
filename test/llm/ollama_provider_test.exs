defmodule Kerf.LLM.OllamaProviderTest do
  use ExUnit.Case, async: true

  alias Kerf.LLM.OllamaProvider

  defp start_provider(adapter) do
    suffix = System.unique_integer([:positive])
    name = :"ollama_test_#{suffix}"
    rl_name = :"ollama_rl_#{suffix}"

    {:ok, _} =
      Kerf.LLM.RateLimiter.start_link(
        name: rl_name,
        max_requests_per_minute: 1000,
        max_tokens_per_minute: 1_000_000
      )

    {:ok, pid} =
      OllamaProvider.start_link(
        name: name,
        base_url: "http://localhost:11434",
        adapter: adapter,
        rate_limiter: rl_name
      )

    {name, pid}
  end

  defp ollama_response(content, opts \\ []) do
    %{
      "model" => Keyword.get(opts, :model, "qwen3:8b"),
      "message" => %{
        "role" => "assistant",
        "content" => content
      },
      "done" => true,
      "prompt_eval_count" => Keyword.get(opts, :input_tokens, 10),
      "eval_count" => Keyword.get(opts, :output_tokens, 20)
    }
  end

  describe "complete/4" do
    test "returns text response" do
      adapter = fn request ->
        body = ollama_response("Hello from Ollama")
        {request, Req.Response.json(body)}
      end

      {name, _pid} = start_provider(adapter)
      {:ok, result} = OllamaProvider.complete(name, "qwen3:8b", [{"role", "user", "content", "hi"}])

      assert result.type == :text
      assert result.content == "Hello from Ollama"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 20
    end

    test "sends correct Ollama request format" do
      test_pid = self()

      adapter = fn request ->
        send(test_pid, {:request, request})
        {request, Req.Response.json(ollama_response("ok"))}
      end

      {name, _} = start_provider(adapter)

      OllamaProvider.complete(name, "qwen3:32b", [
        %{role: "user", content: "Hello"}
      ])

      assert_receive {:request, req}
      body = Jason.decode!(req.body)
      assert body["model"] == "qwen3:32b"
      assert is_list(body["messages"])
      assert body["stream"] == false
    end

    test "passes system prompt as first message" do
      test_pid = self()

      adapter = fn request ->
        send(test_pid, {:request, request})
        {request, Req.Response.json(ollama_response("ok"))}
      end

      {name, _} = start_provider(adapter)

      OllamaProvider.complete(name, "qwen3:8b", [%{role: "user", content: "hi"}],
        system: "You are a helpful assistant."
      )

      assert_receive {:request, req}
      body = Jason.decode!(req.body)
      messages = body["messages"]
      assert hd(messages)["role"] == "system"
      assert hd(messages)["content"] == "You are a helpful assistant."
    end

    test "handles API error response" do
      adapter = fn request ->
        {request, %Req.Response{status: 500, body: "internal error"}}
      end

      {name, _} = start_provider(adapter)
      {:error, reason} = OllamaProvider.complete(name, "qwen3:8b", [])
      assert reason =~ "500"
    end

    test "handles network error" do
      adapter = fn _request ->
        raise "connection refused"
      end

      {name, _} = start_provider(adapter)
      {:error, reason} = OllamaProvider.complete(name, "qwen3:8b", [])
      assert is_binary(reason)
    end

    test "respects rate limiter" do
      {:ok, rl} =
        Kerf.LLM.RateLimiter.start_link(
          name: :"rl_zero_#{System.unique_integer([:positive])}",
          max_requests_per_minute: 0,
          max_tokens_per_minute: 0
        )

      suffix = System.unique_integer([:positive])
      name = :"ollama_rl_test_#{suffix}"

      {:ok, _} =
        OllamaProvider.start_link(
          name: name,
          base_url: "http://localhost:11434",
          rate_limiter: rl
        )

      assert {:denied, _} = OllamaProvider.complete(name, "qwen3:8b", [])
    end
  end
end
