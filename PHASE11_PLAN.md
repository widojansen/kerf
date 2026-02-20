# Phase 11: Tool Registry + WebFetch + WebSearch

## Context

ExClaw has 3 built-in tools (shell_exec, file_read, file_write) routed through a hardcoded Dispatcher. Phase 11 adds:

1. **Tool Registry** — ETS-backed dynamic tool registration, replacing hardcoded dispatch
2. **WebFetch** — Fetch and extract readable content from URLs (Req + Floki)
3. **WebSearch** — Web search via self-hosted SearXNG (Docker)

No new Elixir dependencies needed — `req` and `floki` are already in mix.exs.

## Architecture

```
ExClaw.Tools.Registry (GenServer + ETS)
├── ETS :public reads (no GenServer bottleneck)
├── GenServer serializes writes (register/unregister)
└── Built-in tools auto-registered on startup

ExClaw.Tools.Dispatcher (refactored)
├── dispatch/3 → Registry lookup → apply(mod, fun, [input, opts])
├── build_executor/1 → closure over opts
└── tool_definitions/1 → delegates to Registry

ExClaw.Tools.WebFetch (stateless)
├── fetch(input, opts) → Req.get + Floki extraction
├── SSRF protection (block private IPs)
└── Content truncation (default 50K chars)

ExClaw.Tools.WebSearch (stateless)
├── search(input, opts) → Req.get to SearXNG JSON API
└── Format results as numbered list
```

## New Files

| File | Purpose |
|------|---------|
| `lib/exclaw/tools/registry.ex` | ETS-backed GenServer for dynamic tool registration |
| `lib/exclaw/tools/registrations.ex` | Registers all built-in tools on startup |
| `lib/exclaw/tools/web_fetch.ex` | URL fetch + content extraction tool |
| `lib/exclaw/tools/web_search.ex` | SearXNG web search tool |
| `test/tools/registry_test.exs` | ~15 tests |
| `test/tools/web_fetch_test.exs` | ~20 tests |
| `test/tools/web_search_test.exs` | ~12 tests |
| `docker-compose.searxng.yml` | SearXNG Docker setup |
| `searxng/settings.yml` | SearXNG config enabling JSON API |

## Files to Modify

| File | Change |
|------|--------|
| `lib/exclaw/tools/dispatcher.ex` | Refactor to look up tools from Registry |
| `test/tools/dispatcher_test.exs` | Update for Registry-backed dispatch |
| `lib/exclaw/application.ex` | Add Registry to supervision tree |
| `lib/exclaw/channels/cli.ex` | Update `Dispatcher.tool_definitions()` call |
| `lib/exclaw/channels/whatsapp.ex` | Same update as CLI |
| `config/config.exs` | Add WebFetch, WebSearch, Registry configs |
| `config/test.exs` | Add test overrides |
| `CLAUDE.md` | Document Phase 11 |

## Module Contracts

### ExClaw.Tools.Registry (GenServer + ETS)

```elixir
Registry.start_link(opts)
# opts: [name: atom()]

Registry.register_tool(name \\ __MODULE__, tool_spec)
# tool_spec: %{name: String.t(), description: String.t(),
#              input_schema: map(), module: module(), function: atom()}
# => :ok | {:error, reason}

Registry.unregister_tool(name \\ __MODULE__, tool_name)
# => :ok | {:error, :not_found}

Registry.get_tool(name \\ __MODULE__, tool_name)
# => {:ok, tool_spec} | {:error, :not_found}

Registry.list_tools(name \\ __MODULE__)
# => [tool_spec]

Registry.tool_definitions(name \\ __MODULE__)
# => [%{"name" => ..., "description" => ..., "input_schema" => ...}]

Registry.clear(name \\ __MODULE__)
# => :ok (test helper)
```

**Design:**
- ETS `:set`, `:public`, `:named_table` — reads bypass GenServer
- Writes (`register_tool`, `unregister_tool`, `clear`) via `GenServer.call`
- Table name derived from GenServer name (e.g., `:"#{name}_table"`)
- Re-registration updates the tool (idempotent upsert)
- Validation: name, module, function, input_schema all required

### ExClaw.Tools.Registrations (stateless module)

```elixir
Registrations.register_builtins(registry \\ ExClaw.Tools.Registry)
# Registers: shell_exec, file_read, file_write, web_fetch, web_search
# Tool definitions moved here from Dispatcher (single source of truth)
```

### ExClaw.Tools.Dispatcher (refactored)

```elixir
# Before: hardcoded pattern match
# After: Registry lookup
def dispatch(tool_name, input, opts) do
  registry = Keyword.get(opts, :registry, ExClaw.Tools.Registry)
  case Registry.get_tool(registry, tool_name) do
    {:ok, %{module: mod, function: fun}} ->
      apply(mod, fun, [input, opts])
    {:error, :not_found} ->
      {:error, "unknown tool: #{tool_name}"}
  end
end

def tool_definitions(opts \\ []) do
  registry = Keyword.get(opts, :registry, ExClaw.Tools.Registry)
  Registry.tool_definitions(registry)
end

# build_executor/1 unchanged
```

### ExClaw.Tools.WebFetch (stateless)

```elixir
WebFetch.fetch(input, opts \\ [])
# input: %{"url" => "https://...", "extract_mode" => "text"|"markdown"}
# extract_mode optional, default "text"
# => {:ok, formatted_string} | {:error, reason}

# Pure functions (testable directly):
WebFetch.validate_url(url)        # => :ok | {:error, reason}
WebFetch.check_ssrf(host)         # => :ok | {:error, reason}
WebFetch.extract_content(html)    # => {:ok, %{title: str, content: str}}
WebFetch.truncate(text, max)      # => truncated_text
```

**SSRF protection** — block before HTTP request:
- Resolve hostname via `:inet.getaddr(host, :inet)` / `:inet6`
- Block: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `::1`, `fe80::/10`, `0.0.0.0`
- Block hostnames: `localhost`, `*.local`
- Only `http://` and `https://` schemes

**Content extraction** via Floki:
1. Parse HTML with `Floki.parse_document/1`
2. Strip unwanted: `script`, `style`, `nav`, `footer`, `header`, `aside`, `iframe`
3. Extract main content: `<article>` > `<main>` > `<body>` fallback
4. Extract title from `<title>` tag
5. Convert to text with paragraph structure preserved
6. Truncate to `max_content_chars` (default 50K)

**HTTP via Req** — adapter injected via opts for testing (same pattern as LLM.Provider):
```elixir
http_client = Keyword.get(opts, :http_client, &default_http_client/1)
```

**Formatted result string:**
```
URL: https://example.com
Title: Example Domain
---
[extracted content]
```

### ExClaw.Tools.WebSearch (stateless)

```elixir
WebSearch.search(input, opts \\ [])
# input: %{"query" => "search terms", "count" => 5}
# count optional, default 5, max 10
# => {:ok, formatted_string} | {:error, reason}

# Pure functions:
WebSearch.validate_input(input)    # => {:ok, %{query: str, count: int}} | {:error, reason}
WebSearch.build_url(base, query, count)  # => url_string
WebSearch.format_results(results)  # => formatted_string
WebSearch.parse_response(body)     # => {:ok, [result]} | {:error, reason}
```

**SearXNG API call:**
```
GET {searxng_url}/search?q={query}&format=json&pageno=1
```

**Formatted result string:**
```
Search results for: "elixir otp tutorial"

1. Introduction to OTP - Learn Elixir
   https://example.com/elixir-otp
   A comprehensive guide to understanding OTP concepts...

2. Building GenServers — Elixir School
   https://elixirschool.com/genservers
   Learn how to build fault-tolerant applications...
```

## Security Considerations

- **FileGuard**: passes through non-file tools (no changes needed)
- **ShellSandbox**: passes through non-shell tools (no changes needed)
- **PromptGuard**: already scans ALL string values in input — catches prompt injection in search queries and URLs
- **SSRF**: built into WebFetch module (not a cross-cutting guard — tool-specific concern)
- **URL scheme**: only `http://` and `https://` allowed
- **No credential forwarding**: Req defaults to no cookies/auth headers
- **Content size limits**: enforced in both WebFetch and WebSearch

## Configuration

```elixir
# config/config.exs
config :exclaw, ExClaw.Tools.WebFetch,
  timeout: 15_000,
  max_content_chars: 50_000,
  user_agent: "ExClaw/0.1"

config :exclaw, ExClaw.Tools.WebSearch,
  searxng_url: "http://localhost:8080",
  timeout: 10_000

# config/test.exs
config :exclaw, ExClaw.Tools.WebFetch,
  timeout: 5_000,
  max_content_chars: 10_000

config :exclaw, ExClaw.Tools.WebSearch,
  searxng_url: "http://localhost:8080",
  timeout: 5_000
```

## SearXNG Docker Setup

`docker-compose.searxng.yml`:
```yaml
services:
  searxng:
    image: searxng/searxng:latest
    container_name: exclaw-searxng
    ports:
      - "8080:8080"
    volumes:
      - ./searxng:/etc/searxng
    restart: unless-stopped
```

`searxng/settings.yml` — enable JSON API:
```yaml
server:
  bind_address: "0.0.0.0"
  port: 8080
  secret_key: "exclaw-dev-only-key"
search:
  formats:
    - html
    - json
  default_lang: "en"
```

## TDD Implementation Order

### Phase 11a: Tool Registry (RED → GREEN)

**RED** (~15 tests in `test/tools/registry_test.exs`):
1. `start_link` starts GenServer
2. `register_tool` with valid spec returns `:ok`
3. `register_tool` with missing name returns error
4. `register_tool` with missing module returns error
5. `register_tool` with missing function returns error
6. `register_tool` with missing input_schema returns error
7. Re-registration updates tool (idempotent)
8. `get_tool` returns spec for registered tool
9. `get_tool` returns `{:error, :not_found}` for unregistered
10. `list_tools` returns all registered tools
11. `list_tools` returns empty list when none registered
12. `unregister_tool` removes a registered tool
13. `unregister_tool` returns error for non-existent
14. `tool_definitions` returns Anthropic-format list
15. `clear` empties registry

**GREEN**: Implement `ExClaw.Tools.Registry`

Then update Dispatcher + tests:
- Refactor `dispatcher.ex` to use Registry lookup
- Update `dispatcher_test.exs` — each test starts its own Registry, registers needed tools
- Create `registrations.ex` with all 3 existing tool definitions
- Verify existing dispatcher tests still pass (routing, build_executor, tool_definitions)

### Phase 11b: WebFetch (RED → GREEN)

**RED** (~20 tests in `test/tools/web_fetch_test.exs`):

URL validation (3):
- Rejects empty URL
- Rejects `ftp://` and `file:///` schemes
- Accepts `https://example.com`

SSRF protection (6):
- Blocks `127.0.0.1`, `localhost`
- Blocks `10.x`, `172.16.x`, `192.168.x` ranges
- Blocks `169.254.169.254` (cloud metadata)
- Allows public IPs

Content extraction (6):
- Extracts `<title>` tag
- Strips `<script>`, `<style>`, `<nav>`, `<footer>`
- Extracts `<article>` content preferentially
- Falls back to `<body>`
- Truncates to max chars
- Handles empty/malformed HTML gracefully

Fetch integration (5):
- Returns formatted result on 200 with HTML (mocked Req)
- Handles 404, 500 errors
- Returns non-HTML body as plain text
- Handles connection errors gracefully

**GREEN**: Implement `ExClaw.Tools.WebFetch`
**Register** web_fetch in `registrations.ex`

### Phase 11c: WebSearch (RED → GREEN)

**RED** (~12 tests in `test/tools/web_search_test.exs`):

Input validation (3):
- Rejects empty/missing query
- Clamps count to 1..10
- Accepts valid input

Search execution (5):
- Returns formatted results from mocked SearXNG response
- Returns "no results" message for empty results
- Handles SearXNG timeout/connection errors
- Handles malformed JSON response
- Handles SearXNG 500 error

Result formatting (2):
- Formats numbered results correctly
- Handles missing fields in result entries

URL construction (2):
- Encodes special characters in query
- Uses custom base URL from opts

**GREEN**: Implement `ExClaw.Tools.WebSearch`
**Register** web_search in `registrations.ex`

### Phase 11d: Wiring

1. Add `ExClaw.Tools.Registry` to `application.ex` supervision tree (after Container, before LLM)
2. Call `Registrations.register_builtins/0` in Registry init
3. Update `cli.ex` line 90: `Dispatcher.tool_definitions()` → `Dispatcher.tool_definitions()`
   (signature stays compatible — defaults to global Registry)
4. Update `whatsapp.ex` line 402: same
5. Add config to `config/config.exs` and `config/test.exs`
6. Create `docker-compose.searxng.yml` and `searxng/settings.yml`
7. `mix test` — full suite passes
8. Update CLAUDE.md

## Verification

1. `mix test test/tools/ --no-start` — all tool tests pass (existing + ~47 new)
2. `mix test` — full suite passes (~348 total)
3. Manual SearXNG: `docker compose -f docker-compose.searxng.yml up -d`
4. Manual: `curl "http://localhost:8080/search?q=test&format=json"` returns results
5. Manual E2E: `ANTHROPIC_API_KEY=... mix exclaw.cli`, ask agent to search/fetch
