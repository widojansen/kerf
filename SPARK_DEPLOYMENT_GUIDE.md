# ExClaw Phase B — Spark Deployment Guide

## Prerequisites

- Spark accessible via `ssh spark` (Tailscale)
- vLLM running on port 8000 (Qwen3-32B-NVFP4)
- Ollama running on port 11434 (bge-m3 for embeddings, 1024 dimensions)
- PostgreSQL 18.3 running (systemd)
- gog authenticated for `alice@gmail.com`
- ExClaw git repo on Spark at `~/Projects/exClaw/exclaw/`

Work through these steps in order. Each step is self-contained — you can stop and resume at any point.

---

## Step 1: Push and Pull Latest Code

**On MacBook:**
```bash
cd ~/Projects/exClaw/exclaw
git add -A
git commit -m "feat: Phase B Email Triage Agent, 780 tests"
git push
```

**On Spark:**
```bash
cd ~/Projects/exClaw/exclaw
git pull
mix deps.get
mix compile
```

**Verify:** `mix test --no-start` should show 780+ tests, 0 failures.

---

## Step 2: Check Environment

**Check what's running:**
```bash
# PostgreSQL
sudo systemctl status postgresql
psql -U wido -d exclaw_prod -c "SELECT 1;"

# vLLM
sudo systemctl status vllm
curl -s http://localhost:8000/v1/models | head -5

# Ollama (check if still running)
systemctl status ollama 2>/dev/null || echo "Ollama not running as service"
pgrep -f ollama && echo "Ollama process found" || echo "No Ollama process"

# gog
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD="rma2814\$"
gog auth list
gog gmail labels list --account alice@gmail.com
```

**Note the results** — we need to know:
- [ ] PostgreSQL is running and exclaw_prod exists
- [ ] vLLM is serving Qwen3-32B on port 8000
- [ ] Whether Ollama is running with bge-m3 for embeddings
- [ ] gog can access Gmail

---

## Step 3: Verify Embedding Service

Embeddings use **bge-m3** (1024 dimensions, multilingual) on Ollama, port 11434.

```bash
# Verify Ollama is running
pgrep -f ollama && echo "Ollama running" || echo "Ollama not running — start it"

# Check bge-m3 is available
ollama list | grep bge-m3

# If not pulled yet:
# ollama pull bge-m3

# Test the embeddings endpoint
curl -s http://localhost:11434/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model": "bge-m3", "input": "test embedding"}' | python3 -c "
import sys, json
data = json.load(sys.stdin)
emb = data['data'][0]['embedding']
print(f'Dimensions: {len(emb)}')
print(f'First 5 values: {emb[:5]}')
"
```

**Verify:** Output shows `Dimensions: 1024` and numeric values.

Env vars for `.env`:
```bash
EMBEDDING_URL=http://localhost:11434
EMBEDDING_MODEL=bge-m3
```

---

## Step 4: Run Migrations

```bash
cd ~/Projects/exClaw/exclaw
source .env

# Run all pending migrations on the prod database
MIX_ENV=prod mix ecto.migrate

# Verify new tables exist
psql -U wido -d exclaw_prod -c "\dt kb_*"
psql -U wido -d exclaw_prod -c "\dt email_senders"
psql -U wido -d exclaw_prod -c "\dt credential_vault_*"
psql -U wido -d exclaw_prod -c "\dt approval_gate_*"

# Verify AGE graph
psql -U wido -d exclaw_prod -c "LOAD 'age'; SET search_path = ag_catalog, public; SELECT * FROM ag_graph;"
```

**Verify:** All tables created, AGE graph `exclaw_kg` exists.

---

## Step 5: Check/Generate SECRET_KEY_BASE

The Credential Vault needs SECRET_KEY_BASE for encryption.

```bash
# Check if it's already in .env
grep SECRET_KEY_BASE ~/Projects/exClaw/exclaw/.env

# If not set, generate one and add it
if ! grep -q SECRET_KEY_BASE ~/Projects/exClaw/exclaw/.env; then
  SECRET=$(mix phx.gen.secret 2>/dev/null || openssl rand -base64 48)
  echo "SECRET_KEY_BASE=$SECRET" >> ~/Projects/exClaw/exclaw/.env
  echo "Generated and added SECRET_KEY_BASE"
else
  echo "SECRET_KEY_BASE already set"
fi
```

**Important:** Once set, never change this key — it encrypts all credentials in the vault.

---

## Step 6: Import Gmail OAuth Tokens

First, find where gog stores its tokens:

```bash
# Check gog's token storage
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD="rma2814\$"

# List authenticated accounts
gog auth list

# The token file is typically at:
ls -la ~/.config/gog/ 2>/dev/null
ls -la ~/.local/share/gog/ 2>/dev/null
# Or search for it:
find ~/ -name "*.json" -path "*/gog/*" 2>/dev/null
```

Once you know the token file path, we need to extract the OAuth credentials. The exact approach depends on how gog stores them (encrypted keyring file vs. JSON).

**Option A — If tokens are accessible as JSON:**
Create the import script:
```bash
cat > ~/Projects/exClaw/exclaw/priv/scripts/import_gmail_oauth.exs << 'ELIXIR'
# Import Gmail OAuth tokens from gog into Credential Vault
#
# Usage: MIX_ENV=prod mix run priv/scripts/import_gmail_oauth.exs
#
# You'll need to provide the OAuth credentials manually since
# gog's keyring is encrypted. Get them from Google Cloud Console
# (APIs & Services > Credentials > OAuth 2.0 Client IDs > Download JSON)
# and from gog's stored tokens.

alias ExClaw.CredentialVault

# Get these from your Google Cloud Console OAuth client JSON
client_id = System.get_env("GMAIL_CLIENT_ID") || raise "Set GMAIL_CLIENT_ID"
client_secret = System.get_env("GMAIL_CLIENT_SECRET") || raise "Set GMAIL_CLIENT_SECRET"

# Get these from gog's stored tokens (or re-authenticate to capture)
access_token = System.get_env("GMAIL_ACCESS_TOKEN") || raise "Set GMAIL_ACCESS_TOKEN"
refresh_token = System.get_env("GMAIL_REFRESH_TOKEN") || raise "Set GMAIL_REFRESH_TOKEN"

credential_data = %{
  client_id: client_id,
  client_secret: client_secret,
  access_token: access_token,
  refresh_token: refresh_token,
  token_url: "https://oauth2.googleapis.com/token",
  scopes: [
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/gmail.labels"
  ],
  expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
}

case CredentialVault.store(
  ExClaw.CredentialVault,
  "gmail_oauth",
  :oauth2,
  credential_data
) do
  {:ok, id} ->
    IO.puts("✅ Gmail OAuth credential stored with ID: #{id}")
  {:error, reason} ->
    IO.puts("❌ Failed to store credential: #{inspect(reason)}")
end
ELIXIR
```

**Option B — Re-authenticate and capture tokens directly:**

If extracting from gog's keyring is too complex, the easiest path is to capture the tokens during a fresh OAuth flow. We can do this in a later step if needed.

**To get client_id and client_secret:**
1. Go to https://console.cloud.google.com
2. Select the "OpenClaw Anita" project
3. Go to APIs & Services → Credentials
4. Click on the OAuth 2.0 Client ID ("OpenClaw DGX Spark")
5. Copy the Client ID and Client Secret

**To get access_token and refresh_token from gog:**
```bash
# Try to extract from gog's debug/verbose output
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD="rma2814\$"
gog auth info alice@gmail.com 2>&1
# or
gog auth token alice@gmail.com 2>&1
```

Once you have all four values, run:
```bash
cd ~/Projects/exClaw/exclaw
source .env
export GMAIL_CLIENT_ID="your_client_id"
export GMAIL_CLIENT_SECRET="your_client_secret"
export GMAIL_ACCESS_TOKEN="your_access_token"
export GMAIL_REFRESH_TOKEN="your_refresh_token"
MIX_ENV=prod mix run priv/scripts/import_gmail_oauth.exs
```

**Verify:**
```bash
MIX_ENV=prod mix run -e '
  creds = ExClaw.CredentialVault.list(ExClaw.CredentialVault, [])
  IO.inspect(creds, label: "Stored credentials")
'
```

---

## Step 7: Create Credential Vault Policy

The EmailIngestor needs permission to use the Gmail credential:

```bash
cat > ~/Projects/exClaw/exclaw/priv/scripts/create_email_policy.exs << 'ELIXIR'
# Create credential policy for EmailIngestor
#
# Usage: MIX_ENV=prod mix run priv/scripts/create_email_policy.exs

alias ExClaw.Repo
alias ExClaw.CredentialVault.Policy

%Policy{}
|> Policy.changeset(%{
  agent_module: "Elixir.ExClaw.Ingestors.EmailIngestor",
  credential_name: "gmail_oauth",
  allowed_scopes: [
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/gmail.labels"
  ],
  max_lease_ttl: 600,
  rate_limit_per_second: 10
})
|> Repo.insert!()

IO.puts("✅ Email policy created")
ELIXIR

cd ~/Projects/exClaw/exclaw
source .env
MIX_ENV=prod mix run priv/scripts/create_email_policy.exs
```

---

## Step 8: Seed Interests

```bash
cd ~/Projects/exClaw/exclaw
source .env
MIX_ENV=prod mix run priv/repo/seeds/interests.exs
```

**Verify:**
```bash
psql -U wido -d exclaw_prod -c "SELECT topic, weight FROM kb_interests ORDER BY topic;"
```

Should show 12 topics.

---

## Step 9: Generate Interest Embeddings

The seeded interests need embeddings for semantic matching:

```bash
cat > ~/Projects/exClaw/exclaw/priv/scripts/embed_interests.exs << 'ELIXIR'
# Generate embeddings for all interests
#
# Usage: MIX_ENV=prod mix run priv/scripts/embed_interests.exs

alias ExClaw.Repo
alias ExClaw.KnowledgeBase.Interest
alias ExClaw.KnowledgeBase.Embedder

interests = Repo.all(Interest)
IO.puts("Embedding #{length(interests)} interests...")

for interest <- interests do
  text = "#{interest.topic}: #{Enum.join(interest.keywords, ", ")}"

  case Embedder.embed(text) do
    {:ok, embedding} ->
      interest
      |> Ecto.Changeset.change(%{embedding: embedding})
      |> Repo.update!()
      IO.puts("  ✅ #{interest.topic}")

    {:error, reason} ->
      IO.puts("  ❌ #{interest.topic}: #{inspect(reason)}")
  end
end

IO.puts("Done!")
ELIXIR

cd ~/Projects/exClaw/exclaw
source .env
MIX_ENV=prod mix run priv/scripts/embed_interests.exs
```

**Verify:**
```bash
psql -U wido -d exclaw_prod -c "SELECT topic, embedding IS NOT NULL as has_embedding FROM kb_interests;"
```

All should show `has_embedding = t`.

---

## Step 10: Update .env

Add/verify all new env vars in `~/Projects/exClaw/exclaw/.env`:

```bash
cat >> ~/Projects/exClaw/exclaw/.env << 'ENV'

# Embedding service (bge-m3 on Ollama, 1024 dimensions)
EMBEDDING_URL=http://localhost:11434
EMBEDDING_MODEL=bge-m3

# Email Triage
EMAIL_TRIAGE_ENABLED=true
GMAIL_ACCOUNT=alice@gmail.com
GMAIL_CREDENTIAL_NAME=gmail_oauth

# ApprovalGate
TELEGRAM_APPROVAL_CHAT_ID=8064166045
ENV
```

---

## Step 11: Restart ExClaw

```bash
# Stop the current ExClaw service
sudo systemctl stop exclaw

# Verify .env is complete
cat ~/Projects/exClaw/exclaw/.env

# Start ExClaw
sudo systemctl start exclaw

# Watch the logs
journalctl -u exclaw -f
```

**What to look for in logs:**
- `[CredentialVault] Started` — vault is running
- `[SchemaRegistry] Registered N built-in schemas` — structured output ready
- `[EmailIngestor] Starting, poll interval: 300000ms` — ingestor is polling
- `[EmailIngestor] Synced N new emails` — emails being ingested
- `[EmailTriage] Triaged N emails` — classification working
- `[Telegram] Sending message` — results going to Telegram

---

## Step 12: Test in Telegram

After ExClaw starts and the first poll runs (within 5 minutes):

1. Check Telegram for triage messages from Tina
2. Send `/status` to the bot to check agent status (if implemented)
3. Tap an approval button to test the feedback loop
4. Verify the feedback was recorded:
   ```bash
   psql -U wido -d exclaw_prod -c "SELECT * FROM kb_feedback ORDER BY inserted_at DESC LIMIT 5;"
   ```

---

## Troubleshooting

**Migrations fail:**
```bash
# Check current migration status
MIX_ENV=prod mix ecto.migrations
# Run with verbose output
MIX_ENV=prod mix ecto.migrate --log-migrations-sql
```

**AGE extension issues:**
```bash
# Verify AGE is loaded
psql -U wido -d exclaw_prod -c "LOAD 'age'; SELECT * FROM ag_catalog.ag_graph;"
```

**Embedding service not responding:**
```bash
# Test directly
curl -v http://localhost:11434/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model": "bge-m3", "input": "hello"}'
```

**Gmail auth expired:**
```bash
# Check gog auth
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD="rma2814\$"
gog gmail labels list --account alice@gmail.com

# If expired, re-auth and re-import tokens
```

**No emails appearing:**
```bash
# Check if documents were created
psql -U wido -d exclaw_prod -c "SELECT COUNT(*) FROM kb_documents WHERE source_type = 'email';"

# Check ExClaw logs for errors
journalctl -u exclaw --since "5 minutes ago" | grep -i "error\|warning"
```

---

## Rollback

If anything goes wrong and you need to revert:

```bash
# Stop ExClaw
sudo systemctl stop exclaw

# Roll back migrations (careful — this drops tables)
MIX_ENV=prod mix ecto.rollback --step 6

# Restart with previous version
git checkout <previous-commit>
sudo systemctl start exclaw
```
