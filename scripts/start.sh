#!/usr/bin/env bash
# start.sh — DHT proxy (public, docker fallback) -> wg-quick -> stunmesh-go; sudo needed for interface + daemon
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh
. ./scripts/dht.sh

[[ -f "$STATE/settings.env" ]] || { echo "✗ Run make setup first" >&2; exit 1; }
_load_settings
[[ -x "$STATE/stunmesh-go" ]] || { echo "✗ stunmesh-go missing or not executable; run make setup" >&2; exit 1; }
# a hand-edited config.yaml carries its own peer key; only generation needs settings.env's
if [[ ! -f "$STATE/config.yaml" && -z "${PEER_KEY:-}" ]]; then
  echo "✗ Peer public key missing. This is node $NODE, so it needs node $(_other_node)'s public key —" >&2
  echo "  the one printed by 'make setup' on the other machine, not the key printed here." >&2
  echo "  Run: make setup NODE=$NODE     (it will ask you to paste that key)" >&2
  echo "  Not there yet? 'make next' prints how to get it." >&2
  exit 1
fi
PROBLEMS="$(_config_problems)"
if [[ -n "$PROBLEMS" ]]; then
  {
    echo "✗ Config file issues detected:"
    sed 's/^/  - /' <<< "$PROBLEMS"
    echo "  Run 'make next' for guidance."
  } >&2
  exit 1
fi

WG_STARTED=0
STUN_STARTED=0
START_COMPLETE=0

_rollback_start() {
  local status=$?
  (( START_COMPLETE )) && return "$status"
  set +e
  echo "==> Start failed; rolling back components started by this run" >&2
  if (( STUN_STARTED )); then
    if PID="$(_stunmesh_pid)"; then
      sudo kill "$PID" >/dev/null 2>&1
    fi
    rm -f "$STATE/stunmesh.pid"
  fi
  if (( WG_STARTED )); then
    sudo env PATH="$PATH" wg-quick down "$PWD/$WG_CONF" >/dev/null 2>&1
  fi
  _dht_rollback
  return "$status"
}
trap _rollback_start EXIT

_dht_up

echo "==> WireGuard"
if _wg_running; then
  echo "    already up, skipping"
else
  # keep PATH under sudo so wg-quick can find brew-installed wireguard-go
  WG_STARTED=1
  sudo env PATH="$PATH" wg-quick up "$PWD/$WG_CONF"
fi
if [[ "$OS" == "Darwin" ]]; then
  # newer wireguard-tools create the .name file root-only, so read it with sudo
  UTUN="$(sudo cat "$WG_NAME_FILE")"
else
  UTUN="$WG_CONF_NAME"
fi
echo "    interface: $UTUN ($SELF_IP)"

if [[ -f "$STATE/config.yaml" ]]; then
  # keep user edits; only the interface name (per boot on macOS) and the
  # DHT endpoint (picked by the probe, but never a custom value) change
  sed -i.bak -E "s/^(  \")(utun[0-9]+|${WG_CONF_NAME})(\":)/\\1${UTUN}\\3/" "$STATE/config.yaml"
  _dht_sync_endpoint "$STATE/config.yaml"
  rm -f "$STATE/config.yaml.bak"
  echo "    using existing config.yaml (interface $UTUN)"
else
# utun name may differ per boot, so config is generated at start time
cat > "$STATE/config.yaml" <<EOF
---
refresh_interval: "1m"
log:
  level: "info"
interfaces:
  "$UTUN":
    protocol: "ipv4"
    peers:
      "peer":
        public_key: "$PEER_KEY"
        plugin: dht
        protocol: "ipv4"
        ping:
          enabled: true
          target: "$PEER_IP"
          interval: "30s"
          timeout: "5s"
stun:
  addresses:
    - "stun.l.google.com:19302"
    - "stun1.l.google.com:19302"
plugins:
  dht:
    type: builtin
    name: opendht
    endpoint: "$DHT_ENDPOINT"
    timeout: "15s"
    dedup: false
EOF
fi

echo "==> stunmesh-go"
if PID="$(_stunmesh_pid)"; then
  echo "    already running (pid $PID), skipping"
else
  # stunmesh-go reads config.yaml from cwd, so run inside state/
  sudo bash -c 'cd "$1" || exit 1; nohup ./stunmesh-go >> stunmesh.log 2>&1 & echo $! > stunmesh.pid' bash "$PWD/$STATE"
  STUN_STARTED=1
  PID=""
  for _ in {1..10}; do
    if PID="$(_stunmesh_pid)"; then
      break
    fi
    sleep 0.2
  done
  if [[ -z "$PID" ]]; then
    echo "✗ stunmesh-go exited during startup. Last log lines:" >&2
    tail -n 20 "$STATE/stunmesh.log" >&2 2>/dev/null || true
    exit 1
  fi
  echo "    started (pid $PID), log: $STATE/stunmesh.log"
fi

START_COMPLETE=1
echo
echo "✓ All started. Once both machines are up, the tunnel forms in ~1-2 min. Verify:"
echo "  ping $PEER_IP"
echo "  tail -f $STATE/stunmesh.log"
if [[ "$OS" == "Darwin" ]]; then
  echo
  echo "Note: if this machine can go to sleep, stunmesh-go stops publishing and the"
  echo "      peer loses the tunnel. Check System Settings > Energy (or 'pmset -g'),"
  echo "      or keep it awake while running: caffeinate -i -w \$(cat $STATE/stunmesh.pid)"
fi
