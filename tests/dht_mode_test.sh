#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/scripts" "$TMP/repo/state" "$TMP/bin"
cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/dht.sh" "$ROOT/scripts/dht-mode.sh" "$TMP/repo/scripts/"
cat > "$TMP/repo/state/settings.env" <<'EOF'
NODE=A
SELF_IP=10.66.0.1
PEER_IP=10.66.0.2
PEER_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
PEER_SSH_USER=peer
EOF
cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
touch "$TMP/docker-called"
exit 1
EOF
chmod +x "$TMP/bin/docker"

(cd "$TMP/repo" && PATH="$TMP/bin:/usr/bin:/bin" bash scripts/dht-mode.sh local)
grep -qx 'DHT_ENDPOINT=http://127.0.0.1:8080' "$TMP/repo/state/settings.env" || {
  echo "local mode was not persisted" >&2
  exit 1
}
[[ ! -e "$TMP/docker-called" ]] || { echo "choosing local mode must not start Docker" >&2; exit 1; }

(cd "$TMP/repo" && PATH="$TMP/bin:/usr/bin:/bin" bash scripts/dht-mode.sh public)
grep -qx 'DHT_ENDPOINT=https://dhtproxy3.jami.net' "$TMP/repo/state/settings.env" || {
  echo "public mode was not persisted" >&2
  exit 1
}

echo "ok: DHT endpoint selection is explicit and persistent"
