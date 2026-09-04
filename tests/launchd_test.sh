#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for target in launchd-install launchd-uninstall launchd-status launchd-restart dht-local-up dht-local-down dht-use-local dht-use-public; do
  make -C "$ROOT" -n "$target" >/dev/null || {
    echo "missing make target: $target" >&2
    exit 1
  }
done

[[ -x "$ROOT/scripts/launchd.sh" ]] || { echo "missing launchd supervisor" >&2; exit 1; }
[[ -x "$ROOT/scripts/launchd-install.sh" ]] || { echo "missing launchd installer" >&2; exit 1; }
[[ -x "$ROOT/scripts/dht-local.sh" ]] || { echo "missing explicit local DHT helper" >&2; exit 1; }
[[ -x "$ROOT/scripts/dht-mode.sh" ]] || { echo "missing DHT mode helper" >&2; exit 1; }

PLIST="$ROOT/launchd/macos/com.stunmesh.setup.plist.in"
[[ -f "$PLIST" ]] || { echo "missing macOS launchd plist template" >&2; exit 1; }
grep -q '<key>RunAtLoad</key>' "$PLIST" || { echo "plist does not start at load" >&2; exit 1; }
grep -q '<key>KeepAlive</key>' "$PLIST" || { echo "plist does not supervise the service" >&2; exit 1; }
grep -q '<key>ThrottleInterval</key>' "$PLIST" || { echo "plist has no restart throttle" >&2; exit 1; }
grep -q '@REPO_ROOT@/scripts/launchd.sh' "$PLIST" || { echo "plist does not run the repo supervisor" >&2; exit 1; }

echo "ok: macOS launchd entry points and template are present"
