#!/usr/bin/env bash
# status.sh — project-scoped status for DHT, WireGuard, and stunmesh-go
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh
. ./scripts/dht.sh

echo "dht public:  good $(_dht_good "$DHT_PUBLIC_ENDPOINT") ($DHT_PUBLIC_ENDPOINT)"

if STATUS="$(docker ps --filter 'name=^/dhtnode$' --format '{{.Status}}' 2>/dev/null)" && [[ -n "$STATUS" ]]; then
  echo "dhtnode:     $STATUS (good $(_dht_good "$DHT_LOCAL_ENDPOINT"))"
else
  echo "dhtnode:     not running (fallback)"
fi

if _wg_running; then
  echo "wireguard:   running"
else
  echo "wireguard:   not running"
fi

if PID="$(_stunmesh_pid)"; then
  echo "stunmesh-go: running (pid $PID)"
else
  echo "stunmesh-go: not running"
  if [[ -f "$STATE/stunmesh.log" ]] && PANIC_LINE="$(tail -n 20 "$STATE/stunmesh.log" | grep '^panic:' | tail -1)" && [[ -n "$PANIC_LINE" ]]; then
    echo "  ⚠ crashed — last error: $PANIC_LINE"
    echo "  see: tail -50 $STATE/stunmesh.log"
  fi
fi
