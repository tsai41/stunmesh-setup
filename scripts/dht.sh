#!/usr/bin/env bash
# dht.sh — DHT endpoint selection and health checks. Docker lifecycle is kept
# in dht-local.sh and is always explicit. Sourced after lib.sh; callers cd to
# repo root first.
# shellcheck disable=SC2034  # DHT_ENDPOINT is read by the sourcing scripts

DHT_PUBLIC_ENDPOINT="https://dhtproxy3.jami.net"
DHT_LOCAL_ENDPOINT="http://127.0.0.1:8080"

# good IPv4 node count a DHT proxy reports; 0 when unreachable or malformed
_dht_good() {
  local good
  good="$(curl -sS --max-time 5 "$1/node/info" 2>/dev/null \
    | jq -r '.ipv4.good // 0' 2>/dev/null || echo 0)"
  [[ "$good" =~ ^[0-9]+$ ]] || good=0
  echo "$good"
}

# Selects the persisted endpoint (public by default) and requires it to be
# reachable. This intentionally never invokes Docker.
_dht_up() {
  local good
  echo "==> DHT proxy"
  DHT_ENDPOINT="${DHT_ENDPOINT:-$DHT_PUBLIC_ENDPOINT}"
  good="$(_dht_good "$DHT_ENDPOINT")"
  if (( good == 0 )); then
    echo "✗ DHT endpoint unavailable: $DHT_ENDPOINT" >&2
    echo "  Check the network, or explicitly choose/start a local endpoint with:" >&2
    echo "  make dht-local-up && make dht-use-local" >&2
    return 1
  fi
  if [[ "$DHT_ENDPOINT" == "$DHT_PUBLIC_ENDPOINT" ]]; then
    echo "    public proxy $DHT_ENDPOINT (good nodes: $good)"
  else
    echo "    selected endpoint $DHT_ENDPOINT (good nodes: $good)"
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
