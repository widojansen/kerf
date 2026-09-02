# ExClaw Credential Vault — Design Document

> **Status:** Draft — New phase proposal for ExClaw security subsystem
> **Date:** 2026-03-26
> **Depends on:** Security layer (FileGuard, ShellSandbox, PromptGuard), Agent.Session
> **Phase placement:** Insert as **Phase A.5** — after KB foundation (Phase A) but before Email Triage (Phase B). The vault is needed before any agent connects to external APIs (Gmail OAuth, Telegram Bot API, SearXNG, etc.)
>
> **Context:** ExClaw is currently at 395 tests passing, all 11 original architecture phases complete. The Intelligence Platform build sequence (Phases A–G in `ARCHITECTURE_INTELLIGENCE_PLATFORM.md`) defines the next roadmap. The Credential Vault is a cross-cutting security subsystem that should be in place before Phase B (Email Triage Agent) connects to Gmail, and before Phase E (MCP Server/Client) exposes tool access externally.

---

## Problem

When an ExClaw agent calls an external API (Gmail, Stripe, GitHub, Telegram Bot API, etc.), it needs credentials. If those credentials live in the agent's process state — or worse, get passed through the LLM context window — a crash dump, prompt injection, or log statement can leak them.

OpenClaw demonstrated this at scale: 135,000+ exposed instances, agents freely returning credentials when prompted, Cisco documenting exfiltration in the wild. Jentic's response (a credential proxy) validates the pattern. ExClaw can do it natively in OTP with stronger isolation guarantees.

---

## Design Principles

1. **Agents never see raw credentials.** An agent receives an opaque lease token. The vault injects the real credential at call time.
2. **Crash isolation is automatic.** OTP process boundaries mean a crashed agent's memory is garbage-collected. No credential residue.
3. **Leases are scoped and short-lived.** A lease grants access to one API, with one permission set, for a bounded duration.
4. **Kill switch is instant.** One call revokes all active leases across all agents.
5. **Credentials at rest are encrypted.** The vault encrypts stored credentials with a key derived from the node's runtime secret.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  ExClaw.Security.Supervisor                         │
│                                                     │
│  ┌──────────────┐  ┌──────────────┐                │
│  │ FileGuard    │  │ ShellSandbox │  (existing)    │
│  └──────────────┘  └──────────────┘                │
│  ┌──────────────┐                                   │
│  │ PromptGuard  │                       (existing) │
│  └──────────────┘                                   │
│                                                     │
│  ┌──────────────────────────────────────────┐      │
│  │ Credential.Supervisor  (new)             │      │
│  │                                          │      │
│  │  ┌──────────────────┐                    │      │
│  │  │ Credential.Vault │ ← GenServer       │      │
│  │  │ (encrypted store) │   singleton       │      │
│  │  └────────┬─────────┘                    │      │
│  │           │                              │      │
│  │  ┌────────▼─────────┐                    │      │
│  │  │ Credential.Lease │ ← ETS table       │      │
│  │  │ Manager          │   for active       │      │
│  │  │                  │   leases           │      │
│  │  └────────┬─────────┘                    │      │
│  │           │                              │      │
│  │  ┌────────▼─────────┐                    │      │
│  │  │ Credential.Proxy │ ← DynamicSup      │      │
│  │  │ (per-request     │   of short-lived   │      │
│  │  │  HTTP workers)   │   Task processes   │      │
│  │  └──────────────────┘                    │      │
│  └──────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────┘
```

### Request Flow

```
Agent.Session                Credential System             External API
     │                            │                             │
     │  request_lease(            │                             │
     │    :stripe,                │                             │
     │    [:read_charges],        │                             │
     │    ttl: 300)               │                             │
     │ ──────────────────────►    │                             │
     │                            │                             │
     │  {:ok, lease_token}        │                             │
     │ ◄──────────────────────    │                             │
     │                            │                             │
     │  proxy_request(            │                             │
     │    lease_token,            │                             │
     │    :get,                   │                             │
     │    "/v1/charges",          │                             │
     │    params)                 │                             │
     │ ──────────────────────►    │                             │
     │                            │  GET /v1/charges            │
     │                            │  Authorization: Bearer sk_  │
     │                            │ ────────────────────────►   │
     │                            │                             │
     │                            │  200 OK + body              │
     │                            │ ◄────────────────────────   │
     │                            │                             │
     │  {:ok, sanitized_body}     │  (strips credential        │
     │ ◄──────────────────────    │   from response headers,   │
     │                            │   logs, error messages)     │
     │                            │                             │
     │  --- agent crashes ---     │                             │
     │         ✗                  │                             │
     │                            │  Process.monitor fires      │
     │                            │  → lease auto-revoked       │
     │                            │  → no cleanup needed        │
```

---

## Module Contracts

### `ExClaw.Credential.Vault` (GenServer)

The singleton credential store. Holds encrypted credentials in its process state backed by an encrypted SQLite table for persistence across restarts.

```elixir
# Store a credential (operator action, not agent-callable)
Vault.store(:stripe, %{
  type: :bearer,
  secret: "sk_live_...",
  base_url: "https://api.stripe.com",
  scopes: [:read_charges, :write_charges, :read_customers]
})

# List registered services (names only, never secrets)
Vault.list_services()
# => [:stripe, :gmail, :github]

# Rotate a credential
Vault.rotate(:stripe, %{secret: "sk_live_new_..."})

# Delete a credential (revokes all active leases for this service)
Vault.delete(:stripe)

# Kill switch — revoke everything
Vault.kill_all()
```

**Internal state:**

```elixir
%{
  credentials: %{
    stripe: %EncryptedCredential{
      type: :bearer,
      encrypted_secret: <<...>>,
      base_url: "https://api.stripe.com",
      scopes: MapSet.new([:read_charges, :write_charges, :read_customers]),
      inserted_at: ~U[2026-03-26 10:00:00Z],
      rotated_at: nil
    }
  },
  encryption_key: <<...>>  # derived from app secret at boot
}
```

### `ExClaw.Credential.LeaseManager` (GenServer + ETS)

Issues and tracks scoped, time-limited lease tokens.

```elixir
# Agent requests a lease (called from Agent.Session process)
LeaseManager.request(
  service: :stripe,
  scopes: [:read_charges],
  ttl: 300,            # seconds, max 3600
  agent_pid: self()    # monitored for crash cleanup
)
# => {:ok, "lease_abc123"}

# Check if a lease is valid (called by Proxy before injecting creds)
LeaseManager.validate("lease_abc123", :read_charges)
# => {:ok, %Lease{service: :stripe, scopes: [...], expires_at: ...}}
# => {:error, :expired}
# => {:error, :scope_denied}
# => {:error, :revoked}

# Revoke a specific lease
LeaseManager.revoke("lease_abc123")

# Revoke all leases for a service (called by Vault on delete/rotate)
LeaseManager.revoke_service(:stripe)

# Revoke all leases (kill switch)
LeaseManager.revoke_all()

# List active leases (for dashboard/audit)
LeaseManager.active_leases()
# => [%Lease{token: "lease_...", service: :stripe, agent_pid: #PID<...>, ...}]
```

**Lease struct:**

```elixir
defmodule ExClaw.Credential.Lease do
  defstruct [
    :token,        # opaque binary, generated via :crypto.strong_rand_bytes
    :service,      # atom — matches Vault key
    :scopes,       # MapSet of allowed scopes
    :agent_pid,    # PID of the requesting agent (monitored)
    :expires_at,   # DateTime
    :created_at,   # DateTime
    :revoked?,     # boolean
    :request_count # integer — how many proxy calls used this lease
  ]
end
```

**Auto-cleanup mechanics:**

- `Process.monitor(agent_pid)` on lease creation
- `handle_info({:DOWN, ref, :process, pid, _reason})` → revoke all leases for that PID
- Periodic sweep (every 60s) purges expired leases from ETS

### `ExClaw.Credential.Proxy`

Executes HTTP requests on behalf of agents, injecting credentials server-side. Each request spawns a short-lived `Task` under a `DynamicSupervisor`.

```elixir
# Agent calls this with its lease token — never sees the real credential
Proxy.request(
  lease_token: "lease_abc123",
  method: :get,
  path: "/v1/charges",
  params: %{limit: 10},
  headers: %{}
)
# => {:ok, %{status: 200, body: %{...}}}
# => {:error, :lease_expired}
# => {:error, :scope_denied}
# => {:error, :request_failed, reason}
```

**What the Proxy does:**

1. Validates the lease via `LeaseManager.validate/2`
2. Looks up the real credential from `Vault` (in-memory, no DB hit)
3. Builds the full HTTP request (base_url + path + auth header)
4. Executes via `Req` or `Finch`
5. **Sanitizes the response**: strips any credential echoes from headers, error bodies, redirect URLs
6. Increments `request_count` on the lease
7. Returns sanitized response to the agent

**What the Proxy blocks:**

- Requests to URLs not matching the service's `base_url` (prevents SSRF via lease)
- Scopes not granted in the lease
- Expired or revoked leases
- Response bodies containing the raw credential string (replaced with `[REDACTED]`)

### `ExClaw.Credential.Supervisor`

```elixir
defmodule ExClaw.Credential.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      ExClaw.Credential.Vault,
      ExClaw.Credential.LeaseManager,
      {DynamicSupervisor, name: ExClaw.Credential.ProxySupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

---

## Encryption

Credentials at rest use `AES-256-GCM` via Erlang's `:crypto` module.

```elixir
defmodule ExClaw.Credential.Encryption do
  @aad "exclaw_credential_vault_v1"

  def encrypt(plaintext, key) do
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(
      :aes_256_gcm, key, iv, plaintext, @aad, true
    )
    iv <> tag <> ciphertext
  end

  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>, key) do
    :crypto.crypto_one_time_aead(
      :aes_256_gcm, key, iv, ciphertext, @aad, tag, false
    )
  end

  def derive_key(secret) do
    :crypto.hash(:sha256, secret)
  end
end
```

The encryption key is derived from the application's `:vault_secret` config value at boot. On the Spark, this comes from an environment variable — never committed to source.

---

## Persistence

PostgreSQL table (via Ecto) for surviving restarts:

```elixir
# Migration
create table(:vault_credentials) do
  add :service, :string, null: false
  add :encrypted_blob, :binary, null: false  # AES-256-GCM encrypted JSON
  add :metadata, :map, default: %{}          # unencrypted: type, base_url, scopes
  timestamps()
end

create unique_index(:vault_credentials, [:service])
```

On boot, `Vault.init/1` loads all rows, decrypts into process state. The DB is only written on `store/2`, `rotate/2`, `delete/1`. Active leases are ETS-only (ephemeral by design — restarts revoke all leases).

---

## Audit Log

Every lease operation is logged to a separate PostgreSQL table:

```elixir
create table(:vault_audit_log) do
  add :event, :string, null: false    # "lease_granted", "lease_revoked", "lease_expired",
                                       # "proxy_request", "kill_all", "credential_rotated"
  add :service, :string
  add :lease_token_prefix, :string    # first 8 chars only
  add :agent_pid, :string
  add :metadata, :map, default: %{}   # scopes, path, status code, etc.
  add :inserted_at, :utc_datetime, null: false
end
```

---

## Integration with Existing Security Layer

The Credential Vault extends `ExClaw.Security.Supervisor`'s children:

```elixir
# In ExClaw.Security.Supervisor
children = [
  ExClaw.Security.FileGuard,
  ExClaw.Security.ShellSandbox,
  ExClaw.Security.PromptGuard,
  ExClaw.Credential.Supervisor    # NEW
]
```

**PromptGuard integration:** PromptGuard already scans LLM outputs. Add a credential-specific pattern:

- If an LLM response contains any string matching a stored credential's pattern (API key prefix, token format), PromptGuard redacts it before the response reaches the agent or the user.
- This is a defense-in-depth measure — the Proxy should already prevent this, but PromptGuard catches leaks from other paths (e.g., the LLM "remembering" a key from training data).

---

## Integration with MCP Bridge (Phase E)

The MCP server (Phase E in `ARCHITECTURE_INTELLIGENCE_PLATFORM.md`) can expose credential operations as MCP tools:

```
Tool: vault.list_services
Tool: vault.request_lease {service, scopes, ttl}
Tool: vault.proxy_request {lease_token, method, path, params}
Tool: vault.kill_all
```

This means Claude Code (or any MCP client) can request leases and make proxied API calls without ever seeing credentials — the same isolation model as Jentic, but native to OTP.

---

## Comparison: ExClaw Vault vs. Jentic

| Aspect | ExClaw Vault | Jentic |
|--------|-------------|--------|
| Runtime | OTP GenServer, in-process | Python/SaaS, HTTP proxy |
| Crash isolation | Automatic via BEAM GC | Application-level cleanup |
| Lease revocation on crash | Instant (Process.monitor) | Requires TTL expiry or sweep |
| Kill switch latency | Microseconds (ETS delete) | HTTP round-trip |
| API catalog | Manual registration | 10,000+ pre-indexed |
| Encryption at rest | AES-256-GCM, local key | Platform-managed |
| Deployment | Self-hosted, single binary | SaaS or self-hosted container |
| Audit | Local PostgreSQL | Platform dashboard |

ExClaw's advantage is runtime properties — crash cleanup and kill switch speed. Jentic's advantage is the pre-built API catalog and managed auth flows (OAuth dance, token refresh). They're complementary: ExClaw could use Jentic as one of its credential backends for APIs that need complex OAuth.

---

## Consumers Across the Platform

The vault is cross-cutting — nearly every phase in `ARCHITECTURE_INTELLIGENCE_PLATFORM.md` needs it:

| Phase | Agent/System | Credentials Managed |
|-------|-------------|---------------------|
| B | EmailTriageAgent | Gmail OAuth tokens |
| B | Telegram channel | Bot API token (already in env, migrate to vault) |
| C | CodeContextAgent | GitHub deploy key / API token |
| C | DependencyAgent | Hex, npm, PyPI API tokens |
| D | DeployAgent | Spark SSH key, Ollama/vLLM endpoints |
| E | MCP Server | Client auth tokens |
| E | MCP Client | External MCP server credentials |
| G | BusinessConnector | Client system API keys (pct-panel, automotive) |
| — | SearXNG integration | API key (if auth enabled) |
| — | vLLM | API key for OpenAI-compat endpoint |

This is why the vault should land early — it prevents credential sprawl across `.env` files and process state as more agents come online.

---

## Build Sequence

**TDD — Red-Prompt-Green-Refactor throughout.**

### Step 1: Encryption module
- `test/credential/encryption_test.exs` — round-trip encrypt/decrypt, key derivation, tamper detection
- `lib/exclaw/credential/encryption.ex`

### Step 2: Vault GenServer
- `test/credential/vault_test.exs` — store, list, rotate, delete, persistence across restart
- `lib/exclaw/credential/vault.ex`
- Migration for `vault_credentials` table

### Step 3: LeaseManager
- `test/credential/lease_manager_test.exs` — request, validate, expire, revoke, crash cleanup
- `lib/exclaw/credential/lease_manager.ex`
- This is where `Process.monitor` crash isolation gets tested

### Step 4: Proxy
- `test/credential/proxy_test.exs` — credential injection, SSRF blocking, response sanitization
- `lib/exclaw/credential/proxy.ex`
- Uses `Bypass` or `Mox` for HTTP mocking

### Step 5: Supervisor + integration
- `test/credential/supervisor_test.exs` — full startup, kill switch end-to-end
- `lib/exclaw/credential/supervisor.ex`
- Wire into `Security.Supervisor`

### Step 6: Audit log
- Migration for `vault_audit_log` table
- Telemetry events from all modules → audit writer

### Step 7: PromptGuard integration
- Extend existing PromptGuard tests with credential pattern detection
- Add redaction rules for known credential formats

---

## Dependencies

```elixir
# Already in mix.exs:
{:postgrex, "~> 0.19"}        # already present (PostgreSQL driver)
{:ecto_sql, "~> 3.12"}        # already present

# Needed:
{:req, "~> 0.5"}              # HTTP client for Proxy (may already be present)
{:bypass, "~> 2.1", only: :test}  # HTTP mocking for Proxy tests

# No new crypto deps — :crypto ships with OTP
```

---

## Open Questions

1. **OAuth token refresh**: Should the Vault handle OAuth refresh flows internally, or delegate to a separate `OAuthManager` process? (Jentic handles this server-side — we could too, but it adds complexity.)

2. **Credential backends**: Should the Vault support pluggable backends (local encrypted store, HashiCorp Vault, Jentic as a backend)? Or start simple and add later?

3. **Per-agent credential policies**: Should agents have a static config of which services they're allowed to request leases for? (Prevents a compromised agent from requesting a Stripe lease when it only needs Gmail.)

4. **Rate limiting**: Should the LeaseManager enforce per-service rate limits, or leave that to the external API?
