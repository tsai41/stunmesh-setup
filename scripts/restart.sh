#!/usr/bin/env bash
# restart.sh — bounce stunmesh-go only; dhtnode + WireGuard stay up (start.sh skips them)
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh

echo "==> stunmesh-go (restart)"
if PID="$(_stunmesh_pid)"; then
  sudo kill "$PID"
  for _ in {1..20}; do
    _stunmesh_pid >/dev/null || break
    sleep 0.1
  done
  if _stunmesh_pid >/dev/null; then
    echo "✗ stunmesh-go did not stop after SIGTERM" >&2
    exit 1
  fi
  echo "    stopped (pid $PID)"
else
  echo "    not running"
fi
rm -f "$STATE/stunmesh.pid"

exec ./scripts/start.sh
