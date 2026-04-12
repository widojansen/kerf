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
  local need_model="${1:-true}"

  log "Running preflight checks..."

  if ! command -v docker &>/dev/null; then
    err "Docker not found. Install Docker first."
    exit 1
  fi

  if ! docker info &>/dev/null; then
    err "Docker daemon not running."
    exit 1
  fi

  # HF_TOKEN and disk space only needed when downloading the model
  if [ "$need_model" = "true" ]; then
    if [ -z "${HF_TOKEN:-}" ]; then
      err "HF_TOKEN not set. Export it: export HF_TOKEN=hf_..."
      exit 1
    fi

    if [ ! -d "$HF_CACHE" ]; then
      err "Model cache directory $HF_CACHE does not exist."
      exit 1
    fi

    # df --output is Linux-only (GNU coreutils); this script targets DGX Spark
    local avail_gb
    avail_gb=$(df --output=avail -BG "$HF_CACHE" 2>/dev/null | tail -1 | tr -d ' G')
    if [ "${avail_gb:-0}" -lt 25 ]; then
      err "Less than 25 GB free on $HF_CACHE (${avail_gb}G available)."
      exit 1
    fi
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
  local max_wait=900
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
    preflight false
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
