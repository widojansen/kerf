# ExClaw ApprovalGate — Implementation Spec (Phase A.5)

## Context

The ApprovalGate is the second Phase A.5 component. It provides a workflow primitive that lets agents pause execution and request human approval before performing consequential actions. The Email Triage Agent (Phase B) will use this for actions like "follow up on this email" or "add sender to priority list."

The existing Telegram channel adapter handles message I/O. The ApprovalGate extends this with structured approval requests using Telegram inline keyboards (callback buttons), timeouts, and auto-approval rules.

This spec is designed for Claude Code to implement using Red-Prompt-Green-Refactor TDD.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│              ApprovalGate.Supervisor                     │
│                (one_for_one)                             │
│                                                         │
│  ┌──────────────────┐  ┌──────────────────────────────┐ │
│  │ ApprovalGate     │  │ ApprovalGate.CallbackHandler │ │
│  │ .Manager         │  │ (GenServer)                  │ │
│  │ (GenServer)      │  │                              │ │
│  │                  │  │ Receives Telegram callback    │ │
│  │ Creates, tracks, │  │ query updates and routes     │ │
│  │ resolves pending │  │ them to the Manager          │ │
│  │ approval requests│  │                              │ │
│  └──────────────────┘  └──────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## How It Works

1. An agent calls `ApprovalGate.Manager.request_approval/2` with a description and options
2. The Manager stores the pending request in ETS, `Process.monitor`s the calling agent
3. The Manager sends a Telegram message with inline keyboard buttons (Approve / Reject / custom actions)
4. The calling agent blocks (synchronous GenServer.call with configurable timeout)
5. When the user taps a button in Telegram, the CallbackHandler receives the callback query
6. The CallbackHandler resolves the request in the Manager
7. The Manager replies to the blocked agent with the decision
8. If the request times out, the Manager returns `{:error, :timeout}` to the agent

## Design Decisions

### 1. Synchronous Blocking vs. Async Callback

**Decision: Synchronous (blocking GenServer.call).**

The agent that requests approval should block until a decision is made. This keeps agent workflow code simple and linear — no callback spaghetti. The timeout ensures agents don't block forever. For agents that need to continue working while waiting, they can spawn a Task that calls `request_approval` and handle the result in a message.

### 2. Auto-Approval Rules

Stored in PostgreSQL. Rules match on `{agent_module, action_type, context_pattern}`. When a request matches an auto-approval rule, the Manager approves immediately without sending a Telegram message. This allows the system to learn: "always approve email label changes from EmailTriageAgent" after you've approved N times manually.

Auto-approval rules can be created manually or proposed by agents via Telegram: "You've approved 'add label' 5 times in a row. Auto-approve this action?"

### 3. Kill Switch

`ApprovalGate.Manager.kill_switch/1` immediately rejects ALL pending approvals and suspends new requests for a configurable duration. Surfaced via Telegram command `/killswitch` and (future) MCP tool. For emergency situations where an agent is misbehaving.

### 4. Telegram Integration

Uses the existing Telegram bot token and chat. Approval messages use Telegram's `reply_markup` with `InlineKeyboardMarkup` for button rendering. Callback queries come through `getUpdates` — the existing Telegram polling loop needs a small extension to forward callback queries to the CallbackHandler.

## Module Contracts

### ExClaw.Workflow.ApprovalGate.Manager (GenServer)

```elixir
# Request approval (blocks the caller until resolved or timeout)
@spec request_approval(manager, request) ::
  {:approved, metadata} | {:rejected, metadata} | {:error, :timeout | :killed | :suspended}
# request:
#   %{
#     agent: module(),           # e.g., ExClaw.Agents.EmailTriage
#     action: String.t(),        # e.g., "add_priority_sender"
#     description: String.t(),   # Human-readable: "Add john@example.com to priority?"
#     context: map(),            # Arbitrary context for auto-approval matching
#     options: [String.t()],     # Button labels, default: ["Approve", "Reject"]
#     timeout_ms: pos_integer(), # Default: 300_000 (5 minutes)
#     chat_id: integer() | nil   # Telegram chat, nil = use default from config
#   }
# metadata:
#   %{
#     decided_by: :human | :auto_rule | :timeout | :kill_switch,
#     decision: String.t(),      # The button label that was chosen
#     decided_at: DateTime.t(),
#     rule_id: String.t() | nil  # If auto-approved, which rule matched
#   }

# Resolve a pending request (called by CallbackHandler)
@spec resolve(manager, request_id, decision, decided_by) :: :ok | {:error, :not_found}

# List pending requests
@spec pending(manager) :: [pending_request]

# Kill switch: reject all pending, suspend new requests
@spec kill_switch(manager, duration_ms) :: :ok
# duration_ms: how long to suspend. Default: 60_000 (1 minute)

# Resume after kill switch
@spec resume(manager) :: :ok

# Revoke a specific pending request
@spec revoke(manager, request_id) :: :ok | {:error, :not_found}
```

Internally, the Manager uses ETS for pending requests and `Process.monitor/1` on the calling agent's process. If the agent crashes while waiting, the pending request is cleaned up automatically.

### ExClaw.Workflow.ApprovalGate.CallbackHandler (GenServer)

```elixir
# Handle a Telegram callback query
@spec handle_callback(handler, callback_query) :: :ok
# callback_query: the raw Telegram callback_query object from getUpdates
# Parses the callback_data to extract request_id and decision,
# then calls Manager.resolve/4
#
# Also sends answerCallbackQuery to Telegram to dismiss the loading spinner
# and edits the original message to show the decision (strikethrough buttons)
```

### ExClaw.Workflow.ApprovalGate.AutoRule (Ecto Schema + context module)

```elixir
# Check if a request matches any auto-approval rule
@spec match(request) :: {:ok, rule} | :no_match

# Create a new auto-approval rule
@spec create(attrs) :: {:ok, rule} | {:error, changeset}

# Delete a rule
@spec delete(rule_id) :: :ok | {:error, :not_found}

# List all rules
@spec list(opts) :: [rule]
# opts: [agent: module(), action: String.t()]
```

### ExClaw.Workflow.ApprovalGate.TelegramRenderer (module, not GenServer)

```elixir
# Build a Telegram message with inline keyboard for an approval request
@spec render_approval_message(pending_request) ::
  %{chat_id: integer(), text: String.t(), reply_markup: map()}
# Produces:
# Text: "[AgentName] requests approval:\n\nDescription here\n\nContext: key=value, ..."
# InlineKeyboard: [[{text: "Approve", callback_data: "ag:REQ_ID:approve"},
#                    {text: "Reject", callback_data: "ag:REQ_ID:reject"}]]
# callback_data format: "ag:{request_id}:{option_index}"
# Max callback_data is 64 bytes (Telegram limit)

# Build the edited message after a decision is made
@spec render_decision_message(pending_request, decision, decided_by) :: map()
# Shows: "✅ Approved by human" or "❌ Rejected" or "⏰ Timed out"
# Removes the inline keyboard (empty reply_markup)

# Build the answerCallbackQuery payload
@spec render_callback_answer(decision) :: map()
```

## Database Schema

### Migration: `approval_gate_auto_rules`

```sql
CREATE TABLE approval_gate_auto_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_module VARCHAR(255) NOT NULL,  -- e.g., 'Elixir.ExClaw.Agents.EmailTriage'
  action VARCHAR(255) NOT NULL,        -- e.g., 'add_priority_sender'
  context_pattern JSONB DEFAULT '{}',  -- partial match against request context
  decision VARCHAR(50) NOT NULL DEFAULT 'approve',
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  times_matched INTEGER NOT NULL DEFAULT 0,
  last_matched_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_agar_agent_action ON approval_gate_auto_rules(agent_module, action)
  WHERE enabled = TRUE;
```

### Migration: `approval_gate_log`

```sql
CREATE TABLE approval_gate_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id VARCHAR(255) NOT NULL,
  agent_module VARCHAR(255) NOT NULL,
  action VARCHAR(255) NOT NULL,
  description TEXT,
  context JSONB DEFAULT '{}',
  decision VARCHAR(50),            -- 'approve', 'reject', NULL if still pending
  decided_by VARCHAR(50),          -- 'human', 'auto_rule', 'timeout', 'kill_switch', 'revoked'
  rule_id UUID REFERENCES approval_gate_auto_rules(id),
  telegram_message_id INTEGER,     -- for editing the message after decision
  chat_id BIGINT,
  requested_at TIMESTAMPTZ NOT NULL,
  decided_at TIMESTAMPTZ,
  timeout_ms INTEGER NOT NULL
);

CREATE INDEX idx_agl_agent ON approval_gate_log(agent_module);
CREATE INDEX idx_agl_requested ON approval_gate_log(requested_at);
CREATE INDEX idx_agl_pending ON approval_gate_log(decision)
  WHERE decision IS NULL;
```

## ETS Tables

### `:approval_gate_pending` (set, public read)

```elixir
# Key: request_id (String.t())
# Value: %{
#   agent: module(),
#   agent_pid: pid(),
#   monitor_ref: reference(),
#   from: GenServer.from(),        # The blocked caller to reply to
#   action: String.t(),
#   description: String.t(),
#   context: map(),
#   options: [String.t()],
#   chat_id: integer(),
#   telegram_message_id: integer() | nil,
#   timeout_ref: reference(),       # Process.send_after ref for timeout
#   requested_at: DateTime.t(),
#   timeout_ms: pos_integer()
# }
```

## Telegram Integration

### Extending the Existing Telegram Polling

The existing `ExClaw.Channels.Telegram` GenServer polls `getUpdates` and currently only handles `message` updates. It needs a small extension to also forward `callback_query` updates to the CallbackHandler.

In `ExClaw.Channels.Telegram`, when processing updates, check for the `callback_query` key:

```elixir
# In process_updates/2, add a clause:
defp process_single_update(%{"callback_query" => callback} = _update, state) do
  # Forward to ApprovalGate.CallbackHandler if it's running
  if Process.whereis(ExClaw.Workflow.ApprovalGate.CallbackHandler) do
    ExClaw.Workflow.ApprovalGate.CallbackHandler.handle_callback(
      ExClaw.Workflow.ApprovalGate.CallbackHandler,
      callback
    )
  end
  state
end
```

### Telegram API Calls

The TelegramRenderer produces payloads. The Manager or CallbackHandler sends them via Req:

- `sendMessage` with `reply_markup: %{inline_keyboard: [[...]]}` — to post the approval request
- `answerCallbackQuery` with `callback_query_id` — to dismiss the button spinner
- `editMessageReplyMarkup` with empty `reply_markup` — to remove buttons after decision
- `editMessageText` — to update the message text with the decision

All Telegram HTTP calls should go through a shared helper (extract from existing Telegram module or create `ExClaw.Channels.Telegram.API`).

## TDD Build Sequence

### Step 1: TelegramRenderer (pure functions)

RED: Write tests for message rendering, callback data format, decision messages.
GREEN: Implement pure functions.
Tests should verify:
- Approval message includes agent name, description, context summary
- Inline keyboard has correct callback_data format (`ag:{id}:{index}`)
- callback_data stays within 64-byte Telegram limit
- Decision message shows correct icon and decided_by text
- Long descriptions are truncated to Telegram's 4096 char limit
- Custom options beyond Approve/Reject render correctly

### Step 2: AutoRule (Ecto schema + matching logic)

RED: Write tests for rule matching, CRUD, context pattern matching.
GREEN: Implement schema, migration, matching function.
Tests should verify:
- Exact match on agent_module + action
- JSONB context_pattern partial matching (rule pattern is subset of request context)
- Disabled rules are skipped
- times_matched counter increments on match
- CRUD operations work
- No rules → :no_match

### Step 3: ApprovalGate.Manager (GenServer core)

RED: Write tests for request lifecycle, timeout, process monitoring, kill switch.
GREEN: Implement GenServer with ETS-backed pending requests.
Tests should verify:
- request_approval/2 blocks the caller and returns on resolve
- Timeout returns {:error, :timeout} after timeout_ms
- Agent process crash cleans up pending request
- resolve/4 with valid request_id unblocks the caller
- resolve/4 with invalid request_id returns {:error, :not_found}
- pending/1 lists all pending requests
- kill_switch/2 rejects all pending and suspends new requests
- resume/1 re-enables requests after kill switch
- Auto-approval rules are checked before sending to Telegram
- Auto-approved requests return immediately without blocking

Use Mox or a test adapter for the Telegram HTTP calls — don't actually call Telegram in tests.

### Step 4: CallbackHandler (GenServer)

RED: Write tests for callback query parsing, routing to Manager.
GREEN: Implement GenServer.
Tests should verify:
- Parses callback_data format `ag:{request_id}:{option_index}`
- Calls Manager.resolve with correct arguments
- Ignores callback queries not matching the `ag:` prefix
- Sends answerCallbackQuery to Telegram (via mock)
- Handles unknown request_ids gracefully (already resolved or timed out)

### Step 5: Telegram Integration

RED: Write tests for the Telegram polling extension.
GREEN: Extend `ExClaw.Channels.Telegram` to forward callback queries.
Tests should verify:
- callback_query updates are forwarded to CallbackHandler
- Regular message updates still work as before (no regression)
- If CallbackHandler is not running, callback queries are silently dropped

### Step 6: Supervisor + Integration + Log

RED: Write integration tests for the full approval lifecycle.
GREEN: Wire up the Supervisor, add to Application, implement audit logging.
Tests should verify:
- Full flow: agent requests approval → Telegram message sent → callback received → agent unblocked
- Full flow with auto-approval: agent requests → rule matches → immediate return, no Telegram message
- Full flow with timeout: agent requests → no response → timeout → agent unblocked with error
- Kill switch flow: requests pending → kill_switch → all rejected → new requests suspended
- Audit log written for every decision (approve, reject, timeout, kill_switch, revoked)
- Supervisor restarts crashed children
- Application.ex starts ApprovalGate.Supervisor

## Integration with Existing ExClaw

### Application.ex

Add `ApprovalGate.Supervisor` to the children list, after `CredentialVault.Supervisor`:

```elixir
defp approval_gate_children do
  if Application.get_env(:exclaw, ExClaw.Workflow.ApprovalGate, [])[:enabled] != false do
    [{ExClaw.Workflow.ApprovalGate.Supervisor, []}]
  else
    []
  end
end
```

### Config

```elixir
# config/runtime.exs
config :exclaw, ExClaw.Workflow.ApprovalGate,
  enabled: true,
  default_timeout_ms: 300_000,       # 5 minutes
  default_chat_id: System.get_env("TELEGRAM_APPROVAL_CHAT_ID") ||
                   System.get_env("TELEGRAM_ALLOW_FROM") |> then(fn
                     nil -> nil
                     ids -> ids |> String.split(",") |> List.first() |> String.to_integer()
                   end)
```

### File Locations

```
lib/exclaw/workflow/
├── approval_gate/
│   ├── supervisor.ex
│   ├── manager.ex
│   ├── callback_handler.ex
│   ├── auto_rule.ex             # Ecto schema + matching logic
│   ├── telegram_renderer.ex     # Pure functions for message building
│   └── log.ex                   # Ecto schema for audit log

test/workflow/
├── approval_gate/
│   ├── manager_test.exs
│   ├── callback_handler_test.exs
│   ├── auto_rule_test.exs
│   ├── telegram_renderer_test.exs
│   └── integration_test.exs

priv/repo/migrations/
├── YYYYMMDDHHMMSS_create_approval_gate_auto_rules.exs
└── YYYYMMDDHHMMSS_create_approval_gate_log.exs
```

## Dependencies

No new dependencies. Uses:
- `Req` (already in deps) — Telegram API calls
- `Ecto` + `Postgrex` (already in deps) — PostgreSQL storage
- `Jason` (already in deps) — JSON encoding for Telegram payloads
- ETS — pending request storage
- `Process.monitor/1` — crash cleanup
- `Process.send_after/3` — timeout handling

## Open for Future

- MCP exposure: `approval.request`, `approval.pending`, `approval.kill_switch` as MCP tools (Phase C)
- Telegram command: `/killswitch` parsed in the Telegram channel and forwarded to Manager
- Rule learning: after N manual approvals of the same action, propose auto-approval rule
- Batch approvals: "Approve all pending from EmailTriageAgent"
- Dashboard widget: Phoenix LiveView showing pending approvals with approve/reject buttons
