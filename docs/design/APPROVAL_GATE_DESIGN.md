# ExClaw ApprovalGate — Design Document

> **Status:** Draft — Cross-cutting workflow primitive
> **Date:** 2026-03-31
> **Depends on:** Agent.Session, Telegram channel adapter, Credential Vault (Phase A.5)
> **Inspired by:** OpenClaw Lobster's approval gate pattern — deterministic pipeline pauses with resumable state via tokens. ExClaw implements the same semantics natively in OTP with stronger isolation guarantees.

---

## Problem

ExClaw agents will increasingly perform actions with real-world side effects: sending emails (Phase B), posting reviews, triggering builds, executing business queries that modify data (Phase H/I). Today, each agent would need to implement its own ad-hoc confirmation logic via Telegram — asking "should I send this?" with custom message handling per agent.

This leads to:
- **Duplicated confirmation logic** across every agent that has side effects
- **No consistent pause/resume model** — each agent reinvents how to wait for user approval
- **No audit trail** of what was approved, denied, or timed out
- **No kill switch** to halt all pending approvals across all agents

OpenClaw's Lobster solved this with an `approve` primitive that pauses pipelines and returns a resume token. ExClaw can do this better: OTP GenServer state naturally holds the paused context, `Process.monitor` handles crash cleanup, and the supervision tree provides structural isolation.

---

## Design Principles

1. **Approval is a behaviour, not per-agent logic.** Any agent step can emit an approval request. The agent doesn't implement the wait/resume mechanics.
2. **Pause is real process suspension.** The agent GenServer enters a `:waiting_approval` state. No busy-waiting, no polling.
3. **Resume is a message, not a callback.** The approval response arrives as a normal GenServer message. OTP's mailbox handles ordering and delivery.
4. **Timeout is mandatory.** Every approval request has a TTL. Unanswered approvals expire and trigger a configurable fallback (deny by default).
5. **Audit is automatic.** Every request, approval, denial, and timeout is logged.
6. **Kill switch works.** One call denies all pending approvals across all agents.

---

## Architecture

```
Agent.Session (any agent)
     |
     |  {:needs_approval, context, opts}
     |
     v
ApprovalGate.Manager (GenServer)
     |
     |  1. Generates approval_ref
     |  2. Stores pending request in ETS
     |  3. Monitors requesting agent PID
     |  4. Schedules timeout
     |  5. Routes to approval channel (Telegram)
     |
     v
TelegramRouter / MCP Client
     |
     |  User sees: "EmailTriageAgent wants to send a reply to john@example.com:
     |              Subject: Re: Q3 Report
     |              [Approve] [Deny] [Approve & Remember]"
     |
     |  User taps [Approve]
     |
     v
ApprovalGate.Manager
     |
     |  1. Validates approval_ref exists and is not expired
     |  2. Sends {:approved, approval_ref, context} to waiting agent
     |  3. Logs to audit
     |  4. Cleans up ETS entry
     |
     v
Agent.Session (resumes execution)
```

---

## Module Contracts

### `ExClaw.Workflow.ApprovalGate` (Behaviour)

Any agent that needs approval gates implements this behaviour. It defines how the agent prepares approval requests and handles responses.

```elixir
defmodule ExClaw.Workflow.ApprovalGate do
  @moduledoc """
  Behaviour for agents that need human approval before executing side effects.
  """

  @type approval_ref :: binary()
  @type approval_context :: map()
  @type approval_decision :: :approved | :denied | :expired

  @doc """
  Called when the agent needs to present an approval request to the user.
  Returns a structured context that the Manager routes to the approval channel.
  """
  @callback format_approval(action :: atom(), context :: map()) :: %{
    summary: String.t(),
    details: String.t() | nil,
    actions: [atom()],            # [:approve, :deny] or [:approve, :deny, :approve_always]
    urgency: :normal | :high,
    ttl: pos_integer()            # seconds, max 86400 (24h)
  }

  @doc """
  Called when the approval decision arrives. The agent resumes or aborts.
  """
  @callback handle_approval(
    approval_ref(),
    approval_decision(),
    approval_context()
  ) :: {:continue, new_state :: term()} | {:abort, reason :: term()}
end
```

### `ExClaw.Workflow.ApprovalGate.Manager` (GenServer)

The singleton manager that coordinates all pending approvals across all agents.

```elixir
# Agent requests approval (called from within agent process)
Manager.request_approval(
  agent_pid: self(),
  agent_module: __MODULE__,
  action: :send_email_reply,
  context: %{
    to: "john@example.com",
    subject: "Re: Q3 Report",
    body_preview: "Thanks for the update. I'll review the numbers and..."
  },
  group: "wido",
  project: "email-triage",
  ttl: 600  # 10 minutes
)
# => {:ok, approval_ref}
# Agent GenServer now enters :waiting_approval state

# User approves via Telegram (routed through TelegramRouter)
Manager.resolve(approval_ref, :approved, resolved_by: :telegram, user_id: 8064166045)
# => :ok — agent receives {:approved, ref, context} message

# User denies
Manager.resolve(approval_ref, :denied, resolved_by: :telegram, user_id: 8064166045)
# => :ok — agent receives {:denied, ref, context} message

# Approve with "remember" — creates a standing rule
Manager.resolve(approval_ref, :approved, resolved_by: :telegram, user_id: 8064166045, remember: true)
# => :ok — also creates an auto-approval rule for this action pattern

# List all pending approvals
Manager.pending()
# => [%PendingApproval{ref: "...", agent: EmailTriageAgent, action: :send_email, ...}]

# Kill switch — deny all pending
Manager.deny_all(reason: :operator_kill_switch)
# => :ok — all waiting agents receive {:denied, ref, context}
```

### Pending Approval Struct

```elixir
defmodule ExClaw.Workflow.ApprovalGate.PendingApproval do
  defstruct [
    :ref,              # opaque binary, :crypto.strong_rand_bytes
    :agent_pid,        # monitored PID
    :agent_module,     # module name for display/routing
    :action,           # atom describing the action
    :context,          # map with action-specific details
    :group,            # group scope
    :project,          # project scope
    :formatted,        # result of agent's format_approval/2
    :expires_at,       # DateTime
    :created_at,       # DateTime
    :status,           # :pending | :approved | :denied | :expired
    :resolved_by,      # nil | :telegram | :mcp | :auto_rule | :timeout | :kill_switch
    :monitor_ref       # Process.monitor reference
  ]
end
```

---

## Agent Integration Pattern

Here's how an agent uses the ApprovalGate. The key insight is that the agent's GenServer naturally pauses — it just stops processing its mailbox until the approval message arrives.

```elixir
defmodule ExClaw.Agent.EmailTriageAgent do
  use GenServer
  @behaviour ExClaw.Workflow.ApprovalGate

  # ... normal agent logic ...

  # When the agent decides it needs to send a reply:
  def handle_info({:action_ready, :send_reply, email_context}, state) do
    {:ok, ref} = ApprovalGate.Manager.request_approval(
      agent_pid: self(),
      agent_module: __MODULE__,
      action: :send_reply,
      context: email_context,
      group: state.group,
      project: state.project,
      ttl: 600
    )

    {:noreply, %{state | status: :waiting_approval, pending_ref: ref}}
  end

  # Approval arrives — resume
  def handle_info({:approved, ref, context}, %{pending_ref: ref} = state) do
    # Actually send the email
    {:ok, _} = Gmail.send_reply(context)
    {:noreply, %{state | status: :running, pending_ref: nil}}
  end

  # Denial arrives — abort gracefully
  def handle_info({:denied, ref, _context}, %{pending_ref: ref} = state) do
    Logger.info("Email reply denied by user")
    {:noreply, %{state | status: :running, pending_ref: nil}}
  end

  # Timeout/expiry
  def handle_info({:expired, ref, _context}, %{pending_ref: ref} = state) do
    Logger.warn("Email reply approval timed out")
    {:noreply, %{state | status: :running, pending_ref: nil}}
  end

  # ApprovalGate behaviour callbacks
  @impl ExClaw.Workflow.ApprovalGate
  def format_approval(:send_reply, context) do
    %{
      summary: "Send reply to #{context.to}",
      details: "Subject: #{context.subject}\n\n#{String.slice(context.body, 0..200)}",
      actions: [:approve, :deny, :approve_always],
      urgency: :normal,
      ttl: 600
    }
  end

  @impl ExClaw.Workflow.ApprovalGate
  def handle_approval(_ref, :approved, _context), do: {:continue, nil}
  def handle_approval(_ref, :denied, _context), do: {:abort, :user_denied}
  def handle_approval(_ref, :expired, _context), do: {:abort, :timed_out}
end
```

---

## Auto-Approval Rules

When a user taps "Approve & Remember", the Manager creates a standing rule:

```elixir
%AutoApprovalRule{
  agent_module: ExClaw.Agent.EmailTriageAgent,
  action: :send_reply,
  match: %{to_domain: "example.com"},  # pattern extracted from context
  created_by: 8064166045,
  group: "wido",
  project: "email-triage",
  created_at: ~U[2026-03-31 12:00:00Z],
  expires_at: ~U[2026-04-30 12:00:00Z]  # 30-day default, configurable
}
```

On future `request_approval/1` calls, the Manager checks rules before routing to Telegram. If a rule matches, the agent gets an immediate `{:approved, ref, context}` without user interaction — but the approval is still logged with `resolved_by: :auto_rule`.

Rules are stored in PostgreSQL (per-project schema) and manageable via Telegram: "show my auto-approval rules", "delete rule for email replies to example.com".

---

## Telegram Rendering

The TelegramRouter renders approval requests as inline keyboard messages:

```
[EmailTriageAgent · email-triage]

Send reply to john@example.com
Subject: Re: Q3 Report

Thanks for the update. I'll review the numbers and...

[✅ Approve]  [❌ Deny]  [✅ Always Approve]

⏱ Expires in 10 minutes
```

Callback data encodes the approval_ref. The TelegramRouter parses the callback and calls `Manager.resolve/3`.

---

## MCP Integration

Approval requests are also exposed via MCP (Phase E), enabling Claude Code or other MCP clients to approve actions:

```
Resource: approvals://{group}/{project}/pending
Tool:     approvals.resolve {ref, decision}
Tool:     approvals.deny_all {reason}
Tool:     approvals.rules.list {group, project}
Tool:     approvals.rules.delete {rule_id}
```

---

## Crash Semantics

- **Agent crashes while waiting:** `Process.monitor` fires in the Manager. The pending approval is marked `:expired` (not `:denied` — the agent may restart and re-request). Logged to audit.
- **Manager crashes:** Supervisor restarts it. ETS table is lost — all pending approvals expire. Agents in `:waiting_approval` state will time out naturally. This is safe: the worst case is re-asking.
- **Telegram adapter crashes:** Approvals remain pending in the Manager. When Telegram recovers, pending approvals can be re-rendered. TTL handles the case where recovery takes too long.

---

## Audit Log

Every approval event is logged to the project's `approval_audit_log` table:

```elixir
create table(:approval_audit_log) do
  add :ref_prefix, :string, null: false     # first 8 chars of approval_ref
  add :event, :string, null: false           # "requested", "approved", "denied",
                                              # "expired", "auto_approved", "kill_switch"
  add :agent_module, :string, null: false
  add :action, :string, null: false
  add :group, :string, null: false
  add :project, :string, null: false
  add :context_summary, :text                # formatted summary, not full context
  add :resolved_by, :string                  # "telegram", "mcp", "auto_rule", "timeout"
  add :user_id, :bigint                      # Telegram user ID if human-resolved
  add :inserted_at, :utc_datetime, null: false
end
```

---

## Relationship to Credential Vault

The ApprovalGate and Credential Vault are complementary:
- **Credential Vault** controls *access to external APIs* ("can this agent call Gmail?")
- **ApprovalGate** controls *execution of side effects* ("should this agent send this specific email?")

An agent requesting to send an email needs both: a credential lease (to authenticate with Gmail) and an approval (to confirm the user wants this specific email sent). The Credential Vault handles the first; the ApprovalGate handles the second.

The approval flow can also gate credential lease requests — a `CredentialVault.request_lease/1` call could itself require approval for high-risk services, creating a two-layer authorization model.

---

## Build Sequence

**TDD — Red-Prompt-Green-Refactor throughout.**

### Step 1: ApprovalGate behaviour + PendingApproval struct
- `test/workflow/approval_gate_test.exs` — behaviour contract tests
- `lib/exclaw/workflow/approval_gate.ex`

### Step 2: Manager GenServer
- `test/workflow/approval_gate/manager_test.exs` — request, resolve, expire, crash cleanup, kill switch
- `lib/exclaw/workflow/approval_gate/manager.ex`
- ETS table for pending approvals

### Step 3: Auto-approval rules
- `test/workflow/approval_gate/auto_rules_test.exs` — create, match, expire, delete
- `lib/exclaw/workflow/approval_gate/auto_rules.ex`
- Migration for `auto_approval_rules` table

### Step 4: Telegram rendering
- `test/workflow/approval_gate/telegram_renderer_test.exs` — format, callback parsing
- `lib/exclaw/workflow/approval_gate/telegram_renderer.ex`

### Step 5: Audit log
- Migration for `approval_audit_log` table
- Telemetry events from Manager → audit writer

### Step 6: Integration test
- End-to-end: agent requests → Telegram renders → user approves → agent resumes
- Crash scenarios: agent crash, manager crash, timeout

---

## Phase Placement

The ApprovalGate should land as part of **Phase A.5** alongside the Credential Vault, or as the first step of **Phase B** (Email Triage). The Email Triage Agent is the first consumer — it needs approval before sending replies.

Alternatively, it can be built incrementally:
- **Phase A.5:** Manager + behaviour + audit (core mechanics)
- **Phase B:** Telegram rendering + integration with EmailTriageAgent
- **Phase E:** MCP exposure for Claude Code approvals
- **Phase H/I:** Auto-approval rules mature with business track usage

