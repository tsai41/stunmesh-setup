#!/usr/bin/env bash
# next.sh — first-time guide: inspect current state, print the single next step
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh

if [[ ! -f "$STATE/settings.env" ]]; then
  echo "Next: make setup NODE=A     (use NODE=B on the other machine)"
  exit 0
fi
_load_settings

PUB_KEY=""
[[ -f "$STATE/wg.key" ]] && PUB_KEY="$(wg pubkey < "$STATE/wg.key" 2>/dev/null || true)"

if [[ -z "${PEER_KEY:-}" ]]; then
  echo "Waiting for the OTHER machine's key."
  if [[ -n "$PUB_KEY" ]]; then
    echo "1. Send this machine's key to the other machine:"
    echo "     $PUB_KEY"
    echo "2. On the other machine: make setup NODE=$([[ "$NODE" == "A" ]] && echo B || echo A) PEER_KEY=$PUB_KEY"
    echo "3. It prints ITS key; bring that back here and run:"
    echo "     make setup NODE=$NODE PEER_KEY=<the key node $(_other_node) printed>"
  fi
  exit 0
fi

if [[ -n "$PUB_KEY" && "$PEER_KEY" == "$PUB_KEY" ]]; then
  echo "✗ settings.env holds this machine's OWN key (a previous mix-up)."
  echo "  Re-run: make setup NODE=$NODE PEER_KEY=<the key node $(_other_node) printed>"
  exit 1
fi

PROBLEMS="$(_config_problems)"
if [[ -n "$PROBLEMS" ]]; then
  echo "✗ Config file issues detected:"
  sed 's/^/  - /' <<< "$PROBLEMS"
  echo "  Fix: re-run make setup NODE=$NODE and paste node $(_other_node)'s public key when asked"
  exit 1
fi

if _wg_running && _stunmesh_pid >/dev/null; then
  echo "Everything is running. Verify the tunnel:"
  echo "  ping $PEER_IP        (log: tail -f $STATE/stunmesh.log, status: make status)"
else
  echo "Setup complete. Next: make start"
  echo "(remember to run start on the other machine too, then: ping $PEER_IP)"
fi
