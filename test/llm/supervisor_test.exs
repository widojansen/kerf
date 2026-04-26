defmodule Kerf.LLM.SupervisorTest do
  use ExUnit.Case

  describe "supervision tree" do
    test "starts both RateLimiter and Provider children" do
      # If the app started the supervisor, verify its children
      # If not (--no-start), start our own
      {rl_pid, provider_pid} = ensure_supervisor_running()

      assert Process.alive?(rl_pid)
      assert Process.alive?(provider_pid)
    end

    test "restarts a crashed child" do
      {rl_pid, _provider_pid} = ensure_supervisor_running()

      Process.exit(rl_pid, :kill)
      Process.sleep(50)

      new_pid = Process.whereis(Kerf.LLM.RateLimiter)
      assert new_pid != nil
      assert new_pid != rl_pid
      assert Process.alive?(new_pid)
    end
  end

  defp ensure_supervisor_running do
    case Process.whereis(Kerf.LLM.Supervisor) do
      nil ->
        Application.put_env(:exclaw, Kerf.LLM.RateLimiter, [
          max_requests_per_minute: 100,
          max_tokens_per_minute: 100_000
        ])

        Application.put_env(:exclaw, Kerf.LLM.Provider, [
          api_key: "test-key-not-real",
          adapter: fn request ->
            {request, Req.Response.json(%{"error" => "test"})}
          end
        ])

        start_supervised!(Kerf.LLM.Supervisor)

      _pid ->
        :ok
    end

    {Process.whereis(Kerf.LLM.RateLimiter), Process.whereis(Kerf.LLM.Provider)}
  end
end
