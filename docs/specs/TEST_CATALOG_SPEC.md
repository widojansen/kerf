# ExClaw Test Catalog Task — Implementation Spec

## What

A Mix task `mix exclaw.test_catalog` that parses all test files and generates a structured markdown overview of every test in the project. Run it anytime to get an accurate snapshot.

## Usage

```bash
# Full catalog to stdout
mix exclaw.test_catalog

# Write to file
mix exclaw.test_catalog --output TEST_CATALOG.md

# Filter by module/path
mix exclaw.test_catalog --filter credential_vault

# Summary only (counts per module, no individual tests)
mix exclaw.test_catalog --summary
```

## Output Format

```markdown
# ExClaw Test Catalog

Generated: 2026-04-01T12:00:00Z
Total: 623 tests across 28 files

## Summary

| Module | File | Tests |
|--------|------|-------|
| CredentialVault.Backend.LocalEncrypted | test/credential_vault/backend/local_encrypted_test.exs | 16 |
| CredentialVault | test/credential_vault/credential_vault_test.exs | 12 |
| ... | ... | ... |

## Detail

### Security.FileGuard (15 tests)
`test/security/file_guard_test.exs`

- ✓ allows workspace paths
- ✓ allows relative paths
- ✓ blocks path traversal with ..
- ✓ blocks URL-encoded traversal
...

### Security.ShellSandbox (27 tests)
`test/security/shell_sandbox_test.exs`

- ✓ allows ls command
- ✓ blocks rm -rf
...
```

## Implementation

### File: `lib/mix/tasks/exclaw.test_catalog.ex`

```elixir
defmodule Mix.Tasks.Exclaw.TestCatalog do
  @moduledoc "Generate a catalog of all ExClaw tests"
  @shortdoc "Generate test catalog"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    # Parse args: --output FILE, --filter PATTERN, --summary
    # Walk test/ directory
    # Parse each *_test.exs file
    # Extract: describe blocks, test names, @tag annotations
    # Group by module
    # Render markdown
    # Output to stdout or file
  end
end
```

### Parsing Strategy

Use simple regex/string parsing on the test files — no need for full Elixir AST parsing. Extract:

1. `describe "..."` blocks → section headers
2. `test "..."` lines → test names
3. `@tag :skip` or `@tag :integration` → annotations
4. `@moduletag` → module-level tags
5. Top-level `defmodule ... do` → module name

Pattern:
```elixir
# Extract module name
~r/defmodule\s+([\w.]+)\s+do/

# Extract describe blocks
~r/describe\s+"([^"]+)"/

# Extract test names
~r/test\s+"([^"]+)"/

# Extract tags
~r/@tag\s+:(\w+)/
```

### TDD

One test file: `test/mix/tasks/exclaw_test_catalog_test.exs`

Tests should verify:
- Parses a sample test file and extracts correct module, describes, test names
- Counts match actual test count
- `--filter` limits output to matching modules
- `--summary` produces table without individual tests
- `--output` writes to file
- Handles nested describe blocks
- Handles tests outside describe blocks
- Skips non-test .exs files (test_helper.exs, data_case.exs, etc.)

### File Location

```
lib/mix/tasks/exclaw.test_catalog.ex
test/mix/tasks/exclaw_test_catalog_test.exs
```

## No Dependencies

Pure file I/O and string parsing. No new deps needed.
