# ExClaw Structured Output Validation — Design Document

> **Status:** Draft — LLM response validation subsystem
> **Date:** 2026-03-31
> **Depends on:** LLM.VLLMProvider, Agent.Session, ModelRouter
> **Inspired by:** OpenClaw Lobster's `llm-task` tool, which enforces JSON Schema on LLM outputs. ExClaw adopts the same constraint pattern but integrates it at the provider level rather than as an external tool wrapper.

---

## Problem

ExClaw agents call vLLM (Qwen3-32B) for classification, summarization, and decision-making. Today, the LLM response is treated as opaque text — the agent parses it ad-hoc and hopes the format is correct. When the model returns malformed JSON, unexpected keys, or free-text instead of structured data, the agent either crashes or silently produces wrong results.

OpenClaw's Lobster solved this with a dedicated `llm-task` tool that accepts a JSON Schema and validates the model output against it before returning to the pipeline. This is the right idea — but ExClaw can integrate it deeper: at the VLLMProvider level, so every agent gets validated structured output without wrapping calls in an external tool.

vLLM already supports structured output via its OpenAI-compatible API (`response_format` parameter with `json_schema` type). ExClaw just needs to wire it up and add validation on the response side.

---

## Design Principles

1. **Schema is declared at call time.** The agent passes a JSON Schema with each LLM request that expects structured output. Plain text requests are unaffected.
2. **Validation is at the provider level.** VLLMProvider validates the response before returning to the agent. Invalid responses are retried or rejected — never silently passed through.
3. **vLLM does the heavy lifting.** The `response_format` parameter tells vLLM to constrain token generation to valid JSON matching the schema. ExClaw validates the result as defense-in-depth.
4. **Retry with feedback.** On validation failure, the provider can retry once with the validation error appended to the prompt, giving the model a chance to self-correct.
5. **Schema registry for reuse.** Common schemas (email classification, priority scoring, code review findings) are registered once and referenced by name.

---

## Architecture

```
Agent.Session
     |
     |  chat(messages, tools: [], response_schema: :email_classification)
     |
     v
ModelRouter
     |
     |  Routes to VLLMProvider (or OllamaProvider, AnthropicProvider)
     |
     v
VLLMProvider
     |
     |  1. Resolves schema (name → JSON Schema map)
     |  2. Adds response_format to vLLM request body
     |  3. Sends to vLLM /v1/chat/completions
     |  4. Parses JSON response
     |  5. Validates against schema (defense-in-depth)
     |  6. On failure: retry once with error context, or return {:error, :schema_validation_failed}
     |  7. Returns {:ok, %{type: :structured, data: validated_map}}
     |
     v
Agent.Session (receives validated, typed data)
```

---

## Module Contracts

### `ExClaw.LLM.StructuredOutput` (Schema Registry)

A simple GenServer that holds named schemas. Schemas are registered at application boot from a config file or inline definitions.

```elixir
defmodule ExClaw.LLM.StructuredOutput do
  @moduledoc """
  Registry for JSON Schemas used in structured LLM output.
  Schemas are referenced by name in LLM calls.
  """

  use GenServer

  # Register a named schema
  def register(name, json_schema) when is_atom(name) and is_map(json_schema)

  # Resolve a name to its schema
  def resolve(name) :: {:ok, map()} | {:error, :not_found}

  # Resolve, or pass through a raw schema map
  def resolve!(name_or_schema)

  # List registered schemas
  def list() :: [atom()]
end
```

### Schema Registration (at boot)

```elixir
# In application.ex or a dedicated schema config module
StructuredOutput.register(:email_classification, %{
  "type" => "object",
  "properties" => %{
    "category" => %{
      "type" => "string",
      "enum" => ["business", "personal", "newsletter", "transactional", "spam"]
    },
    "priority" => %{
      "type" => "number",
      "minimum" => 0,
      "maximum" => 1
    },
    "summary" => %{
      "type" => "string",
      "maxLength" => 500
    },
    "follow_up" => %{
      "type" => "boolean"
    },
    "reasoning" => %{
      "type" => "string"
    }
  },
  "required" => ["category", "priority", "summary", "follow_up"],
  "additionalProperties" => false
})

StructuredOutput.register(:code_review_findings, %{
  "type" => "object",
  "properties" => %{
    "findings" => %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "severity" => %{"type" => "string", "enum" => ["suggestion", "warning", "issue"]},
          "file" => %{"type" => "string"},
          "line" => %{"type" => "integer"},
          "message" => %{"type" => "string"},
          "category" => %{"type" => "string", "enum" => ["style", "bug", "security", "performance", "test_coverage"]}
        },
        "required" => ["severity", "message", "category"]
      }
    },
    "summary" => %{"type" => "string"},
    "overall_assessment" => %{"type" => "string", "enum" => ["clean", "minor_issues", "needs_work", "blocking"]}
  },
  "required" => ["findings", "summary", "overall_assessment"],
  "additionalProperties" => false
})

StructuredOutput.register(:priority_score, %{
  "type" => "object",
  "properties" => %{
    "score" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
    "factors" => %{
      "type" => "array",
      "items" => %{"type" => "string"}
    },
    "action" => %{"type" => "string", "enum" => ["urgent", "follow_up", "read_later", "archive", "ignore"]}
  },
  "required" => ["score", "action"],
  "additionalProperties" => false
})

StructuredOutput.register(:query_plan, %{
  "type" => "object",
  "properties" => %{
    "intent" => %{"type" => "string", "enum" => ["data_query", "lookup", "analysis", "validation", "action", "rule_setup", "report"]},
    "sql" => %{"type" => "string"},
    "parameters" => %{"type" => "object"},
    "explanation" => %{"type" => "string"},
    "requires_approval" => %{"type" => "boolean"}
  },
  "required" => ["intent", "sql", "explanation", "requires_approval"],
  "additionalProperties" => false
})
```

### VLLMProvider Changes

The existing `VLLMProvider` GenServer gains structured output support:

```elixir
# Current call (unchanged for plain text):
VLLMProvider.chat(messages, model: "qwen3-32b")
# => {:ok, %{type: :text, content: "..."}}

# New: structured output call
VLLMProvider.chat(messages,
  model: "qwen3-32b",
  response_schema: :email_classification  # name or inline schema map
)
# => {:ok, %{type: :structured, data: %{"category" => "business", "priority" => 0.8, ...}}}
# => {:error, :schema_validation_failed, %{errors: [...], raw_response: "..."}}
```

### vLLM Request Format

When `response_schema` is provided, VLLMProvider adds `response_format` to the request body:

```json
{
  "model": "nvidia/Qwen3-32B-NVFP4",
  "messages": [...],
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "email_classification",
      "strict": true,
      "schema": {
        "type": "object",
        "properties": { ... },
        "required": [...],
        "additionalProperties": false
      }
    }
  }
}
```

vLLM uses this to constrain token generation — the model can only produce tokens that result in valid JSON matching the schema. This is not post-hoc validation; it is grammar-constrained decoding.

---

## Validation Layer (Defense-in-Depth)

Even though vLLM constrains generation, ExClaw validates the parsed response:

```elixir
defmodule ExClaw.LLM.StructuredOutput.Validator do
  @moduledoc """
  Validates parsed JSON against a JSON Schema.
  Defense-in-depth: vLLM should produce valid output,
  but we verify before passing to agents.
  """

  @doc """
  Validates a parsed map against a JSON Schema.
  Returns {:ok, data} or {:error, errors}.
  """
  @spec validate(map(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(data, schema)

  @doc """
  Validates and coerces types where safe (e.g., string "0.8" to float 0.8).
  """
  @spec validate_and_coerce(map(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate_and_coerce(data, schema)
end
```

Validation checks:
- Required fields present
- Field types match (string, number, boolean, array, object)
- Enum values are in the allowed set
- Number ranges (minimum/maximum)
- String constraints (maxLength, pattern)
- Array item schemas
- No additional properties when `additionalProperties: false`

### Retry on Failure

If validation fails (should be rare with vLLM grammar-constrained decoding), VLLMProvider retries once:

```elixir
# Pseudocode inside VLLMProvider
case validate(parsed_json, schema) do
  {:ok, data} ->
    {:ok, %{type: :structured, data: data}}

  {:error, errors} when retries_left > 0 ->
    # Append error context and retry
    retry_message = %{
      role: "user",
      content: "Your previous response had validation errors: #{inspect(errors)}. " <>
               "Please respond again with valid JSON matching the schema."
    }
    chat(messages ++ [retry_message], opts |> Map.put(:retries_left, 0))

  {:error, errors} ->
    {:error, :schema_validation_failed, %{errors: errors, raw: raw_response}}
end
```

---

## Provider Abstraction

The structured output interface is provider-agnostic. Each provider implements it differently:

| Provider | Mechanism | Constraint Level |
|----------|-----------|-----------------|
| **VLLMProvider** | `response_format.json_schema` — grammar-constrained decoding | Token-level (strongest) |
| **OllamaProvider** | `format: "json"` + schema in system prompt | Prompt-level (weaker, validate strictly) |
| **AnthropicProvider** | Tool use with input_schema (force tool call) | Tool-level (strong) |

The `Provider` behaviour gains an optional callback:

```elixir
@callback supports_structured_output?() :: boolean()
@callback structured_output_mechanism() :: :grammar | :prompt | :tool | :none
```

ModelRouter uses this to decide whether to trust the provider's output or add extra validation.

---

## Agent Usage Examples

### Email Triage (Phase B)

```elixir
def classify_email(email) do
  messages = [
    %{role: "system", content: "Classify this email. Respond with JSON only."},
    %{role: "user", content: "From: #{email.from}\nSubject: #{email.subject}\n\n#{email.body}"}
  ]

  {:ok, %{data: classification}} = LLM.chat(messages,
    response_schema: :email_classification
  )

  # classification is a validated map — safe to pattern match
  %{"category" => category, "priority" => priority, "follow_up" => follow_up?} = classification
end
```

### Code Review (Phase C)

```elixir
def review_diff(diff, conventions) do
  messages = [
    %{role: "system", content: "Review this code diff against the given conventions."},
    %{role: "user", content: "Conventions:\n#{conventions}\n\nDiff:\n#{diff}"}
  ]

  {:ok, %{data: review}} = LLM.chat(messages,
    response_schema: :code_review_findings
  )

  # review.findings is guaranteed to be a list of properly-typed finding maps
end
```

### Business Query (Phase H)

```elixir
def translate_query(natural_language, schema_context) do
  messages = [
    %{role: "system", content: "Translate this natural language query to SQL. Schema: #{schema_context}"},
    %{role: "user", content: natural_language}
  ]

  {:ok, %{data: plan}} = LLM.chat(messages,
    response_schema: :query_plan
  )

  # plan.requires_approval triggers ApprovalGate if true
  if plan["requires_approval"] do
    ApprovalGate.Manager.request_approval(...)
  else
    execute_query(plan["sql"], plan["parameters"])
  end
end
```

---

## Relationship to ApprovalGate

Structured output and the ApprovalGate work together naturally. When an LLM step returns structured data with a `requires_approval` field, the agent can route to the ApprovalGate before executing. The schema enforces that the field is present and boolean — no parsing ambiguity.

This is exactly the pattern Lobster uses: deterministic pipeline steps with typed data flowing between them, and approval gates at side-effect boundaries.

---

## Build Sequence

**TDD — Red-Prompt-Green-Refactor throughout.**

### Step 1: Validator module
- `test/llm/structured_output/validator_test.exs` — type checking, required fields, enums, ranges, nested objects, arrays
- `lib/exclaw/llm/structured_output/validator.ex`
- Pure functions, no GenServer needed

### Step 2: Schema Registry
- `test/llm/structured_output_test.exs` — register, resolve, list, duplicate handling
- `lib/exclaw/llm/structured_output.ex`
- GenServer with ETS-backed lookup

### Step 3: VLLMProvider integration
- `test/llm/vllm_provider_structured_test.exs` — request format, response parsing, validation, retry
- Update `lib/exclaw/llm/vllm_provider.ex` with response_schema support
- Uses Bypass for HTTP mocking

### Step 4: Provider behaviour extension
- Update `lib/exclaw/llm/provider.ex` behaviour with structured output callbacks
- Update OllamaProvider with prompt-level JSON mode
- Update AnthropicProvider with tool-use-as-schema pattern

### Step 5: Predefined schemas
- `lib/exclaw/llm/schemas/email.ex` — email classification, priority scoring
- `lib/exclaw/llm/schemas/code_review.ex` — review findings, test analysis
- `lib/exclaw/llm/schemas/business.ex` — query plan, rule extraction
- Registered at application boot

### Step 6: Integration test
- End-to-end: agent calls LLM with schema → vLLM returns constrained JSON → validated → agent receives typed data
- Failure path: invalid response → retry → success or error

---

## Phase Placement

Structured output support should land in **Phase A.5** alongside the Credential Vault and ApprovalGate — it is a cross-cutting LLM subsystem that every subsequent phase depends on:

- **Phase B** (Email Triage): email classification schema, priority scoring schema
- **Phase C** (Developer Team): code review findings schema, test analysis schema
- **Phase H** (Business Intelligence): query plan schema, rule extraction schema

Building it early means every agent from Phase B onward gets validated structured output by default, rather than each agent implementing its own JSON parsing and validation.

---

## Dependencies

```elixir
# Already in mix.exs:
{:req, "~> 0.5"}             # HTTP client (VLLMProvider already uses this)
{:jason, "~> 1.4"}           # JSON parsing (already present)

# Optional (for more thorough JSON Schema validation):
{:ex_json_schema, "~> 0.10"}  # Full JSON Schema Draft 7 validator
# Or implement a lightweight validator (fewer deps, covers 90% of cases)

# No new deps required if using lightweight custom validator
```

---

## Open Questions

1. **Full JSON Schema vs. lightweight validator?** `ex_json_schema` gives full Draft 7 compliance but adds a dependency. A custom validator covering type checks, required fields, enums, and ranges covers the practical use cases with zero deps. Start lightweight, upgrade if needed?

2. **Schema versioning?** When a schema changes (e.g., adding a field to email classification), old agents using the schema need to handle both versions. Version schemas explicitly (`:email_classification_v2`) or use `additionalProperties: true` with required-field-only validation?

3. **Thinking tags interaction?** Qwen3 uses `<think>` tags for chain-of-thought. When `response_format` is set, does vLLM strip thinking output or include it? Need to test — may need to parse out thinking before JSON validation.

4. **Token budget for structured output?** Grammar-constrained decoding can use more tokens than free-form text (the model may "waste" tokens on JSON syntax). Should ExClaw track token usage per schema and alert if a schema is consistently expensive?
