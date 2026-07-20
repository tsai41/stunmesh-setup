#!/usr/bin/env bash
# status.sh — project-scoped status for dhtnode, WireGuard, and stunmesh-go
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh

if STATUS="$(docker ps --filter 'name=^/dhtnode$' --format '{{.Status}}' 2>/dev/null)" && [[ -n "$STATUS" ]]; then
  echo "dhtnode:     $STATUS"
else
  echo "dhtnode:     not running"
fi

curl -sS --max-time 2 http://127.0.0.1:8080/node/info 2>/dev/null \
  | jq -r '"dht good:    \(.ipv4.good // 0)"' 2>/dev/null || true

if _wg_running; then
  echo "wireguard:   running"
else
  echo "wireguard:   not running"
fi

if PID="$(_stunmesh_pid)"; then
  echo "stunmesh-go: running (pid $PID)"
else
  echo "stunmesh-go: not running"
fi
