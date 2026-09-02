# Kerf docs

| Folder | What lives here |
|---|---|
| `architecture/` | Generated reference: module map and test catalog (`mix kerf.test_catalog`). |
| `design/` | Design documents for subsystems: approval gate, structured output, credential vault, monitoring, knowledge-base lint, LiveDashboard, self-improvement write path, threat model. |
| `specs/` | Implementation specs and fix specs that have been (or are being) executed. |
| `superpowers/` | Specs (`specs/`) and plans (`plans/`) written for the superpowers workflow — the lettered `SPEC_*` files are the current series. |
| `patterns/` | Reusable working patterns (e.g. the autoresearch loop). |
| `history/` | Phase history and past design decisions. |
| `KERF_CONVENTIONS.md` | Project conventions. |

Investigation reports, baselines, deployment runbooks and anything client-related
are kept outside the repository on purpose (see the public/private split in `CLAUDE.md`).
