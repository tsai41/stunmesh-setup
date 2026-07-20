#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/scripts" "$TMP/repo/state" "$TMP/bin"
cp "$ROOT/scripts/setup.sh" "$ROOT/scripts/lib.sh" "$TMP/repo/scripts/"
cp "$ROOT/compose.yaml" "$TMP/repo/"
printf 'private-key\n' > "$TMP/repo/state/wg.key"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/repo/state/stunmesh-go"
chmod +x "$TMP/repo/state/stunmesh-go"

cat > "$TMP/bin/wg" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "pubkey" ]]; then
  cat >/dev/null
  printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
fi
EOF
cat > "$TMP/bin/shasum" <<'EOF'
#!/usr/bin/env bash
case "$(uname -m)" in
  arm64) hash=8b6d12226db02f8c1c38e5040f4dfb2c726d440596e78d0f34e5bcbbba799f3f ;;
  *) hash=8994a430baed23020a755a9997c40323225a43d3fe6c6f930954005311491597 ;;
esac
printf '%s  %s\n' "$hash" "${@: -1}"
EOF
for command in wireguard-go wg-quick jq docker; do
  cp "$TMP/bin/wg" "$TMP/bin/$command"
done
chmod +x "$TMP/bin/"*

cat > "$TMP/run.exp" <<'EOF'
set timeout 5
set repo [lindex $argv 0]
set fake_path [lindex $argv 1]
spawn env PATH=$fake_path:/usr/bin:/bin bash $repo/scripts/setup.sh --node A --peer-key BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
expect "Other machine's SSH user (Enter = same as this machine): "
send "peer-login\r"
expect eof
catch wait result
exit [lindex $result 3]
EOF

expect "$TMP/run.exp" "$TMP/repo" "$TMP/bin"

if ! grep -qx 'PEER_SSH_USER=peer-login' "$TMP/repo/state/settings.env"; then
  echo "expected setup to save the prompted peer SSH user" >&2
  exit 1
fi

echo "ok: setup saves the prompted peer SSH user"
