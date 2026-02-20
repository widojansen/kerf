# Phase 10: WhatsApp Channel (Node.js Baileys Sidecar)

## Context

ExClaw has a CLI channel, agent loop, Docker sandboxing, memory, and telemetry. The next step is the first external messaging channel: **WhatsApp** via a Node.js sidecar running `@whiskeysockets/baileys`. This enables the personal assistant to receive and respond to WhatsApp messages (DMs and groups).

**Why a sidecar?** Baileys is a Node.js library with no Elixir equivalent. Rather than embedding Node.js via NIFs, we run a separate Node.js process communicating over an Erlang Port (stdin/stdout JSON lines). This gives us OTP-native lifecycle management: when the GenServer dies, the Port closes, killing Node.js automatically.

**Why Port over HTTP?** Auto-cleanup, no network configuration, bidirectional streaming, OTP-idiomatic. HTTP adds a server, health checks, and zombie process risk for no benefit in a single-account personal assistant.

## Architecture

```
ExClaw (Elixir/OTP)                        whatsapp-bridge/ (Node.js)
+--------------------------+               +------------------------+
| Channels.WhatsApp        |               | bridge.js              |
|   (GenServer)            |<-- Port ----->|  +- Baileys client     |
|   - owns Erlang Port     |  JSON lines   |  +- auth persistence   |
|   - parses events        |  stdin/stdout |  +- reconnect logic    |
|   - routes to Agent.Sup  |               |  +- message filtering  |
|   - sends responses back |               +------------------------+
|   - telemetry emission   |
+--------------------------+
| Channels.WhatsApp.Sup    |
|   (Supervisor)           |
+--------------------------+
```

## Protocol (JSON Lines over stdin/stdout)

### Node -> Elixir (Events)
```json
{"type":"ready"}
{"type":"qr","data":"2@abc123..."}
{"type":"connected","user":{"id":"12345@s.whatsapp.net","name":"Bot"}}
{"type":"disconnected","reason":"connection closed","code":428}
{"type":"logged_out"}
{"type":"message","id":"MSG123","from":"12345@s.whatsapp.net","participant":null,"pushName":"John","text":"hello","timestamp":1708300000,"isGroup":false}
{"type":"send_result","id":"ref123","success":true}
{"type":"error","message":"something went wrong"}
```

### Elixir -> Node (Commands)
```json
{"type":"send","to":"12345@s.whatsapp.net","text":"Hello back!","id":"ref123"}
{"type":"read","jid":"12345@s.whatsapp.net","id":"MSG123","participant":null}
{"type":"typing","jid":"12345@s.whatsapp.net","composing":true}
{"type":"shutdown"}
```

## New Files

| File | Purpose |
|------|---------|
| `whatsapp-bridge/package.json` | Node.js deps: baileys 6.7.21, pino |
| `whatsapp-bridge/bridge.js` | Baileys <-> stdin/stdout JSON bridge (~200 lines) |
| `whatsapp-bridge/.gitignore` | Ignore node_modules/, auth_info/ |
| `lib/exclaw/channels/whatsapp.ex` | GenServer: Port management + message routing (~250 lines) |
| `lib/exclaw/channels/whatsapp/supervisor.ex` | Supervisor for WhatsApp GenServer |
| `test/channels/whatsapp_test.exs` | ~14 tests (pure functions + GenServer with mock Port) |
| `test/channels/whatsapp/supervisor_test.exs` | ~2 tests |

## Files to Modify

| File | Change |
|------|--------|
| `lib/exclaw/application.ex` | Add conditional WhatsApp.Supervisor |
| `config/config.exs` | Add WhatsApp config (enabled: false) |
| `config/test.exs` | Add WhatsApp test config (enabled: false) |
| `CLAUDE.md` | Document Phase 10 |

## Module Contracts

### ExClaw.Channels.WhatsApp (GenServer)

```elixir
WhatsApp.start_link(opts)
# opts: [name:, bridge_dir:, auth_dir:, node_path:, group_id_prefix:,
#        mention_required_in_groups:, model:, base_prompt:,
#        port_opener:, agent_supervisor:, registry:, store:]

WhatsApp.status(name \\ __MODULE__)
# => :starting | :waiting_qr | :connected | :disconnected | :stopped

WhatsApp.send_message(name \\ __MODULE__, jid, text)
# => :ok | {:error, reason}

WhatsApp.get_info(name \\ __MODULE__)
# => %{status:, user_info:, ...}
```

**State:**
```elixir
%{
  port: port() | nil,
  status: :starting | :waiting_qr | :connected | :disconnected | :stopped,
  user_info: map() | nil,
  buffer: "",                    # partial line buffer for Port data
  config: %{bridge_dir, auth_dir, node_path, group_id_prefix,
            mention_required, bot_jid, model, base_prompt},
  pending_sends: %{ref => {from, timer_ref}},
  port_opener: fun,             # injected for testing
  agent_supervisor: atom,
  registry: atom,
  store: atom
}
```

**Extracted pure functions (testable without GenServer):**
```elixir
derive_group_id(event, prefix)
# %{"from" => "12345@s.whatsapp.net"}, "wa" -> "wa_12345"
# %{"from" => "12345-67890@g.us"}, "wa" -> "wa_12345-67890_g"

should_process_message?(event, config)
# Skips: fromMe, empty text, status@broadcast, non-notify (if applicable)

parse_event(json_line)
# => {:ok, map} | {:error, reason}

build_send_command(jid, text)
# => %{type: "send", to: jid, text: text, id: ref}
```

**Key behavior — async message processing:**

The WhatsApp GenServer CANNOT block on LLM calls (unlike CLI). Each incoming message spawns a lightweight process:

```elixir
spawn(fn ->
  result = Agent.Supervisor.handle_message(sup, registry, group_id, text, session_opts)
  send(parent, {:agent_response, jid, group_id, text, result})
end)
```

Agent.Session serializes per group_id via its own GenServer queue, so concurrent spawns for the same group are safe.

### Port Communication

- Port opened with `{:line, 16_384}` — Erlang handles line buffering
- Complete lines arrive as `{port, {:data, {:eol, line}}}`
- Partial lines (overflow) arrive as `{port, {:data, {:noeol, partial}}}` — accumulated in buffer
- Port exit arrives as `{port, {:exit_status, code}}`
- **CRITICAL**: bridge.js must NOT use console.log — stdout is the protocol. Logging via pino to stderr.

### Restart Strategy

- `restart: :transient` on WhatsApp GenServer — restart on crash, NOT on normal stop (logged_out)
- Port exit with unexpected code triggers `Process.send_after(self(), :restart_port, 5_000)`
- Baileys handles its own reconnect for network drops (exponential backoff in bridge.js)

## Node.js Bridge (bridge.js)

Ported from nanoclaw's `src/channels/whatsapp.ts`. Key responsibilities:

1. **stdin**: Read JSON commands line-by-line via `readline`
2. **stdout**: Write JSON events (one per line) via `process.stdout.write`
3. **Baileys init**: `useMultiFileAuthState(authDir)` + `makeWASocket` + `makeCacheableSignalKeyStore`
4. **connection.update**: Emit qr/connected/disconnected/logged_out events
5. **creds.update**: Persist via `saveCreds()`
6. **messages.upsert**: Filter (skip fromMe, skip non-notify, skip status@broadcast), extract text, emit message events
7. **Reconnect**: On disconnect (non-401), exponential backoff (2s..60s), reset on success
8. **Commands**: send -> `sock.sendMessage`, typing -> `sock.sendPresenceUpdate`, read -> `sock.readMessages`, shutdown -> `sock.end()` + exit

## Configuration

```elixir
# config/config.exs
config :exclaw, ExClaw.Channels.WhatsApp,
  enabled: false,
  bridge_dir: "whatsapp-bridge",
  auth_dir: "priv/whatsapp_auth",
  node_path: "node",
  group_id_prefix: "wa",
  mention_required_in_groups: true,
  model: "claude-sonnet-4-20250514",
  base_prompt: "You are ExClaw, a personal AI assistant on WhatsApp. Be concise and helpful. Keep responses under 4000 characters."

# config/test.exs
config :exclaw, ExClaw.Channels.WhatsApp,
  enabled: false
```

## TDD Implementation Order

### Phase 10a: Node.js Bridge
1. Create `whatsapp-bridge/package.json` + `.gitignore`
2. Implement `whatsapp-bridge/bridge.js`
3. Manual smoke test: start bridge, observe QR/ready events

### Phase 10b: Pure Functions (RED -> GREEN)
4. **RED**: Write pure function tests in `test/channels/whatsapp_test.exs` (~6 tests)
   - `derive_group_id/2` — DM, group, special chars
   - `should_process_message?/2` — fromMe, empty text, valid
5. **GREEN**: Implement pure functions in `lib/exclaw/channels/whatsapp.ex`

### Phase 10c: GenServer (RED -> GREEN)
6. **RED**: Add GenServer tests (~8 tests) — uses `:simulate_event` pattern (no real Port)
   - Lifecycle: start, ready, qr, connected, disconnected, logged_out
   - Message routing: incoming message -> Agent.Supervisor -> response
   - Status reporting
7. **GREEN**: Implement full GenServer

### Phase 10d: Supervisor (RED -> GREEN)
8. **RED**: Write supervisor tests (~2 tests)
9. **GREEN**: Implement supervisor

### Phase 10e: Wiring
10. Add config to `config/config.exs`, `config/test.exs`
11. Add conditional WhatsApp.Supervisor to `application.ex`
12. `mix test` — all tests pass (existing + ~16 new)
13. Update CLAUDE.md

### Phase 10f: Manual Integration
14. `cd whatsapp-bridge && npm install`
15. Enable WhatsApp in config, start ExClaw
16. Scan QR code, send WhatsApp message, verify response

## Testing Strategy

**Pure functions**: Tested directly, no GenServer or infrastructure needed.

**GenServer**: Started with `port_opener: fn _, _, _ -> nil end` (no real Port). Events injected via `send(pid, {:simulate_event, json_line})`. Uses same test infra as CLI tests (start_infra helper with RateLimiter, Provider, Registry, Agent.Supervisor, Store + Ecto Sandbox).

**Message routing verified by**: Checking Agent.Session exists in Registry after message processing, and Memory.Store has persisted exchange.

**No integration tests tagged `:whatsapp`** — manual only (requires phone + QR scan).

## Verification

1. `mix test` — all existing 277+ tests pass, ~16 new WhatsApp tests pass
2. Manual: `cd whatsapp-bridge && npm install`, enable in config, start ExClaw, scan QR
3. Send WhatsApp message -> verify agent response
4. Kill Node.js process -> verify Elixir detects exit and logs error
5. Disconnect WiFi briefly -> verify Baileys reconnects
