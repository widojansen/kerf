# ExClaw Personal Intelligence Platform — Architecture

> Unified architecture for MCP bidirectional communication, email triage with learning, and a personal knowledge base. Designed 2026-03-22.

## Overview

Three systems — **Knowledge Base**, **Email Triage**, **MCP Bridge** — share a single spine: the knowledge base backed by PostgreSQL (pgvector + AGE) on the DGX Spark, with all agents running as supervised ExClaw OTP processes.

The knowledge base is the foundation. Email triage is an agent that reads from and writes to it. MCP exposes it to external clients (Claude Code) and lets agents consume external tools.

---

## Layer 1: Knowledge Base (Core)

### Storage — PostgreSQL on Spark

| Table | Purpose |
|-------|---------|
| `documents` | Source metadata: type, origin URL/sender, timestamp, raw text |
| `chunks` | Chunked content with pgvector embeddings |
| `interests` | Topic/keyword interests with learnable weights |
| `feedback` | User decisions (priority Y/N, follow-up Y/N, bookmarks, searches) |
| AGE graph | Relationships between senders, topics, documents, threads |

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

## Layer 3: MCP Bridge (Bidirectional)

### ExClaw as MCP Server

Exposes internals to Claude Code and external MCP clients.

**Resources:**
- `knowledge://search?q=...` — semantic search over the knowledge base
- `knowledge://interests` — current interest topics and weights
- `email://inbox/categorized` — categorized inbox state
- `email://priority/senders` — priority sender list with scores
- `agents://status` — supervision tree health, running agents

**Tools:**
- `knowledge.ingest(url)` — trigger ingestion of a new source
- `email.add_priority_sender(email)` — add sender to priority
- `email.feedback(email_id, decision)` — record a triage decision
- `interests.update(topic, weight)` — adjust interest weights

### ExClaw as MCP Client

Agents consume external MCP servers at runtime:
- `EmailIngestor` → Gmail MCP / raw API
- `RSSIngestor` → web fetch tools
- Future: dynamic MCP server discovery, agents propose new connections

### OTP Implementation

Each MCP connection (inbound or outbound) is a supervised `GenServer` under `McpConnectionSupervisor`.

Transport is pluggable via a behaviour:
- `ExClaw.Mcp.Transport.Stdio` — for Claude Code local connections
- `ExClaw.Mcp.Transport.Http` — for remote / Streamable HTTP (MCP spec)

---

## System Diagram

```
External Sources                    User (Telegram / Claude Code)
   │                                        │
   ▼                                        ▼
┌─────────────────────────────────────────────────┐
│  ExClaw OTP Application                         │
│                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐     │
│  │ Email    │  │ YouTube  │  │ RSS/PDF/ │     │
│  │ Ingestor │  │ Ingestor │  │ Podcast  │     │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘     │
│       │              │              │           │
│       ▼              ▼              ▼           │
│  ┌──────────────────────────────────────────┐  │
│  │  Knowledge Base (pgvector + AGE)         │  │
│  │  chunks / embeddings / graph / feedback  │  │
│  └──────────────┬───────────────────────────┘  │
│                 │                               │
│       ┌─────────┼─────────┐                    │
│       ▼         ▼         ▼                    │
│  ┌────────┐ ┌────────┐ ┌────────┐             │
│  │ Email  │ │ Search │ │ MCP    │             │
│  │ Triage │ │ Agent  │ │ Server │             │
│  │ Agent  │ │        │ │        │             │
│  └────┬───┘ └────┬───┘ └────┬───┘             │
│       │          │          │                   │
└───────┼──────────┼──────────┼───────────────────┘
        ▼          ▼          ▼
    Telegram    Telegram   Claude Code /
    (triage)   (answers)   External MCP Clients
```

---

## Build Sequence

### Phase A — Knowledge Base Foundation
- pgvector + AGE schema on Spark
- Embedding pipeline (nomic-embed-text via Ollama)
- First ingestor: `EmailIngestor` (highest overlap with triage)
- Search working end-to-end

### Phase B — Email Triage Agent
- Classification pipeline (category, interest match, priority)
- Telegram output with summaries and follow-up recommendations
- Feedback loop: user decisions → `feedback` table → priority model
- Thread-aware priority propagation via AGE graph

### Phase C — MCP Server
- Expose KB and triage state to Claude Code
- Resource and tool definitions
- Stdio + HTTP transport implementations
- Unlocks "ask Claude about your emails/knowledge" workflows

### Phase D — Remaining Ingestors
- YouTube (yt-dlp transcripts)
- Podcasts (RSS → Whisper transcription on Spark)
- RSS/Blogs (feed fetching, HTML stripping)
- PDFs (text extraction, GLM-OCR for scanned docs)
- Each enriches the same knowledge base

### Phase E — MCP Client
- Agents consuming external MCP servers
- Dynamic tool discovery
- Agent-proposed new MCP connections

---

## Infrastructure

| Component | Location |
|-----------|----------|
| ExClaw runtime | DGX Spark (`ssh spark` / `100.101.119.128`) |
| PostgreSQL + pgvector + AGE | DGX Spark |
| Ollama (embeddings + inference) | DGX Spark |
| Models: Qwen3 32B, nomic-embed-text, GLM-OCR, Whisper | DGX Spark |
| User interface | Telegram (existing agent channel) |
| Dev access | Claude Code via MCP, SSH via Tailscale |

---

## Key Design Principles

- **OTP-native**: every connection, ingestor, and agent is a supervised process. Crash isolation is the default.
- **Single knowledge base**: all sources converge on one store. No silos.
- **Learning by default**: every user interaction (triage decisions, searches, bookmarks) feeds back into ranking and prioritization.
- **MCP as the integration layer**: ExClaw both serves and consumes MCP, making it composable with any MCP-compatible tool or client.
- **Local-first / privacy-first**: all processing (embedding, inference, transcription) runs on the Spark. No data leaves the network.
