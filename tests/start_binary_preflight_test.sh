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

if (( STATUS == 0 )); then
  echo "expected start to fail when state/stunmesh-go is not executable" >&2
  exit 1
fi
if [[ "$OUTPUT" != *"stunmesh-go missing or not executable; run make setup"* ]]; then
  echo "expected a setup recovery hint, got: $OUTPUT" >&2
  exit 1
fi
if [[ -e "$TMP/docker-called" ]]; then
  echo "expected binary preflight before Docker is touched" >&2
  exit 1
fi

echo "ok: start rejects a missing stunmesh-go before starting services"
