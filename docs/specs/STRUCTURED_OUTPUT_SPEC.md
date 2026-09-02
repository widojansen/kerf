# ExClaw Structured Output — Implementation Spec (Phase A.5)

## Context

The Structured Output module is the third and final Phase A.5 component. It ensures that LLM responses from vLLM can be constrained to specific schemas — JSON objects, enums, regex patterns — and validated before agents act on them. This is critical for the Email Triage Agent (Phase B), which needs reliable structured classifications (category, priority score, action recommendation) from every LLM call.

vLLM supports grammar-constrained decoding via `guided_json`, `guided_choice`, `guided_regex`, and `guided_grammar` parameters passed as `extra_body` in the OpenAI-compatible API. It also supports the standard OpenAI `response_format` with `json_schema`. ExClaw's Structured Output module wraps this capability with a schema registry, defense-in-depth validation, and retry-with-feedback on parse failures.

This spec is designed for Claude Code to implement using Red-Prompt-Green-Refactor TDD.

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│  ┌───────────────────┐  ┌──────────────────────────────┐ │
│  │ SchemaRegistry    │  │ Validator                    │ │
│  │ (GenServer)       │  │ (pure module)                │ │
│  │                   │  │                              │ │
│  │ Stores named      │  │ Validates parsed data        │ │
│  │ schemas as JSON   │  │ against registered schemas.  │ │
│  │ Schema + Elixir   │  │ Returns {:ok, data} or       │ │
│  │ type coercions    │  │ {:error, errors}             │ │
│  └───────────────────┘  └──────────────────────────────┘ │
│                                                          │
│  ┌──────────────────────────────────────────────────────┐ │
│  │ StructuredOutput (facade module)                     │ │
│  │                                                      │ │
│  │ complete/4 — calls VLLMProvider with guided_json,    │ │
│  │ parses JSON, validates, retries on failure           │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌──────────────────────────────────────────────────────┐ │
│  │ VLLMProvider extensions                              │ │
│  │                                                      │ │
│  │ complete/4 opts now accepts:                         │ │
│  │   guided_json: json_schema                           │ │
│  │   guided_choice: [choices]                           │ │
│  │   guided_regex: regex_string                         │ │
│  │   response_format: %{type: "json_schema", ...}      │ │
│  │                                                      │ │
│  │ These are passed as extra_body to vLLM               │ │
│  └──────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

## Design Decisions

### 1. Schema Definition: JSON Schema + Elixir Coercions

Schemas are defined as JSON Schema objects (the standard vLLM understands) with optional Elixir-side coercion rules. The JSON Schema is sent to vLLM for grammar-constrained decoding. The Elixir coercion rules handle type conversion after parsing (e.g., string "3" to integer 3, ISO date string to DateTime).

This means vLLM enforces structure at the token level (the LLM can't generate invalid JSON), and ExClaw validates and coerces after parsing (defense-in-depth).

### 2. Retry with Feedback

If the LLM output fails validation despite grammar constraints (rare but possible with complex schemas), the Structured Output module retries up to N times. Each retry includes the validation errors in the prompt as feedback, giving the LLM a chance to self-correct. Default: 2 retries (3 total attempts).

### 3. Provider-Agnostic with vLLM Optimization

The `StructuredOutput.complete/4` function works with any provider (Anthropic, Ollama, vLLM). For vLLM, it passes `guided_json` in `extra_body` for grammar-constrained decoding. For Anthropic/Ollama, it adds JSON schema instructions to the system prompt and relies on post-parse validation only. The caller doesn't need to know which provider is being used.

### 4. SchemaRegistry as GenServer vs. Module

**Decision: GenServer with ETS cache.**

Schemas can be registered at startup (compile-time) or dynamically at runtime (e.g., an agent registering a new schema for a new email classification category). The GenServer stores schemas in ETS for fast concurrent read access. Most agents will register schemas once at startup and then read them on every LLM call.

## Module Contracts

### ExClaw.StructuredOutput (facade module)

```elixir
@moduledoc """
High-level API for getting structured LLM responses.
Handles provider selection, guided decoding, parsing, validation, and retry.
"""

# Get a structured response from the LLM
@spec complete(schema_name, model, messages, opts) ::
  {:ok, validated_data} | {:error, reason}
# schema_name: atom — registered schema name (e.g., :email_classification)
# model: String.t() — model name passed to ModelRouter
# messages: [map()] — conversation messages
# opts: [
#   system: String.t(),         # system prompt
#   max_retries: non_neg_integer(),  # default: 2
#   provider: atom(),           # override provider (default: auto-detect from model)
#   temperature: float(),       # default: 0.1 for structured output
#   max_tokens: pos_integer()   # default: from schema or 2048
# ]
#
# Behavior:
# 1. Look up schema from SchemaRegistry
# 2. If provider is vLLM: add guided_json to opts
#    If provider is Anthropic/Ollama: add JSON instructions to system prompt
# 3. Call ModelRouter.complete/4 (or specific provider)
# 4. Parse JSON from response content (strip ```json fences, <think> tags, etc.)
# 5. Validate against schema using Validator
# 6. Apply coercions
# 7. On validation failure: retry with error feedback (up to max_retries)
# 8. Return {:ok, validated_map} or {:error, reason}

# Shortcut: complete with inline schema (not registered)
@spec complete_with_schema(json_schema, model, messages, opts) ::
  {:ok, validated_data} | {:error, reason}
```

### ExClaw.StructuredOutput.SchemaRegistry (GenServer)

```elixir
# Register a named schema
@spec register(registry, schema_name, schema_def) :: :ok | {:error, reason}
# schema_def:
#   %{
#     json_schema: map(),           # Standard JSON Schema object
#     coercions: keyword(),         # Optional: [{field, coercion_type}]
#     description: String.t(),      # Human-readable, included in prompts
#     max_tokens: pos_integer()     # Suggested max_tokens for this schema
#   }
# coercion_type: :integer | :float | :boolean | :datetime | :date | :atom
#   | {:list, inner_type} | {:enum, [atom()]}

# Get a registered schema
@spec get(registry, schema_name) :: {:ok, schema_def} | {:error, :not_found}

# List all registered schemas
@spec list(registry) :: [{schema_name, schema_def}]

# Deregister a schema
@spec deregister(registry, schema_name) :: :ok

# Register multiple schemas at once (for startup)
@spec register_all(registry, [{schema_name, schema_def}]) :: :ok
```

### ExClaw.StructuredOutput.Validator (pure module)

```elixir
# Validate parsed data against a JSON schema
@spec validate(data, json_schema) :: :ok | {:error, [validation_error]}
# validation_error: %{path: String.t(), message: String.t(), value: term()}
#
# Validates:
# - Required fields present
# - Type checking (string, integer, number, boolean, array, object)
# - Enum constraints
# - Minimum/maximum for numbers
# - MinLength/maxLength for strings
# - MinItems/maxItems for arrays
# - Nested object validation (recursive)
# - Pattern matching (regex on strings)

# Apply coercions to validated data
@spec coerce(data, coercions) :: {:ok, coerced_data} | {:error, [coercion_error]}
# Coerces string values to target types based on the coercion rules.
# E.g., %{"priority" => "3"} with coercion [priority: :integer] → %{"priority" => 3}

# Validate and coerce in one call
@spec validate_and_coerce(data, json_schema, coercions) ::
  {:ok, coerced_data} | {:error, [error]}
```

### ExClaw.StructuredOutput.JSONParser (pure module)

```elixir
# Extract and parse JSON from LLM response content
@spec parse(content) :: {:ok, map() | list()} | {:error, reason}
# Handles:
# - Raw JSON string
# - JSON wrapped in ```json ... ``` fences
# - JSON preceded by <think>...</think> tags (vLLM/Qwen thinking)
# - JSON with trailing text after the closing } or ]
# - Multiple JSON objects (takes the first valid one)
```

### VLLMProvider Extension

The existing `VLLMProvider.complete/4` opts need to pass through structured output parameters to vLLM's `extra_body`. Add support for these keys in opts:

```elixir
# In build_request_body/4, when opts contain structured output keys:
# opts[:guided_json]   → extra_body: %{"guided_json" => schema}
# opts[:guided_choice] → extra_body: %{"guided_choice" => choices}
# opts[:guided_regex]  → extra_body: %{"guided_regex" => pattern}
# opts[:response_format] → top-level response_format field
```

This is a small change to the existing VLLMProvider — just pass through the extra keys.

## Example Usage

### Defining a Schema (Email Classification)

```elixir
# In the EmailTriageAgent's init/1:
ExClaw.StructuredOutput.SchemaRegistry.register(
  ExClaw.StructuredOutput.SchemaRegistry,
  :email_classification,
  %{
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "category" => %{
          "type" => "string",
          "enum" => ["business", "personal", "newsletter", "transactional", "spam"]
        },
        "priority" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 5
        },
        "summary" => %{
          "type" => "string",
          "maxLength" => 500
        },
        "action" => %{
          "type" => "string",
          "enum" => ["follow_up", "archive", "flag", "ignore"]
        },
        "confidence" => %{
          "type" => "number",
          "minimum" => 0.0,
          "maximum" => 1.0
        }
      },
      "required" => ["category", "priority", "summary", "action", "confidence"],
      "additionalProperties" => false
    },
    coercions: [priority: :integer, confidence: :float],
    description: "Classify an email by category, priority (1-5), and recommended action",
    max_tokens: 512
  }
)
```

### Getting a Structured Response

```elixir
{:ok, classification} = ExClaw.StructuredOutput.complete(
  :email_classification,
  "nvidia/Qwen3-32B-NVFP4",
  [%{role: "user", content: "Classify this email:\n\n#{email_body}"}],
  system: "You are an email classifier. Respond with JSON matching the schema."
)

# classification is a validated, coerced map:
# %{
#   "category" => "business",
#   "priority" => 3,
#   "summary" => "Invoice from supplier regarding Q2 delivery",
#   "action" => "follow_up",
#   "confidence" => 0.92
# }
```

## Built-in Schemas

Register these at application startup for common ExClaw use cases:

```elixir
# :yes_no — simple binary decision
%{
  json_schema: %{
    "type" => "object",
    "properties" => %{
      "decision" => %{"type" => "string", "enum" => ["yes", "no"]},
      "reason" => %{"type" => "string"}
    },
    "required" => ["decision", "reason"]
  },
  coercions: [],
  description: "A yes/no decision with reasoning"
}

# :priority_score — numeric priority with explanation
%{
  json_schema: %{
    "type" => "object",
    "properties" => %{
      "score" => %{"type" => "integer", "minimum" => 1, "maximum" => 10},
      "factors" => %{"type" => "array", "items" => %{"type" => "string"}},
      "explanation" => %{"type" => "string"}
    },
    "required" => ["score", "factors", "explanation"]
  },
  coercions: [score: :integer],
  description: "A priority score from 1-10 with contributing factors"
}

# :entity_extraction — extract named entities
%{
  json_schema: %{
    "type" => "object",
    "properties" => %{
      "entities" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string"},
            "type" => %{"type" => "string", "enum" => ["person", "organization", "location", "date", "amount"]},
            "value" => %{"type" => "string"}
          },
          "required" => ["name", "type", "value"]
        }
      }
    },
    "required" => ["entities"]
  },
  coercions: [],
  description: "Extract named entities from text"
}
```

## TDD Build Sequence

### Step 1: JSONParser (pure functions)

RED: Write tests for JSON extraction from various LLM output formats.
GREEN: Implement the parser.
Tests should verify:
- Raw JSON string parses correctly
- JSON wrapped in ```json fences parses correctly
- JSON preceded by `<think>...</think>` tags parses correctly
- JSON with trailing text after closing brace parses correctly
- Invalid JSON returns {:error, reason} with useful message
- Empty string returns error
- Multiple JSON objects: first valid one is returned
- Handles both map and list top-level JSON
- Handles escaped characters, unicode, nested objects

### Step 2: Validator (pure functions)

RED: Write tests for JSON Schema validation and coercion.
GREEN: Implement the validator.
Tests should verify:
- Required field missing returns error with field path
- Type checking: string, integer, number, boolean, array, object
- Enum constraint violations
- Min/max for numbers
- MinLength/maxLength for strings
- MinItems/maxItems for arrays
- Nested object validation (recursive)
- Pattern matching (regex on string fields)
- additionalProperties: false rejects extra fields
- Coercion: string "3" → integer 3
- Coercion: string "true" → boolean true
- Coercion: string "2026-03-31" → Date
- Coercion: string "2026-03-31T12:00:00Z" → DateTime
- Coercion: {:enum, [:a, :b]} converts string to atom
- Coercion failure returns error
- validate_and_coerce/3 chains both operations

### Step 3: SchemaRegistry (GenServer)

RED: Write tests for registration, lookup, deregistration.
GREEN: Implement GenServer with ETS.
Tests should verify:
- Register a schema and retrieve it
- List returns all registered schemas
- Deregister removes the schema
- register_all/2 registers multiple at once
- Duplicate registration overwrites (upsert)
- get/2 on non-existent returns {:error, :not_found}
- Concurrent reads work (ETS is public read)
- Invalid schema definition is rejected (missing json_schema key)

### Step 4: VLLMProvider Extension

RED: Write tests for structured output parameter passthrough.
GREEN: Extend build_request_body to include extra_body params.
Tests should verify:
- opts[:guided_json] appears in request body as `extra_body.guided_json` (older vLLM) or `guided_json` at top level
- opts[:guided_choice] appears correctly
- opts[:guided_regex] appears correctly
- opts[:response_format] appears as top-level field
- Normal requests (no structured output opts) are unchanged (no regression)
- Structured output opts coexist with tool definitions

### Step 5: StructuredOutput Facade

RED: Write tests for the complete/4 flow including retry.
GREEN: Implement the facade module.
Tests should verify:
- Happy path: schema found → LLM returns valid JSON → validated → returned
- Auto-detect provider: vLLM model gets guided_json, Anthropic model gets prompt injection
- JSON parse failure triggers retry with error in prompt
- Validation failure triggers retry with validation errors in prompt
- Max retries exhausted returns {:error, {:validation_failed, errors}}
- complete_with_schema/4 works without registration
- Temperature defaults to 0.1 for structured output calls
- system prompt is augmented with schema description

Use Mox or test adapters for the LLM provider calls.

### Step 6: Built-in Schemas + Integration

RED: Write integration tests for built-in schemas and full lifecycle.
GREEN: Register built-in schemas at startup, integration tests.
Tests should verify:
- Built-in schemas (:yes_no, :priority_score, :entity_extraction) are registered on startup
- Full lifecycle with mocked provider: register → complete → validate → coerce → return
- SchemaRegistry survives process restart (schemas re-registered from config)
- Application.ex starts SchemaRegistry as part of the supervision tree

## Integration with Existing ExClaw

### Application.ex

Add `SchemaRegistry` to the supervision tree. It's a lightweight GenServer that should start early:

```elixir
defp structured_output_children do
  [{ExClaw.StructuredOutput.SchemaRegistry, [name: ExClaw.StructuredOutput.SchemaRegistry]}]
end
```

Always started (no config toggle needed — it's pure infrastructure with no external dependencies).

### Config

```elixir
# config/config.exs
config :exclaw, ExClaw.StructuredOutput,
  default_max_retries: 2,
  default_temperature: 0.1,
  register_builtins: true  # register :yes_no, :priority_score, :entity_extraction at startup
```

### File Locations

```
lib/exclaw/structured_output/
├── structured_output.ex          # Facade module (complete/4)
├── schema_registry.ex            # GenServer + ETS
├── validator.ex                  # Pure validation functions
├── json_parser.ex                # Pure JSON extraction

test/structured_output/
├── structured_output_test.exs    # Facade integration tests
├── schema_registry_test.exs
├── validator_test.exs
├── json_parser_test.exs

# VLLMProvider modification:
lib/exclaw/llm/vllm_provider.ex   # Extended (existing file)
test/llm/vllm_provider_test.exs   # Extended (existing file)
```

## Dependencies

No new dependencies. Uses:
- `Jason` (already in deps) — JSON parsing
- `Req` (already in deps, via VLLMProvider) — HTTP to vLLM
- ETS — schema cache
- `Regex` (stdlib) — pattern validation and JSON extraction

## Open for Future

- MCP exposure: `schema.list`, `schema.register`, `structured_output.complete` as MCP tools
- Schema versioning: track schema changes over time for backward compatibility
- Streaming structured output: parse partial JSON as it streams from vLLM
- Schema inference: given example outputs, generate a JSON Schema automatically
- Anthropic native structured output: when Anthropic adds json_schema support, use it directly
- Metrics: track validation success/failure rates per schema for quality monitoring
