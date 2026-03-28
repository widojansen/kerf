# ExClaw Intelligence Platform — Architecture

> Unified architecture for a personal intelligence system and a commercial business intelligence product. Both tracks share a single ExClaw OTP core: supervised agents, a knowledge base (pgvector + AGE), MCP bidirectional communication, and privacy-first local inference. Designed 2026-03-22, updated 2026-03-24.

## Overview

ExClaw serves two tracks from a single codebase:

**Track 1 — Personal Intelligence Platform:** your own deployment on the DGX Spark. Email triage, developer team agents, knowledge base, content ingestion. This is the reference architecture — built for daily use, proving out every capability that the commercial product will offer.

**Track 2 — Business Intelligence Product:** ExClaw deployed alongside existing business systems (e.g., pct-panel-skeleton, ERP, CRM). Adds a conversational AI layer via Telegram — business users ask questions in natural language, agents query the business database, apply business rules, and respond. No replacement of existing systems, just an intelligence addon.

Both tracks share the same spine: supervised OTP agents, a knowledge base backed by PostgreSQL (pgvector + AGE), MCP bidirectional communication, and local-first inference. Both tracks also share the same isolation model: **Groups** (organizational boundary) contain **Projects** (data + agent scope). Your personal deployment is a group with multiple projects. Each commercial client is a separate group.

The knowledge base is the foundation. Email triage and developer agents read from and write to it. Infrastructure agents keep the Spark healthy and data safe. MCP exposes everything to external clients (Claude Code, business systems) and lets agents consume external tools.

### Machine Roles

| Machine | Role | Always on? | Backup |
|---------|------|-----------|--------|
| **DGX Spark** | ExClaw runtime, PostgreSQL, Ollama, bare repo mirrors, all agents | Yes | Nightly to Hetzner Storage Box |
| **MacBook Air M2** | Development client, git source of truth, IDE | No (portable) | Time Machine + Backblaze |
| **Hetzner AX41** | Public-facing infra (web services, agency) | Yes | Managed |
| **Hetzner Storage Box BX11** | Dedicated backup target for Spark (1 TB) | Yes (managed) | Built-in snapshots (10 automated) |

The Spark is the always-on server. The MacBook is a development client that pushes to it. Code repos have three copies: MacBook (working tree) → GitHub (remote) → Spark (bare mirror for agents). The knowledge base, AGE graph, embeddings, and feedback data are unique to the Spark and backed up to the Hetzner Storage Box nightly via SFTP/rsync. The AX41 is freed from backup duty — it handles public-facing infrastructure only.

---

## Layer 1: Knowledge Base (Core)

### Storage — PostgreSQL on Spark

All data tables are scoped by group and project. Each project gets its own PostgreSQL schema (`{group}_{project}`) within a shared database, providing data isolation while keeping backup simple (one `pg_dump`).

| Table | Scope | Purpose |
|-------|-------|---------|
| `groups` | Platform | Group definitions: name, owner, billing, settings |
| `projects` | Platform | Project definitions: name, group_id, type, connector config |
| `users` | Platform | User registry: Telegram ID, group memberships, project roles |
| `documents` | Project | Source metadata: type, origin URL/sender, timestamp, raw text |
| `chunks` | Project | Chunked content with pgvector embeddings |
| `interests` | Project | Topic/keyword interests with learnable weights |
| `feedback` | Project | User decisions (priority Y/N, follow-up Y/N, bookmarks, searches) |
| `code_files` | Project | Indexed source files: path, project, module, hash, raw content |
| `code_chunks` | Project | Chunked code with embeddings, tagged by function/module/type |
| `test_runs` | Project | Test results over time: suite, file, pass/fail, duration, timestamp |
| `build_results` | Project | Build/cross-compilation results: target triple, success/fail, artifact size, duration |
| `dependencies` | Project | Package manifests: name, version, source (hex/crates.io/npm/pypi), last checked |
| `toolchains` | Platform | Installed toolchains and targets: name, version, installed targets, last updated |
| `rules` | Project | Standing business rules: condition, action, schedule, owner |
| `audit_log` | Project | All interactions: who, what, when, query, result |
| AGE graph | Project | Relationships between entities — scoped per project, cross-project queries only within same group |

### Ingestion Pipeline

Each ingestor is an ExClaw agent implementing a shared `Ingestor` behaviour:

```
raw content → chunking → embedding (nomic-embed-text via Ollama) → pgvector insert + metadata
```

| Agent | Source | Notes |
|-------|--------|-------|
| `EmailIngestor` | Gmail API / IMAP | Classifies, chunks, embeds |
| `YouTubeIngestor` | yt-dlp transcripts | Pulls captions/transcripts |
| `PodcastIngestor` | RSS → audio → Whisper on Spark | Local transcription |
| `RSSIngestor` | Blog/feed URLs | Strip HTML, chunk, embed |
| `PDFIngestor` | Local/uploaded PDFs | OCR via GLM-OCR for scanned docs |
| `CodeIngestor` | Bare mirror repos on Spark | Parses, chunks, embeds code; builds module graph |

All ingestors are supervised under an `IngestionSupervisor` — crash isolation per source.

### Search

Hybrid retrieval:
- pgvector cosine similarity (semantic)
- Keyword matching (traditional)
- Interest weighting (personalized ranking)
- Recency factor

Summarization and Q&A over retrieved chunks via Qwen3 32B on Spark.

---

## Layer 2: Email Triage (Agent)

Not a separate system — an ExClaw agent that operates on the knowledge base.

### EmailTriageAgent (supervised GenServer)

1. `EmailIngestor` deposits new emails into the knowledge base
2. `EmailTriageAgent` picks them up, runs classification:
   - **Category**: business, personal, newsletter, transactional, spam
   - **Interest match score**: against `interests` table (semantic + keyword)
   - **Priority score**: sender reputation from graph, thread context, historical feedback
3. For interest-matched emails: generates summary + follow-up recommendation via Qwen3
4. Surfaces results to Telegram

### Learning Loop

- User responds in Telegram: "yes follow up" / "no" / "add sender to priority"
- Feedback writes to the `feedback` table
- Priority model: scored sender table + thread participation graph in AGE
- Sender confirmation: creates/decays graph nodes and edges
- Over time, agent proposes: "You've followed up on 4/5 emails from this domain — auto-prioritize?"

### Thread-Aware Priority Propagation

When a third party replies to a priority thread, the agent performs a graph traversal:

```cypher
MATCH (t:Thread)-[:INVOLVES]->(s:Sender {priority: true}),
      (t)-[:INVOLVES]->(new:Sender)
WHERE NOT new.priority
RETURN new
```

The new sender is flagged, and the user is asked via Telegram whether to add them to priority.

---

## Layer 3: Developer Team (Agents)

Not a separate system — a set of ExClaw agents that operate on the knowledge base, acting as specialized developer teammates. Each is a supervised GenServer under `DevTeamSupervisor`.

### Git Mirror — Bridging MacBook and Spark

The MacBook is not always on, but the developer agents need repo access 24/7. The solution is bare mirror repos on the Spark, kept in sync via git push hooks.

**Setup:** Each watched project has a bare repo on the Spark at `/data/repos/{project}.git`. The MacBook has a git remote `spark` pointing to it over Tailscale SSH.

**Sync mechanism:**
1. A `post-commit` hook on the MacBook pushes to the Spark bare repo automatically
2. The Spark bare repo has a `post-receive` hook that notifies `CodeIngestor` via a lightweight message (e.g., Unix socket or pg_notify)
3. `CodeIngestor` picks up the new commits and re-indexes changed files

**Fallback:** If the MacBook was offline and commits accumulated, the next push sends all of them. The agents simply process whatever is newest. There's no requirement for real-time — the agents work on last-pushed state, which for a TDD workflow means they're never more than a few commits behind.

**Alternative trigger:** `CodeIngestor` can also be triggered via MCP tool (`code.reindex(project)`) or by polling the bare repo for new refs on a timer — useful as a safety net if hooks fail.

### Agent Location Matrix

Not all agents need repo access. This determines what can run autonomously vs. what depends on fresh pushes from the MacBook.

| Agent | Needs repo access? | Data source | Runs when MacBook is off? |
|-------|-------------------|-------------|--------------------------|
| `CodeContextAgent` | Yes | Bare mirror repos | Yes (last-pushed state) |
| `CodeIngestor` | Yes | Bare mirror repos | Yes (last-pushed state) |
| `TestWatchAgent` | Yes | Bare mirror repos + test runners on Spark | Yes (runs tests on Spark) |
| `BuildAgent` | Yes | Bare mirror repos + build runners on Spark | Yes (builds from last-pushed state) |
| `ReviewAgent` | Yes | Bare mirror repos + knowledge base | Yes (reviews last-pushed commits) |
| `DependencyAgent` | No | Knowledge base + registry APIs | Yes |
| `DocAgent` | No | Knowledge base + AGE graph | Yes |
| `DeployAgent` | No | Spark system metrics + toolchain inventory | Yes |
| `BackupAgent` | No | PostgreSQL + Spark config | Yes |
| `EmailTriageAgent` | No | Knowledge base + Gmail API | Yes |

Key insight: once `CodeIngestor` has indexed the repos into the knowledge base, the downstream agents (DocAgent, DependencyAgent) don't need the repos at all — they read from the DB. Only the four agents that directly inspect files or run code need repo access, and the bare mirrors satisfy that.

### Language Abstraction Layer

The developer agents are language-agnostic. All language-specific logic is isolated behind behaviours with per-language implementations. The agents themselves never hardcode assumptions about Elixir, Rust, Python, or any other language.

#### LanguageAnalyzer Behaviour

Defines how to parse and understand a codebase. Each implementation knows its language's module system, dependency format, and conventions.

```elixir
@callback detect?(project_path) :: boolean
@callback parse_modules(file_path) :: [Module.t()]
@callback parse_functions(file_path) :: [Function.t()]
@callback extract_imports(file_path) :: [Import.t()]
@callback parse_dependencies(project_path) :: [Dependency.t()]
@callback map_test_to_source(test_path) :: source_path | nil
@callback public_api(module) :: [function_signature]
@callback extract_docs(file_path) :: [DocEntry.t()]
```

**Implementations:**

| Analyzer | Detection marker | Modules | Dependencies | Notes |
|----------|-----------------|---------|-------------|-------|
| `ElixirAnalyzer` | `mix.exs` | `defmodule` → Module nodes | `mix.exs` deps, `mix.lock` | Understands behaviours, supervision trees, OTP patterns |
| `RustAnalyzer` | `Cargo.toml` | `mod`, `pub struct`, `impl` → Module nodes | `Cargo.toml`, `Cargo.lock` | Understands traits, crate structure, `pub` visibility |
| `GoAnalyzer` | `go.mod` | `package`, exported types/funcs → Module nodes | `go.mod`, `go.sum` | Understands packages, interfaces, exported vs. unexported |
| `ZigAnalyzer` | `build.zig` | `pub fn`, structs → Module nodes | `build.zig.zon` | Understands comptime, build system |
| `PythonAnalyzer` | `pyproject.toml` / `requirements.txt` | `class`, top-level `def` → Module nodes | `pyproject.toml`, `requirements.txt`, `poetry.lock` | Understands `__init__.py` packages, type hints |
| `JavaScriptAnalyzer` | `package.json` | `export`, `module.exports` → Module nodes | `package.json`, `package-lock.json` | Handles both ESM and CommonJS |

**Detection:** When `CodeIngestor` encounters a new project, it runs `detect?/1` against all registered analyzers. A project can match multiple analyzers (e.g., a project with both `mix.exs` and `package.json`). The analyzers produce a common output format — `Module.t()`, `Function.t()`, `Dependency.t()` — that the agents consume uniformly.

**Adding a new language:** Implement the `LanguageAnalyzer` behaviour, register it. No agent code changes needed.

#### TestRunner Behaviour

Defines how to run tests and normalize results for any language's test framework.

```elixir
@callback detect?(project_path) :: boolean
@callback run_tests(project_path, opts) :: {:ok, [TestResult.t()]} | {:error, term}
@callback parse_output(raw_output) :: [TestResult.t()]
```

`TestResult.t()` is a common struct: `%{name, file, line, status, duration_ms, output}` where status is `:pass | :fail | :skip | :error`.

**Implementations:**

| Runner | Framework | Command | Notes |
|--------|-----------|---------|-------|
| `MixTestRunner` | ExUnit | `mix test --formatter json` | Elixir projects |
| `CargoTestRunner` | built-in | `cargo test -- --format json` (nightly) or parsed stdout | Rust projects |
| `GoTestRunner` | built-in | `go test -json ./...` | Go projects, JSON output native |
| `ZigTestRunner` | built-in | `zig build test` | Parsed from stderr |
| `PytestRunner` | pytest | `pytest --json-report` | Python projects |
| `JestRunner` | Jest | `jest --json` | JavaScript/TypeScript projects |

All test commands are executed inside ExClaw's ShellSandbox (see Sandboxed Execution below).

#### BuildRunner Behaviour

Defines how to compile projects and produce artifacts, including cross-compilation.

```elixir
@callback detect?(project_path) :: boolean
@callback build(project_path, target, opts) :: {:ok, BuildResult.t()} | {:error, term}
@callback available_targets() :: [Target.t()]
@callback clean(project_path) :: :ok
```

`Target.t()` represents a compilation target: `%{arch, os, variant, triple}` — e.g., `%{arch: :x86_64, os: :linux, variant: :musl, triple: "x86_64-unknown-linux-musl"}`.

`BuildResult.t()`: `%{target, artifact_path, size_bytes, duration_ms, warnings}`.

**Implementations:**

| Runner | Build command | Cross-compilation | Notes |
|--------|-------------|-------------------|-------|
| `MixBuildRunner` | `mix release` | N/A (BEAM is portable) | Produces OTP releases; Burrito for standalone binaries |
| `CargoBuildRunner` | `cargo build --release --target {triple}` | Native via `rustup target add` + linker config, or via `zig cc` as linker | Rust's strongest suit |
| `GoBuildRunner` | `GOOS={os} GOARCH={arch} go build` | Built-in, env vars only | Simplest cross-compilation story |
| `ZigBuildRunner` | `zig build -Dtarget={triple}` | Built-in, Zig is a cross-compiler | Also serves as C/C++ cross-compiler |
| `PythonBuildRunner` | `python -m build` / `pyinstaller` | Limited (PyInstaller for target platform) | Interpreted; cross-compilation mainly for C extensions |

**Cross-compilation targets (Spark is ARM64 / aarch64):**

| Target triple | Use case |
|---------------|----------|
| `aarch64-unknown-linux-gnu` | Native Spark build |
| `x86_64-unknown-linux-gnu` | Client servers, most cloud VMs |
| `x86_64-unknown-linux-musl` | Static binaries, Alpine containers |
| `x86_64-pc-windows-gnu` | Windows client delivery |
| `aarch64-unknown-linux-musl` | Static ARM binaries (e.g., Raspberry Pi, other ARM servers) |

**Zig as cross-compilation backbone:** Zig's `zig cc` can serve as the C cross-compiler and linker for Rust and C projects, eliminating the need for heavy cross-toolchain packages. This is configured per-project rather than globally — a project's `.exclaw.toml` can specify `linker = "zig"` for its cross-compilation targets.

**Build artifacts** land at `/data/builds/{project}/{target}/` on the Spark. The BackupAgent explicitly excludes these — they're regenerable from source.

#### Project Configuration — `.exclaw.toml`

Each project can include an optional `.exclaw.toml` at its root to configure agent behaviour. Without it, agents use sensible defaults based on detected language.

```toml
[project]
name = "exclaw"
languages = ["elixir"]  # auto-detected if omitted

[review]
# Patterns and conventions for ReviewAgent
conventions = [
  "All public functions must have @doc",
  "GenServers must implement handle_info for :timeout",
  "No direct Process.exit calls outside supervision trees",
]
security_contracts = ["FileGuard", "ShellSandbox", "PromptGuard"]

[test]
command = "mix test"  # override auto-detected runner
timeout_seconds = 300

[build]
targets = ["aarch64-unknown-linux-gnu", "x86_64-unknown-linux-musl"]
linker = "zig"  # use zig cc for cross-compilation

[build.release]
command = "mix release"  # language-specific release command

[dependencies]
# Package registries to monitor
registries = ["hex"]
ignore = ["phoenix_live_dashboard"]  # don't alert on these
```

Projects without `.exclaw.toml` get auto-detected defaults: language from project markers, test runner from framework detection, no cross-compilation targets, generic review prompts.

### Sandboxed Execution

All test runs and builds execute inside ExClaw's ShellSandbox. This is the same SecurityLayer already built for ExClaw — extended to cover compiled language toolchains.

**What ShellSandbox enforces:**
- Filesystem: read-only access to bare mirror repo, write access only to project's `_build`/`target`/`bin` and `/data/builds/{project}/`
- Network: blocked by default during test runs (tests shouldn't call external services); allowed during builds for dependency fetching (crates.io, proxy.golang.org, etc.)
- Resources: CPU time limit, memory limit, no process spawning outside the sandbox
- No access to PostgreSQL, Ollama, or other Spark services from sandboxed processes

**Compiled language specifics:**
- Rust `cargo test` and Go `go test` run the compiled test binary — the sandbox must allow execution of binaries built within the sandbox but nowhere else
- Build caches (`target/`, `$GOPATH/pkg/mod/`) are writable but excluded from backups
- Cross-compiled artifacts are written to `/data/builds/` which is outside the project sandbox — the BuildAgent has explicit write permission there

**Escalation path:** For untrusted code (e.g., evaluating third-party repos), Podman containers provide stronger isolation. A `ContainerSandbox` transport can be added later as an alternative to `ShellSandbox`, selectable per-project in `.exclaw.toml`:

```toml
[sandbox]
mode = "container"  # "shell" (default) or "container"
image = "rust:1.82-slim"  # base image for container mode
```

This is a future addition — ShellSandbox is sufficient for your own projects where the threat model is accidental damage, not adversarial code.

### Toolchain Management

The DeployAgent manages installed toolchains on the Spark, extending its existing role of tracking asdf/Elixir/OTP versions.

**Managed toolchains:**

| Toolchain | Install method | Version manager | Notes |
|-----------|---------------|-----------------|-------|
| Elixir / OTP | asdf | asdf | Already in place |
| Node.js | asdf | asdf | Already in place |
| Rust | rustup | rustup | Includes cross-compilation targets |
| Go | asdf or official tarball | asdf | Single binary, simple |
| Zig | asdf or official tarball | asdf | Also provides `zig cc` for cross-linking |
| Python | asdf | asdf | For projects that need it |

**DeployAgent responsibilities:**
- `check_toolchains()` — reports installed versions, compares to latest stable
- `install_target(toolchain, target_triple)` — e.g., `rustup target add x86_64-unknown-linux-musl`
- Alerts when a project's required toolchain version doesn't match what's installed
- Tracks disk usage of toolchains and build caches, alerts on thresholds

**Cross-compilation sysroots:** For Rust cross-compilation to glibc targets, the Spark needs the target's sysroot (headers and libraries). Options: install `gcc-x86-64-linux-gnu` packages, or use Zig as the linker (no sysroot needed for musl targets). The DeployAgent tracks which sysroots are installed and which projects need them.

### CodeContextAgent

Indexes active projects and maintains a live understanding of the codebase. Language-agnostic — delegates all parsing to `LanguageAnalyzer` implementations.

**Behaviour:**
1. Watches bare mirror repos on Spark for new refs
2. On new commits: detects project language(s), invokes the appropriate `LanguageAnalyzer` to re-parse changed files, updates embeddings in `code_chunks`
3. Builds/updates AGE graph using the common output format from analyzers:
   - `(:Module {language: "rust"})-[:CALLS]->(:Module)`
   - `(:Module)-[:DEPENDS_ON]->(:Package {registry: "crates.io"})`
   - `(:Function)-[:DEFINED_IN]->(:Module)`
   - `(:Module)-[:BELONGS_TO]->(:Project)`
   - `(:Project)-[:TARGETS]->(:Platform {triple: "x86_64-unknown-linux-musl"})`
4. Maintains per-project summaries: language, module count, test coverage snapshot, dependency count, configured build targets

**Why it matters:** When Claude Code asks "how does SecurityLayer interact with ShellSandbox?", the MCP server answers from the graph and embeddings instead of re-reading files every time. Every other dev agent depends on this index. The same graph handles Elixir modules, Rust crates, Go packages, and Zig modules uniformly.

### TestWatchAgent

Monitors test suites and tracks test health over time. Language-agnostic — delegates test execution to `TestRunner` implementations.

**Behaviour:**
1. On new commits (triggered by CodeIngestor): detects test framework, invokes the appropriate `TestRunner` inside ShellSandbox
2. Records each run to `test_runs` using the normalized `TestResult.t()` format — same schema regardless of language
3. Detects patterns:
   - **Flaky tests**: same test alternating pass/fail over recent runs
   - **Slow drift**: tests whose duration has increased >2x over the last N runs
   - **Persistent red**: tests failing for >N consecutive runs
   - **Coverage gaps**: modules with no corresponding test files (cross-referenced via CodeContextAgent graph)
4. Surfaces alerts to Telegram: "ShellSandbox integration test has been red for 3 days" or "automotiveMcpServer Jest suite slowed from 200ms to 800ms this week"
5. Writes findings to the knowledge base so they're searchable and can influence priority

**TDD integration:** Fits the Red-Prompt-Green-Refactor cycle — the agent tracks which tests you wrote red, whether they went green, and how long the cycle took. Works the same whether you're writing ExUnit, `#[test]`, or `func Test*`.

### BuildAgent

Handles compilation, cross-compilation, and artifact management. Distinct from TestWatchAgent — testing and building are separate concerns with different triggers and outputs.

**Behaviour:**
1. Triggered by: new commits on release branches, manual MCP tool call, or scheduled nightly builds
2. Reads project's `.exclaw.toml` for configured targets (or defaults to native aarch64 only)
3. Invokes the appropriate `BuildRunner` inside ShellSandbox for each target
4. Records results to knowledge base: `build_results` table (project, target, success/fail, artifact size, duration, warnings)
5. Places artifacts at `/data/builds/{project}/{target}/{artifact}`
6. Surfaces results to Telegram: "ExClaw release built for 2 targets: aarch64 (OK, 12MB), x86_64-musl (OK, 14MB)" or "automotiveMcpServer Go build failed for windows-amd64: linker error"

**Cross-compilation workflow:**
1. BuildAgent checks that the required toolchain and targets are installed (via DeployAgent's toolchain inventory)
2. If a target is missing: alerts via Telegram, optionally auto-installs if configured
3. Runs the build with the appropriate cross-compilation flags
4. Verifies the produced binary is the correct architecture (`file` command check)

**Artifact delivery:** Build artifacts can be exposed via MCP resource (`builds://project/target/latest`) for Claude Code to reference, or synced to Hetzner for client delivery. The BackupAgent excludes `/data/builds/` — artifacts are regenerable.

### ReviewAgent

Performs async first-pass code review on new commits or diffs. Language-agnostic — loads review conventions from `.exclaw.toml` and uses `LanguageAnalyzer` for structural understanding.

**Behaviour:**
1. Watches for new commits in bare mirror repos on configured branches (or triggered manually via MCP tool)
2. Extracts the diff and loads relevant context from CodeContextAgent's index
3. Loads project-specific review conventions from `.exclaw.toml` (or uses generic defaults)
4. Runs the diff + context + conventions through Qwen3 32B with a review prompt covering:
   - Language-specific patterns: OTP conventions for Elixir, ownership/borrowing for Rust, goroutine safety for Go, etc.
   - Project conventions: from `.exclaw.toml` `[review]` section
   - Security: matches against project-defined security contracts
   - Test coverage: flags new public functions/types without corresponding tests (via LanguageAnalyzer's `public_api/1`)
5. Posts review findings to Telegram with severity levels (suggestion / warning / issue)
6. Stores reviews in the knowledge base for trend tracking

**Scope boundary:** This is a first pass, not a replacement for deliberate review. It catches the obvious stuff — missing tests, pattern violations, security oversights — while you're working on something else. The `.exclaw.toml` conventions make it project-aware without hardcoding language assumptions into the agent.

### DependencyAgent

Monitors the dependency stack across all projects. Language-agnostic — uses `LanguageAnalyzer.parse_dependencies/1` to read any project's dependency manifest.

**Behaviour:**
1. Uses each project's `LanguageAnalyzer` to parse dependency manifests (`mix.exs`, `Cargo.toml`, `go.mod`, `build.zig.zon`, `pyproject.toml`, `package.json`)
2. Periodically checks upstream registries (Hex, crates.io, pkg.go.dev, PyPI, npm) for new versions
3. Ingests changelogs and release notes through the same pipeline as RSSIngestor
4. Correlates updates against the AGE dependency graph from CodeContextAgent:
   - "tokio 1.40 released with breaking changes — you use this in project X modules Y, Z"
   - "Ash 3.5 released with breaking changes to `Ash.Resource` — you use this in ExClaw modules A, B, C"
5. Classifies updates: security patch (urgent), breaking change (needs review), minor (informational)
6. Surfaces to Telegram with context; writes to knowledge base for searchability

**Extended scope:** Also monitors system-level dependencies — Elixir/OTP versions via asdf, Rust stable channel, Go releases, CUDA toolkit updates, Ollama releases, PostgreSQL versions. Anything that could break the Spark environment or a project's build.

### DocAgent

Maintains living documentation by reading from the code context graph and generating structured docs. Language-agnostic — uses `LanguageAnalyzer.extract_docs/1` and the common graph format.

**Behaviour:**
1. Triggered on significant code changes (new modules, changed public APIs, updated supervision trees)
2. Uses `LanguageAnalyzer` to read language-native docs: `@moduledoc`/`@doc` for Elixir, `///` doc comments for Rust, `//` godoc for Go, docstrings for Python, JSDoc for JavaScript
3. Generates/updates:
   - Module-level documentation (what it does, public API, supervision/ownership relationships)
   - Architecture diagrams (supervision tree, module dependency graph, crate/package structure)
   - Project README sections (getting started, module map, configuration, build targets)
4. Writes docs back into the knowledge base as searchable documents
5. Flags documentation drift: "Module `exclaw::mcp::transport::http` was added 5 days ago with no doc comment"

**Content strategy link:** Blog posts about ExClaw can pull from accurate, up-to-date internal docs. The DocAgent ensures that what you write publicly matches the actual codebase. Works across all project languages.

### DeployAgent

Manages the DGX Spark environment and deployment operations.

**Behaviour:**
1. Monitors system health via periodic checks:
   - Ollama: model list, GPU memory allocation, running inference processes
   - Disk: NVMe usage, model storage, PostgreSQL data directory
   - GPU: memory utilization, temperature, compute load (via `nvidia-smi`)
   - Services: PostgreSQL, Ollama, ExClaw application status
2. Handles operational commands (via Telegram or MCP):
   - `pull_model(name)` — pulls a model via Ollama, monitors progress, reports completion
   - `restart_service(name)` — supervised restart of managed services
   - `check_versions()` — reports asdf tool versions, compares to latest available
3. Alerts on thresholds: disk >80%, GPU memory sustained >90%, service down
4. Maintains an infrastructure log in the knowledge base — useful for debugging "what changed when things broke"

**Scope:** Spark only. The Hetzner AX41 and MacBook Air are out of scope — this agent manages the AI server environment.

### BackupAgent

Protects irreplaceable Spark data by replicating it to the Hetzner Storage Box (BX11, 1 TB dedicated backup storage).

**Why a Storage Box, not the AX41:**
- Separation of concerns — backups don't compete for disk with public-facing services on the AX41
- 1 TB dedicated to backups vs. 512 GB shared on the AX41
- Built-in snapshots (10 automated) provide a second layer of protection — if a corrupt dump gets pushed, the Storage Box can roll back independently
- ~€3.20/month, no setup fee, no contract
- Supports BorgBackup, rsync via SSH, SFTP, SCP natively

**What's irreplaceable vs. recoverable:**

| Data | Irreplaceable? | Backup strategy |
|------|---------------|-----------------|
| PostgreSQL (knowledge base, AGE graph, feedback, test history, build results) | Yes | BorgBackup to Storage Box (deduplicated, compressed) |
| Spark config (dotfiles, systemd units, Ollama config, asdf versions, .exclaw.toml files) | Yes | BorgBackup to Storage Box |
| Bare mirror repos | No | Re-clone from GitHub |
| Ollama models | No | Re-pull (DeployAgent maintains a manifest in the KB) |
| `_build` / `target` / `deps` / `node_modules` | No | Regenerated from source |
| `/data/builds/` (cross-compiled artifacts) | No | Rebuilt from source by BuildAgent |

**Behaviour:**
1. Runs nightly on a timer (supervised GenServer with `:timer`-based scheduling)
2. Executes `pg_dump --format=custom` → pipes to BorgBackup archive on Storage Box via SSH (`uXXXXXX.your-storagebox.de`)
3. Backs up Spark config directories to a separate Borg repo on the same Storage Box
4. BorgBackup handles deduplication and compression — 7 daily dumps take a fraction of the space vs. 7 full copies
5. Verifies archive integrity (`borg check`)
6. Prunes old archives: keep 7 daily, 4 weekly, 3 monthly
7. Reports to Telegram: success with archive size, dedup ratio, and duration, or failure with error details
8. Maintains a backup log in the knowledge base: last successful backup, size trend, failures

**Connectivity:** The Storage Box is reached over the public internet via SSH (not Tailscale — it's a Hetzner-managed service at `uXXXXXX.your-storagebox.de:23`). SSH key authentication, no password. The BackupAgent stores the connection details in its GenServer state, loaded from environment config at startup.

**Retention:** BorgBackup prune policy — 7 daily, 4 weekly, 3 monthly. Combined with the Storage Box's built-in automated snapshots, this gives multiple recovery points at different granularities.

**Recovery playbook:** If the Spark NVMe fails — `borg extract` latest archive from Storage Box to restore PostgreSQL dump and config, `pg_restore` the database, re-clone bare repos from GitHub, re-pull models from Ollama manifest. The BackupAgent maintains a `RECOVERY.md` in the knowledge base documenting these steps.

### Agent Interaction via the Knowledge Base

The developer agents don't communicate directly — they share state through the knowledge base and AGE graph. This is intentional:

- **CodeContextAgent** writes the code index (via LanguageAnalyzers) that **ReviewAgent**, **TestWatchAgent**, **BuildAgent**, **DocAgent**, and **DependencyAgent** all read
- **TestWatchAgent** writes test health data that **ReviewAgent** references when evaluating diffs
- **BuildAgent** writes build results that **DeployAgent** monitors for disk usage and **ReviewAgent** can reference for compilation warnings
- **DependencyAgent** writes dependency status that **CodeContextAgent** uses to flag outdated imports and **BuildAgent** checks before cross-compilation
- **DeployAgent** writes infrastructure and toolchain state that all agents can check before operations

The graph enables compound queries that span agents and languages:
```cypher
-- Which modules (any language) do I change most often, that use outdated
-- dependencies, and have flaky tests?
MATCH (m:Module)<-[:MODIFIES]-(c:Commit),
      (m)-[:DEPENDS_ON]->(p:Package {outdated: true}),
      (m)<-[:TESTS]-(t:TestFile)-[:HAS_RESULT]->(r:TestRun {flaky: true})
RETURN m.name, m.language, p.name, p.registry, t.name
ORDER BY count(c) DESC
```

```cypher
-- Which projects have cross-compilation targets that haven't built
-- successfully in the last 7 days?
MATCH (proj:Project)-[:TARGETS]->(plat:Platform),
      (proj)-[:HAS_BUILD]->(b:BuildResult {target: plat.triple})
WHERE b.timestamp < datetime() - duration('P7D')
   OR b.status = 'fail'
RETURN proj.name, plat.triple, b.status, b.timestamp
```

This is the compound value — no single tool gives you this cross-cutting, cross-language view.

---

## Layer 4: MCP Bridge (Bidirectional)

### ExClaw as MCP Server

Exposes internals to Claude Code and external MCP clients.

**Knowledge Resources:**
- `knowledge://search?q=...` — semantic search over the knowledge base
- `knowledge://interests` — current interest topics and weights

**Email Resources:**
- `email://inbox/categorized` — categorized inbox state
- `email://priority/senders` — priority sender list with scores

**Developer Resources:**
- `code://search?q=...` — semantic search over indexed codebases
- `code://module/{name}` — module details, dependencies, test status
- `code://deps/outdated` — stale dependencies with impact analysis
- `code://tests/status` — current test health summary
- `code://tests/flaky` — known flaky tests with history
- `code://reviews/recent` — recent ReviewAgent findings
- `builds://project/{name}/targets` — configured build targets and last build status
- `builds://project/{name}/{target}/latest` — latest build artifact metadata

**Infrastructure Resources:**
- `agents://status` — supervision tree health, running agents
- `infra://spark/health` — GPU, disk, memory, service status
- `infra://models` — Ollama model list with sizes and GPU allocation
- `infra://backup/status` — last backup time, archive size, dedup ratio, success/failure
- `infra://repos` — bare mirror repo list with last-pushed timestamps
- `infra://toolchains` — installed toolchains, versions, cross-compilation targets

**Knowledge Tools:**
- `knowledge.ingest(url)` — trigger ingestion of a new source
- `interests.update(topic, weight)` — adjust interest weights

**Email Tools:**
- `email.add_priority_sender(email)` — add sender to priority
- `email.feedback(email_id, decision)` — record a triage decision

**Developer Tools:**
- `code.review(diff)` — trigger async review of a diff
- `code.reindex(project)` — force re-index of a project
- `code.explain(module)` — generate explanation of a module from the graph
- `tests.run(project, path?)` — trigger a test run and record results
- `build.run(project, target?)` — trigger a build, optionally for a specific target
- `build.targets(project)` — list configured cross-compilation targets
- `deps.check(project)` — force dependency freshness check
- `docs.generate(module)` — trigger doc generation for a module
- `deploy.pull_model(name)` — pull a model on Spark via Ollama
- `deploy.restart(service)` — supervised restart of a service
- `deploy.check_versions()` — report tool/runtime versions
- `deploy.install_target(toolchain, triple)` — install a cross-compilation target (e.g., `rustup target add`)
- `deploy.check_toolchains()` — report installed toolchain versions and targets
- `backup.run_now()` — trigger an immediate BorgBackup to Storage Box
- `backup.status()` — last backup details, dedup ratio, Storage Box usage

### ExClaw as MCP Client

Agents consume external MCP servers at runtime:
- `EmailIngestor` → Gmail MCP / raw API
- `RSSIngestor` → web fetch tools
- `DependencyAgent` → Hex, crates.io, pkg.go.dev, PyPI, npm APIs
- `BuildAgent` → registry APIs for dependency fetching during builds
- Future: dynamic MCP server discovery, agents propose new connections

### OTP Implementation

Each MCP connection (inbound or outbound) is a supervised `GenServer` under `McpConnectionSupervisor`.

Transport is pluggable via a behaviour:
- `ExClaw.Mcp.Transport.Stdio` — for Claude Code local connections
- `ExClaw.Mcp.Transport.Http` — for remote / Streamable HTTP (MCP spec)

---

## Layer 5: Business Intelligence Track (Commercial Product)

ExClaw as an AI addon for existing business systems. The business application stays as-is — ExClaw sits alongside it, connecting to the existing database, understanding business rules, and giving users a natural language interface via Telegram.

This is the agency's repeatable product: for each new client, implement a BusinessConnector, configure business rules, deploy ExClaw alongside their software, hand them a Telegram channel.

### BusinessConnector Behaviour

Defines how ExClaw connects to and understands a business system. Each implementation knows the domain — its schema, its entities, its natural language patterns.

```elixir
@callback connect(config) :: {:ok, connection} | {:error, term}
@callback describe_schema() :: [Table.t()]
@callback query(natural_language, context) :: {:ok, QueryPlan.t()} | {:error, term}
@callback execute(QueryPlan.t()) :: {:ok, result} | {:error, term}
@callback business_rules(domain) :: [Rule.t()]
@callback entities() :: [EntityDefinition.t()]  # domain-specific concepts
```

**Implementations:**

| Connector | Target system | Domain concepts | Notes |
|-----------|--------------|-----------------|-------|
| `PctPanelConnector` | pct-panel-skeleton (PostgreSQL) | Resellers, members, users, devices, subscriptions, tiers, quotas | First implementation — streaming service reseller management |
| `AutomotiveConnector` | automotiveMcpServer (PostgreSQL) | Vehicles, customers, services, parts, invoices | Second implementation — automotive domain (via existing MCP server) |
| `GenericPostgresConnector` | Any PostgreSQL database | Auto-discovered from schema | Fallback for systems without a dedicated connector |
| `RestApiConnector` | REST/JSON APIs | Defined via OpenAPI spec | For SaaS systems that don't expose their database |
| `McpConnector` | Any MCP server | Defined by MCP tool/resource schema | Reuses ExClaw's MCP client — connect to any MCP-compatible system |

**Detection and domain understanding:** When a BusinessConnector is configured, it introspects the target database schema and builds an AGE graph of the business domain: `(:Reseller)-[:MANAGES]->(:User)-[:HAS_DEVICE]->(:Device)` for the PCT panel, or `(:Customer)-[:OWNS]->(:Vehicle)-[:HAD_SERVICE]->(:ServiceRecord)` for automotive. This graph enables the QueryAgent to translate natural language into accurate queries grounded in actual data relationships.

**Adding a new business system:** Implement the `BusinessConnector` behaviour with domain-specific entity mappings and natural language patterns. The QueryAgent, RulesEngine, and Telegram interface don't change. This is the agency's scaling model — the connector is the per-client work, everything else is reusable.

### QueryAgent

Takes natural language from Telegram, classifies intent, routes to the appropriate handler, grounds the response in actual business data.

**Behaviour:**
1. Receives message from Telegram (or MCP tool call)
2. Classifies intent:
   - **Data query**: "How many active users does reseller X have?" → translate to SQL via BusinessConnector, execute, format response
   - **Lookup**: "What devices are registered to user Y?" → direct record lookup
   - **Analysis**: "Which resellers are close to their user quota?" → aggregation query against tier limits
   - **Validation**: "Can reseller X add 5 more users?" → checks quota rules, tier limits, current allocation
   - **Action request**: "Disable all devices for user Z" → validates against business rules, queues action, asks for confirmation
   - **Rule setup**: "Alert me when any reseller hits 90% of their quota" → creates a standing rule in the RulesEngine
   - **Report**: "Give me a summary of new user signups this week by reseller" → aggregation query + Qwen3 formatting
3. Executes via the BusinessConnector — all responses grounded in actual database data, not LLM hallucination
4. Formats response via Qwen3 for natural language output
5. Sends back to Telegram

**Grounding guarantee:** The QueryAgent never generates business data from the LLM. The LLM translates natural language to structured queries and formats structured results back to natural language. The actual data comes from the business database. This is critical for trust — a reseller manager needs to know that "reseller X has 142 active users out of a 150 quota" is a database fact, not an AI guess.

**Fallback:** If the QueryAgent can't confidently translate a query, it asks for clarification in Telegram rather than guessing. "I'm not sure what you mean by 'recent' — do you mean this week, this month, or this quarter?"

### RulesEngine

Evaluates standing business rules on a schedule, triggering actions when conditions are met.

**Behaviour:**
1. Runs as a supervised GenServer with configurable check intervals per rule
2. Rules stored in the knowledge base with structure:
   ```
   %Rule{
     condition: "reseller quota usage > 90%",
     action: :notify_telegram,
     schedule: :hourly,
     owner: "panel_admin",
     created_via: :natural_language,
     original_text: "Alert me when any reseller hits 90% of their quota"
   }
   ```
3. On each tick: evaluates each rule's condition against the business database via BusinessConnector
4. When a condition is met: executes the action (Telegram notification, queued email, flagged record)
5. Tracks rule history: when each rule last fired, how often, false positive rate

**Rule creation flow:**
1. User says in Telegram: "Alert me when any reseller hits 90% of their quota"
2. QueryAgent classifies as rule setup, extracts: entity (reseller), metric (quota usage), threshold (>90%), action (alert)
3. Translates to a structured Rule via the BusinessConnector's domain understanding
4. Confirms with user: "I'll check hourly and alert you when any reseller exceeds 90% of their user quota. OK?"
5. User confirms → rule saved to knowledge base → RulesEngine picks it up

**Predefined rules:** Each BusinessConnector can ship with domain-appropriate default rules. The PctPanelConnector might include: quota threshold alerts (90% of user limit), inactive device cleanup flags (no connection in 30 days), subscription expiry warnings (7 days before), bulk operation limits (prevent reseller from adding >N users in one action). The AutomotiveConnector might include: APK reminders, service follow-ups, low stock alerts. The business owner can modify, disable, or add rules via natural language.

### Isolation Model: Groups and Projects

Isolation is not just a commercial need — the personal track already requires it. Your personal deployment has ExClaw dev agents, email triage, the PCT panel, automotive data, and a knowledge base. These are separate concerns with separate data. A query about automotive parts shouldn't surface in your dev agent context.

The isolation model is two levels: **Groups** (organizational boundary) contain **Projects** (data + agent scope).

#### Groups

A group is the hard boundary — the organizational, billing, and data sovereignty unit. Cross-group data access is impossible by design.

| Group | Owner | Projects |
|-------|-------|----------|
| `wido` (personal) | You | exclaw-dev, email-triage, pct-panel, automotive, knowledge-base |
| `streamingco` (client) | Client admin | reseller-mgmt |
| `garage-chain` (client) | Client admin | workshop-ops |

**What a group provides:**
- Data isolation: no cross-group queries, ever
- User management: the group owner controls who has access
- Billing boundary: each group is a billing entity (for commercial clients)
- Separate Telegram routing: each group's messages are isolated

#### Projects

A project is the data + agent scope within a group. Each project gets its own PostgreSQL schema, its own AGE graph namespace, its own supervision tree of agents, and its own Telegram channel (or prefix within a group channel).

**Your personal group's projects:**

```
Group: "wido"
├── Project: "exclaw-dev"
│   ├── CodeContextAgent, TestWatchAgent, BuildAgent,
│   │   ReviewAgent, DependencyAgent, DocAgent
│   └── Schema: wido_exclaw_dev (code_files, code_chunks, test_runs, ...)
├── Project: "email-triage"
│   ├── EmailIngestor, EmailTriageAgent
│   └── Schema: wido_email_triage (documents, chunks, interests, feedback)
├── Project: "pct-panel"
│   ├── QueryAgent, RulesEngine, PctPanelConnector
│   └── Schema: wido_pct_panel (rules, audit_log, + connector to PCT DB)
├── Project: "automotive"
│   ├── QueryAgent, RulesEngine, AutomotiveConnector
│   └── Schema: wido_automotive (rules, audit_log, + connector to auto DB)
└── Project: "knowledge-base"
    ├── RSSIngestor, YouTubeIngestor, PodcastIngestor, PDFIngestor
    └── Schema: wido_knowledge_base (documents, chunks, interests, feedback)
```

**A commercial client's group:**

```
Group: "streamingco"
├── Project: "reseller-mgmt"
│   ├── QueryAgent, RulesEngine, PctPanelConnector
│   └── Schema: streamingco_reseller_mgmt (rules, audit_log, + connector to client DB)
└── Users: admin@streamingco (owner), support@streamingco (staff)
```

#### OTP Supervision Tree

The Group → Project model maps directly to nested OTP supervision trees:

```
ExClaw.Application
├── ExClaw.PlatformSupervisor
│   ├── DeployAgent (Spark-level)
│   ├── BackupAgent (backs up all schemas)
│   └── McpServer (routes to group/project based on auth)
├── ExClaw.GroupSupervisor ("wido")
│   ├── ExClaw.ProjectSupervisor ("exclaw-dev")
│   │   ├── CodeContextAgent
│   │   ├── TestWatchAgent
│   │   ├── BuildAgent
│   │   ├── ReviewAgent
│   │   ├── DependencyAgent
│   │   └── DocAgent
│   ├── ExClaw.ProjectSupervisor ("email-triage")
│   │   ├── EmailIngestor
│   │   └── EmailTriageAgent
│   ├── ExClaw.ProjectSupervisor ("pct-panel")
│   │   ├── QueryAgent
│   │   ├── RulesEngine
│   │   └── PctPanelConnector → PCT database
│   ├── ExClaw.ProjectSupervisor ("automotive")
│   │   ├── QueryAgent
│   │   ├── RulesEngine
│   │   └── AutomotiveConnector → automotive database
│   ├── ExClaw.ProjectSupervisor ("knowledge-base")
│   │   ├── RSSIngestor
│   │   ├── YouTubeIngestor
│   │   ├── PodcastIngestor
│   │   └── PDFIngestor
│   └── GroupAdminAgent (cross-project queries within group)
├── ExClaw.GroupSupervisor ("streamingco")
│   ├── ExClaw.ProjectSupervisor ("reseller-mgmt")
│   │   ├── QueryAgent
│   │   ├── RulesEngine
│   │   └── PctPanelConnector → client database
│   └── GroupAdminAgent
```

**Crash isolation is structural:** a crash in StreamingCo's QueryAgent restarts that agent within its ProjectSupervisor. It can't affect your personal ExClaw dev agents — they're in a completely separate branch of the supervision tree. A crash in an entire project restarts that project's supervisor. A crash in an entire group restarts the group supervisor. The platform-level agents (Deploy, Backup, MCP) are isolated from all groups.

#### Data Isolation via PostgreSQL Schemas

Each project gets its own PostgreSQL schema: `{group}_{project}` (e.g., `wido_exclaw_dev`, `streamingco_reseller_mgmt`).

**Why schemas, not separate databases:**
- Single `pg_dump` backs up everything — the BackupAgent stays simple
- Cross-project queries within a group are possible via schema-qualified queries (`SELECT FROM wido_exclaw_dev.test_runs`)
- Cross-group queries are prevented at the application layer — the GroupSupervisor enforces that its projects only access schemas belonging to the group
- Simpler connection management — one connection pool, schema set per session via `SET search_path`
- Can migrate to separate databases later if a client needs physical database isolation

**AGE graph isolation:** Each project gets its own AGE graph namespace. The graph for `wido_exclaw_dev` contains module/function/dependency nodes. The graph for `wido_pct_panel` contains reseller/user/device nodes. The GroupAdminAgent can traverse across project graphs within the same group for cross-project queries.

#### Telegram Routing

Two models, selectable per group:

**Multi-channel (recommended for commercial clients):** Each project gets its own Telegram channel or group chat. Clean isolation, clear context, no routing ambiguity. StreamingCo's reseller management gets one channel; a future content ops project gets another.

**Single-channel with routing (convenient for personal use):** One Telegram channel for the group, with project addressing via prefix or mention. You type `@dev how many tests are failing?` and it routes to the exclaw-dev project. You type `@pct how many resellers are active?` and it routes to the pct-panel project. Unaddressed messages go to a default project or the GroupAdminAgent.

The routing is handled by a `TelegramRouter` GenServer per group that parses incoming messages, identifies the target project, and forwards to the correct ProjectSupervisor's agents.

#### Cross-Project Queries

The GroupAdminAgent enables queries that span projects within the same group:

- "Which of my projects has failing tests?" → queries `test_runs` across all dev project schemas in the group
- "Give me a summary of all alerts from the last 24 hours" → aggregates Telegram notifications from all projects
- "What's my total active user count across all business projects?" → queries across business project schemas

Cross-project queries are explicit — they go through the GroupAdminAgent, not through individual project agents. Individual project agents only see their own schema.

**Cross-group queries don't exist.** This is the hard boundary. There is no mechanism to query across groups, by design. Even the platform-level agents (DeployAgent, BackupAgent) don't read group data — they operate on infrastructure.

### RBAC (Role-Based Access Control)

RBAC operates at both group and project level.

**Group-level roles:**

| Role | Scope | Capabilities |
|------|-------|-------------|
| **Group Owner** | Entire group | Create/delete projects, manage users, all project access, billing |
| **Group Admin** | Entire group | Manage users, all project access, no billing/deletion |
| **Group Member** | Assigned projects | Access only to projects they're assigned to |

**Project-level roles (per user, per project):**

| Role | Capabilities |
|------|-------------|
| **Project Admin** | All queries, rule management, configuration |
| **Operator** | All queries, rule creation, no configuration changes |
| **Staff** | Predefined queries, read-only on rules |
| **Read-only** | Receives notifications, views reports |

**Example:** In the StreamingCo group, the admin is Group Owner with Project Admin on all projects. A support team member is a Group Member with Operator role on the reseller-mgmt project. They can query reseller data and create alert rules, but can't change the connector configuration or add new projects.

**Enforcement:** The `TelegramRouter` resolves the user's Telegram ID → group membership → project role before forwarding any message. The ProjectSupervisor's agents check the role on every operation. Role assignments are stored in the platform-level `users` table and manageable via Telegram by Group Owners: "Add @support_anna as operator on reseller-mgmt."

### Audit Logging

Every interaction is logged per project for compliance and learning:
- Who asked what, when (Telegram ID, timestamp, raw message)
- Which project handled it (routing decision)
- What query was generated and executed (SQL/Cypher)
- What data was returned (row count, not raw data — for privacy)
- What rules fired and what actions were taken
- What feedback was given (confirmations, corrections)

Stored in each project's `audit_log` table within its schema. Queryable via MCP (scoped to the requesting user's access level). Essential for business clients who need to demonstrate data access compliance (GDPR, industry regulations).

The GroupAdminAgent can produce cross-project audit summaries within the group: "Show me all queries across all projects in the last 7 days."

### Business Track — MCP Integration

The MCP server from Layer 4 extends naturally with group/project scoping. MCP connections authenticate to a group and project, and all resources/tools are scoped accordingly.

**Business Resources (per group/project):**
- `business://{group}/{project}/schema` — business database schema and entity map
- `business://{group}/{project}/rules` — active rules and their status
- `business://{group}/{project}/queries/recent` — recent query history
- `business://{group}/{project}/audit` — audit log
- `group://{group}/projects` — list of projects in the group (group admin only)
- `group://{group}/users` — users and roles (group admin only)

**Business Tools (per group/project):**
- `business.query(group, project, natural_language)` — execute a business query
- `business.add_rule(group, project, condition, action)` — create a standing rule
- `business.list_rules(group, project)` — list active rules
- `group.add_user(group, telegram_id, role)` — add a user to the group
- `group.set_project_role(group, project, telegram_id, role)` — set project-level role

This means Claude Code (or any MCP client) can interact with any group/project combination the authenticated user has access to. A developer managing multiple client deployments can switch between groups via MCP without reconnecting.

### Deployment Models

| Model | Description | Use case |
|-------|-------------|----------|
| **Hosted on Spark** | Group supervision tree runs on your Spark, connects to client's DB remotely | Small clients, agency-managed, personal projects |
| **On-premise** | ExClaw deployed on client's own hardware (DGX, GPU server) | Enterprise clients, strict data sovereignty |
| **Hybrid** | ExClaw on Spark, business DB stays on client's network, connected via Tailscale/VPN | Mid-market, client keeps data control |

For the agency launch, the hosted model is simplest — you manage everything, clients get a Telegram channel and a group. Your personal group is also hosted. On-premise and hybrid come later for enterprise clients who need full data sovereignty.

---

## Commercial Positioning

### ExClaw vs. OpenClaw

OpenClaw is a deployment/sandbox wrapper — it runs agents in containers, handles orchestration, provides a web UI. ExClaw operates at a different layer: the agents themselves, their supervision, their shared memory (knowledge base + graph), their security contracts.

The Personal Intelligence Platform makes this distinction concrete. NemoClaw/OpenClaw could *deploy* ExClaw agents, but they can't provide the OTP runtime properties — per-process crash isolation, hot code reloading, supervision tree self-healing, and now multi-tenant isolation. Those are ExClaw's moat.

### The Reference Architecture Argument

The Personal Intelligence Platform is the proving ground for every capability the commercial product offers:

| Personal track proves | Commercial track needs |
|----------------------|----------------------|
| Knowledge base + pgvector + AGE pipeline | Same — per-project business data indexed and queryable |
| Group/project isolation (personal projects) | Same — per-client groups, per-system projects |
| Supervised agents with crash isolation | Same — per-project supervision trees |
| Telegram natural language interface | Same — business users ask questions in Telegram |
| Feedback loop (email triage learning) | Same — query history and rule refinement |
| MCP bidirectional communication | Same — business systems integrate via MCP |
| SecurityLayer (FileGuard, ShellSandbox, PromptGuard) | Extended with RBAC and audit logging |
| Local inference (Qwen3, nomic-embed-text) | Same — privacy-first, no business data leaves the network |
| Language-agnostic behaviours | BusinessConnector behaviour — same pattern, different domain |
| `.exclaw.toml` per-project config | Per-project/tenant configuration |

Every phase of the personal build sequence validates something an enterprise buyer cares about. The consulting pitch: "Here's the architecture I run daily. Here's how your deployment would look."

### Agency Delivery Model

For each new client:
1. Create a group for the client
2. Create a project within the group
3. Implement a `BusinessConnector` for their system (or use `GenericPostgresConnector`)
4. Configure domain-specific business rules and predefined rules
5. Set up group users with appropriate roles
6. Deploy the group's supervision tree (hosted or on-premise)
7. Hand them a Telegram channel bound to their project
8. Iterate on rules and query patterns based on their usage

The ExClaw core doesn't change — only the connector, rules, and group/project config. Adding a second project for an existing client (e.g., StreamingCo adds a content management system) means creating a new project within their group — the group infrastructure, user management, and Telegram routing already exist.

---

## System Diagram

```
MacBook Air M2                     Hetzner Storage Box BX11
(dev client)                       (dedicated backup, 1 TB)
   │                                      ▲
   │ git push (post-commit hook)          │ nightly BorgBackup
   │ via Tailscale SSH                    │ via SSH (port 23)
   │                                      │
   ▼                                      │
┌─────────────────────────────────────────┼────────────────┐
│  DGX Spark (always on)                  │                │
│                                         │                │
│  /data/repos/*.git ◄── post-receive ──► CodeIngestor    │
│  (bare mirrors)         hook notifies                    │
│                                                          │
│  External Sources              User (Telegram / Claude)  │
│     │                                    │               │
│     ▼                                    ▼               │
│  ┌──────────────────────────────────────────────────┐   │
│  │  IngestionSupervisor                              │   │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌──────────┐  │   │
│  │  │ Email  │ │YouTube │ │RSS/PDF/│ │ Code     │  │   │
│  │  │Ingestor│ │Ingestor│ │Podcast │ │ Ingestor │  │   │
│  │  └───┬────┘ └───┬────┘ └───┬────┘ └────┬─────┘  │   │
│  └──────┼──────────┼──────────┼────────────┼────────┘   │
│         │          │          │            │             │
│         ▼          ▼          ▼            ▼             │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Knowledge Base (pgvector + AGE)                  │   │
│  │  chunks / embeddings / graph / feedback /          │   │
│  │  code_files / code_chunks / test_runs / deps      │   │
│  └───────────────────┬──────────────────────────────┘   │
│                      │                                   │
│    ┌─────────────────┼──────────────────────┐           │
│    │                 │                      │           │
│    ▼                 ▼                      ▼           │
│ ┌────────┐   ┌──────────────┐   ┌──────────────────┐  │
│ │ Email  │   │ DevTeam      │   │ MCP Server       │  │
│ │ Triage │   │ Supervisor   │   │                  │  │
│ │ Agent  │   │ ┌──────────┐ │   │                  │  │
│ │        │   │ │CodeContxt│ │   │                  │  │
│ │        │   │ │TestWatch │ │   │                  │  │
│ │        │   │ │Build     │ │   │                  │  │
│ │        │   │ │Review    │ │   │                  │  │
│ │        │   │ │Dependency│ │   │                  │  │
│ │        │   │ │Doc       │ │   │                  │  │
│ │        │   │ │Deploy    │ │   │                  │  │
│ │        │   │ │Backup ───┼─┼───┼──► Storage Box   │  │
│ │        │   │ └──────────┘ │   │                  │  │
│ └───┬────┘   └──────┬───────┘   └────────┬─────────┘  │
│     │               │                     │            │
│     │    ┌──────────┼─────────────────────┤            │
│     │    │          │                     │            │
│     │    │  ┌───────┴──────────────────┐  │            │
│     │    │  │  Tenant Supervisors      │  │            │
│     │    │  │  (Business Track)        │  │            │
│     │    │  │  ┌────────────────────┐  │  │            │
│     │    │  │  │ Tenant A (streaming)│  │  │            │
│     │    │  │  │  QueryAgent       │  │  │            │
│     │    │  │  │  RulesEngine      │  │  │            │
│     │    │  │  │  PctPanelConnector│──┼──┼──► Client DB│
│     │    │  │  └────────────────────┘  │  │            │
│     │    │  │  ┌────────────────────┐  │  │            │
│     │    │  │  │ Tenant B (auto)   │  │  │            │
│     │    │  │  │  QueryAgent       │  │  │            │
│     │    │  │  │  RulesEngine      │  │  │            │
│     │    │  │  │  AutomotiveConntr │──┼──┼──► Client DB│
│     │    │  │  └────────────────────┘  │  │            │
│     │    │  └──────────────────────────┘  │            │
│     │    │                                │            │
└─────┼────┼────────────────────────────────┼────────────┘
      ▼    ▼                                ▼
  Telegram Telegram                    Claude Code /
  (personal) (business clients)     External MCP Clients
```

---

## Layer 6: Autonomous Experiment Loop (autoresearch)

> Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch). See `AUTORESEARCH_PATTERN.md` for full analysis.

A cross-cutting capability: any ExClaw agent can run autonomous experiment loops that propose changes, execute them in sandboxes, evaluate results, and keep or discard — continuously, overnight, unattended.

### Core Loop

```
┌─────────────────────────────────────────────────┐
│                ExClaw Supervisor                 │
│                                                  │
│  ┌───────────┐  ┌───────────┐  ┌─────────────┐  │
│  │ Program   │  │ Experiment│  │ Evaluation   │  │
│  │ Document  │──│ Runner    │──│ & Decision   │  │
│  │ (context) │  │ (sandbox) │  │ (keep/drop)  │  │
│  └───────────┘  └───────────┘  └─────────────┘  │
│        │                              │          │
│        │         ┌──────────┐         │          │
│        └─────────│ State    │─────────┘          │
│                  │ (best so │                    │
│                  │  far)    │                    │
│                  └──────────┘                    │
└─────────────────────────────────────────────────┘
         │                          │
    ┌────▼────┐              ┌──────▼──────┐
    │ Telegram│              │ Knowledge   │
    │ (human  │              │ Base        │
    │  in the │              │ (experiment │
    │  loop)  │              │  history)   │
    └─────────┘              └─────────────┘
```

### The `program.md`-as-Code Paradigm

Agent behaviour is steered by a natural language document, not rigid task definitions. The researcher authors a `program.md` that provides context, defines the objective ("what better means"), sets boundaries (what the agent may/may not change), and describes the experimental protocol. The AI reads this and autonomously decides what to try next.

**Tiered autonomy:** tight constraints in the document = low autonomy; loose constraints = wide exploration. The human controls the surface area by editing the document, not the code.

### OTP Fit

- Each experiment run is a **supervised child process** — crashes don't kill the loop
- The supervisor restarts with the last known-good state
- **Container.Manager** provides sandboxed execution for code/config changes
- **Credential Vault** (Phase A.5) provides scoped lease tokens for experiments needing API access
- **Telegram** surfaces decisions: improvements found, anomalous results, budget exhausted, human input needed

### Applications

Any domain with a measurable outcome, modifiable parameter space, and fast feedback loop:

| Domain | What Changes | Metric | Feedback Time |
|--------|-------------|--------|---------------|
| Prompt engineering | System prompts, few-shot examples | Task accuracy on eval set | Seconds |
| Pipeline optimization | Extraction rules, chunking strategies | F1 score on labeled data | Minutes |
| Infrastructure tuning | vLLM params, batch sizes, quantization | Throughput / latency | Minutes |
| Agent workflow design | Tool selection order, retry strategies | Task completion rate | Minutes |
| Content generation | Templates, tone, structure | Quality score (LLM-as-judge) | Seconds |
| Business rule tuning | Thresholds, conditions, schedules | Alert precision/recall | Minutes |

### Code Generation & Optimization

The experiment loop applied to code is essentially **TDD on autopilot** — the test (metric) is fixed, the agent iterates on the implementation autonomously until it passes or improves. This is the Red-Prompt-Green cycle where the "Prompt" step runs in a closed feedback loop.

The key difference from plain code generation: **the feedback loop is closed.** The agent doesn't generate code and hope — it runs it, measures it, and discards failures automatically. Bad code never leaves the sandbox.

| Goal | What Changes | Metric | Feedback |
|------|-------------|--------|----------|
| Optimize a hot path | Function implementation | Benchmark time (μs) | Seconds |
| Reduce memory usage | Data structures, algorithms | `:erlang.memory()` delta | Seconds |
| Improve test coverage | Generate new test cases | Coverage % on target module | Seconds |
| Fix a failing test | Implementation code | Test pass/fail | Seconds |
| Refactor for readability | Code structure | Credo score, cyclomatic complexity | Seconds |
| API response optimization | Query logic, caching | Response latency p95 | Seconds |
| Cross-compilation fix | Build flags, linker config | Build success on target triple | Minutes |

**Integration with Developer Team agents (Phases C/D):**
- `TestWatchAgent` provides the test results that serve as the evaluation metric
- `CodeContextAgent` provides the codebase understanding the agent needs to propose meaningful changes
- `BuildAgent` provides build success/failure feedback for compilation-targeted experiments
- `ReviewAgent` can evaluate code quality metrics (conventions, security patterns)
- The experiment ledger feeds back into the knowledge base — "what optimization strategies worked for this module?" becomes a searchable history

**Workflow example — overnight performance optimization:**
1. Human writes `program.md`: "Optimize `ExClaw.Memory.Store.semantic_search/4`. Metric: p95 latency on 10K-record dataset. Boundary: don't change the public API. May modify query structure, indexing strategy, batch sizes."
2. ExperimentLoop proposes a change (e.g., add a pre-filter, change the HNSW ef_search parameter)
3. Runs the modified code in Container.Manager sandbox against a benchmark dataset
4. Measures p95 latency — improvement? Keep. Regression? Discard.
5. Repeats overnight. Morning: Telegram summary "Reduced p95 from 45ms to 12ms. 3 changes kept, 7 discarded. Review diff?"

### Components

1. **ExperimentLoop GenServer** — core loop: holds current best state, runs proposals, evaluates, decides. Supervised by OTP.
2. **ProgramDocument behaviour** — parsing and validating program documents. Documents versioned in the knowledge base.
3. **Sandbox execution** — experiment runners execute in isolated contexts via Container.Manager. Code changes: temporary branches or in-memory patches. Config changes: ephemeral process state.
4. **Experiment ledger** — every proposal, result, and decision logged to PostgreSQL. Enables analysis of what changes work, dead-end detection, and human review. Searchable via pgvector (semantic) and AGE (relational).
5. **Notification hooks** — Telegram alerts for: new best found, anomalous result, budget exhausted, human decision needed.

### Integration with Existing Architecture

- **Knowledge Base**: experiment history, results, and program document evolution stored and searchable. "What did we try before for prompt X?" is a vector search.
- **MCP Server**: expose experiment status, history, and control to Claude Code and external tools.
- **Multi-tenancy (Group → Project)**: each client/domain gets isolated experiment loops with their own program documents, state, and budget.
- **Scheduler**: experiment loops can run on cron schedules (nightly optimization runs) or continuously.

### What NOT to Build (Yet)

- Multi-agent swarms competing on the same problem
- Self-modifying program documents (agent rewriting its own steering doc)
- Cross-domain transfer (learnings from one loop informing another)

### Open Questions

- **Rollback granularity**: OTP handles process crashes, but what about data mutations from a bad experiment?
- **Budget/resource limits**: cap GPU time, API calls, or wall-clock time per loop?
- **Convergence detection**: stop on diminishing returns? N consecutive failures?
- **Composability**: nested loops? (Outer loop optimizes program document, inner loop runs experiments)

---

## Build Sequence

### Phase A — Knowledge Base Foundation + Git Mirror
- Group/Project isolation model: platform tables (`groups`, `projects`, `users`), per-project schema pattern (`{group}_{project}`)
- pgvector + AGE schema within first project schema (including `code_files`, `code_chunks`, `test_runs`, `dependencies` tables)
- Embedding pipeline (nomic-embed-text via Ollama)
- Set up bare mirror repos on Spark (`/data/repos/`) with post-receive hooks
- Configure MacBook post-commit hooks to push to Spark over Tailscale
- First group: `wido` (personal). First project: `knowledge-base` with `EmailIngestor` (highest overlap with triage)
- Telegram routing: single-channel with project prefixes for personal group
- Search working end-to-end within a project scope

### Phase B — Email Triage Agent
- Classification pipeline (category, interest match, priority)
- Telegram output with summaries and follow-up recommendations
- Feedback loop: user decisions → `feedback` table → priority model
- Thread-aware priority propagation via AGE graph

### Phase C — Developer Team (Core)
- `LanguageAnalyzer` behaviour + `ElixirAnalyzer` (first implementation, highest overlap with ExClaw development)
- `TestRunner` behaviour + `MixTestRunner` (first implementation)
- `CodeIngestor` — parse, chunk, embed source files; build module/function/dependency graph in AGE
- `CodeContextAgent` — watch repos for changes, keep index fresh
- `TestWatchAgent` — run tests via TestRunner, record results, detect flaky/slow/red patterns
- Telegram output for dev alerts
- **Milestone:** semantic code search works end-to-end via knowledge base, tests run automatically on push

### Phase D — Developer Team (Extended) + Infrastructure
- Additional `LanguageAnalyzer` implementations: `RustAnalyzer`, `GoAnalyzer`, `PythonAnalyzer`, `JavaScriptAnalyzer`, `ZigAnalyzer`
- Additional `TestRunner` implementations: `CargoTestRunner`, `GoTestRunner`, `PytestRunner`, `JestRunner`, `ZigTestRunner`
- `BuildRunner` behaviour + implementations with cross-compilation support
- `BuildAgent` — compilation, cross-compilation, artifact management
- `.exclaw.toml` project configuration support
- Sandboxed execution via ShellSandbox for all test and build operations
- Toolchain management in DeployAgent (rustup, Go, Zig via asdf)
- `ReviewAgent` — async first-pass review on commits/diffs, project-convention-aware
- `DependencyAgent` — monitor Hex/crates.io/npm/PyPI/pkg.go.dev, correlate with codebase graph
- `DocAgent` — generate and maintain living documentation, language-aware doc extraction
- `DeployAgent` — Spark environment monitoring, toolchain management, operational commands
- `BackupAgent` — nightly BorgBackup (pg_dump + config) to Hetzner Storage Box BX11, deduplication, integrity verification, Telegram alerts

### Phase E — MCP Server
- Expose KB, triage state, and developer resources/tools to Claude Code
- Resource and tool definitions (knowledge, email, code, infra namespaces)
- Stdio + HTTP transport implementations
- **Milestone:** "ask Claude about your code/emails/knowledge" workflows work

### Phase F — Remaining Ingestors
- YouTube (yt-dlp transcripts)
- Podcasts (RSS → Whisper transcription on Spark)
- RSS/Blogs (feed fetching, HTML stripping)
- PDFs (text extraction, GLM-OCR for scanned docs)
- Each enriches the same knowledge base

### Phase G — MCP Client
- Agents consuming external MCP servers
- Dynamic tool discovery
- Agent-proposed new MCP connections

### Phase G.5 — Autonomous Experiment Loop
- `ExperimentLoop` GenServer — core propose/execute/evaluate/decide loop, supervised
- `ProgramDocument` behaviour — parse, validate, and version program documents in KB
- Sandbox execution via Container.Manager for isolated experiment runs
- Experiment ledger in PostgreSQL — proposals, results, decisions, searchable via pgvector
- Telegram notification hooks — new best, anomalies, budget exhausted, human decisions
- First application: prompt engineering optimization for Tina's system prompt
- **Milestone:** overnight experiment loop improves a measurable metric autonomously, with full audit trail in KB

### Phase H — Business Intelligence Track (Core)
- `BusinessConnector` behaviour + `PctPanelConnector` (first implementation — streaming service reseller management via pct-panel-skeleton)
- `GenericPostgresConnector` as fallback for systems without dedicated connectors
- `QueryAgent` — natural language to SQL translation, grounded in business data, Telegram interface
- Business domain graph in AGE (resellers, members, users, devices, subscriptions, tiers)
- First commercial group setup: create group, project, schema, Telegram channel, RBAC
- **Milestone:** panel admin asks "how many active users does reseller X have?" in Telegram, gets an accurate answer from the database — running as a project within a group with proper isolation

### Phase I — Business Intelligence Track (Extended)
- `RulesEngine` — standing business rules with scheduled evaluation, Telegram notifications
- Natural language rule creation: "Alert me when any reseller hits 90% of their quota"
- Predefined domain rules per BusinessConnector (quota alerts, inactive device flags, subscription expiry)
- `AutomotiveConnector` — second BusinessConnector for automotive domain (via automotiveMcpServer)
- Multi-tenancy: per-tenant supervision trees, data isolation, deployment models
- RBAC: role-based access control for business users
- Audit logging: full query and action history for compliance
- `RestApiConnector` and `McpConnector` for SaaS and MCP-compatible business systems
- **Milestone:** first paying client deployment — agency revenue begins

---

## Infrastructure

| Component | Location |
|-----------|----------|
| ExClaw runtime | DGX Spark (`ssh spark` / `100.101.119.128`) |
| PostgreSQL + pgvector + AGE | DGX Spark |
| Ollama (embeddings + inference) | DGX Spark |
| Models: Qwen3 32B, nomic-embed-text, GLM-OCR, Whisper | DGX Spark |
| Bare mirror repos | DGX Spark (`/data/repos/*.git`) |
| Build artifacts | DGX Spark (`/data/builds/{project}/{target}/`) |
| Toolchains: Elixir/OTP, Rust, Go, Zig, Python, Node.js | DGX Spark (asdf + rustup) |
| Backup target | Hetzner Storage Box BX11 (1 TB, BorgBackup via SSH, 7d/4w/3m retention) |
| User interface | Telegram (existing agent channel) |
| Dev client | MacBook Air M2 (git push to Spark via Tailscale) |
| Dev access | Claude Code via MCP, SSH via Tailscale |

---

## Key Design Principles

- **OTP-native**: every connection, ingestor, and agent is a supervised process. Crash isolation is the default.
- **Single knowledge base**: all sources — emails, code, docs, feeds — converge on one store. No silos.
- **Learning by default**: every user interaction (triage decisions, searches, bookmarks, test runs, review feedback) feeds back into ranking and prioritization.
- **MCP as the integration layer**: ExClaw both serves and consumes MCP, making it composable with any MCP-compatible tool or client.
- **Local-first / privacy-first**: all processing (embedding, inference, transcription, code indexing) runs on the Spark. No data leaves the network.
- **Agents as teammates, not tools**: developer agents operate autonomously on schedules and triggers, surfacing findings proactively rather than waiting to be asked. The knowledge base is their shared memory.
- **Language-agnostic by design**: all language-specific logic is behind behaviours (`LanguageAnalyzer`, `TestRunner`, `BuildRunner`). Adding a new language means implementing a behaviour, not changing agent code. The same graph, the same test tracking, the same review pipeline work for Elixir, Rust, Go, Zig, Python, and JavaScript.
- **Cross-compilation native**: the Spark builds for any target from ARM64. Zig serves as the cross-compilation backbone. Build targets are configured per-project, artifacts land in a known location, and the full pipeline — build, verify architecture, store artifact — is automated and sandboxed.
- **Compound intelligence via the graph**: the real value is cross-cutting queries that no single tool provides — connecting code health, dependency status, test results, documentation gaps, and infrastructure state through AGE graph traversals.
- **MacBook-independent**: all agents run on the Spark against bare mirror repos. The MacBook is a development client, not a dependency. When it's off, agents continue working on last-pushed state.
- **Recoverable by design**: irreplaceable data (knowledge base, graph, feedback) is backed up nightly via BorgBackup to a dedicated Hetzner Storage Box (1 TB, deduplicated, with built-in snapshots). Everything else (repos, models, build artifacts) is re-pullable from upstream sources. A full Spark rebuild from backup should take hours, not days.
- **Personal track proves the commercial track**: every capability built for the personal platform — supervision, knowledge base, MCP, Telegram, feedback loops, security — transfers directly to business deployments. The personal track is the reference architecture; the commercial track is the same code with different connectors.
- **Addon, not replacement**: the business product doesn't replace existing systems. It sits alongside them, adding conversational AI. Clients keep their software, their database, their workflows. ExClaw adds intelligence on top.
- **Grounded in data, not hallucination**: the QueryAgent never generates business data from the LLM. Natural language translates to structured queries; structured results format back to natural language. The database is the source of truth.
- **Per-tenant isolation via OTP**: groups and projects map to nested supervision trees. Each group is a hard boundary (no cross-group access). Each project gets its own schema, agents, and Telegram channel. Crash isolation, data isolation, and access control are structural properties of the OTP architecture, not application-layer bolt-ons. The personal track and commercial track use the same isolation model.
