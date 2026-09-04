#!/usr/bin/env bash
# launchd.sh — macOS LaunchDaemon supervisor. It owns shutdown cleanup.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "${1:-}" == "run" ]] || { echo "Usage: $0 run" >&2; exit 2; }
[[ "$(uname -s)" == "Darwin" ]] || { echo "✗ launchd supervisor is for macOS only" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || { echo "✗ launchd supervisor must run as root" >&2; exit 1; }

child=""
stopping=0

_stop() {
  (( stopping )) && return 0
  stopping=1
  if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  ./scripts/stop.sh || true
}

trap '_stop; exit 0' TERM INT

./scripts/start.sh --foreground &
child="$!"
set +e
wait "$child"
status=$?
set -e
_stop
exit "$status"
