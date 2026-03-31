# ExClaw Security Audit — Lessons from KNP Logistics Collapse

*Generated: 2026-03-30 — Based on KNP Logistics ransomware case (June 2025, Akira group)*

---

## Context

A 158-year-old UK logistics company was destroyed in 22 days after attackers brute-forced a single password on an unprotected account. No MFA, no rate limiting, no network segmentation, no isolated backups. The attack chain was entirely preventable with basic security hygiene.

This document maps the relevant lessons to ExClaw's production stack on the DGX Spark.

---

## 1. Inference Endpoint Authentication

**Risk:** vLLM's default configuration exposes `/v1/chat/completions` without authentication. If the Spark's Tailscale IP is reachable by any device on the tailnet, any compromised node can hit the inference API directly.

**Current state:** vLLM runs as NGC Docker container, accessible at `100.101.119.128` on the tailnet.

**Actions:**
- Verify vLLM is bound to `127.0.0.1` or tailnet-only interface, not `0.0.0.0`
- Consider adding an nginx reverse proxy with API key validation in front of vLLM
- Add rate limiting on the inference endpoint (prevent abuse if a tailnet device is compromised)
- Log all inference requests — anomalous patterns (bulk exfiltration of model outputs) should be detectable

---

## 2. Credential Vault Design (Phase A.5) — Security Implications

**Risk:** The Credential Vault is designed to hold OAuth tokens (Gmail), GitHub deploy keys, Telegram bot tokens, and MCP client auth. A compromise of the Vault GenServer's state would expose all downstream services.

**Actions:**
- ETS-backed kill switch (microsecond credential revocation) is a strong design — keep it
- Ensure `Credential.Proxy` lease tokens have short TTLs (minutes, not hours)
- `Process.monitor`-based cleanup on consumer crash is correct — verify it works when the *Vault itself* restarts (supervision tree ordering)
- Encrypt credentials at rest in PostgreSQL (not just in-memory ETS); if the database is dumped, credentials should be useless
- Never store raw OAuth refresh tokens in the database without envelope encryption
- Per-agent credential policies should enforce least privilege: the email triage agent should not have access to GitHub deploy keys

---

## 3. Backup Isolation for Model Artifacts

**Risk:** Fine-tuned LoRA adapters, Docling extraction pipelines, pgvector embeddings, and AGE graph data represent significant compute investment. If backups are accessible from the same credentials that run ExClaw, they're targets, not backups.

**Current state:** Hetzner Storage Box BX11 with BorgBackup over SSH planned; OVH Cold Archive tracked as future tier.

**Actions:**
- BorgBackup repo on Hetzner should use a dedicated SSH key that is *not* present on the Spark's filesystem — use append-only mode
- PostgreSQL WAL archiving to Hetzner should use a separate credential from the main BorgBackup key
- Model weights (Qwen3-32B-NVFP4 checkpoint, any LoRA adapters) should be included in backup scope
- Test restore procedure quarterly — a backup that has never been restored is a hypothesis, not a backup
- Consider immutable snapshots: Hetzner Storage Box supports snapshot functionality

---

## 4. Network Segmentation on the Spark

**Risk:** The DGX Spark currently runs PostgreSQL, vLLM (Docker), SearXNG (Docker), and ExClaw on the same host. A compromise of any one service gives access to all others via localhost.

**Actions:**
- Use Docker network isolation: vLLM and SearXNG containers should be on a dedicated Docker bridge network, not `--network host`
- PostgreSQL should only accept connections from `127.0.0.1` and use `pg_hba.conf` to restrict which Unix users can connect
- ExClaw's `.env` credentials should be readable only by the ExClaw service user (`chmod 600`)
- Firewall rules (ufw/nftables): block all inbound except Tailscale interface and SSH
- SearXNG's JSON API should not be exposed beyond localhost — verify `settings.yml` bind address

---

## 5. SSH and Access Hardening

**Risk:** SSH is the primary access channel to the Spark. A compromised SSH key gives full access to the entire stack.

**Actions:**
- Verify `PasswordAuthentication no` in sshd_config (only key-based auth)
- Use separate SSH keys per purpose: personal access vs. GitHub deploy key vs. BorgBackup — already partially done (`github-exclaw` in `~/.ssh/config`)
- Consider `fail2ban` on the Spark for SSH brute-force protection (even behind Tailscale, defense in depth)
- Audit `authorized_keys` periodically — remove any keys that are no longer in use
- Disable root SSH login if not already done

---

## 6. Supply Chain Security

**Risk not covered by the KNP article but relevant to ExClaw:**

- Model weights downloaded from Hugging Face could be tampered with (model poisoning)
- Python/Elixir dependencies could contain malicious code
- NGC Docker images should be verified against NVIDIA's signatures

**Actions:**
- Pin model weight checksums (SHA256) after initial download; verify on each vLLM restart
- Use `mix audit` for Elixir dependency vulnerability scanning
- Pin Docker image digests in systemd unit files rather than using `:latest` tags
- Review Hex.pm dependencies periodically for known vulnerabilities

---

## 7. Prompt Injection as Attack Vector

**Risk not covered by the KNP article but critical for ExClaw:**

ExClaw processes external content (emails via Gmail triage, web search results via SearXNG, potentially invoices via Docling). Malicious content crafted to manipulate LLM behavior is a real attack surface.

**Actions:**
- Sanitize all external content before passing to LLM — strip known injection patterns
- Use separate system prompts with explicit instruction hierarchy (user content is untrusted data)
- Log all tool calls made by agents — if an agent suddenly makes unexpected tool calls after processing an email, that's a signal
- Consider a "canary" pattern: include a verification token in system prompts that agents must preserve; if it's missing from the response, the prompt may have been hijacked

---

## 8. Multi-Tenancy Security (Business Track)

**Risk:** ExClaw's commercial vision includes multi-tenant deployment. The KNP case shows that flat architectures with shared credentials are catastrophic.

**Actions:**
- PostgreSQL schema isolation (`{group}_{project}`) is a good start — ensure cross-schema queries are impossible without explicit grants
- Per-tenant OTP supervision trees should crash-isolate: one tenant's failure must never affect another
- RBAC at Group and Project levels must be enforced at the Ecto query level, not just the UI level
- Tenant credential stores must be isolated: tenant A's OAuth tokens must be inaccessible to tenant B's agents
- Rate limiting per tenant to prevent resource exhaustion attacks

---

## Priority Matrix

| Action | Effort | Impact | Priority |
|--------|--------|--------|----------|
| Verify vLLM bind address | 5 min | High | **Now** |
| PostgreSQL `pg_hba.conf` audit | 15 min | High | **Now** |
| SSH hardening audit | 30 min | High | **Now** |
| Docker network isolation | 1 hour | Medium | **This week** |
| Credential Vault encryption at rest | 2-3 hours | High | **Phase A.5** |
| BorgBackup append-only + separate key | 1 hour | High | **When implementing backup** |
| Prompt injection defenses | 2-4 hours | Medium | **Email triage agent phase** |
| Supply chain pinning | 1 hour | Medium | **Next maintenance window** |
| Multi-tenancy isolation audit | 4+ hours | High | **Business track phase** |

---

## The OTP Advantage

ExClaw's Elixir/OTP architecture provides structural advantages that KNP's flat Windows environment lacked:

- **Process isolation**: Each agent runs in its own process with its own state — a compromised agent can be killed and restarted without affecting the system
- **Supervision trees**: Crash isolation is built into the runtime, not bolted on
- **ETS kill switch**: Credential revocation in microseconds via ETS table deletion, vs. HTTP round-trips to revoke tokens
- **Let it crash**: Rather than trying to handle every failure gracefully (and potentially masking attacks), OTP's philosophy of crashing and restarting from known-good state is inherently more resilient

The key insight from KNP: **resilience must be structural, not procedural**. OTP gives ExClaw this structurally. The remaining gaps are at the infrastructure layer (network, backups, credentials at rest) rather than the application layer.
