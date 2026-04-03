#!/usr/bin/env bash
#
# ExClaw deployment — bare-metal Elixir release on DGX Spark.
#
# Usage:
#   ./deploy/deploy.sh              # build + migrate + swap + restart
#   ./deploy/deploy.sh --init       # first-time setup (dirs, service, .env)
#   ./deploy/deploy.sh --rollback   # revert to previous release
#
# Directory layout on the Spark:
#   /opt/exclaw/
#     .env                           # environment variables
#     current -> releases/20260403-143000   # symlink to active release
#     releases/
#       20260403-120000/             # timestamped release dirs
#       20260403-143000/
#     data/                          # Memory.Store persistent data
#     workspaces/                    # Container.Manager bind mounts
#     telemetry/                     # JSONL telemetry fallback
#     whatsapp_auth/                 # WhatsApp Baileys auth state
#
# Prerequisites:
#   - Elixir 1.19+ / OTP 28+ (asdf)
#   - PostgreSQL running
#   - /opt/exclaw/.env populated
#   - User has sudo access for systemctl
#
set -euo pipefail

# --- Configuration -------------------------------------------------------

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_DIR="/opt/exclaw"
SERVICE_NAME="exclaw"
MAX_RELEASES=5
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# --- Helpers --------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[deploy]${NC} $*"; }
warn() { echo -e "${YELLOW}[deploy]${NC} $*"; }
err()  { echo -e "${RED}[deploy]${NC} $*" >&2; }

# --- Init: first-time setup ----------------------------------------------

do_init() {
  log "First-time setup..."

  sudo mkdir -p "$DEPLOY_DIR"/{releases,data,workspaces,telemetry,whatsapp_auth}
  sudo chown -R "$(whoami):$(whoami)" "$DEPLOY_DIR"

  if [ ! -f "$DEPLOY_DIR/.env" ]; then
    cp "$REPO_DIR/env.example.txt" "$DEPLOY_DIR/.env"
    chmod 0600 "$DEPLOY_DIR/.env"
    warn "Created $DEPLOY_DIR/.env from template (mode 0600)."
    warn "Edit it before deploying:  nano $DEPLOY_DIR/.env"
  else
    log "$DEPLOY_DIR/.env already exists — skipping."
  fi

  # Install systemd service
  sudo cp "$REPO_DIR/deploy/exclaw.service" /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"

  log "Service installed and enabled."
  log "Next steps:"
  log "  1. Edit $DEPLOY_DIR/.env"
  log "  2. Run: ./deploy/deploy.sh"
}

# --- Rollback: revert to previous release ---------------------------------

do_rollback() {
  local releases
  mapfile -t releases < <(find "$DEPLOY_DIR/releases" -mindepth 1 -maxdepth 1 -type d | sort)

  if [ ${#releases[@]} -lt 2 ]; then
    err "No previous release to roll back to."
    exit 1
  fi

  local current prev
  current="$(readlink -f "$DEPLOY_DIR/current")"
  prev="${releases[-2]}"

  log "Rolling back: $(basename "$current") -> $(basename "$prev")"
  ln -sfn "$prev" "$DEPLOY_DIR/current"
  sudo systemctl restart "$SERVICE_NAME"

  sleep 3
  if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Rollback successful."
  else
    err "Rollback failed. Check: journalctl -u $SERVICE_NAME -n 50"
    exit 1
  fi
}

# --- Deploy: build + migrate + swap + restart -----------------------------

do_deploy() {
  # Preflight checks
  [ -d "$DEPLOY_DIR/releases" ] || { err "$DEPLOY_DIR/releases not found. Run with --init first."; exit 1; }
  [ -f "$DEPLOY_DIR/.env" ]     || { err "$DEPLOY_DIR/.env not found. Run with --init first."; exit 1; }

  cd "$REPO_DIR"

  # 1. Pull latest code
  log "Pulling latest code..."
  git pull --ff-only

  # 2. Build release
  log "Building release (MIX_ENV=prod)..."
  export MIX_ENV=prod
  mix deps.get --only prod
  mix compile
  mix release --overwrite

  # 3. Copy to versioned release directory
  local release_src="_build/prod/rel/exclaw"
  local release_dst="$DEPLOY_DIR/releases/$TIMESTAMP"

  log "Copying release to $release_dst..."
  mkdir -p "$release_dst"
  cp -a "$release_src/." "$release_dst/"

  # 4. Run migrations via the new release binary.
  #    Env vars scoped to the child process only (secrets stay out of deploy shell).
  log "Running migrations..."
  env MIX_ENV=prod $(grep -v '^\s*#' "$DEPLOY_DIR/.env" | grep -v '^\s*$' | xargs) \
    "$release_dst/bin/exclaw" eval "ExClaw.Release.migrate()"

  # 5. Atomic symlink swap
  log "Swapping symlink..."
  ln -sfn "$release_dst" "$DEPLOY_DIR/current.new"
  mv -T "$DEPLOY_DIR/current.new" "$DEPLOY_DIR/current"

  # 6. Restart service
  log "Restarting $SERVICE_NAME..."
  sudo systemctl restart "$SERVICE_NAME"

  # 7. Verify
  sleep 5
  if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Deployed successfully: $TIMESTAMP"
    log "Dashboard: http://localhost:4000"
  else
    warn "Service failed to start. Auto-rolling back..."
    do_auto_rollback
    exit 1
  fi

  # 8. Prune old releases
  prune_releases
}

do_auto_rollback() {
  local releases
  mapfile -t releases < <(find "$DEPLOY_DIR/releases" -mindepth 1 -maxdepth 1 -type d | sort)

  if [ ${#releases[@]} -lt 2 ]; then
    err "No previous release for auto-rollback. Check: journalctl -u $SERVICE_NAME -n 50"
    return
  fi

  local prev="${releases[-2]}"
  ln -sfn "$prev" "$DEPLOY_DIR/current.new"
  mv -T "$DEPLOY_DIR/current.new" "$DEPLOY_DIR/current"
  sudo systemctl restart "$SERVICE_NAME"

  sleep 3
  if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
    warn "Rolled back to $(basename "$prev")"
  else
    err "Auto-rollback also failed. Check: journalctl -u $SERVICE_NAME -n 50"
  fi
}

prune_releases() {
  local releases
  mapfile -t releases < <(find "$DEPLOY_DIR/releases" -mindepth 1 -maxdepth 1 -type d | sort)
  local count=${#releases[@]}

  if [ "$count" -gt "$MAX_RELEASES" ]; then
    local to_remove=$((count - MAX_RELEASES))
    log "Pruning $to_remove old release(s)..."
    for ((i = 0; i < to_remove; i++)); do
      rm -rf "${releases[$i]}"
    done
  fi
}

# --- Entrypoint -----------------------------------------------------------

case "${1:-}" in
  --init)     do_init ;;
  --rollback) do_rollback ;;
  --help|-h)
    echo "Usage: $0 [--init | --rollback | --help]"
    echo ""
    echo "  (no args)    Build and deploy latest code"
    echo "  --init       First-time setup (dirs, service, .env)"
    echo "  --rollback   Revert to previous release"
    ;;
  *)          do_deploy ;;
esac
