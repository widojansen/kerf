#!/bin/bash
set -e

# --- Wait for PostgreSQL ---
wait_for_pg() {
  local retries=30
  local wait_seconds=2

  echo "Waiting for PostgreSQL..."

  for i in $(seq 1 $retries); do
    if /app/bin/exclaw eval "
      {:ok, _} = Application.ensure_all_started(:postgrex)
      opts = [
        hostname: System.get_env(\"DB_HOST\", \"localhost\"),
        port: String.to_integer(System.get_env(\"DB_PORT\", \"5432\")),
        username: System.get_env(\"DB_USER\", \"postgres\"),
        password: System.get_env(\"DB_PASS\", \"\"),
        database: \"postgres\"
      ]
      case Postgrex.start_link(opts) do
        {:ok, pid} -> GenServer.stop(pid); :ok
        _ -> exit({:shutdown, 1})
      end
    " 2>/dev/null; then
      echo "PostgreSQL is available."
      return 0
    fi
    echo "  Attempt $i/$retries — retrying in ${wait_seconds}s..."
    sleep $wait_seconds
  done

  echo "ERROR: PostgreSQL not available after $retries attempts."
  exit 1
}

# --- Run Migrations ---
run_migrations() {
  echo "Running Ecto migrations..."
  /app/bin/exclaw eval "ExClaw.Release.migrate()"
  echo "Migrations complete."
}

# --- Main ---
case "${1:-start}" in
  start)
    wait_for_pg
    run_migrations
    echo "Starting ExClaw..."
    exec /app/bin/exclaw start
    ;;
  migrate)
    wait_for_pg
    run_migrations
    ;;
  eval)
    shift
    exec /app/bin/exclaw eval "$@"
    ;;
  remote)
    exec /app/bin/exclaw remote
    ;;
  *)
    exec /app/bin/exclaw "$@"
    ;;
esac
