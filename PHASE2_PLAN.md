# Phase 2: LLM Provider — Implementation Plan

## Context

Phase 1 (Security Layer) is complete — all 61 tests green. The next step per the architecture doc is building the LLM Provider layer: the Anthropic Messages API client that Agent.Session will call to get completions. This is the bridge between ExClaw and Claude.

The architecture defines this contract (used by Agent.Session in Phase 3):
```elixir
case ExClaw.LLM.Provider.complete(state.model, state.messages, state.tools) do
  {:ok, %{type: :text} = response} -> ...
  {:ok, %{type: :tool_use, calls: calls}} -> ...
  {:error, reason} -> ...
end
```

## Design Decisions

1. **HTTP client**: Build directly with `Req` (already in deps) — no 3rd-party Anthropic SDK. Full control, no version lag.
2. **Non-streaming first**: Synchronous request/response. Streaming (SSE) deferred to when CLI channel needs real-time output.
3. **Testability**: Use `Req.Test` adapter injection (Req's built-in test support) — no Mox needed for HTTP mocking.
4. **API key**: Resolved from env var at `init/1` time via `{:system, "ANTHROPIC_API_KEY"}` config pattern. Graceful degradation if missing (no crash loop).
5. **RateLimiter**: Separate GenServer, checked inside Provider before each API call. Sliding window per minute.
6. **Provider as GenServer**: Holds pre-configured Req client in state (headers, base URL built once). `complete/3` is a `GenServer.call`.

## Modules to Create

### `ExClaw.LLM.Provider` — `lib/exclaw/llm/provider.ex`
GenServer wrapping Req for Anthropic Messages API.

**Public API:**
- `start_link/1` — starts GenServer (called by Supervisor)
- `complete(model, messages, tools \\ [])` — send completion request, returns `{:ok, %{type: :text | :tool_use, ...}} | {:error, reason}`

**State:** `%{req: %Req.Request{}, default_model: string, default_max_tokens: integer}`

**Request flow:**
1. `check_budget()` via RateLimiter
2. Build JSON body (model, max_tokens, messages, tools, system)
3. `Req.post(state.req, url: "/messages", json: body)`
4. Parse response: map `content` blocks + `stop_reason` to internal format
5. `record_usage()` via RateLimiter
6. Return `{:ok, result}` or `{:error, reason}`

**API key safety:** Resolved once in `init/1`, stored inside Req headers only. If missing, `req` is set to `nil` and all calls return `{:error, "API key not configured"}`.

### `ExClaw.LLM.RateLimiter` — `lib/exclaw/llm/rate_limiter.ex`
GenServer for sliding-window token/request budgets.

**Public API:**
- `start_link/1`, `check_budget/0`, `record_usage/2`, `get_stats/0`, `reset/0`

**State:** requests/tokens this minute, max limits, window start, total accumulators

### `ExClaw.LLM.Supervisor` — `lib/exclaw/llm/supervisor.ex`
Supervisor starting RateLimiter then Provider. Strategy: `:one_for_one`.

## Test Files to Create

### `test/llm/rate_limiter_test.exs` (~10 tests)
- Allows requests under limit
- Denies when request count exceeds per-minute limit
- Denies when token count exceeds per-minute limit
- Resets counters after window expires
- `record_usage/2` accumulates tokens
- `get_stats/0` returns current counters
- `reset/0` clears everything
- Configurable limits

### `test/llm/provider_test.exs` (~18 tests)
- Text response: returns `{:ok, %{type: :text, content: "..."}}`
- Multi-block text: concatenates text blocks
- Tool use response: returns `{:ok, %{type: :tool_use, calls: [...]}}`
- Multiple tool calls in one response
- System prompt passed through
- Tools array sent in request body
- Error handling: 401, 400, 429, 500, network error, malformed JSON
- Never crashes GenServer on error
- Correct headers sent (x-api-key, anthropic-version, content-type)
- API key never logged
- Graceful handling when API key not configured

### `test/llm/supervisor_test.exs` (~2 tests)
- Starts both children
- Survives child crash/restart

## Config Changes

**`config/config.exs`** — add:
```elixir
config :exclaw, ExClaw.LLM.Provider,
  api_key: {:system, "ANTHROPIC_API_KEY"},
  base_url: "https://api.anthropic.com/v1",
  anthropic_version: "2023-06-01",
  default_model: "claude-sonnet-4-20250514",
  default_max_tokens: 8192

config :exclaw, ExClaw.LLM.RateLimiter,
  max_requests_per_minute: 50,
  max_tokens_per_minute: 40_000
```

**`config/test.exs`** — add:
```elixir
config :exclaw, ExClaw.LLM.Provider,
  api_key: "test-key-not-real",
  adapter: {Req.Test, ExClaw.LLM.Provider}

config :exclaw, ExClaw.LLM.RateLimiter,
  max_requests_per_minute: 1000,
  max_tokens_per_minute: 1_000_000
```

**`lib/exclaw/application.ex`** — uncomment `ExClaw.LLM.Supervisor` (at end, after all tests pass)

## Implementation Order (TDD Steps)

| Step | Phase | What |
|------|-------|------|
| 1 | RED | Write `test/llm/rate_limiter_test.exs` + stub `rate_limiter.ex` |
| 2 | GREEN | Implement RateLimiter — all ~10 tests pass |
| 3 | RED | Write `test/llm/provider_test.exs` + stub `provider.ex` |
| 4 | GREEN | Implement Provider — all ~18 tests pass |
| 5 | GREEN | Create `supervisor.ex` + `supervisor_test.exs` |
| 6 | WIRE | Add config, uncomment in application.ex |
| 7 | VERIFY | `mix test test/llm/ --no-start` all green |

## Verification

1. `mix test test/llm/ --no-start` — all LLM tests pass
2. `mix test test/security/ --no-start` — security tests still pass (no regression)
3. `mix compile --warnings-as-errors` — clean compile
4. `mix test` — full suite passes (after wiring into application.ex)
