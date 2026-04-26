defmodule Kerf.LLM.Supervisor do
  @moduledoc """
  Supervises the LLM subsystem:
  - RateLimiter   : sliding-window token/request budget
  - Provider      : Anthropic backend (always started)
  - VLLMProvider  : vLLM/OpenAI-compatible backend (started when configured)
  - OllamaProvider: legacy Ollama backend (started when configured)
  - ModelRouter   : routes model names to the right backend

  Callers address Kerf.LLM.ModelRouter directly.
  Legacy callers using Kerf.LLM.Provider still work -- they route
  through ModelRouter for any model matching the claude-* pattern.

  Configure via LLM_BACKEND env var:
    - "vllm"   -> starts VLLMProvider, routes local models to it
    - "ollama" -> starts OllamaProvider, routes local models to it
    - unset    -> routes everything to Anthropic Provider
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    rl_config       = Application.get_env(:kerf, Kerf.LLM.RateLimiter, [])
    anthropic_config = Application.get_env(:kerf, Kerf.LLM.Provider, [])
    vllm_config     = Application.get_env(:kerf, Kerf.LLM.VLLMProvider, nil)
    ollama_config   = Application.get_env(:kerf, Kerf.LLM.OllamaProvider, nil)

    # Always start a shared RateLimiter and the Anthropic Provider.
    base_children = [
      {Kerf.LLM.RateLimiter, rl_config},
      {Kerf.LLM.Provider, anthropic_config}
    ]

    # Start the local inference backend (vLLM preferred over Ollama).
    local_children =
      cond do
        vllm_config   -> [{Kerf.LLM.VLLMProvider, vllm_config}]
        ollama_config -> [{Kerf.LLM.OllamaProvider, ollama_config}]
        true          -> []
      end

    # Build the routing table from config.
    routes = build_routes(vllm_config, ollama_config)

    router_child = [
      {Kerf.LLM.ModelRouter,
       name: Kerf.LLM.ModelRouter, routes: routes}
    ]

    children = base_children ++ local_children ++ router_child

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Build routing table based on which local backend is configured.
  defp build_routes(nil, nil) do
    # No local backend -- route everything to Anthropic.
    [{~r/./, Kerf.LLM.Provider}]
  end

  defp build_routes(vllm_config, _ollama_config) when vllm_config != nil do
    local = Kerf.LLM.VLLMProvider

    [
      # Anthropic models
      {~r/^claude-/, Kerf.LLM.Provider},
      # vLLM models (HuggingFace-style names via NVFP4 quantization)
      {~r/^nvidia\//, local},
      # Also match bare model names for convenience
      {~r/^qwen/i,      local},
      {~r/^deepseek/i,  local},
      {~r/^glm/i,       local},
      {~r/^nemotron/i,  local},
      {~r/^llama/i,     local},
      {~r/^phi/i,       local},
      # Fallback: unknown models go to Anthropic
      {~r/./, Kerf.LLM.Provider}
    ]
  end

  defp build_routes(nil, _ollama_config) do
    local = Kerf.LLM.OllamaProvider

    [
      # Anthropic models
      {~r/^claude-/, Kerf.LLM.Provider},
      # Ollama models available on the Spark
      {~r/^qwen3/,     local},
      {~r/^deepseek-/, local},
      {~r/^glm-/,      local},
      {~r/^nemotron-/, local},
      # Fallback: unknown models go to Anthropic
      {~r/./, Kerf.LLM.Provider}
    ]
  end
end
