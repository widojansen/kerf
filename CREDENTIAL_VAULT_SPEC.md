# ExClaw Credential Vault — Implementation Spec (Phase A.5)

## Context

The Credential Vault is the first Phase A.5 component, required before Phase B (Email Triage Agent). The Email Triage Agent needs Gmail OAuth credentials. The Google OAuth app ("OpenClaw Anita") is published for internal use — tokens no longer expire after 7 days. However, OAuth access tokens still expire (typically 1 hour) and must be refreshed using the refresh token.

This spec is designed for Claude Code to implement using Red-Prompt-Green-Refactor TDD.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                  CredentialVault.Supervisor              │
│                    (one_for_one)                         │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐ │
│  │ CredentialVault│  │ LeaseManager │  │ TokenRefresh  │ │
│  │ (GenServer)   │  │ (GenServer)  │  │ Worker        │ │
│  │               │  │              │  │ (GenServer)   │ │
│  │ CRUD ops on   │  │ Issues scoped│  │ Proactive     │ │
│  │ encrypted     │  │ short-lived  │  │ refresh of    │ │
│  │ credentials   │  │ leases to    │  │ expiring      │ │
│  │               │  │ agents       │  │ tokens        │ │
│  └──────────────┘  └──────────────┘  └───────────────┘ │
│                                                         │
│  ┌──────────────┐                                       │
│  │ Credential   │  (not a GenServer — a module used     │
│  │ .Proxy       │   by agents to make authenticated     │
│  │              │   HTTP requests through a lease)       │
│  └──────────────┘                                       │
└─────────────────────────────────────────────────────────┘
```

## Design Decisions (Resolved)

### 1. OAuth Token Refresh: Proactive + Reactive

A `TokenRefreshWorker` GenServer checks token expiry every 5 minutes. If an access token is within 10 minutes of expiry, it refreshes proactively using the stored refresh token. This means agents almost never encounter expired tokens.

The `Credential.Proxy` is the reactive fallback: if an API call returns 401, the Proxy attempts one refresh-and-retry cycle before returning the error. If the refresh token itself is invalid (revoked, etc.), the Proxy returns `{:error, :refresh_failed}` and the agent should escalate (e.g., Telegram notification via the existing channel).

### 2. Backend: Behaviour + Local Encrypted (PostgreSQL)

A `CredentialVault.Backend` behaviour defines the storage interface. The first (and initially only) implementation is `Backend.LocalEncrypted`:

- Credentials stored in PostgreSQL table `credential_vault_credentials`
- Encrypted at rest using `Plug.Crypto.MessageEncryptor` with a key derived from `SECRET_KEY_BASE`
- Decryption happens in-memory only when a lease is issued
- Future backends (HashiCorp Vault, cloud KMS) implement the same behaviour

### 3. Per-Agent Credential Policies: Scope-Based Leases

Each stored credential has a set of available scopes (e.g., `["gmail.readonly", "gmail.labels"]`). Agents request credentials by specifying required scopes. The LeaseManager checks a policy table (`credential_vault_policies`) that maps `{agent_module, group_id}` to allowed scopes. The issued lease contains only the intersection of available and allowed scopes.

For personal use, a single policy row per agent is sufficient. Multi-tenant commercial use adds per-group/per-project policies.

### 4. Rate Limiting: Token Bucket in ETS

The `Credential.Proxy` enforces per-credential rate limits using a token bucket stored in ETS. Gmail API limits: 250 quota units/second for modify, 5 units for read. When the bucket is empty, the Proxy returns `{:rate_limited, retry_after_ms}` without making the API call.

## Module Contracts

### ExClaw.CredentialVault (GenServer)

```elixir
# Store a new credential
@spec store(vault, credential_name, credential_type, credential_data, opts) ::
  {:ok, credential_id} | {:error, reason}
# credential_type: :oauth2 | :api_key | :bearer_token
# credential_data for :oauth2:
#   %{
#     client_id: String.t(),
#     client_secret: String.t(),
#     access_token: String.t(),
#     refresh_token: String.t(),
#     token_url: String.t(),  # e.g., "https://oauth2.googleapis.com/token"
#     scopes: [String.t()],
#     expires_at: DateTime.t() | nil
#   }
# opts: [group_id: String.t(), project_id: String.t()]

# Retrieve a credential (decrypted, internal use only — agents use LeaseManager)
@spec get(vault, credential_id) :: {:ok, credential} | {:error, :not_found}

# Update credential data (e.g., after token refresh)
@spec update(vault, credential_id, updates) :: :ok | {:error, reason}

# Delete a credential
@spec delete(vault, credential_id) :: :ok | {:error, :not_found}

# List credentials (metadata only, no secrets)
@spec list(vault, opts) :: [credential_metadata]
# opts: [group_id: String.t(), type: atom()]
```

### ExClaw.CredentialVault.LeaseManager (GenServer)

```elixir
# Request a lease for a credential
@spec acquire(lease_manager, agent_module, credential_name, required_scopes, opts) ::
  {:ok, lease} | {:error, :not_found | :scope_denied | :policy_violation}
# lease is:
#   %ExClaw.CredentialVault.Lease{
#     id: String.t(),
#     credential_id: String.t(),
#     agent: module(),
#     scopes: [String.t()],
#     access_token: String.t(),
#     expires_at: DateTime.t(),
#     issued_at: DateTime.t()
#   }
# opts: [group_id: String.t(), ttl: pos_integer()]
# Default TTL: 300 seconds (5 minutes). Lease auto-expires.

# Release a lease early
@spec release(lease_manager, lease_id) :: :ok

# Check if a lease is still valid
@spec valid?(lease_manager, lease_id) :: boolean()

# List active leases (for monitoring)
@spec active_leases(lease_manager) :: [lease_metadata]
```

Internally, LeaseManager uses ETS for active leases and `Process.monitor/1` on the agent process. If the agent process crashes, the lease is automatically cleaned up.

### ExClaw.CredentialVault.TokenRefreshWorker (GenServer)

```elixir
# Starts automatically as part of the Supervisor.
# No public API — runs on an internal timer.
# Every 5 minutes, checks all OAuth2 credentials.
# If access_token expires within 10 minutes, refreshes it.
# On refresh failure, logs a warning. Does NOT crash.
# On refresh success, updates the credential via CredentialVault.update/3.
```

### ExClaw.CredentialVault.Proxy (module, not a GenServer)

```elixir
# Make an authenticated HTTP request using a lease
@spec request(lease, method, url, opts) ::
  {:ok, response} | {:error, :lease_expired | :rate_limited | :refresh_failed | term()}
# method: :get | :post | :put | :patch | :delete
# opts: [headers: keyword(), body: term(), params: keyword()]
#
# Behavior:
# 1. Check lease validity (not expired)
# 2. Check rate limit bucket for the credential
# 3. Inject Authorization header (Bearer token for OAuth2, etc.)
# 4. Make the HTTP request via Req
# 5. On 401: attempt one token refresh via CredentialVault, retry the request
# 6. On success: return {:ok, response}
# 7. On rate limit exceeded: return {:error, {:rate_limited, retry_after_ms}}
```

### ExClaw.CredentialVault.Backend (behaviour)

```elixir
@callback store(credential_name, credential_type, encrypted_data, metadata) ::
  {:ok, credential_id} | {:error, term()}

@callback get(credential_id) ::
  {:ok, %{encrypted_data: binary(), metadata: map()}} | {:error, :not_found}

@callback update(credential_id, encrypted_data) :: :ok | {:error, term()}

@callback delete(credential_id) :: :ok | {:error, :not_found}

@callback list(opts :: keyword()) :: [map()]
```

### ExClaw.CredentialVault.Backend.LocalEncrypted

Implements the Backend behaviour. Uses PostgreSQL for persistence, `Plug.Crypto.MessageEncryptor` for encryption/decryption. The encryption key is derived from `SECRET_KEY_BASE` using `Plug.Crypto.KeyGenerator`.

## Database Schema

### Migration: `credential_vault_credentials`

```sql
CREATE TABLE credential_vault_credentials (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL,
  type VARCHAR(50) NOT NULL,  -- 'oauth2', 'api_key', 'bearer_token'
  encrypted_data BYTEA NOT NULL,
  -- Metadata (not encrypted, for querying)
  scopes TEXT[] DEFAULT '{}',
  group_id VARCHAR(255),
  project_id VARCHAR(255),
  expires_at TIMESTAMPTZ,
  last_refreshed_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE(name, group_id)
);

CREATE INDEX idx_cvc_group ON credential_vault_credentials(group_id);
CREATE INDEX idx_cvc_type ON credential_vault_credentials(type);
CREATE INDEX idx_cvc_expires ON credential_vault_credentials(expires_at)
  WHERE expires_at IS NOT NULL;
```

### Migration: `credential_vault_policies`

```sql
CREATE TABLE credential_vault_policies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_module VARCHAR(255) NOT NULL,  -- e.g., 'Elixir.ExClaw.Agents.EmailTriage'
  credential_name VARCHAR(255) NOT NULL,
  allowed_scopes TEXT[] NOT NULL,
  group_id VARCHAR(255),  -- NULL = global policy
  max_lease_ttl INTEGER DEFAULT 300,  -- seconds
  rate_limit_per_second INTEGER DEFAULT 10,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE(agent_module, credential_name, group_id)
);
```

### Migration: `credential_vault_lease_log`

```sql
CREATE TABLE credential_vault_lease_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lease_id VARCHAR(255) NOT NULL,
  credential_id UUID NOT NULL REFERENCES credential_vault_credentials(id),
  agent_module VARCHAR(255) NOT NULL,
  scopes TEXT[] NOT NULL,
  group_id VARCHAR(255),
  issued_at TIMESTAMPTZ NOT NULL,
  released_at TIMESTAMPTZ,
  release_reason VARCHAR(50)  -- 'manual', 'expired', 'process_down', 'revoked'
);

CREATE INDEX idx_cvll_credential ON credential_vault_lease_log(credential_id);
CREATE INDEX idx_cvll_issued ON credential_vault_lease_log(issued_at);
```

## ETS Tables

### `:credential_vault_leases` (set, public read)

```elixir
# Key: lease_id
# Value: %{
#   credential_id: String.t(),
#   agent: module(),
#   agent_pid: pid(),
#   monitor_ref: reference(),
#   scopes: [String.t()],
#   access_token: String.t(),
#   expires_at: DateTime.t(),
#   issued_at: DateTime.t()
# }
```

### `:credential_vault_rate_limits` (set, public read/write)

```elixir
# Key: credential_id
# Value: %{
#   tokens: float(),
#   max_tokens: float(),
#   refill_rate: float(),  # tokens per second
#   last_refill: integer()  # System.monotonic_time(:millisecond)
# }
```

## TDD Build Sequence

### Step 1: Backend.LocalEncrypted + Ecto Schema

RED: Write tests for encryption round-trip, store/get/update/delete/list.
GREEN: Implement the Ecto schema, migration, and Backend module.
Tests should verify:
- Storing a credential and retrieving it returns decrypted data
- Listing credentials returns metadata only (no secrets)
- Updating credential data re-encrypts
- Deleting a credential removes it
- Unique constraint on (name, group_id)
- Encryption uses `SECRET_KEY_BASE` — changing the key makes old data unreadable

### Step 2: CredentialVault GenServer

RED: Write tests for the GenServer wrapping the Backend.
GREEN: Implement the GenServer with store/get/update/delete/list delegating to Backend.
Tests should verify:
- GenServer starts and registers
- All CRUD operations work through the GenServer
- Concurrent access is serialized correctly
- Invalid credential types are rejected

### Step 3: LeaseManager GenServer

RED: Write tests for lease acquisition, release, expiry, process monitoring.
GREEN: Implement LeaseManager with ETS-backed lease storage.
Tests should verify:
- Acquiring a lease returns a valid lease struct
- Lease expires after TTL
- Releasing a lease removes it from ETS
- Agent process crash triggers automatic lease cleanup (via Process.monitor)
- Scope intersection: agent only gets scopes allowed by policy AND available on credential
- Policy violation returns {:error, :scope_denied}
- Missing credential returns {:error, :not_found}
- active_leases/1 returns current state

### Step 4: TokenRefreshWorker GenServer

RED: Write tests for proactive token refresh.
GREEN: Implement the timer-based worker.
Tests should verify:
- Worker starts and schedules first check
- OAuth2 credential expiring within 10 minutes triggers refresh
- Refresh calls the correct token URL with client credentials
- Successful refresh updates the credential via CredentialVault
- Failed refresh logs warning but does not crash
- Non-OAuth2 credentials are skipped
- Credentials not expiring soon are skipped

### Step 5: Credential.Proxy

RED: Write tests for authenticated requests, 401 retry, rate limiting.
GREEN: Implement the Proxy module.
Tests should verify:
- Valid lease + successful request returns {:ok, response}
- Expired lease returns {:error, :lease_expired}
- 401 response triggers one refresh + retry
- Second 401 after refresh returns {:error, :refresh_failed}
- Rate limit exceeded returns {:error, {:rate_limited, retry_after_ms}}
- Authorization header is correctly injected
- Rate limit bucket refills over time

### Step 6: Supervisor + Integration

RED: Write integration tests for the full vault lifecycle.
GREEN: Wire up the Supervisor, add to Application.
Tests should verify:
- Full flow: store credential → create policy → acquire lease → make request → release lease
- Supervisor restarts crashed children
- Application.ex starts CredentialVault.Supervisor
- ETS tables are created on startup

## Integration with Existing ExClaw

### Application.ex

Add `CredentialVault.Supervisor` to the children list in `ExClaw.Application`, after `ExClaw.Memory.Supervisor` and before any agent supervisors:

```elixir
defp credential_vault_children do
  if Application.get_env(:exclaw, ExClaw.CredentialVault, [])[:enabled] != false do
    [{ExClaw.CredentialVault.Supervisor, []}]
  else
    []
  end
end
```

### Config

```elixir
# config/runtime.exs
config :exclaw, ExClaw.CredentialVault,
  enabled: true,
  encryption_key_base: System.get_env("SECRET_KEY_BASE"),
  refresh_interval_ms: 300_000,  # 5 minutes
  default_lease_ttl: 300  # seconds
```

### File Locations

```
lib/exclaw/credential_vault/
├── supervisor.ex
├── credential_vault.ex          # Main GenServer
├── lease_manager.ex
├── lease.ex                     # Lease struct
├── token_refresh_worker.ex
├── proxy.ex
├── backend.ex                   # Behaviour
└── backend/
    └── local_encrypted.ex

test/credential_vault/
├── credential_vault_test.exs
├── lease_manager_test.exs
├── token_refresh_worker_test.exs
├── proxy_test.exs
└── backend/
    └── local_encrypted_test.exs

priv/repo/migrations/
├── YYYYMMDDHHMMSS_create_credential_vault_credentials.exs
├── YYYYMMDDHHMMSS_create_credential_vault_policies.exs
└── YYYYMMDDHHMMSS_create_credential_vault_lease_log.exs
```

## First Consumer: Gmail OAuth for Email Triage

After the Credential Vault is built, the first credential to store will be the Gmail OAuth2 tokens from gog (already authenticated on the Spark for `alice@gmail.com`). The Email Triage Agent (Phase B) will acquire a lease with `["gmail.readonly", "gmail.labels"]` scopes and use the Proxy to call the Gmail API.

The gog keyring file on the Spark contains the OAuth tokens. A one-time import script will read from gog's storage and store the credential in the vault:

```elixir
# One-time seed script (mix run priv/scripts/import_gmail_oauth.exs)
# Reads gog's token file → stores in CredentialVault
```

## Dependencies

No new dependencies required. Uses:
- `Plug.Crypto` (already in deps via Phoenix) — encryption
- `Req` (already in deps) — HTTP requests in Proxy and TokenRefreshWorker
- `Ecto` + `Postgrex` (already in deps) — PostgreSQL storage

## Open for Future

- MCP exposure: `credential.list`, `credential.lease.acquire` as MCP tools (Phase C)
- Telegram notification on refresh failure (wire into existing Telegram channel)
- Per-tenant encryption keys for multi-tenant commercial deployment
- Audit log queries via AGE graph (credential access patterns)
- Jentic integration as alternative Backend
