#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
mkdir state
. "$ROOT/scripts/lib.sh"

if _valid_ipv4 999.1.2.3; then
  echo "expected IPv4 validation to reject octets over 255" >&2
  exit 1
fi
_valid_ipv4 10.66.0.1

NODE=A
SELF_IP=10.66.0.1
PEER_IP=10.66.0.2
PEER_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
PEER_SSH_USER="peer-login"
_save_settings

EXPECTED="$(printf '%s\n' \
  'NODE=A' \
  'SELF_IP=10.66.0.1' \
  'PEER_IP=10.66.0.2' \
  'PEER_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=' \
  'PEER_SSH_USER=peer-login')"
ACTUAL="$(cat state/settings.env)"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "shared settings writer produced unexpected content" >&2; exit 1; }

echo "ok: shared state helpers validate IPv4 and write canonical settings"
