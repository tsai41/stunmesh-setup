#!/usr/bin/env bash
# stop.sh — stop stunmesh-go + WireGuard. Local Docker DHT is managed explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh

ERRORS=0

echo "==> stunmesh-go"
_stop_stunmesh || ERRORS=1

# before WireGuard: the proxy's ssh rides the tunnel
echo "==> SOCKS proxy"
_stop_proxy || ERRORS=1

echo "==> WireGuard"
if _wg_running; then
  if ! sudo env PATH="$PATH" wg-quick down "$PWD/$WG_CONF"; then
    echo "✗ failed to stop WireGuard" >&2
    ERRORS=1
  fi
else
  echo "    not running"
fi

if (( ERRORS )); then
  echo "✗ Stop completed with errors" >&2
  exit 1
fi
echo "✓ All stopped"
