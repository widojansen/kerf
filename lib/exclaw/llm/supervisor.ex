defmodule ExClaw.LLM.Supervisor do
  @moduledoc """
  Supervises the LLM subsystem:
  - RateLimiter  : sliding-window token/request budget
  - Provider     : Anthropic backend (always started)
  - OllamaProvider: local Ollama backend (started when configured)
  - ModelRouter  : routes model names to the right backend

  Callers address ExClaw.LLM.ModelRouter directly.
  Legacy callers using ExClaw.LLM.Provider still work -- they route
  through ModelRouter for any model matching the claude-* pattern.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    rl_config       = Application.get_env(:exclaw, ExClaw.LLM.RateLimiter, [])
    anthropic_config = Application.get_env(:exclaw, ExClaw.LLM.Provider, [])
    ollama_config   = Application.get_env(:exclaw, ExClaw.LLM.OllamaProvider, nil)

    # Always start a shared RateLimiter and the Anthropic Provider.
    base_children = [
      {ExClaw.LLM.RateLimiter, rl_config},
      {ExClaw.LLM.Provider, anthropic_config}
    ]

    # Start OllamaProvider only when config is present.
    ollama_children =
      if ollama_config do
        [{ExClaw.LLM.OllamaProvider, ollama_config}]
      else
        []
      end

    # Build the routing table from config.
    routes = build_routes(ollama_config)

    router_child = [
      {ExClaw.LLM.ModelRouter,
       name: ExClaw.LLM.ModelRouter, routes: routes}
    ]

    children = base_children ++ ollama_children ++ router_child
    Supervisor.init(children, strategy: :one_for_one)
  end

  # Build routing table. Ollama gets all local model patterns;
  # Anthropic gets claude-* and anything not matched by a local route.
  defp build_routes(nil) do
    # Ollama not configured -- route everything to Anthropic Provider.
    [{~r/./, ExClaw.LLM.Provider}]
  end

  defp build_routes(_ollama_config) do
    [
      # Anthropic models
      {~r/^claude-/, ExClaw.LLM.Provider},
      # Ollama models available on the Spark
      {~r/^qwen3/,     ExClaw.LLM.OllamaProvider},
      {~r/^deepseek-/, ExClaw.LLM.OllamaProvider},
      {~r/^glm-/,      ExClaw.LLM.OllamaProvider},
      {~r/^nemotron-/, ExClaw.LLM.OllamaProvider},
      # Fallback: unknown models go to Anthropic
      {~r/./, ExClaw.LLM.Provider}
    ]
  end
end
