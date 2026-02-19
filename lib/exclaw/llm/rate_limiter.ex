defmodule ExClaw.LLM.RateLimiter do
  @moduledoc """
  Sliding-window rate limiter for LLM API calls.
  Tracks requests and tokens per minute to stay within API limits.
  """
  use GenServer

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def check_budget(name \\ __MODULE__) do
    GenServer.call(name, :check_budget)
  end

  def record_usage(name \\ __MODULE__, tokens) do
    GenServer.call(name, {:record_usage, tokens})
  end

  def get_stats(name \\ __MODULE__) do
    GenServer.call(name, :get_stats)
  end

  def reset(name \\ __MODULE__) do
    GenServer.call(name, :reset)
  end

  def expire_window(name \\ __MODULE__) do
    GenServer.call(name, :expire_window)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    state = %{
      max_requests: Keyword.get(opts, :max_requests_per_minute, 50),
      max_tokens: Keyword.get(opts, :max_tokens_per_minute, 40_000),
      requests_this_minute: 0,
      tokens_this_minute: 0,
      total_requests: 0,
      total_tokens: 0,
      window_start: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:check_budget, _from, state) do
    state = maybe_reset_window(state)

    cond do
      state.tokens_this_minute >= state.max_tokens ->
        {:reply, {:denied, "token budget exceeded (#{state.tokens_this_minute}/#{state.max_tokens} per minute)"}, state}

      state.requests_this_minute >= state.max_requests ->
        {:reply, {:denied, "request budget exceeded (#{state.requests_this_minute}/#{state.max_requests} per minute)"}, state}

      true ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:record_usage, tokens}, _from, state) do
    state =
      state
      |> Map.update!(:requests_this_minute, &(&1 + 1))
      |> Map.update!(:tokens_this_minute, &(&1 + tokens))
      |> Map.update!(:total_requests, &(&1 + 1))
      |> Map.update!(:total_tokens, &(&1 + tokens))

    {:reply, :ok, state}
  end

  def handle_call(:get_stats, _from, state) do
    stats = %{
      requests_this_minute: state.requests_this_minute,
      tokens_this_minute: state.tokens_this_minute,
      total_requests: state.total_requests,
      total_tokens: state.total_tokens
    }

    {:reply, stats, state}
  end

  def handle_call(:reset, _from, state) do
    state = %{state |
      requests_this_minute: 0,
      tokens_this_minute: 0,
      total_requests: 0,
      total_tokens: 0,
      window_start: System.monotonic_time(:millisecond)
    }

    {:reply, :ok, state}
  end

  def handle_call(:expire_window, _from, state) do
    state = %{state |
      requests_this_minute: 0,
      tokens_this_minute: 0,
      window_start: System.monotonic_time(:millisecond)
    }

    {:reply, :ok, state}
  end

  # --- Private ---

  defp maybe_reset_window(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.window_start

    if elapsed >= 60_000 do
      %{state |
        requests_this_minute: 0,
        tokens_this_minute: 0,
        window_start: now
      }
    else
      state
    end
  end
end
