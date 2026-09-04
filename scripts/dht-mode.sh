#!/usr/bin/env bash
# dht-mode.sh — persist the endpoint used by start and the boot-time service.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh
. ./scripts/dht.sh

[[ -f "$STATE/settings.env" ]] || { echo "✗ Run make setup first" >&2; exit 1; }
case "${1:-}" in
  public) DHT_ENDPOINT="$DHT_PUBLIC_ENDPOINT" ;;
  local) DHT_ENDPOINT="$DHT_LOCAL_ENDPOINT" ;;
  *) echo "Usage: $0 {public|local}" >&2; exit 2 ;;
esac
_load_settings
case "$1" in
  public) DHT_ENDPOINT="$DHT_PUBLIC_ENDPOINT" ;;
  local) DHT_ENDPOINT="$DHT_LOCAL_ENDPOINT" ;;
esac
_save_settings
echo "✓ DHT endpoint selected: $DHT_ENDPOINT"
