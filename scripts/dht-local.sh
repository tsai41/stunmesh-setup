#!/usr/bin/env bash
# dht-local.sh — explicit lifecycle for the optional local Docker DHT.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/dht.sh

case "${1:-}" in
  up)
    docker compose up -d
    echo "✓ Local dhtnode started. Select it with: make dht-use-local"
    ;;
  down)
    docker compose stop
    echo "✓ Local dhtnode stopped. Select the public proxy with: make dht-use-public"
    ;;
  *) echo "Usage: $0 {up|down}" >&2; exit 2 ;;
esac
