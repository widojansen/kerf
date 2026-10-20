# Kerf

Local-first, privacy-first Elixir/OTP personal AI platform. Deterministic OTP machinery
handles orchestration; LLM reasoning is scoped to typed steps. Licence AGPL-3.0-or-later.
Namespace `Kerf.*`, OTP app `:kerf`.

- Specs live in `docs/superpowers/specs/`. `SPEC_*` files plus their `*_addendum_NN.json`
  files are the contract; an addendum supersedes the spec text it cites.
- Development is spec-first and strictly RED → GREEN. Tests are written from the committed
  spec against the live code; implementation follows and never edits tests.
- `mix compile --warnings-as-errors`, `mix test`, `mix dialyzer`, and
  `mix format --check-formatted` on touched files are the gates.
- Postgres is required for `Kerf.DataCase` tests.

Maintainer-specific operating notes are kept outside this repository.

@/Users/wido/Projects/kerf/private/CLAUDE.md

