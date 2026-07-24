#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/scripts" "$TMP/repo/state" "$TMP/bin"
cp "$ROOT/scripts/start.sh" "$ROOT/scripts/lib.sh" "$ROOT/scripts/dht.sh" "$TMP/repo/scripts/"
cat > "$TMP/repo/state/settings.env" <<'EOF'
NODE=A
SELF_IP=10.66.0.1
PEER_IP=10.66.0.2
PEER_KEY=
PEER_SSH_USER=peer-login
EOF
cat > "$TMP/repo/state/config.yaml" <<'EOF'
interfaces:
  "stunmesh0":
    peers:
      "peer":
        public_key: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
        ping:
          target: "10.66.0.2"
plugins:
  dht:
    endpoint: "http://127.0.0.1:8080"
EOF
cat > "$TMP/repo/state/stunmesh-go" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF
cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
touch "$TMP/docker-called"
exit 0
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"ipv4":{"good":5}}'
EOF
cat > "$TMP/bin/jq" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo 5
EOF
cat > "$TMP/bin/wg-quick" <<EOF
#!/usr/bin/env bash
printf 'wg-quick %s\n' "\$*" >> "$TMP/actions"
EOF
cat > "$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat > "$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/"* "$TMP/repo/state/stunmesh-go"

set +e
OUTPUT="$(PATH="$TMP/bin:/usr/bin:/bin" bash "$TMP/repo/scripts/start.sh" 2>&1)"
set -e

[[ "$OUTPUT" == *'public proxy'* ]] || { echo "expected public proxy pick, got: $OUTPUT" >&2; exit 1; }
if [[ -e "$TMP/docker-called" ]]; then
  echo "public DHT path must not touch docker: $OUTPUT" >&2
  exit 1
fi
grep -q 'endpoint: "https://dhtproxy3.jami.net"' "$TMP/repo/state/config.yaml" || {
  echo "existing config.yaml endpoint was not rewritten to the public proxy" >&2
  exit 1
}

echo "ok: public DHT proxy path skips docker and rewrites the config endpoint"
