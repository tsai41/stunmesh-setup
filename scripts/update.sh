#!/usr/bin/env bash
# update.sh — install the newest verified stunmesh-go release. If its daemon
# is running, restart only that daemon; WireGuard and the DHT stay in place.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh

[[ -f "$STATE/settings.env" ]] || { echo "✗ Run make setup first" >&2; exit 1; }
for command in curl jq; do
  command -v "$command" >/dev/null 2>&1 || { echo "✗ $command is required (make setup lists install hints)" >&2; exit 1; }
done

_install_stunmesh_go

if (( ! STUNMESH_UPDATED )); then
  echo "✓ stunmesh-go is already ${STUNMESH_VERSION}"
  exit 0
fi

if ! _stunmesh_pid >/dev/null; then
  echo "✓ stunmesh-go updated to ${STUNMESH_VERSION}; it will run on the next make start"
  exit 0
fi

echo "==> Restarting stunmesh-go on ${STUNMESH_VERSION} (tunnel re-punches in ~1-2 min)"
_stop_stunmesh
exec ./scripts/start.sh
