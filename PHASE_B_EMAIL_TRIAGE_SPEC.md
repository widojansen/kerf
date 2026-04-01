# ExClaw Phase B — Email Triage Agent — Implementation Spec

## Context

Phase A.5 is complete (Credential Vault, ApprovalGate, Structured Output). Phase B builds the first agent that delivers daily value: an Email Triage Agent that classifies, prioritizes, and summarizes incoming email, surfaces results via Telegram, and learns from your feedback.

Phase B has two parts built in order:
1. **Knowledge Base foundation** — tables, embedding pipeline, EmailIngestor
2. **Email Triage Agent** — classification, Telegram output, feedback loop, priority learning

This spec covers both. It's designed for Claude Code to implement using Red-Prompt-Green-Refactor TDD.

## Architecture Overview

```
Gmail API (alice@gmail.com)
       │
       ▼
┌──────────────────┐     ┌────────────────────────────┐
│ EmailIngestor    │────▶│ Knowledge Base (PostgreSQL) │
│ (GenServer)      │     │                            │
│                  │     │ documents + chunks +        │
│ Polls Gmail,     │     │ embeddings + AGE graph     │
│ stores emails,   │     └─────────────┬──────────────┘
│ generates        │                   │
│ embeddings       │                   ▼
└──────────────────┘     ┌────────────────────────────┐
                         │ EmailTriageAgent           │
                         │ (GenServer)                │
                         │                            │
                         │ Classifies new emails      │
                         │ via StructuredOutput,       │
                         │ scores priority via graph,  │
                         │ surfaces to Telegram        │
                         │ with ApprovalGate buttons   │
                         └─────────────┬──────────────┘
                                       │
                                       ▼
                                   Telegram
                              (summaries + buttons)
                                       │
                                       ▼
                              ┌────────────────┐
                              │ Feedback Loop  │
                              │ (interests,    │
                              │  sender scores,│
                              │  AGE graph)    │
                              └────────────────┘
```

## Part 1: Knowledge Base Foundation

### Database Schema

One knowledge base — source types as metadata, not separate databases.

#### Migration: `knowledge_base_documents`

```sql
CREATE TABLE kb_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_type VARCHAR(50) NOT NULL,     -- 'email', 'pdf', 'youtube', 'rss', 'book', 'podcast'
  source_id VARCHAR(500),               -- Gmail message ID, URL, file path, etc.
  source_metadata JSONB DEFAULT '{}',   -- type-specific: sender, subject, labels, etc.
  title TEXT,
  raw_text TEXT,
  content_hash VARCHAR(64),             -- SHA-256 for deduplication
  processed_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE(source_type, source_id)
);

CREATE INDEX idx_kbd_source_type ON kb_documents(source_type);
CREATE INDEX idx_kbd_source_id ON kb_documents(source_id);
CREATE INDEX idx_kbd_content_hash ON kb_documents(content_hash);
CREATE INDEX idx_kbd_inserted ON kb_documents(inserted_at);
CREATE INDEX idx_kbd_metadata ON kb_documents USING GIN(source_metadata);
```

#### Migration: `knowledge_base_chunks`

```sql
CREATE TABLE kb_chunks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id UUID NOT NULL REFERENCES kb_documents(id) ON DELETE CASCADE,
  chunk_index INTEGER NOT NULL,         -- order within document
  content TEXT NOT NULL,
  embedding vector(768),                -- nomic-embed-text outputs 768 dimensions
  token_count INTEGER,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE(document_id, chunk_index)
);

CREATE INDEX idx_kbc_document ON kb_chunks(document_id);
CREATE INDEX idx_kbc_embedding ON kb_chunks USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);
```

#### Migration: `knowledge_base_interests`

```sql
CREATE TABLE kb_interests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  topic VARCHAR(255) NOT NULL UNIQUE,
  keywords TEXT[] DEFAULT '{}',         -- additional matching keywords
  weight FLOAT NOT NULL DEFAULT 1.0,    -- learnable, 0.0 = ignore, 2.0 = high interest
  embedding vector(768),                -- topic embedding for semantic matching
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

#### Migration: `knowledge_base_feedback`

```sql
CREATE TABLE kb_feedback (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id UUID REFERENCES kb_documents(id),
  feedback_type VARCHAR(50) NOT NULL,   -- 'priority', 'follow_up', 'archive', 'label', 'interest_match'
  decision VARCHAR(50) NOT NULL,        -- 'yes', 'no', 'approve', 'reject'
  context JSONB DEFAULT '{}',           -- what was shown to the user
  source VARCHAR(50) DEFAULT 'telegram', -- 'telegram', 'dashboard', 'mcp'
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_kbf_document ON kb_feedback(document_id);
CREATE INDEX idx_kbf_type ON kb_feedback(feedback_type);
CREATE INDEX idx_kbf_inserted ON kb_feedback(inserted_at);
```

#### Migration: `email_senders` (email-specific, lives alongside KB)

```sql
CREATE TABLE email_senders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email VARCHAR(500) NOT NULL UNIQUE,
  name VARCHAR(255),
  domain VARCHAR(255),
  priority_score FLOAT NOT NULL DEFAULT 0.0,  -- -1.0 to 1.0, learned from feedback
  is_priority BOOLEAN NOT NULL DEFAULT FALSE,
  total_emails INTEGER NOT NULL DEFAULT 0,
  total_interactions INTEGER NOT NULL DEFAULT 0,  -- follow-ups, replies
  last_email_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_es_domain ON email_senders(domain);
CREATE INDEX idx_es_priority ON email_senders(is_priority) WHERE is_priority = TRUE;
```

#### Migration: AGE Graph Setup

```sql
-- Load AGE extension (already installed)
LOAD 'age';
SET search_path = ag_catalog, "$user", public;

-- Create the knowledge graph
SELECT create_graph('exclaw_kg');

-- Graph will contain:
-- (:Sender {email, name, priority_score})
-- (:Thread {gmail_thread_id, subject})
-- (:Topic {name, weight})
-- (:Document {id, source_type, title})
--
-- Edges:
-- (:Sender)-[:SENT]->(:Document)
-- (:Sender)-[:PARTICIPATES_IN]->(:Thread)
-- (:Document)-[:IN_THREAD]->(:Thread)
-- (:Document)-[:ABOUT]->(:Topic)
-- (:Sender)-[:RELATED_TO]->(:Sender)  -- co-participants in threads
```

### Seed Data: Initial Interests

```elixir
# priv/repo/seeds/interests.exs
interests = [
  %{topic: "AI/ML", keywords: ["artificial intelligence", "machine learning", "LLM", "neural network", "deep learning", "transformer", "GPT", "Claude"]},
  %{topic: "Elixir/OTP", keywords: ["elixir", "erlang", "OTP", "GenServer", "supervision", "phoenix", "liveview"]},
  %{topic: "NVIDIA", keywords: ["nvidia", "cuda", "GPU", "DGX", "tensorrt", "vllm", "blackwell"]},
  %{topic: "Automotive", keywords: ["automotive", "TecDoc", "parts", "vehicle", "car", "workshop"]},
  %{topic: "Invoice Processing", keywords: ["invoice", "extraction", "OCR", "document processing", "PDF"]},
  %{topic: "MCP", keywords: ["model context protocol", "MCP", "tool use", "function calling"]},
  %{topic: "Infrastructure", keywords: ["kubernetes", "docker", "systemd", "deployment", "CI/CD", "DevOps"]},
  %{topic: "Security", keywords: ["cybersecurity", "ransomware", "zero trust", "authentication", "OAuth"]},
  %{topic: "Business/Consulting", keywords: ["consulting", "agency", "SaaS", "client", "proposal", "contract"]},
  %{topic: "Rust", keywords: ["rust", "cargo", "crate", "ownership", "borrow checker"]},
  %{topic: "Privacy", keywords: ["privacy", "GDPR", "data protection", "encryption", "local-first"]},
  %{topic: "Open Source", keywords: ["open source", "github", "contribution", "license", "community"]},
]
```

### Embedding Pipeline

#### ExClaw.KnowledgeBase.Embedder (module)

```elixir
@moduledoc """
Generates embeddings via vLLM or Ollama's OpenAI-compatible endpoint.
"""

# Generate embedding for a single text
@spec embed(text) :: {:ok, [float()]} | {:error, reason}

# Generate embeddings for a batch of texts
@spec embed_batch(texts) :: {:ok, [[float()]]} | {:error, reason}

# Configuration:
# - EMBEDDING_URL: e.g., "http://localhost:8001" (second vLLM instance) or Ollama
# - EMBEDDING_MODEL: e.g., "nomic-ai/nomic-embed-text-v1"
# - Calls POST /v1/embeddings with {"model": ..., "input": [...]}
# - Returns the embedding vectors from the response
```

**Embedding service options** (choose at deployment time):
1. Second vLLM instance on port 8001: `vllm serve nomic-ai/nomic-embed-text-v1 --port 8001`
2. Ollama (if still running): `ollama serve` + `nomic-embed-text` model

The Embedder module is provider-agnostic — it calls the OpenAI-compatible `/v1/embeddings` endpoint.

#### ExClaw.KnowledgeBase.Chunker (module)

```elixir
@moduledoc """
Splits documents into chunks for embedding.
"""

# Chunk a document into embedding-sized pieces
@spec chunk(text, opts) :: [%{content: String.t(), index: integer(), token_count: integer()}]
# opts: [
#   max_tokens: 512,           # target chunk size
#   overlap_tokens: 50,        # overlap between chunks for context continuity
#   strategy: :paragraph       # :paragraph | :sentence | :fixed
# ]
#
# Strategy:
# - :paragraph — split on double newlines, merge small paragraphs
# - :sentence — split on sentence boundaries, merge up to max_tokens
# - :fixed — fixed token windows with overlap
# Default: :paragraph for emails, :sentence for articles
```

### Gmail Integration

#### ExClaw.Ingestors.Email.GmailClient (module)

```elixir
@moduledoc """
Gmail REST API client using Credential Vault for authentication.
"""

# Fetch new emails since last sync
@spec fetch_new(credential_lease, opts) :: {:ok, [email]} | {:error, reason}
# Uses Gmail history API (historyId) for incremental sync.
# Falls back to search if no historyId (first run).
# opts: [max_results: 50, label_ids: ["INBOX"]]

# Fetch emails matching a search query (for backfill)
@spec search(credential_lease, query, opts) :: {:ok, [email]} | {:error, reason}
# query: Gmail search syntax, e.g., "from:someone@example.com"
# opts: [max_results: 100]

# Get a single email by ID
@spec get_message(credential_lease, message_id) :: {:ok, email} | {:error, reason}

# Apply labels to an email
@spec apply_labels(credential_lease, message_id, label_ids) :: :ok | {:error, reason}

# email struct:
# %{
#   id: String.t(),            # Gmail message ID
#   thread_id: String.t(),     # Gmail thread ID
#   from: %{email: String.t(), name: String.t()},
#   to: [%{email: String.t(), name: String.t()}],
#   cc: [%{email: String.t(), name: String.t()}],
#   subject: String.t(),
#   body_text: String.t(),     # plain text body
#   body_html: String.t(),     # HTML body (for fallback)
#   date: DateTime.t(),
#   labels: [String.t()],
#   snippet: String.t(),
#   history_id: String.t()
# }

# Store the last synced historyId
@spec get_history_id() :: String.t() | nil
@spec set_history_id(history_id) :: :ok
# Persisted in a simple key-value row in kb_documents source_metadata
# or a dedicated sync_state table
```

#### ExClaw.Ingestors.EmailIngestor (GenServer)

```elixir
@moduledoc """
Polls Gmail for new emails, stores them in the knowledge base,
generates embeddings, and builds the AGE graph.
"""

# Manual trigger
@spec sync_now(ingestor) :: {:ok, count} | {:error, reason}

# Backfill by sender
@spec backfill(ingestor, opts) :: {:ok, count} | {:error, reason}
# opts: [sender: "someone@example.com"] or [query: "invoice processing"]
# Uses GmailClient.search/3 and ingests results

# Get sync status
@spec status(ingestor) :: %{last_sync: DateTime.t(), emails_processed: integer(), ...}

# Lifecycle:
# 1. On init: schedule first sync after 10 seconds
# 2. Every 5 minutes: call GmailClient.fetch_new/2
# 3. For each new email:
#    a. Dedup check via content_hash on kb_documents
#    b. Insert into kb_documents (source_type: "email")
#    c. Chunk the email body via Chunker
#    d. Generate embeddings via Embedder
#    e. Insert chunks into kb_chunks
#    f. Upsert sender into email_senders
#    g. Create/update AGE graph nodes and edges:
#       - (:Sender) node
#       - (:Thread) node
#       - (:Document) node
#       - (:Sender)-[:SENT]->(:Document)
#       - (:Sender)-[:PARTICIPATES_IN]->(:Thread)
#       - (:Document)-[:IN_THREAD]->(:Thread)
#    h. Notify EmailTriageAgent (via message or PubSub)
# 4. Update historyId for next incremental sync
```

## Part 2: Email Triage Agent

### ExClaw.Agents.EmailTriage (GenServer)

```elixir
@moduledoc """
Classifies new emails, scores priority, generates summaries,
and surfaces results to Telegram with approval buttons.
"""

# Process a batch of new emails (called by EmailIngestor or scheduled)
@spec triage(agent, document_ids) :: {:ok, [triage_result]} | {:error, reason}

# Get triage status
@spec status(agent) :: map()

# triage_result:
# %{
#   document_id: UUID,
#   classification: %{
#     category: String.t(),        # business, personal, newsletter, transactional, spam
#     priority: integer(),         # 1-5
#     action: String.t(),          # follow_up, archive, flag, ignore
#     confidence: float(),         # 0.0-1.0
#     summary: String.t(),         # LLM-generated summary
#     interest_matches: [%{topic: String.t(), score: float()}]
#   },
#   sender_info: %{
#     email: String.t(),
#     is_priority: boolean(),
#     priority_score: float()
#   }
# }
```

### Triage Pipeline (internal flow)

For each new email:

1. **Sender lookup**: Check `email_senders` for priority status and score
2. **Interest matching**: Compare email embedding against `kb_interests` embeddings (cosine similarity). Top-3 matches above threshold (0.5) become interest_matches.
3. **Thread context**: AGE query — does this thread involve priority senders?
   ```cypher
   MATCH (t:Thread {gmail_thread_id: $thread_id})-[:PARTICIPATES_IN]-(s:Sender)
   WHERE s.priority_score > 0.5
   RETURN s
   ```
4. **Classification**: Use `StructuredOutput.complete(:email_classification, ...)` with Qwen3-32B. Prompt includes email content, sender info, thread context, and interest matches.
5. **Priority scoring**: Combine classification priority, sender score, interest match scores, and thread context into a final priority score.
6. **Telegram output**: Based on priority and category:
   - **High priority (4-5) or interest match**: Full summary + ApprovalGate buttons ("Follow up" / "Archive" / "Add sender to priority")
   - **Medium priority (3)**: Short summary, no buttons unless interest match
   - **Low priority (1-2) or spam/newsletter**: Batch digest (grouped summary, once per triage run)

### Telegram Message Format

**High priority email:**
```
📨 New email from John Doe (john@example.com)
Subject: Q2 Invoice Processing Update

Priority: ⭐⭐⭐⭐ (4/5) | Category: Business
Interests: Invoice Processing (0.89), Automotive (0.72)

Summary: John reports that the Q2 extraction pipeline processed
12,400 invoices with 98.3% accuracy. He's requesting a meeting
to discuss scaling for Q3. Mentions potential new client referral.

[Follow up] [Archive] [Add sender to priority]
```

**Batch digest (low priority):**
```
📬 Email Digest (12 new emails)

Newsletters (5): TechCrunch, Hacker News, Elixir Weekly, ...
Transactional (4): GitHub notifications, AWS billing, ...
Spam (3): filtered

No action needed. Reply /digest for full list.
```

### Feedback Loop

When the user taps a button (via ApprovalGate callback):

- **"Follow up"** → Record `kb_feedback(feedback_type: "follow_up", decision: "yes")`. Increment sender's `total_interactions`. If sender isn't priority and interactions > 3, propose auto-priority via Telegram.
- **"Archive"** → Record feedback. Apply Gmail "Archive" label via GmailClient.
- **"Add sender to priority"** → Set `email_senders.is_priority = true`, update AGE graph node. Record feedback.
- **"Ignore"** → Record feedback with decision "no". Decrement sender priority_score slightly.

### Thread-Aware Priority Propagation

When a new email arrives in a thread that involves priority senders:

```elixir
# In the triage pipeline, after step 3:
case priority_senders_in_thread do
  [] -> # No priority context
  senders ->
    # New sender in a priority thread
    if not sender.is_priority do
      # Ask user via ApprovalGate
      ApprovalGate.Manager.request_approval(%{
        agent: __MODULE__,
        action: "add_priority_sender",
        description: "#{sender.name} (#{sender.email}) replied in a thread with #{Enum.map(senders, & &1.name) |> Enum.join(", ")}. Add to priority?",
        context: %{sender_email: sender.email, thread_id: thread_id},
        options: ["Add to priority", "Ignore"],
        timeout_ms: 86_400_000  # 24 hours for sender decisions
      })
    end
end
```

## TDD Build Sequence

### Step 1: KB Schema + Ecto Schemas

RED: Write tests for Ecto schemas and basic CRUD.
GREEN: Create migrations, implement Ecto schemas.
Files:
- `lib/exclaw/knowledge_base/document.ex` — Ecto schema
- `lib/exclaw/knowledge_base/chunk.ex` — Ecto schema
- `lib/exclaw/knowledge_base/interest.ex` — Ecto schema
- `lib/exclaw/knowledge_base/feedback.ex` — Ecto schema
- `lib/exclaw/knowledge_base/email_sender.ex` — Ecto schema
Tests should verify: insert, query, unique constraints, JSONB metadata queries, foreign key cascade delete.

### Step 2: Chunker

RED: Write tests for text chunking strategies.
GREEN: Implement the Chunker module.
Tests should verify: paragraph splitting, sentence splitting, fixed-window splitting, overlap, token counting, edge cases (empty text, single paragraph, very long text).

### Step 3: Embedder

RED: Write tests for embedding generation (mocked HTTP).
GREEN: Implement the Embedder module.
Tests should verify: single embed, batch embed, HTTP request format matches OpenAI spec, error handling, empty input.

### Step 4: GmailClient

RED: Write tests for Gmail API interactions (mocked HTTP).
GREEN: Implement the GmailClient module.
Tests should verify: fetch_new with historyId, search with query, get_message parses full email, apply_labels, history_id persistence, pagination handling, error responses.

### Step 5: EmailIngestor (GenServer)

RED: Write tests for the ingestor lifecycle.
GREEN: Implement the GenServer.
Tests should verify: scheduled sync, dedup via content_hash, document + chunk insertion, embedding generation, sender upsert, AGE graph updates, backfill by sender/query, status reporting. Use mocks for GmailClient and Embedder.

### Step 6: Interest Matching

RED: Write tests for semantic interest matching.
GREEN: Implement interest matching logic.
Tests should verify: cosine similarity between email embedding and interest embeddings, threshold filtering, top-N matches, empty interests table, disabled interests skipped, keyword fallback matching.

### Step 7: EmailTriageAgent (GenServer)

RED: Write tests for the triage pipeline.
GREEN: Implement the agent.
Tests should verify: full triage flow (classify → score → summarize), StructuredOutput integration with :email_classification schema, priority scoring formula, thread context via AGE query, Telegram message rendering, batch digest for low-priority, high-priority with ApprovalGate buttons. Use mocks for StructuredOutput, Telegram, and ApprovalGate.

### Step 8: Feedback Loop

RED: Write tests for feedback processing and learning.
GREEN: Implement feedback handlers.
Tests should verify: "Follow up" records feedback + increments interactions, "Archive" records feedback + applies label, "Add to priority" updates sender + graph, priority score decay on "Ignore", auto-priority proposal after N interactions.

### Step 9: Thread-Aware Priority Propagation

RED: Write tests for graph-based priority propagation.
GREEN: Implement AGE graph queries and propagation logic.
Tests should verify: new sender in priority thread triggers ApprovalGate, approval adds sender to priority, rejection does nothing, thread with no priority senders skips propagation.

### Step 10: Supervisor + Integration + Seeds

RED: Write integration tests for the full email triage lifecycle.
GREEN: Wire up supervisors, add to Application, seed interests.
Tests should verify: full flow from Gmail poll → ingest → triage → Telegram output → feedback → learning. Supervisor structure, conditional startup, interest seeding.

## Integration with Existing ExClaw

### Application.ex

```elixir
defp knowledge_base_children do
  [{ExClaw.KnowledgeBase.Supervisor, []}]
end

defp email_triage_children do
  if Application.get_env(:exclaw, ExClaw.Ingestors.EmailIngestor, [])[:enabled] != false do
    [{ExClaw.Agents.EmailTriage.Supervisor, []}]
  else
    []
  end
end
```

### Config

```elixir
# config/runtime.exs
config :exclaw, ExClaw.KnowledgeBase.Embedder,
  url: System.get_env("EMBEDDING_URL") || "http://localhost:8001",
  model: System.get_env("EMBEDDING_MODEL") || "nomic-ai/nomic-embed-text-v1"

config :exclaw, ExClaw.Ingestors.EmailIngestor,
  enabled: true,
  poll_interval_ms: 300_000,          # 5 minutes
  max_per_batch: 50,
  gmail_account: "alice@gmail.com",
  credential_name: "gmail_oauth"      # name in Credential Vault

config :exclaw, ExClaw.Agents.EmailTriage,
  enabled: true,
  interest_threshold: 0.5,            # minimum cosine similarity for interest match
  high_priority_threshold: 4,         # priority >= this gets full Telegram output
  classification_model: "nvidia/Qwen3-32B-NVFP4"
```

### File Locations

```
lib/exclaw/knowledge_base/
├── supervisor.ex
├── document.ex                 # Ecto schema
├── chunk.ex                    # Ecto schema
├── interest.ex                 # Ecto schema
├── feedback.ex                 # Ecto schema
├── email_sender.ex             # Ecto schema
├── chunker.ex
├── embedder.ex
├── graph.ex                    # AGE graph helpers (create nodes, edges, queries)

lib/exclaw/ingestors/
├── email/
│   ├── gmail_client.ex
│   └── email_ingestor.ex       # GenServer

lib/exclaw/agents/
├── email_triage/
│   ├── supervisor.ex
│   ├── email_triage.ex         # GenServer (the agent)
│   ├── classifier.ex           # StructuredOutput wrapper for classification
│   ├── priority_scorer.ex      # Combines signals into priority score
│   ├── interest_matcher.ex     # Semantic matching against interests
│   ├── telegram_formatter.ex   # Renders triage results for Telegram
│   └── feedback_handler.ex     # Processes ApprovalGate callbacks

test/knowledge_base/
├── document_test.exs
├── chunk_test.exs
├── chunker_test.exs
├── embedder_test.exs
├── graph_test.exs

test/ingestors/
├── email/
│   ├── gmail_client_test.exs
│   └── email_ingestor_test.exs

test/agents/
├── email_triage/
│   ├── email_triage_test.exs
│   ├── classifier_test.exs
│   ├── priority_scorer_test.exs
│   ├── interest_matcher_test.exs
│   ├── telegram_formatter_test.exs
│   ├── feedback_handler_test.exs
│   └── integration_test.exs

priv/repo/migrations/
├── YYYYMMDDHHMMSS_create_kb_documents.exs
├── YYYYMMDDHHMMSS_create_kb_chunks.exs
├── YYYYMMDDHHMMSS_create_kb_interests.exs
├── YYYYMMDDHHMMSS_create_kb_feedback.exs
├── YYYYMMDDHHMMSS_create_email_senders.exs
├── YYYYMMDDHHMMSS_setup_age_graph.exs

priv/repo/seeds/
├── interests.exs
```

## Dependencies

Likely no new deps needed. Uses:
- `Req` (already in deps) — Gmail API, embedding API
- `Ecto` + `Postgrex` (already in deps) — PostgreSQL, pgvector
- `Jason` (already in deps) — JSON parsing
- StructuredOutput (Phase A.5) — email classification
- CredentialVault (Phase A.5) — Gmail OAuth tokens
- ApprovalGate (Phase A.5) — Telegram approval buttons
- AGE extension — graph queries via raw SQL through Ecto

Note: AGE queries are raw SQL executed via `Ecto.Adapters.SQL.query!/3` since there's no Elixir AGE library. Wrap these in `ExClaw.KnowledgeBase.Graph` module.

## Gmail OAuth Token Import

Before the EmailIngestor can work, the OAuth tokens from gog need to be imported into the Credential Vault. One-time script:

```elixir
# priv/scripts/import_gmail_oauth.exs
#
# Reads gog's token file and stores it in the Credential Vault.
# Run once: mix run priv/scripts/import_gmail_oauth.exs
#
# The gog token file location on Spark:
# ~/.config/gog/tokens/ (file-based keyring)
#
# Extract: client_id, client_secret, access_token, refresh_token, token_url
# Store via: ExClaw.CredentialVault.store(vault, "gmail_oauth", :oauth2, data)
```

## Open for Future

- Additional ingestors (YouTube, RSS, PDF, Podcast) — same KB tables, different source_type
- Knowledge base search agent — semantic search exposed via MCP and Telegram
- Dashboard widget — Phoenix LiveView for email triage overview
- Gmail label sync — create ExClaw-specific labels in Gmail (Priority, Follow-up, etc.)
- Batch operations — "Archive all newsletters from last week"
- Interest weight learning — automatically adjust weights based on feedback patterns
- Email draft agent — propose reply drafts for follow-up emails
