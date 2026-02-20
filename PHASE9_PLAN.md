# Phase 9: Docker Container-Per-Group Sandboxing

## Context

ExClaw has a complete agent loop (Session + Supervisor), security gates (FileGuard, ShellSandbox, PromptGuard), and a `tool_executor` injection point — but no actual tools. The default executor returns `{:error, "tool not available"}`. This phase adds real tool execution: `shell_exec`, `file_read`, and `file_write`, each running inside isolated Docker containers scoped per group.

**Why Docker?** Tools execute arbitrary LLM-generated code. Process-level isolation isn't enough — we need filesystem, network, and resource isolation. Each group gets its own persistent container with a bind-mounted workspace.

**Container model:** OpenClaw-style persistent containers (`sleep infinity` + `docker exec`) rather than NanoClaw's ephemeral containers. This fits ExClaw's long-lived GenServer sessions — no container startup overhead per command.

## Architecture

```
Agent.Session (tool_executor injected at session creation)
    │
    ▼
Security checks (FileGuard → ShellSandbox → PromptGuard) — unchanged
    │
    ▼
Tools.Dispatcher.dispatch(tool_name, input, opts)
    ├── "shell_exec"  → Tools.Shell.execute  → Container.Manager.exec (docker exec)
    ├── "file_read"   → Tools.FileOps.read   → Host filesystem (bind-mounted workspace)
    └── "file_write"  → Tools.FileOps.write  → Host filesystem (bind-mounted workspace)

Container.Manager (GenServer)
    ├── tracks containers map: %{group_id => %{name, created_at}}
    ├── ensure_container: lazy create on first use
    ├── exec: docker exec inside group's container
    ├── cleanup: docker rm -f
    └── cleanup_all: on terminate (app shutdown)
```

File operations use the bind mount directly on the host (simpler, faster, testable without Docker). Shell commands go through `docker exec`.

## New Files

| File | Module | Purpose |
|------|--------|---------|
| `lib/exclaw/container/manager.ex` | `ExClaw.Container.Manager` | GenServer: container lifecycle per group |
| `lib/exclaw/container/supervisor.ex` | `ExClaw.Container.Supervisor` | Supervises Manager |
| `lib/exclaw/tools/dispatcher.ex` | `ExClaw.Tools.Dispatcher` | Routes tool calls, builds `tool_executor` closure |
| `lib/exclaw/tools/shell.ex` | `ExClaw.Tools.Shell` | `shell_exec` tool via `docker exec` |
| `lib/exclaw/tools/file_ops.ex` | `ExClaw.Tools.FileOps` | `file_read`/`file_write` via bind-mounted workspace |
| `container/Dockerfile` | — | Sandbox image: `debian:bookworm-slim` + tools |
| `test/container/manager_test.exs` | — | ~13 tests (mock docker adapter) |
| `test/container/supervisor_test.exs` | — | ~3 tests |
| `test/tools/shell_test.exs` | — | ~5 tests |
| `test/tools/file_ops_test.exs` | — | ~7 tests |
| `test/tools/dispatcher_test.exs` | — | ~6 tests |
| `test/container/integration/container_integration_test.exs` | — | ~10 tests (requires Docker, tagged `:docker`) |

## Files to Modify

| File | Change |
|------|--------|
| `lib/exclaw/application.ex` | Add `Container.Supervisor` after Security, before LLM |
| `lib/exclaw/channels/cli.ex` | Inject `tool_executor` + `tools` in `process_input/3` |
| `config/config.exs` | Add `Container.Manager` config |
| `config/test.exs` | Add test config (mock docker, no real containers) |
| `test/test_helper.exs` | Add `ExUnit.configure(exclude: [:docker])` |
| `CLAUDE.md` | Document Phase 9 |

## Module Contracts

### Container.Manager

```elixir
Manager.start_link(opts)
# opts: [name:, workspaces_dir:, image:, docker_adapter:, container_opts:, exec_timeout:]

Manager.ensure_container(name \\ __MODULE__, group_id)
# => {:ok, container_name} | {:error, reason}
# Idempotent: creates if missing, verifies if tracked, recreates if dead

Manager.exec(name \\ __MODULE__, group_id, command, opts \\ [])
# => {:ok, stdout} | {:error, reason}
# Calls ensure_container first, then docker exec sh -c <command>
# opts: [timeout: ms]

Manager.cleanup(name \\ __MODULE__, group_id)
# => :ok  (removes container + deletes from map)

Manager.cleanup_all(name \\ __MODULE__)
# => :ok  (removes all managed containers)

Manager.list_containers(name \\ __MODULE__)
# => {:ok, [%{group_id: _, container_name: _, created_at: _}]}
```

**State:** `%{containers: %{}, workspaces_dir: path, image: str, docker_adapter: fun, container_opts: kw, exec_timeout: ms, max_output_size: int}`

**Docker adapter injection:** Instead of calling `System.cmd("docker", args)` directly, the Manager calls `state.docker_adapter.(args)` which returns `{stdout, exit_code}`. Default adapter: `fn args -> System.cmd("docker", args, stderr_to_stdout: true) end`. Tests inject a mock.

### Tools.Dispatcher

```elixir
Dispatcher.build_executor(opts)
# opts: [container_manager: atom(), group_id: String.t()]
# => fn(tool_name, input) -> {:ok, result} | {:error, reason}

Dispatcher.dispatch(tool_name, input, opts)
# Routes to Shell.execute/2, FileOps.read/2, FileOps.write/2
# Unknown tool => {:error, "unknown tool: #{tool_name}"}

Dispatcher.tool_definitions()
# => [%{name: "shell_exec", ...}, %{name: "file_read", ...}, %{name: "file_write", ...}]
# Anthropic tool schema format
```

### Tools.Shell

```elixir
Shell.execute(input, opts)
# input: %{"command" => str} (string-keyed from Anthropic)
# opts: [container_manager: atom(), group_id: str, timeout: ms]
# => {:ok, output} | {:error, reason}
# Output truncated at max_output_size (100KB default)
```

### Tools.FileOps

```elixir
FileOps.read(input, opts)
# input: %{"path" => str}
# opts: [workspaces_dir: str, group_id: str]
# => {:ok, content} | {:error, reason}
# Reads from host: workspaces_dir/{safe_group_id}/{path}
# Path traversal check: resolved path must stay inside workspace

FileOps.write(input, opts)
# input: %{"path" => str, "content" => str}
# opts: [workspaces_dir: str, group_id: str]
# => {:ok, "file written"} | {:error, reason}
# Writes to host: workspaces_dir/{safe_group_id}/{path}
# Creates intermediate directories
```

## Docker Security Constraints

```
docker create --name exclaw-{safe_id}
  --read-only                              # immutable root filesystem
  --tmpfs /tmp:rw,noexec,nosuid,size=256m  # writable temp only
  --cap-drop ALL                           # no Linux capabilities
  --security-opt no-new-privileges         # no privilege escalation
  --network none                           # no network access
  --memory 512m                            # memory limit
  --cpus 1                                 # CPU limit
  --pids-limit 256                         # fork bomb protection
  --user 1000:1000                         # non-root
  -v {workspace_path}:/workspace           # per-group workspace
  -w /workspace                            # working directory
  exclaw-sandbox:latest
  sleep infinity                           # keep alive for docker exec
```

## Container Lifecycle

1. **Create** (on first tool call for group): sanitize group_id → create workspace dir → `docker create` + `docker start`
2. **Exec** (each shell command): `ensure_container` → `docker exec {name} sh -c {command}`
3. **Health check** (in `ensure_container`): `docker inspect -f {{.State.Running}}` — recreate if dead
4. **Cleanup** (on session end or explicit): `docker rm -f` → remove from map
5. **App shutdown** (`terminate/2`): `cleanup_all` — remove all managed containers

## Configuration

```elixir
# config/config.exs
config :exclaw, ExClaw.Container.Manager,
  workspaces_dir: "priv/workspaces",
  image: "exclaw-sandbox:latest",
  exec_timeout: 30_000,
  max_output_size: 102_400,
  container_opts: [
    read_only: true, network: "none", memory: "512m", cpus: "1",
    pids_limit: 256, cap_drop: ["ALL"],
    security_opt: ["no-new-privileges"],
    tmpfs: ["/tmp:rw,noexec,nosuid,size=256m"], user: "1000:1000"
  ]

# config/test.exs
config :exclaw, ExClaw.Container.Manager,
  workspaces_dir: "priv/workspaces/test",
  exec_timeout: 5_000
```

## TDD Implementation Order

### Phase 9a: Container Manager (core)
1. **RED:** Write `test/container/manager_test.exs` (~13 tests with mock docker adapter)
2. **GREEN:** Implement `lib/exclaw/container/manager.ex`
3. **RED:** Write `test/container/supervisor_test.exs` (~3 tests)
4. **GREEN:** Implement `lib/exclaw/container/supervisor.ex`

### Phase 9b: Tools (Shell + FileOps + Dispatcher)
5. **RED:** Write `test/tools/file_ops_test.exs` (~7 tests, temp dirs, no Docker)
6. **GREEN:** Implement `lib/exclaw/tools/file_ops.ex`
7. **RED:** Write `test/tools/shell_test.exs` (~5 tests, mock Manager)
8. **GREEN:** Implement `lib/exclaw/tools/shell.ex`
9. **RED:** Write `test/tools/dispatcher_test.exs` (~6 tests)
10. **GREEN:** Implement `lib/exclaw/tools/dispatcher.ex`

### Phase 9c: Wiring + Infrastructure
11. Add config to `config/*.exs`
12. Add `Container.Supervisor` to `application.ex`
13. Modify `cli.ex` to inject `tool_executor` + `tools`
14. Add `ExUnit.configure(exclude: [:docker])` to `test_helper.exs`
15. Run `mix test` — all 238+ existing tests still pass

### Phase 9d: Dockerfile + Integration
16. Create `container/Dockerfile`
17. Write `test/container/integration/container_integration_test.exs` (~10 tests, tagged `:docker`)
18. Build image: `docker build -t exclaw-sandbox:latest container/`
19. Run integration: `mix test --include docker`

## Verification

1. `mix test` — all existing 238+ tests pass, new unit tests pass (~34 new tests)
2. `mix test --include docker` — integration tests pass (requires Docker + built image)
3. Manual: `ANTHROPIC_API_KEY=... mix exclaw.cli` → ask LLM to run `ls`, create a file, read it back
4. Security: verify container is read-only, no network, non-root via integration tests
