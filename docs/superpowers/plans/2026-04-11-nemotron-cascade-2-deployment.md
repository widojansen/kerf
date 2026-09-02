# Nemotron-Cascade-2 Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Qwen3-32B-NVFP4 with Nemotron-Cascade-2 on DGX Spark using a custom Docker image with patched FlashInfer + vLLM, and update all ExClaw defaults.

**Architecture:** Custom Docker image extends `nvcr.io/nvidia/vllm:26.02-py3` with two cherry-picked PRs (FlashInfer #2913 for SM 12.x GDC fix, vLLM #38423 for NVFP4 tile constraints). Deployed via the existing Docker-managed-by-systemd pattern. ExClaw code changes are default model name swaps only — no API or routing changes needed.

**Tech Stack:** Docker, systemd, vLLM (OpenAI-compatible API), FlashInfer, CUDA 13.1 (SM 12.1), Elixir/OTP

**Spec:** `docs/superpowers/specs/2026-04-11-nemotron-cascade-2-deployment-design.md`

---

## File Map

| Action | File | Purpose |
|--------|------|---------|
| Create | `deploy/vllm-cascade/Dockerfile` | Custom Docker image with patched FlashInfer + vLLM |
| Create | `deploy/vllm-cascade.service` | systemd unit for Docker-based Nemotron-Cascade-2 |
| Create | `deploy/vllm-cascade.sh` | Build + deploy script (build image, download model, swap service) |
| Modify | `config/runtime.exs` | Update default model names |
| Modify | `lib/exclaw/llm/vllm_provider.ex` | Update default model in moduledoc + init |
| Modify | `lib/exclaw/agents/email_triage/classifier.ex` | Update default model |
| Modify | `env.example.txt` | Update model env var examples |
| Modify | `deploy/exclaw.service` | Add vllm.service dependency |
| Modify | `CLAUDE.md` | Update model references in docs |

---

### Task 1: Create the Dockerfile

**Files:**
- Create: `deploy/vllm-cascade/Dockerfile`

- [ ] **Step 1: Create the Dockerfile**

```dockerfile
# Custom vLLM image for Nemotron-Cascade-2 NVFP4 on DGX Spark (SM 12.1).
#
# Extends the NGC vLLM image with two upstream fixes:
#   - FlashInfer PR #2913: GDC compile flags for CUTLASS fused MoE on SM 12.x
#   - vLLM PR #38423: CUTLASS v4.4.2 + FlashInfer 0.6.7, SM12x NVFP4 tile fixes
#
# Build on the Spark:
#   docker build -t vllm-cascade:latest deploy/vllm-cascade/
#
# Model weights are NOT baked in — mount /data/huggingface at runtime.

FROM nvcr.io/nvidia/vllm:26.02-py3

# --- FlashInfer: apply GDC fix for SM 12.x MoE kernels (PR #2913) ---
WORKDIR /tmp/flashinfer
RUN git clone --depth=1 https://github.com/flashinfer-ai/flashinfer.git . && \
    git fetch --depth=1 origin pull/2913/head:fix-gdc-moe && \
    git checkout fix-gdc-moe

ENV FLASHINFER_CUDA_ARCH_LIST="12.1a"
RUN pip install -e . -v 2>&1 | tail -5

# --- vLLM: apply NVFP4 SM12x tile constraint fix (PR #38423) ---
WORKDIR /tmp/vllm-patch
RUN git clone --depth=1 https://github.com/vllm-project/vllm.git . && \
    git fetch --depth=1 origin pull/38423/head:fix-nvfp4-spark && \
    git checkout fix-nvfp4-spark

RUN pip install -e . -v 2>&1 | tail -5

# Clean up build artifacts to reduce image size
RUN rm -rf /tmp/flashinfer/.git /tmp/vllm-patch/.git /root/.cache/pip

WORKDIR /workspace
```

- [ ] **Step 2: Commit**

```bash
git add deploy/vllm-cascade/Dockerfile
git commit -m "feat: add Dockerfile for Nemotron-Cascade-2 with FlashInfer + vLLM patches

Extends nvcr.io/nvidia/vllm:26.02-py3 with:
- FlashInfer PR #2913 (GDC fix for SM 12.x MoE)
- vLLM PR #38423 (NVFP4 SM12x tile constraints)"
```

---

### Task 2: Create the systemd service file

**Files:**
- Create: `deploy/vllm-cascade.service`

- [ ] **Step 1: Create the systemd unit**

```ini
# vLLM service for Nemotron-Cascade-2 NVFP4 on DGX Spark.
#
# Install:
#   sudo cp deploy/vllm-cascade.service /etc/systemd/system/vllm.service
#   sudo systemctl daemon-reload
#   sudo systemctl enable vllm
#
# Usage:
#   sudo systemctl start vllm
#   sudo systemctl stop vllm
#   journalctl -u vllm -f
#
# Model weights are loaded from /data/huggingface (host volume mount).

[Unit]
Description=vLLM Nemotron-Cascade-2 NVFP4
After=docker.service
Requires=docker.service
Before=exclaw.service

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker stop vllm
ExecStartPre=-/usr/bin/docker rm vllm
ExecStart=/usr/bin/docker run \
  --gpus all \
  --network host \
  --name vllm \
  -v /data/huggingface:/root/.cache/huggingface \
  vllm-cascade:latest \
  vllm serve chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4 \
    --host 0.0.0.0 \
    --port 8000 \
    --served-model-name nemotron-cascade-2 \
    --tensor-parallel-size 1 \
    --gpu-memory-utilization 0.85 \
    --max-model-len 131072 \
    --mamba-ssm-cache-dtype float32 \
    --kv-cache-dtype fp8 \
    --trust-remote-code \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_coder \
    --reasoning-parser nemotron_v3
ExecStop=/usr/bin/docker stop vllm

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Commit**

```bash
git add deploy/vllm-cascade.service
git commit -m "feat: add systemd service for Nemotron-Cascade-2 vLLM

Docker-based, same pattern as existing Qwen3 service.
Key flags: mamba-ssm-cache float32, kv-cache fp8, qwen3_coder tool parser."
```

---

### Task 3: Create the deploy script

**Files:**
- Create: `deploy/vllm-cascade.sh`

- [ ] **Step 1: Create the deploy script**

```bash
#!/usr/bin/env bash
#
# Build and deploy Nemotron-Cascade-2 NVFP4 on DGX Spark.
#
# Usage:
#   ./deploy/vllm-cascade.sh              # full pipeline
#   ./deploy/vllm-cascade.sh --build-only # build Docker image only
#   ./deploy/vllm-cascade.sh --service-only # swap systemd service only
#   ./deploy/vllm-cascade.sh --validate   # health check only
#   ./deploy/vllm-cascade.sh --rollback   # restore Qwen3 service
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="vllm-cascade"
IMAGE_TAG="latest"
SERVICE_FILE="$SCRIPT_DIR/vllm-cascade.service"
SYSTEMD_DEST="/etc/systemd/system/vllm.service"
SYSTEMD_BACKUP="/etc/systemd/system/vllm-qwen3.service.bak"
MODEL_ID="chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4"
HF_CACHE="/data/huggingface"
NGC_IMAGE="nvcr.io/nvidia/vllm:26.02-py3"
VLLM_URL="http://localhost:8000"

# --- Colors ---------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[vllm-cascade]${NC} $*"; }
warn() { echo -e "${YELLOW}[vllm-cascade]${NC} $*"; }
err()  { echo -e "${RED}[vllm-cascade]${NC} $*" >&2; }

# --- Preflight -------------------------------------------------------------

preflight() {
  log "Running preflight checks..."

  if ! command -v docker &>/dev/null; then
    err "Docker not found. Install Docker first."
    exit 1
  fi

  if ! docker info &>/dev/null; then
    err "Docker daemon not running."
    exit 1
  fi

  if [ -z "${HF_TOKEN:-}" ]; then
    err "HF_TOKEN not set. Export it: export HF_TOKEN=hf_..."
    exit 1
  fi

  if [ ! -d "$HF_CACHE" ]; then
    err "Model cache directory $HF_CACHE does not exist."
    exit 1
  fi

  local avail_gb
  avail_gb=$(df --output=avail -BG "$HF_CACHE" 2>/dev/null | tail -1 | tr -d ' G')
  if [ "${avail_gb:-0}" -lt 25 ]; then
    err "Less than 25 GB free on $HF_CACHE (${avail_gb}G available)."
    exit 1
  fi

  log "Preflight OK."
}

# --- Download model --------------------------------------------------------

download_model() {
  log "Downloading model $MODEL_ID (skips if cached)..."
  docker run --rm \
    -v "$HF_CACHE:/root/.cache/huggingface" \
    -e "HF_TOKEN=$HF_TOKEN" \
    "$NGC_IMAGE" \
    huggingface-cli download "$MODEL_ID"
  log "Model download complete."
}

# --- Build Docker image ----------------------------------------------------

build_image() {
  log "Building Docker image $IMAGE_NAME:$IMAGE_TAG..."
  log "This will take a while (CUDA kernel compilation)."

  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"

  docker build \
    -t "$IMAGE_NAME:$IMAGE_TAG" \
    -t "$IMAGE_NAME:$timestamp" \
    "$SCRIPT_DIR/vllm-cascade/"

  log "Image built: $IMAGE_NAME:$IMAGE_TAG (also tagged $IMAGE_NAME:$timestamp)"
}

# --- Swap systemd service --------------------------------------------------

swap_service() {
  # Backup current service if it exists and no backup exists yet
  if [ -f "$SYSTEMD_DEST" ] && [ ! -f "$SYSTEMD_BACKUP" ]; then
    log "Backing up current vllm.service to $SYSTEMD_BACKUP..."
    sudo cp "$SYSTEMD_DEST" "$SYSTEMD_BACKUP"
  fi

  log "Stopping current vllm service..."
  sudo systemctl stop vllm 2>/dev/null || true

  log "Installing new vllm.service..."
  sudo cp "$SERVICE_FILE" "$SYSTEMD_DEST"
  sudo systemctl daemon-reload
  sudo systemctl enable vllm
  sudo systemctl start vllm

  log "Service swapped and started."
}

# --- Validate --------------------------------------------------------------

validate() {
  local max_wait=300
  local interval=10
  local elapsed=0

  log "Waiting for vLLM to start (up to ${max_wait}s)..."
  log "Tip: watch startup in another terminal: journalctl -u vllm -f"

  while [ $elapsed -lt $max_wait ]; do
    if curl -sf "$VLLM_URL/v1/models" >/dev/null 2>&1; then
      break
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
    echo -n "."
  done
  echo ""

  if [ $elapsed -ge $max_wait ]; then
    err "vLLM did not start within ${max_wait}s."
    err "Check logs: journalctl -u vllm -n 100"
    exit 1
  fi

  log "vLLM is responding. Checking model..."

  local models
  models=$(curl -sf "$VLLM_URL/v1/models")

  if echo "$models" | grep -q "nemotron-cascade-2"; then
    log "Model 'nemotron-cascade-2' is being served."
  else
    err "Model 'nemotron-cascade-2' not found in /v1/models response:"
    echo "$models"
    exit 1
  fi

  log "Running completion test..."
  local response
  response=$(curl -sf "$VLLM_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "nemotron-cascade-2",
      "messages": [{"role": "user", "content": "Reply with exactly: hello"}],
      "max_tokens": 20
    }')

  if echo "$response" | grep -q '"choices"'; then
    log "Completion test passed."
  else
    err "Completion test failed:"
    echo "$response"
    exit 1
  fi

  log "All validations passed. Nemotron-Cascade-2 is live."
}

# --- Rollback --------------------------------------------------------------

do_rollback() {
  if [ ! -f "$SYSTEMD_BACKUP" ]; then
    err "No backup found at $SYSTEMD_BACKUP. Cannot rollback."
    exit 1
  fi

  log "Rolling back to previous vLLM service..."
  sudo systemctl stop vllm 2>/dev/null || true
  sudo cp "$SYSTEMD_BACKUP" "$SYSTEMD_DEST"
  sudo systemctl daemon-reload
  sudo systemctl start vllm

  log "Rolled back. Waiting for old service to start..."
  sleep 15

  if sudo systemctl is-active --quiet vllm; then
    log "Rollback successful. Old vLLM service is running."
  else
    err "Rollback service failed to start. Check: journalctl -u vllm -n 50"
    exit 1
  fi
}

# --- Full pipeline ---------------------------------------------------------

do_full() {
  preflight
  download_model
  build_image
  swap_service
  validate
}

# --- Entrypoint ------------------------------------------------------------

case "${1:-}" in
  --build-only)
    preflight
    build_image
    ;;
  --service-only)
    swap_service
    validate
    ;;
  --validate)
    validate
    ;;
  --rollback)
    do_rollback
    ;;
  --help|-h)
    echo "Usage: $0 [--build-only | --service-only | --validate | --rollback | --help]"
    echo ""
    echo "  (no args)       Full pipeline: preflight → download → build → swap → validate"
    echo "  --build-only    Build Docker image only (no service changes)"
    echo "  --service-only  Swap systemd service and validate (skip build)"
    echo "  --validate      Run health checks against running service"
    echo "  --rollback      Restore backed-up Qwen3 service"
    ;;
  *)
    do_full
    ;;
esac
```

- [ ] **Step 2: Make the script executable**

Run: `chmod +x deploy/vllm-cascade.sh`

- [ ] **Step 3: Commit**

```bash
git add deploy/vllm-cascade.sh
git commit -m "feat: add deploy script for Nemotron-Cascade-2 on Spark

Automates: preflight checks, model download, Docker image build,
systemd service swap, and validation. Supports --rollback."
```

---

### Task 4: Update ExClaw default model references

**Files:**
- Modify: `config/runtime.exs:24,68,211`
- Modify: `lib/exclaw/llm/vllm_provider.ex:17,57`
- Modify: `lib/exclaw/agents/email_triage/classifier.ex:13`
- Modify: `env.example.txt:21-22,41`

- [ ] **Step 1: Update `config/runtime.exs` — VLLM_MODEL default (line 24)**

Change:
```elixir
    default_model: System.get_env("VLLM_MODEL", "nvidia/Qwen3-32B-NVFP4"),
```
To:
```elixir
    default_model: System.get_env("VLLM_MODEL", "nemotron-cascade-2"),
```

- [ ] **Step 2: Update `config/runtime.exs` — comment example (line 68)**

Change:
```elixir
#   EXCLAW_DEFAULT_MODEL=nvidia/Qwen3-32B-NVFP4  (vLLM)
```
To:
```elixir
#   EXCLAW_DEFAULT_MODEL=nemotron-cascade-2       (vLLM)
```

- [ ] **Step 3: Update `config/runtime.exs` — CLASSIFICATION_MODEL default (line 211)**

Change:
```elixir
    classification_model: System.get_env("CLASSIFICATION_MODEL", "nvidia/Qwen3-32B-NVFP4")
```
To:
```elixir
    classification_model: System.get_env("CLASSIFICATION_MODEL", "nemotron-cascade-2")
```

- [ ] **Step 4: Update `lib/exclaw/llm/vllm_provider.ex` — moduledoc (line 17)**

Change:
```elixir
        default_model: "nvidia/Qwen3-32B-NVFP4",
```
To:
```elixir
        default_model: "nemotron-cascade-2",
```

- [ ] **Step 5: Update `lib/exclaw/llm/vllm_provider.ex` — init default (line 57)**

Change:
```elixir
      default_model: Keyword.get(opts, :default_model, "nvidia/Qwen3-32B-NVFP4"),
```
To:
```elixir
      default_model: Keyword.get(opts, :default_model, "nemotron-cascade-2"),
```

- [ ] **Step 6: Update `lib/exclaw/agents/email_triage/classifier.ex` — default model (line 13)**

Change:
```elixir
    model = Keyword.get(opts, :model, "nvidia/Qwen3-32B-NVFP4")
```
To:
```elixir
    model = Keyword.get(opts, :model, "nemotron-cascade-2")
```

- [ ] **Step 7: Update `env.example.txt` — model env vars (lines 21-22, 41)**

Change:
```
VLLM_MODEL=nvidia/Qwen3-32B-NVFP4
EXCLAW_DEFAULT_MODEL=nvidia/Qwen3-32B-NVFP4
```
To:
```
VLLM_MODEL=nemotron-cascade-2
EXCLAW_DEFAULT_MODEL=nemotron-cascade-2
```

And change:
```
# CLASSIFICATION_MODEL=nvidia/Qwen3-32B-NVFP4
```
To:
```
# CLASSIFICATION_MODEL=nemotron-cascade-2
```

- [ ] **Step 8: Update `config/runtime.exs` — vLLM comment block (lines 10-13)**

Change:
```elixir
# vLLM uses NVFP4-quantized HuggingFace models (e.g. nvidia/Qwen3-32B-NVFP4)
```
To:
```elixir
# vLLM uses NVFP4-quantized HuggingFace models (e.g. Nemotron-Cascade-2-30B-A3B-NVFP4)
```

- [ ] **Step 9: Run tests to verify nothing broke**

Run: `mix test --no-start test/llm/ test/agents/email_triage/ test/structured_output/`
Expected: All tests pass (tests use injected mock providers, not real model names)

- [ ] **Step 10: Commit**

```bash
git add config/runtime.exs lib/exclaw/llm/vllm_provider.ex \
  lib/exclaw/agents/email_triage/classifier.ex env.example.txt
git commit -m "feat: update default model to nemotron-cascade-2

Replace nvidia/Qwen3-32B-NVFP4 defaults with nemotron-cascade-2
(the --served-model-name from vLLM). Env vars still override."
```

---

### Task 5: Update ExClaw service dependency and CLAUDE.md

**Files:**
- Modify: `deploy/exclaw.service:4-5`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add vllm.service dependency to `deploy/exclaw.service`**

Change:
```ini
After=network.target postgresql.service
Wants=postgresql.service
```
To:
```ini
After=network.target postgresql.service vllm.service
Wants=postgresql.service vllm.service
```

- [ ] **Step 2: Update `CLAUDE.md` — vLLM model reference in Runtime section**

Find the line:
```
- Start with vLLM: Set `LLM_BACKEND=vllm`, `VLLM_URL`, `VLLM_MODEL` env vars
```
No change needed (env var names are the same).

Find all `nvidia/Qwen3-32B-NVFP4` references in CLAUDE.md and update to `nemotron-cascade-2`. Key locations:
- VLLMProvider moduledoc reference
- Config examples
- Any deployment guide references

Search with: `grep -n "Qwen3-32B" CLAUDE.md`

Update each occurrence to `nemotron-cascade-2` where it refers to the default/current model. Leave historical references (phase history, debugging logs) unchanged.

- [ ] **Step 3: Commit**

```bash
git add deploy/exclaw.service CLAUDE.md
git commit -m "feat: add vllm.service dependency to exclaw, update CLAUDE.md

ExClaw now waits for vllm.service before starting.
Updated model references in documentation."
```

---

### Task 6: Deploy to Spark

This task is executed manually on the Spark via SSH, not by a code agent.

- [ ] **Step 1: Push changes to remote**

Run: `git push`

- [ ] **Step 2: SSH into Spark and pull**

```bash
ssh spark
cd ~/Projects/exClaw/exclaw
git pull
```

- [ ] **Step 3: Set HF_TOKEN**

```bash
export HF_TOKEN=<your-huggingface-token>
```

- [ ] **Step 4: Run the deploy script**

```bash
./deploy/vllm-cascade.sh
```

Expected output flow:
1. Preflight checks pass
2. Model downloads (~18.4 GB, skips if cached)
3. Docker image builds (this takes a long time — CUDA kernel compilation)
4. Current vllm service backed up and stopped
5. New service installed and started
6. Validation passes: model name confirmed, completion test passes

- [ ] **Step 5: If build fails — check logs**

```bash
# Docker build logs are inline
# vLLM startup logs:
journalctl -u vllm -f
```

- [ ] **Step 6: Update ExClaw .env on Spark**

```bash
sudo nano /opt/exclaw/.env
```

Update:
```
VLLM_MODEL=nemotron-cascade-2
EXCLAW_DEFAULT_MODEL=nemotron-cascade-2
# CLASSIFICATION_MODEL=nemotron-cascade-2
```

- [ ] **Step 7: Redeploy ExClaw**

```bash
./deploy/deploy.sh
```

This rebuilds the Elixir release, runs migrations, and restarts ExClaw with the new defaults.

- [ ] **Step 8: Verify ExClaw integration**

```bash
# Check ExClaw is running
sudo systemctl status exclaw

# Check vLLM is running
sudo systemctl status vllm

# Test via Telegram or CLI
/opt/exclaw/current/bin/exclaw remote
# In IEx:
# ExClaw.LLM.ModelRouter.complete("nemotron-cascade-2", [%{"role" => "user", "content" => "hello"}])
```

---

### Task 7: Validate throughput improvement

Manual validation on the Spark after deployment.

- [ ] **Step 1: Run email triage on a small batch**

```bash
# Trigger a manual email triage run via IEx
/opt/exclaw/current/bin/exclaw remote
```

```elixir
# In IEx — trigger a single email classification and time it
:timer.tc(fn ->
  ExClaw.Agents.EmailTriage.Classifier.classify(%{
    from: %{name: "Test", email: "test@example.com"},
    subject: "Quarterly report",
    body_text: "Please review the attached quarterly report."
  })
end)
# Expected: {time_microseconds, {:ok, classification}}
# Compare against ~50s (50_000_000 µs) baseline with Qwen3-32B
```

- [ ] **Step 2: Compare throughput**

| Metric | Qwen3-32B (baseline) | Nemotron-Cascade-2 (target) |
|--------|---------------------|-----------------------------|
| Single email classification | ~50s | < 10s |
| 50-email batch | ~45 min | < 10 min |

- [ ] **Step 3: If performance is poor — rollback**

```bash
cd ~/Projects/exClaw/exclaw
./deploy/vllm-cascade.sh --rollback
```

Then update `/opt/exclaw/.env` back to `VLLM_MODEL=nvidia/Qwen3-32B-NVFP4` and run `./deploy/deploy.sh`.
