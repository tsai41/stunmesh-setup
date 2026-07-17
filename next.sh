#!/usr/bin/env bash
# next.sh — first-time guide: inspect current state, print the single next step
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

if [[ ! -f settings.env ]]; then
  echo "Next: ./setup.sh --node A     (use --node B on the other machine)"
  exit 0
fi
. ./settings.env

PUB_KEY=""
[[ -f wg.key ]] && PUB_KEY="$(wg pubkey < wg.key 2>/dev/null || true)"

if [[ -z "${PEER_KEY:-}" ]]; then
  echo "Waiting for the OTHER machine's key."
  if [[ -n "$PUB_KEY" ]]; then
    echo "1. Send this machine's key to the other machine:"
    echo "     $PUB_KEY"
    echo "2. On the other machine: ./setup.sh --node $([[ "$NODE" == "A" ]] && echo B || echo A) --peer-key $PUB_KEY"
    echo "3. It prints ITS key; bring that back here and run:"
    echo "     ./setup.sh --node $NODE --peer-key <KEY_FROM_OTHER_MACHINE>"
  fi
  exit 0
fi

if [[ -n "$PUB_KEY" && "$PEER_KEY" == "$PUB_KEY" ]]; then
  echo "✗ settings.env holds this machine's OWN key (a previous mix-up)."
  echo "  Re-run: ./setup.sh --node $NODE --peer-key <KEY_FROM_OTHER_MACHINE>"
  exit 1
fi

PROBLEMS="$(_config_problems)"
if [[ -n "$PROBLEMS" ]]; then
  echo "✗ Config file issues detected:"
  sed 's/^/  - /' <<< "$PROBLEMS"
  echo "  Fix: re-run ./setup.sh --node $NODE --peer-key <KEY> (regenerates and syncs), or edit the file. Then: make next"
  exit 1
fi

if _wg_running && _stunmesh_pid >/dev/null; then
  echo "Everything is running. Verify the tunnel:"
  echo "  ping $PEER_IP        (log: tail -f stunmesh.log, status: make status)"
else
  echo "Setup complete. Next: ./start.sh"
  echo "(remember to run start on the other machine too, then: ping $PEER_IP)"
fi
