#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/scripts" "$TMP/repo/state" "$TMP/bin"
cp "$ROOT/scripts/status.sh" "$ROOT/scripts/lib.sh" "$TMP/repo/scripts/" 2>/dev/null || cp "$ROOT/scripts/lib.sh" "$TMP/repo/scripts/"
printf '999999\n' > "$TMP/repo/state/stunmesh.pid"

cat > "$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == ps ]]; then
  echo 'Up 1 minute'
fi
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"ipv4":{"good":3}}'
EOF
cat > "$TMP/bin/jq" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo 'dht good:    3'
EOF
cat > "$TMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/"*

if [[ ! -f "$TMP/repo/scripts/status.sh" ]]; then
  echo "expected scripts/status.sh to provide project-scoped status" >&2
  exit 1
fi

OUTPUT="$(PATH="$TMP/bin:/usr/bin:/bin" bash "$TMP/repo/scripts/status.sh")"
[[ "$OUTPUT" == *'dhtnode:     Up 1 minute'* ]] || { echo "missing DHT status: $OUTPUT" >&2; exit 1; }
[[ "$OUTPUT" == *'dht good:    3'* ]] || { echo "missing DHT health: $OUTPUT" >&2; exit 1; }
[[ "$OUTPUT" == *'wireguard:   not running'* ]] || { echo "missing WireGuard status: $OUTPUT" >&2; exit 1; }
[[ "$OUTPUT" == *'stunmesh-go: not running'* ]] || { echo "stale pidfile was reported as running: $OUTPUT" >&2; exit 1; }

echo "ok: status is project-scoped and includes every component"
