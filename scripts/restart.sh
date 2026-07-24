#!/usr/bin/env bash
# restart.sh — bounce stunmesh-go only; dhtnode + WireGuard stay up (start.sh skips them)
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh

echo "==> stunmesh-go (restart)"
_stop_stunmesh

exec ./scripts/start.sh
