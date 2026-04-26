defmodule Kerf.LLM.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Kerf.LLM.RateLimiter

  setup do
    # Start a fresh RateLimiter per test with generous defaults
    name = :"rate_limiter_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      RateLimiter.start_link(
        name: name,
        max_requests_per_minute: 5,
        max_tokens_per_minute: 1000
      )

    %{pid: pid, name: name}
  end

  describe "check_budget/1" do
    test "allows requests under the limit", %{name: name} do
      assert :ok = RateLimiter.check_budget(name)
    end

    test "denies when request count exceeds per-minute limit", %{name: name} do
      # Use up all 5 requests
      for _ <- 1..5 do
        :ok = RateLimiter.check_budget(name)
        :ok = RateLimiter.record_usage(name, 10)
      end

      assert {:denied, reason} = RateLimiter.check_budget(name)
      assert reason =~ "request"
    end

    test "denies when token count exceeds per-minute limit", %{name: name} do
      # Record 1000 tokens (the limit)
      :ok = RateLimiter.check_budget(name)
      :ok = RateLimiter.record_usage(name, 1000)

      assert {:denied, reason} = RateLimiter.check_budget(name)
      assert reason =~ "token"
    end
  end

  describe "record_usage/2" do
    test "accumulates token usage", %{name: name} do
      :ok = RateLimiter.check_budget(name)
      :ok = RateLimiter.record_usage(name, 100)
      :ok = RateLimiter.check_budget(name)
      :ok = RateLimiter.record_usage(name, 200)

      stats = RateLimiter.get_stats(name)
      assert stats.tokens_this_minute == 300
      assert stats.requests_this_minute == 2
    end
  end

  describe "get_stats/1" do
    test "returns current counters", %{name: name} do
      stats = RateLimiter.get_stats(name)
      assert stats.tokens_this_minute == 0
      assert stats.requests_this_minute == 0
      assert stats.total_tokens >= 0
      assert stats.total_requests >= 0
    end
  end

  describe "reset/1" do
    test "clears all counters", %{name: name} do
      :ok = RateLimiter.check_budget(name)
      :ok = RateLimiter.record_usage(name, 500)

      :ok = RateLimiter.reset(name)

      stats = RateLimiter.get_stats(name)
      assert stats.tokens_this_minute == 0
      assert stats.requests_this_minute == 0
      assert stats.total_tokens == 0
      assert stats.total_requests == 0
    end
  end

  describe "window expiry" do
    test "resets counters after window expires", %{name: name} do
      # Use up all requests
      for _ <- 1..5 do
        :ok = RateLimiter.check_budget(name)
        :ok = RateLimiter.record_usage(name, 10)
      end

      assert {:denied, _} = RateLimiter.check_budget(name)

      # Simulate window expiry by sending a message to reset the window
      # In production the GenServer checks elapsed time; we use a test helper
      :ok = RateLimiter.expire_window(name)

      # Should be allowed again
      assert :ok = RateLimiter.check_budget(name)
    end
  end

  describe "configurable limits" do
    test "respects custom request limit" do
      name = :"rate_limiter_custom_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        RateLimiter.start_link(
          name: name,
          max_requests_per_minute: 2,
          max_tokens_per_minute: 100_000
        )

      :ok = RateLimiter.check_budget(name)
      :ok = RateLimiter.record_usage(name, 1)
      :ok = RateLimiter.check_budget(name)
      :ok = RateLimiter.record_usage(name, 1)

      assert {:denied, _} = RateLimiter.check_budget(name)
    end

    test "respects custom token limit" do
      name = :"rate_limiter_tokens_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        RateLimiter.start_link(
          name: name,
          max_requests_per_minute: 100,
          max_tokens_per_minute: 50
        )

      :ok = RateLimiter.check_budget(name)
      :ok = RateLimiter.record_usage(name, 50)

      assert {:denied, _} = RateLimiter.check_budget(name)
    end
  end
end
