#!/usr/bin/env bash
# restart.sh — full stop then start, so config changes (a new/removed peer, an
# edited conf) reload the WireGuard interface, not just bounce stunmesh-go
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/stop.sh
exec ./scripts/start.sh
