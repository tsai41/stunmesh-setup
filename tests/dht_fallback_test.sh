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
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/repo/state/stunmesh-go"
chmod +x "$TMP/repo/state/stunmesh-go"

cat > "$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF
# The selected public endpoint is unavailable.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"ipv4":{"good":0}}'
EOF
cat > "$TMP/bin/jq" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo 0
EOF
cat > "$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/"*

# Docker must not be touched; it is now an explicit candidate, not a fallback.
cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
touch "$TMP/docker-called"
exit 1
EOF
chmod +x "$TMP/bin/docker"
set +e
OUTPUT="$(PATH="$TMP/bin:/usr/bin:/bin" bash "$TMP/repo/scripts/start.sh" 2>&1)"
STATUS=$?
set -e
(( STATUS != 0 )) || { echo "start succeeded with no DHT available: $OUTPUT" >&2; exit 1; }
[[ "$OUTPUT" == *'DHT endpoint unavailable'* ]] || {
  echo "expected a selected-endpoint error, got: $OUTPUT" >&2
  exit 1
}
[[ ! -e "$TMP/docker-called" ]] || { echo "start must not invoke Docker" >&2; exit 1; }

echo "ok: unavailable public DHT fails cleanly without touching Docker"
