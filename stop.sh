#!/usr/bin/env bash
# stop.sh — stop stunmesh-go + WireGuard + dhtnode (container kept for next start)
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

echo "==> stunmesh-go"
if PID="$(_stunmesh_pid)"; then
  sudo kill "$PID"
  echo "    stopped"
else
  echo "    not running"
fi
rm -f stunmesh.pid

echo "==> WireGuard"
if _wg_running; then
  sudo env PATH="$PATH" wg-quick down "$PWD/${WG_CONF_NAME}.conf"
else
  echo "    not running"
fi

echo "==> OpenDHT proxy"
if docker ps --format '{{.Names}}' | grep -qx dhtnode; then
  docker compose stop >/dev/null 2>&1 || docker stop dhtnode >/dev/null
  echo "    stopped"
else
  echo "    not running"
fi

echo "✓ All stopped"
