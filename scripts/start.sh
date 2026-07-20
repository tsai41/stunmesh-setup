#!/usr/bin/env bash
# start.sh — dhtnode (compose) -> wg-quick -> stunmesh-go; sudo needed for interface + daemon
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh

[[ -f "$STATE/settings.env" ]] || { echo "✗ Run make setup first" >&2; exit 1; }
_load_settings
[[ -x "$STATE/stunmesh-go" ]] || { echo "✗ stunmesh-go missing or not executable; run make setup" >&2; exit 1; }
# a hand-edited config.yaml carries its own peer key; only generation needs settings.env's
if [[ ! -f "$STATE/config.yaml" && -z "${PEER_KEY:-}" ]]; then
  echo "✗ Peer public key missing; run make setup NODE=$NODE PEER_KEY=<KEY> (or hand-edit $STATE/config.yaml)" >&2
  exit 1
fi
docker info >/dev/null 2>&1 || { echo "✗ Docker daemon not running; start Docker Desktop / colima / systemctl start docker" >&2; exit 1; }

PROBLEMS="$(_config_problems)"
if [[ -n "$PROBLEMS" ]]; then
  {
    echo "✗ Config file issues detected:"
    sed 's/^/  - /' <<< "$PROBLEMS"
    echo "  Run 'make next' for guidance."
  } >&2
  exit 1
fi

DHT_STARTED=0
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
  if (( DHT_STARTED )); then
    docker compose stop >/dev/null 2>&1
  fi
  return "$status"
}
trap _rollback_start EXIT

echo "==> OpenDHT proxy (docker compose)"
# compose.yaml pins container_name; a dhtnode from docker run or another compose project collides
if docker ps -a --format '{{.Names}}' | grep -qx dhtnode; then
  PROJECT="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')"
  LABEL="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' dhtnode 2>/dev/null || true)"
  if [[ "$LABEL" != "$PROJECT" ]]; then
    echo "✗ Container 'dhtnode' belongs to another Docker project (${LABEL:-unmanaged})." >&2
    echo "  Inspect it first: docker inspect dhtnode" >&2
    echo "  If it is the old tutorial container and safe to remove: docker rm -f dhtnode" >&2
    exit 1
  fi
fi
if ! docker ps --format '{{.Names}}' | grep -qx dhtnode; then
  DHT_STARTED=1
fi
docker compose up -d

echo "==> Waiting for DHT bootstrap"
GOOD=0
for _ in {1..30}; do
  GOOD="$(curl -sS --max-time 2 http://127.0.0.1:8080/node/info 2>/dev/null \
    | jq -r '.ipv4.good // 0' 2>/dev/null || echo 0)"
  [[ "$GOOD" =~ ^[0-9]+$ ]] || GOOD=0
  (( GOOD > 0 )) && break
  sleep 2
done
if (( GOOD == 0 )); then
  echo "✗ DHT bootstrap failed (ipv4.good=0). Check network, or: docker compose logs dhtnode" >&2
  exit 1
fi
echo "    ready (good nodes: $GOOD)"

echo "==> WireGuard"
if _wg_running; then
  echo "    already up, skipping"
else
  # keep PATH under sudo so wg-quick can find brew-installed wireguard-go
  WG_STARTED=1
  sudo env PATH="$PATH" wg-quick up "$PWD/$WG_CONF"
fi
if [[ "$OS" == "Darwin" ]]; then
  UTUN="$(cat "$WG_NAME_FILE")"
else
  UTUN="$WG_CONF_NAME"
fi
echo "    interface: $UTUN ($SELF_IP)"

if [[ -f "$STATE/config.yaml" ]]; then
  # keep user edits; only the interface name changes per boot on macOS
  sed -i.bak -E "s/^(  \")(utun[0-9]+|${WG_CONF_NAME})(\":)/\\1${UTUN}\\3/" "$STATE/config.yaml"
  rm -f "$STATE/config.yaml.bak"
  echo "    using existing config.yaml (interface set to $UTUN)"
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
    endpoint: "http://127.0.0.1:8080"
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
