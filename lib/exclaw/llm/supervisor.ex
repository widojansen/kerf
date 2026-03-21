defmodule ExClaw.LLM.Supervisor do
  @moduledoc """
  Supervises the LLM subsystem:
  - RateLimiter: sliding-window token/request budget
  - Provider: Anthropic or Ollama backend, selected by config

  To use Ollama, set in your config:

      config :exclaw, :llm_backend, :ollama

      config :exclaw, ExClaw.LLM.OllamaProvider,
        base_url: "http://localhost:11434",
        default_model: "qwen3:8b"

  The default backend is :anthropic.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    rl_config = Application.get_env(:exclaw, ExClaw.LLM.RateLimiter, [])
    backend = Application.get_env(:exclaw, :llm_backend, :anthropic)

    provider_child =
      case backend do
        :ollama ->
          config = Application.get_env(:exclaw, ExClaw.LLM.OllamaProvider, [])
          # Register under the generic Provider name so all callers are transparent
          config = Keyword.put_new(config, :name, ExClaw.LLM.Provider)
          {ExClaw.LLM.OllamaProvider, config}

        _ ->
          config = Application.get_env(:exclaw, ExClaw.LLM.Provider, [])
          {ExClaw.LLM.Provider, config}
      end

    children = [
      {ExClaw.LLM.RateLimiter, rl_config},
      provider_child
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
