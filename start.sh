#!/usr/bin/env bash
# start.sh — dhtnode (compose) -> wg-quick -> stunmesh-go; sudo needed for interface + daemon
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

[[ -f settings.env ]] || { echo "✗ Run ./setup.sh first" >&2; exit 1; }
. ./settings.env
# a hand-edited config.yaml carries its own peer key; only generation needs settings.env's
if [[ ! -f config.yaml && -z "${PEER_KEY:-}" ]]; then
  echo "✗ Peer public key missing; run ./setup.sh --node $NODE --peer-key <KEY> (or hand-edit config.yaml)" >&2
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

echo "==> OpenDHT proxy (docker compose)"
# compose.yaml pins container_name; a dhtnode from docker run or another compose project collides
if docker ps -a --format '{{.Names}}' | grep -qx dhtnode; then
  PROJECT="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')"
  LABEL="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' dhtnode 2>/dev/null || true)"
  if [[ "$LABEL" != "$PROJECT" ]]; then
    docker rm -f dhtnode >/dev/null
  fi
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
  sudo env PATH="$PATH" wg-quick up "$PWD/${WG_CONF_NAME}.conf"
fi
if [[ "$OS" == "Darwin" ]]; then
  UTUN="$(cat "$WG_NAME_FILE")"
else
  UTUN="$WG_CONF_NAME"
fi
echo "    interface: $UTUN ($SELF_IP)"

if [[ -f config.yaml ]]; then
  # keep user edits; only the interface name changes per boot on macOS
  sed -i.bak -E "s/^(  \")(utun[0-9]+|${WG_CONF_NAME})(\":)/\\1${UTUN}\\3/" config.yaml
  rm -f config.yaml.bak
  echo "    using existing config.yaml (interface set to $UTUN)"
else
# utun name may differ per boot, so config is generated at start time
cat > config.yaml <<EOF
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
  sudo bash -c "cd '$PWD' && nohup ./stunmesh-go >> stunmesh.log 2>&1 & echo \$! > stunmesh.pid"
  echo "    started (pid $(cat stunmesh.pid)), log: stunmesh.log"
fi

echo
echo "✓ All started. Once both machines are up, the tunnel forms in ~1-2 min. Verify:"
echo "  ping $PEER_IP"
echo "  tail -f stunmesh.log"
