defmodule ExClaw.LLM.Supervisor do
  @moduledoc """
  Supervises the LLM subsystem:
  - RateLimiter: sliding-window rate limiting for API calls
  - Provider: Anthropic Messages API client
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    rl_config = Application.get_env(:exclaw, ExClaw.LLM.RateLimiter, [])
    provider_config = Application.get_env(:exclaw, ExClaw.LLM.Provider, [])

    children = [
      {ExClaw.LLM.RateLimiter, rl_config},
      {ExClaw.LLM.Provider, provider_config}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
