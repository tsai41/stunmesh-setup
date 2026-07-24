#!/usr/bin/env bash
# stop.sh — stop stunmesh-go + WireGuard + dhtnode if the fallback ran (container kept for next start)
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh
. ./scripts/dht.sh

ERRORS=0

echo "==> stunmesh-go"
if PID="$(_stunmesh_pid)"; then
  if sudo kill "$PID"; then
    for _ in {1..20}; do
      _stunmesh_pid >/dev/null || break
      sleep 0.1
    done
    if _stunmesh_pid >/dev/null; then
      echo "✗ stunmesh-go did not stop after SIGTERM" >&2
      ERRORS=1
    else
      echo "    stopped"
    fi
  else
    echo "✗ failed to stop stunmesh-go (pid $PID)" >&2
    ERRORS=1
  fi
else
  echo "    not running"
fi
rm -f "$STATE/stunmesh.pid"

echo "==> WireGuard"
if _wg_running; then
  if ! sudo env PATH="$PATH" wg-quick down "$PWD/$WG_CONF"; then
    echo "✗ failed to stop WireGuard" >&2
    ERRORS=1
  fi
else
  echo "    not running"
fi

_dht_down || ERRORS=1

if (( ERRORS )); then
  echo "✗ Stop completed with errors" >&2
  exit 1
fi
echo "✓ All stopped"
