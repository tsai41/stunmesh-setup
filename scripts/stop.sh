#!/usr/bin/env bash
# stop.sh — stop stunmesh-go + WireGuard + dhtnode if the fallback ran (container kept for next start)
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh
. ./scripts/dht.sh

ERRORS=0

echo "==> stunmesh-go"
_stop_stunmesh || ERRORS=1

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
