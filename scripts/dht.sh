#!/usr/bin/env bash
# dht.sh — DHT proxy selection and lifecycle: public Jami proxy first, local
# dhtnode (docker) only as fallback. Sourced after lib.sh; callers cd to repo
# root first. All docker/DHT knowledge lives here and in compose.yaml.
# shellcheck disable=SC2034  # DHT_ENDPOINT is read by the sourcing scripts

DHT_PUBLIC_ENDPOINT="https://dhtproxy3.jami.net"
DHT_LOCAL_ENDPOINT="http://127.0.0.1:8080"
DHT_STARTED=0

# good IPv4 node count a DHT proxy reports; 0 when unreachable or malformed
_dht_good() {
  local good
  good="$(curl -sS --max-time 5 "$1/node/info" 2>/dev/null \
    | jq -r '.ipv4.good // 0' 2>/dev/null || echo 0)"
  [[ "$good" =~ ^[0-9]+$ ]] || good=0
  echo "$good"
}

# picks DHT_ENDPOINT (public first, docker fallback) and starts the fallback
# when needed; sets DHT_STARTED=1 iff this run started the container so the
# caller's rollback only stops what it started
_dht_up() {
  local good project label
  echo "==> DHT proxy"
  DHT_ENDPOINT="$DHT_PUBLIC_ENDPOINT"
  good="$(_dht_good "$DHT_PUBLIC_ENDPOINT")"
  if (( good > 0 )); then
    echo "    public proxy $DHT_PUBLIC_ENDPOINT (good nodes: $good)"
    return 0
  fi

  echo "    public proxy unreachable; falling back to local dhtnode (docker)"
  DHT_ENDPOINT="$DHT_LOCAL_ENDPOINT"
  if ! docker info >/dev/null 2>&1; then
    echo "✗ Public DHT proxy unreachable and Docker daemon not running — no DHT available." >&2
    echo "  Check network, or start Docker Desktop / colima / systemctl start docker for the fallback." >&2
    return 1
  fi
  # compose.yaml pins container_name; a dhtnode from docker run or another compose project collides
  if docker ps -a --format '{{.Names}}' | grep -qx dhtnode; then
    project="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')"
    label="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' dhtnode 2>/dev/null || true)"
    if [[ "$label" != "$project" ]]; then
      echo "✗ Container 'dhtnode' belongs to another Docker project (${label:-unmanaged})." >&2
      echo "  Inspect it first: docker inspect dhtnode" >&2
      echo "  If it is the old tutorial container and safe to remove: docker rm -f dhtnode" >&2
      return 1
    fi
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx dhtnode; then
    DHT_STARTED=1
  fi
  docker compose up -d || return 1

  echo "==> Waiting for DHT bootstrap"
  good=0
  for _ in {1..30}; do
    good="$(_dht_good "$DHT_LOCAL_ENDPOINT")"
    (( good > 0 )) && break
    sleep 2
  done
  if (( good == 0 )); then
    echo "✗ DHT bootstrap failed (ipv4.good=0). Check network, or: docker compose logs dhtnode" >&2
    return 1
  fi
  echo "    ready (good nodes: $good)"
}

# stops the fallback container when present (kept for the next start);
# returns 1 only on a real stop failure — no docker means nothing to clean up
_dht_down() {
  local names
  echo "==> OpenDHT proxy (docker fallback)"
  if ! command -v docker >/dev/null 2>&1; then
    echo "    docker not installed, skipping"
    return 0
  fi
  if names="$(docker ps --format '{{.Names}}' 2>/dev/null)"; then
    if grep -qx dhtnode <<< "$names"; then
      if docker compose stop >/dev/null 2>&1 || docker stop dhtnode >/dev/null; then
        echo "    stopped"
      else
        echo "✗ failed to stop dhtnode" >&2
        return 1
      fi
    else
      echo "    not running"
    fi
  else
    # daemon down usually means no container is running either; warn, don't fail
    echo "    ⚠ cannot inspect docker (daemon not running?); if dhtnode is up, stop it manually" >&2
  fi
}

# best-effort teardown for a failed start's rollback; never fails the caller
_dht_rollback() {
  if (( DHT_STARTED )); then
    docker compose stop >/dev/null 2>&1 || true
  fi
}

# reconcile config.yaml's dht endpoint with the probe result: rewrite when it
# matches a known endpoint, keep a custom value, warn if the line is missing
_dht_sync_endpoint() {
  local config="$1" current
  current="$(sed -nE 's/^ *endpoint: "([^"]*)".*/\1/p' "$config" | head -1)"
  case "$current" in
    "$DHT_ENDPOINT") ;;
    "$DHT_PUBLIC_ENDPOINT"|"$DHT_LOCAL_ENDPOINT")
      sed -i.bak -E "s|^( *endpoint: \")[^\"]*(\")|\\1${DHT_ENDPOINT}\\2|" "$config" ;;
    "")
      echo "    ⚠ no quoted dht endpoint line in config.yaml; wanted $DHT_ENDPOINT — stunmesh-go may use a stale endpoint" >&2 ;;
    *)
      echo "    keeping custom dht endpoint $current (probe picked $DHT_ENDPOINT)" ;;
  esac
}
