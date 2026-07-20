#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

EXPECTED_IMAGE='ghcr.io/savoirfairelinux/opendht/opendht:v4.1.1@sha256:2da0cbb53c6024c357b9e85c4d86192cf950695f4d4db9f9c02ba8604a8801ff'
grep -Fqx "    image: $EXPECTED_IMAGE" "$ROOT/compose.yaml" || {
  echo "expected OpenDHT image to be pinned by version and multi-arch digest" >&2
  exit 1
}

mkdir -p "$TMP/repo/scripts" "$TMP/repo/state" "$TMP/bin"
cp "$ROOT/scripts/setup.sh" "$ROOT/scripts/lib.sh" "$TMP/repo/scripts/"
cp "$ROOT/compose.yaml" "$TMP/repo/"
printf 'private-key\n' > "$TMP/repo/state/wg.key"
printf 'corrupt\n' > "$TMP/repo/state/stunmesh-go"
chmod +x "$TMP/repo/state/stunmesh-go"

cat > "$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo Linux ;;
  -m) echo x86_64 ;;
  *) echo Linux ;;
esac
EOF
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/wg" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == pubkey ]]; then
  cat >/dev/null
  echo AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
fi
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'verified-download\n' > "$output"
EOF
cat > "$TMP/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  */stunmesh-go) hash=0000000000000000000000000000000000000000000000000000000000000000 ;;
  *) hash=2914c919202a0e8cf61049a60a4600dfb51fe77a0d6489c32ffa4913336d956e ;;
esac
printf '%s  %s\n' "$hash" "$1"
EOF
for command in wireguard-go wg-quick jq; do
  cp "$TMP/bin/docker" "$TMP/bin/$command"
done
chmod +x "$TMP/bin/"*

PATH="$TMP/bin:/usr/bin:/bin" bash "$TMP/repo/scripts/setup.sh" \
  --node A \
  --peer-key BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB= \
  --peer-ssh-user peer-login >/dev/null

grep -qx 'verified-download' "$TMP/repo/state/stunmesh-go" || {
  echo "expected setup to replace an executable with the wrong checksum" >&2
  exit 1
}
[[ -x "$TMP/repo/state/stunmesh-go" ]] || { echo "verified download is not executable" >&2; exit 1; }

echo "ok: release binary and container image are reproducibly pinned"
