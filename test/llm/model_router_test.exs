defmodule ExClaw.LLM.ModelRouterTest do
  use ExUnit.Case, async: true

  alias ExClaw.LLM.ModelRouter

  defp make_anthropic_adapter(test_pid) do
    fn request ->
      send(test_pid, {:called, :anthropic, request})
      body = %{
        "content" => [%{"type" => "text", "text" => "from anthropic"}],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }
      {request, Req.Response.json(body)}
    end
  end

  defp make_ollama_adapter(test_pid) do
    fn request ->
      send(test_pid, {:called, :ollama, request})
      body = %{
        "message" => %{"role" => "assistant", "content" => "from ollama"},
        "done" => true,
        "prompt_eval_count" => 5,
        "eval_count" => 10
      }
      {request, Req.Response.json(body)}
    end
  end

  defp start_router(routes) do
    suffix = System.unique_integer([:positive])
    name = :erlang.list_to_atom('router_' ++ :erlang.integer_to_list(suffix))
    {:ok, _} = ModelRouter.start_link(name: name, routes: routes)
    name
  end

  defp start_anthropic(adapter) do
    suffix = System.unique_integer([:positive])
    rl = :erlang.list_to_atom('rl_a_' ++ :erlang.integer_to_list(suffix))
    b  = :erlang.list_to_atom('anth_' ++ :erlang.integer_to_list(suffix))
    {:ok, _} = ExClaw.LLM.RateLimiter.start_link(name: rl, max_requests_per_minute: 1000, max_tokens_per_minute: 1_000_000)
    {:ok, _} = ExClaw.LLM.Provider.start_link(name: b, api_key: "test", base_url: "https://api.anthropic.com/v1", adapter: adapter, rate_limiter: rl)
    b
  end

  defp start_ollama(adapter) do
    suffix = System.unique_integer([:positive])
    rl = :erlang.list_to_atom('rl_o_' ++ :erlang.integer_to_list(suffix))
    b  = :erlang.list_to_atom('oll_' ++ :erlang.integer_to_list(suffix))
    {:ok, _} = ExClaw.LLM.RateLimiter.start_link(name: rl, max_requests_per_minute: 1000, max_tokens_per_minute: 1_000_000)
    {:ok, _} = ExClaw.LLM.OllamaProvider.start_link(name: b, base_url: "http://localhost:11434", adapter: adapter, rate_limiter: rl)
    b
  end

  describe "routing" do
    test "routes claude-* to anthropic backend" do
      a = start_anthropic(make_anthropic_adapter(self()))
      o = start_ollama(make_ollama_adapter(self()))
      router = start_router([{~r/^claude-/, a}, {~r/^qwen3/, o}])
      ModelRouter.complete(router, "claude-sonnet-4-20250514", [%{role: "user", content: "hi"}])
      assert_receive {:called, :anthropic, _}
      refute_receive {:called, :ollama, _}, 100
    end

    test "routes qwen3 to ollama backend" do
      a = start_anthropic(make_anthropic_adapter(self()))
      o = start_ollama(make_ollama_adapter(self()))
      router = start_router([{~r/^claude-/, a}, {~r/^qwen3/, o}])
      ModelRouter.complete(router, "qwen3:8b", [%{role: "user", content: "hi"}])
      assert_receive {:called, :ollama, _}
      refute_receive {:called, :anthropic, _}, 100
    end

    test "routes deepseek to ollama backend" do
      o = start_ollama(make_ollama_adapter(self()))
      router = start_router([{~r/^deepseek/, o}])
      ModelRouter.complete(router, "deepseek-r1:32b", [%{role: "user", content: "hi"}])
      assert_receive {:called, :ollama, _}
    end

    test "returns error for unknown model" do
      router = start_router([{~r/^claude-/, :some_backend}])
      {:error, msg} = ModelRouter.complete(router, "unknown-model:latest", [])
      assert msg =~ "no route"
    end

    test "returns backend response unchanged" do
      o = start_ollama(make_ollama_adapter(self()))
      router = start_router([{~r/^qwen3/, o}])
      {:ok, result} = ModelRouter.complete(router, "qwen3:8b", [%{role: "user", content: "hi"}])
      assert result.type == :text
      assert result.content == "from ollama"
    end

    test "dispatches multiple models to correct backends in same session" do
      a = start_anthropic(make_anthropic_adapter(self()))
      o = start_ollama(make_ollama_adapter(self()))
      router = start_router([{~r/^claude-/, a}, {~r/^qwen3/, o}, {~r/^deepseek/, o}])

      ModelRouter.complete(router, "claude-sonnet-4-20250514", [%{role: "user", content: "a"}])
      ModelRouter.complete(router, "qwen3:32b", [%{role: "user", content: "b"}])
      ModelRouter.complete(router, "deepseek-r1:32b", [%{role: "user", content: "c"}])

      assert_receive {:called, :anthropic, _}
      assert_receive {:called, :ollama, _}
      assert_receive {:called, :ollama, _}
    end
  end

  describe "list_routes/1" do
    test "returns routing table" do
      o = start_ollama(make_ollama_adapter(self()))
      router = start_router([{~r/^qwen3/, o}])
      routes = ModelRouter.list_routes(router)
      assert length(routes) == 1
      {pat, _} = hd(routes)
      assert is_struct(pat, Regex)
    end
  end

  describe "add_route/3 and remove_route/2" do
    test "adds route at runtime" do
      o = start_ollama(make_ollama_adapter(self()))
      router = start_router([])
      :ok = ModelRouter.add_route(router, ~r/^qwen3/, o)
      ModelRouter.complete(router, "qwen3:8b", [%{role: "user", content: "hi"}])
      assert_receive {:called, :ollama, _}
    end

    test "removes route at runtime" do
      o = start_ollama(make_ollama_adapter(self()))
      router = start_router([{~r/^qwen3/, o}])
      :ok = ModelRouter.remove_route(router, ~r/^qwen3/)
      {:error, _} = ModelRouter.complete(router, "qwen3:8b", [])
    end
  end
end
