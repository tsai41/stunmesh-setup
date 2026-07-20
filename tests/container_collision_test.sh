#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/scripts" "$TMP/repo/state" "$TMP/bin"
cp "$ROOT/scripts/start.sh" "$ROOT/scripts/lib.sh" "$TMP/repo/scripts/"
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

cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  'info ') exit 0 ;;
  'ps -a') echo dhtnode ;;
  'inspect -f') echo another-project ;;
  'rm -f') touch "$TMP/foreign-container-removed"; exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"

set +e
OUTPUT="$(PATH="$TMP/bin:/usr/bin:/bin" bash "$TMP/repo/scripts/start.sh" 2>&1)"
STATUS=$?
set -e

(( STATUS != 0 )) || { echo "expected start to refuse a foreign dhtnode container" >&2; exit 1; }
[[ "$OUTPUT" == *"belongs to another Docker project"* ]] || {
  echo "expected an actionable collision error, got: $OUTPUT" >&2
  exit 1
}
[[ ! -e "$TMP/foreign-container-removed" ]] || {
  echo "start removed a foreign dhtnode container" >&2
  exit 1
}

echo "ok: start refuses to remove a foreign dhtnode container"
