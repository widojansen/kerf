# Kerf

**Elixir/OTP agent platform.** Runs on your hardware, holds your credentials, talks to your channels, stays loyal to you.

> ⚠️ **Status: in development.** The 0.1.0 release on Hex.pm is a namespace placeholder. Functional releases will follow as the platform stabilizes.

## What

Kerf is an agent orchestration platform built on Elixir and OTP. It bundles:

- **Multi-channel surfaces** — Telegram, WhatsApp, CLI
- **Credential vault** — encrypted storage of secrets and API keys for agents to use
- **Approval gates** — human-in-the-loop checkpoints with pause/resume tokens
- **Email triage** — deterministic-first classification with LLM augmentation
- **Knowledge base** — pgvector for semantic search, AGE for graph relationships

## Why

Most AI agent platforms are hosted SaaS. Kerf is for people who want their AI infrastructure to run on hardware they control, with data that doesn't leave, on terms they set.

The eigenwijs way.

## Status

In active development. Not yet stable. Breaking changes expected. Watch the repo for progress.

## Links

- Hex package: [`hex.pm/packages/kerf`](https://hex.pm/packages/kerf)
- Project page: [`kerf.run`](https://kerf.run)

## License

[AGPL-3.0-or-later](LICENSE)

