defmodule Kerf.LLM.ProviderTest do
  use ExUnit.Case, async: true

  alias Kerf.LLM.Provider

  # Helper: start a Provider with a given Req adapter function and its own RateLimiter
  defp start_provider(adapter_fn, opts \\ []) do
    suffix = System.unique_integer([:positive])
    rl_name = :"test_rl_#{suffix}"
    provider_name = :"test_provider_#{suffix}"

    {:ok, _} =
      Kerf.LLM.RateLimiter.start_link(
        name: rl_name,
        max_requests_per_minute: Keyword.get(opts, :max_requests, 1000),
        max_tokens_per_minute: Keyword.get(opts, :max_tokens, 1_000_000)
      )

    {:ok, pid} =
      Provider.start_link(
        name: provider_name,
        api_key: Keyword.get(opts, :api_key, "test-key-not-real"),
        base_url: "https://api.anthropic.com/v1",
        anthropic_version: "2023-06-01",
        default_model: "claude-sonnet-4-20250514",
        default_max_tokens: 8192,
        adapter: adapter_fn,
        rate_limiter: rl_name
      )

    %{pid: pid, name: provider_name, rl_name: rl_name}
  end

  # Helper: build an Anthropic-style JSON response body
  defp anthropic_response(content_blocks, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "msg_test_123"),
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-20250514",
      "content" => content_blocks,
      "stop_reason" => Keyword.get(opts, :stop_reason, "end_turn"),
      "usage" => %{
        "input_tokens" => Keyword.get(opts, :input_tokens, 10),
        "output_tokens" => Keyword.get(opts, :output_tokens, 25)
      }
    }
  end

  describe "complete/4 — text responses" do
    test "returns {:ok, %{type: :text}} for a text response" do
      adapter = fn request ->
        body = anthropic_response([%{"type" => "text", "text" => "Hello!"}])
        {request, Req.Response.json(body)}
      end

      %{name: name} = start_provider(adapter)
      messages = [%{role: "user", content: "Hi"}]

      assert {:ok, result} = Provider.complete(name, "claude-sonnet-4-20250514", messages)
      assert result.type == :text
      assert result.content == "Hello!"
    end

    test "concatenates multiple text blocks" do
      adapter = fn request ->
        body = anthropic_response([
          %{"type" => "text", "text" => "Hello "},
          %{"type" => "text", "text" => "world!"}
        ])
        {request, Req.Response.json(body)}
      end

      %{name: name} = start_provider(adapter)

      assert {:ok, result} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi"}])
      assert result.type == :text
      assert result.content == "Hello world!"
    end
  end

  describe "complete/4 — tool use responses" do
    test "returns {:ok, %{type: :tool_use}} for tool calls" do
      adapter = fn request ->
        body = anthropic_response(
          [%{
            "type" => "tool_use",
            "id" => "toolu_123",
            "name" => "web_search",
            "input" => %{"query" => "elixir otp"}
          }],
          stop_reason: "tool_use"
        )
        {request, Req.Response.json(body)}
      end

      %{name: name} = start_provider(adapter)

      assert {:ok, result} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Search for elixir"}])
      assert result.type == :tool_use
      assert [call] = result.calls
      assert call.id == "toolu_123"
      assert call.name == "web_search"
      assert call.input == %{"query" => "elixir otp"}
    end

    test "handles multiple tool calls in one response" do
      adapter = fn request ->
        body = anthropic_response(
          [
            %{"type" => "tool_use", "id" => "toolu_1", "name" => "file_read", "input" => %{"path" => "a.txt"}},
            %{"type" => "tool_use", "id" => "toolu_2", "name" => "file_read", "input" => %{"path" => "b.txt"}}
          ],
          stop_reason: "tool_use"
        )
        {request, Req.Response.json(body)}
      end

      %{name: name} = start_provider(adapter)

      assert {:ok, result} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Read both files"}])
      assert result.type == :tool_use
      assert length(result.calls) == 2
    end
  end

  describe "complete/4 — request construction" do
    test "sends correct headers" do
      test_pid = self()

      adapter = fn request ->
        send(test_pid, {:request, request})
        body = anthropic_response([%{"type" => "text", "text" => "ok"}])
        {request, Req.Response.json(body)}
      end

      %{name: name} = start_provider(adapter)
      Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi"}])

      assert_receive {:request, request}
      headers = Map.new(request.headers)
      assert headers["x-api-key"] == ["test-key-not-real"]
      assert headers["anthropic-version"] == ["2023-06-01"]
      assert headers["content-type"] == ["application/json"]
    end

    test "passes tools array in request body when provided" do
      test_pid = self()

      adapter = fn request ->
        send(test_pid, {:request_body, request.body})
        body = anthropic_response([%{"type" => "text", "text" => "ok"}])
        {request, Req.Response.json(body)}
      end

      %{name: name} = start_provider(adapter)
      tools = [%{name: "web_search", description: "Search the web", input_schema: %{type: "object"}}]

      Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Search"}], tools: tools)

      assert_receive {:request_body, body}
      decoded = Jason.decode!(body)
      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1
    end

    test "passes system prompt when provided" do
      test_pid = self()

      adapter = fn request ->
        send(test_pid, {:request_body, request.body})
        body = anthropic_response([%{"type" => "text", "text" => "ok"}])
        {request, Req.Response.json(body)}
      end

      %{name: name} = start_provider(adapter)

      Provider.complete(
        name,
        "claude-sonnet-4-20250514",
        [%{role: "user", content: "Hi"}],
        system: "You are a helpful assistant."
      )

      assert_receive {:request_body, body}
      decoded = Jason.decode!(body)
      assert decoded["system"] == "You are a helpful assistant."
    end
  end

  describe "complete/4 — error handling" do
    test "returns {:error, _} on 401 unauthorized" do
      adapter = fn request ->
        resp = Req.Response.new(status: 401, body: Jason.encode!(%{"error" => %{"message" => "invalid api key"}}))
        resp = Req.Response.put_header(resp, "content-type", "application/json")
        {request, resp}
      end

      %{name: name} = start_provider(adapter)

      assert {:error, reason} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi"}])
      assert reason =~ "401"
    end

    test "returns {:error, _} on 400 bad request" do
      adapter = fn request ->
        resp = Req.Response.new(status: 400, body: Jason.encode!(%{"error" => %{"message" => "invalid model"}}))
        resp = Req.Response.put_header(resp, "content-type", "application/json")
        {request, resp}
      end

      %{name: name} = start_provider(adapter)

      assert {:error, reason} = Provider.complete(name, "bad-model", [%{role: "user", content: "Hi"}])
      assert reason =~ "400"
    end

    test "returns {:error, _} on 429 rate limited" do
      adapter = fn request ->
        resp = Req.Response.new(status: 429, body: Jason.encode!(%{"error" => %{"message" => "rate limited"}}))
        resp = Req.Response.put_header(resp, "content-type", "application/json")
        {request, resp}
      end

      %{name: name} = start_provider(adapter)

      assert {:error, reason} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi"}])
      assert reason =~ "429"
    end

    test "returns {:error, _} on 500 server error" do
      adapter = fn request ->
        resp = Req.Response.new(status: 500, body: Jason.encode!(%{"error" => %{"message" => "internal"}}))
        resp = Req.Response.put_header(resp, "content-type", "application/json")
        {request, resp}
      end

      %{name: name} = start_provider(adapter)

      assert {:error, reason} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi"}])
      assert reason =~ "500"
    end

    test "returns {:error, _} on network error" do
      adapter = fn request ->
        {request, %ArgumentError{message: "connection refused"}}
      end

      %{name: name} = start_provider(adapter)

      assert {:error, reason} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi"}])
      assert reason =~ "connection"
    end

    test "returns {:error, _} on malformed JSON body" do
      adapter = fn request ->
        resp = Req.Response.new(status: 200, body: "not json at all")
        {request, resp}
      end

      %{name: name} = start_provider(adapter)

      assert {:error, _reason} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi"}])
    end

    test "never crashes the GenServer on error" do
      adapter = fn request ->
        {request, %ArgumentError{message: "boom"}}
      end

      %{name: name, pid: pid} = start_provider(adapter)

      assert {:error, _} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi"}])
      assert Process.alive?(pid)

      # Still works for subsequent calls
      assert {:error, _} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi again"}])
      assert Process.alive?(pid)
    end
  end

  describe "complete/4 — API key handling" do
    test "returns {:error, _} when API key not configured" do
      adapter = fn request ->
        body = anthropic_response([%{"type" => "text", "text" => "ok"}])
        {request, Req.Response.json(body)}
      end

      %{name: name} = start_provider(adapter, api_key: nil)

      assert {:error, reason} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi"}])
      assert reason =~ "API key"
    end
  end

  describe "complete/4 — rate limiter integration" do
    test "returns {:denied, _} when rate limiter budget exceeded" do
      adapter = fn request ->
        body = anthropic_response([%{"type" => "text", "text" => "ok"}])
        {request, Req.Response.json(body)}
      end

      %{name: name} = start_provider(adapter, max_requests: 1)

      # First call succeeds
      assert {:ok, _} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi"}])

      # Second call denied by rate limiter
      assert {:denied, reason} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi again"}])
      assert reason =~ "budget"
    end
  end

  describe "complete/4 — usage tracking" do
    test "records token usage in rate limiter after successful call" do
      adapter = fn request ->
        body = anthropic_response(
          [%{"type" => "text", "text" => "ok"}],
          input_tokens: 15,
          output_tokens: 30
        )
        {request, Req.Response.json(body)}
      end

      %{name: name, rl_name: rl_name} = start_provider(adapter)

      assert {:ok, _} = Provider.complete(name, "claude-sonnet-4-20250514", [%{role: "user", content: "Hi"}])

      stats = Kerf.LLM.RateLimiter.get_stats(rl_name)
      assert stats.tokens_this_minute == 45
      assert stats.requests_this_minute == 1
    end
  end
end
