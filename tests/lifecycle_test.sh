#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/scripts" "$TMP/repo/state" "$TMP/bin"
cp "$ROOT/scripts/start.sh" "$ROOT/scripts/stop.sh" "$ROOT/scripts/lib.sh" "$TMP/repo/scripts/"
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
printf 'docker %s\n' "\$*" >> "$TMP/actions"
case "\${1:-} \${2:-}" in
  'info '|'compose up') exit 0 ;;
  'ps -a') exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"ipv4":{"good":1}}'
EOF
cat > "$TMP/bin/jq" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo 1
EOF
cat > "$TMP/bin/wg-quick" <<EOF
#!/usr/bin/env bash
printf 'wg-quick %s\n' "\$*" >> "$TMP/actions"
EOF
cat > "$TMP/bin/sudo" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == kill ]]; then
  printf 'kill failed\n' >> "$TMP/actions"
  exit 1
fi
exec "\$@"
EOF
cat > "$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/"* "$TMP/repo/state/stunmesh-go"

set +e
START_OUTPUT="$(PATH="$TMP/bin:/usr/bin:/bin" bash "$TMP/repo/scripts/start.sh" 2>&1)"
START_STATUS=$?
set -e
(( START_STATUS != 0 )) || { echo "start reported success after stunmesh-go exited: $START_OUTPUT" >&2; exit 1; }
grep -q '^wg-quick down ' "$TMP/actions" || { echo "start failure did not roll back WireGuard" >&2; exit 1; }
grep -q '^docker compose stop' "$TMP/actions" || { echo "start failure did not roll back DHT" >&2; exit 1; }

: > "$TMP/actions"
printf '12345\n' > "$TMP/repo/state/stunmesh.pid"
cat > "$TMP/bin/ps" <<'EOF'
#!/usr/bin/env bash
echo stunmesh-go
EOF
chmod +x "$TMP/bin/ps"
set +e
PATH="$TMP/bin:/usr/bin:/bin" bash "$TMP/repo/scripts/stop.sh" >/dev/null 2>&1
STOP_STATUS=$?
set -e
(( STOP_STATUS != 0 )) || { echo "stop should report the failed kill" >&2; exit 1; }
grep -q '^docker ps ' "$TMP/actions" || { echo "stop abandoned remaining cleanup after kill failed" >&2; exit 1; }

echo "ok: lifecycle verifies startup, rolls back, and performs best-effort stop"
