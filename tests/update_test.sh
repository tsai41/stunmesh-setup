#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/scripts" "$TMP/repo/state" "$TMP/bin"
cp "$ROOT/scripts/update.sh" "$ROOT/scripts/lib.sh" "$TMP/repo/scripts/"
printf 'NODE=A\n' > "$TMP/repo/state/settings.env"
printf 'old-release\n' > "$TMP/repo/state/stunmesh-go"
chmod +x "$TMP/repo/state/stunmesh-go"

cat > "$TMP/bin/uname" <<'EOF2'
#!/usr/bin/env bash
case "${1:-}" in
  -m) echo x86_64 ;;
  *) echo Linux ;;
esac
EOF2
cat > "$TMP/bin/jq" <<'EOF2'
#!/usr/bin/env bash
# release JSON stub: tag lookup, then the asset digest lookup
if [[ "$*" == *tag_name* ]]; then
  echo v9.9.9
else
  echo sha256:1111111111111111111111111111111111111111111111111111111111111111
fi
EOF2
cat > "$TMP/bin/curl" <<EOF2
#!/usr/bin/env bash
output=''
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) output="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\$output" ]] || exit 0
touch "$TMP/downloaded"
printf 'new-release\n' > "\$output"
EOF2
# checksum follows the content, so the first run sees a stale binary and the second sees a current one
cat > "$TMP/bin/sha256sum" <<'EOF2'
#!/usr/bin/env bash
if grep -q new-release "$1"; then
  hash=1111111111111111111111111111111111111111111111111111111111111111
else
  hash=0000000000000000000000000000000000000000000000000000000000000000
fi
printf '%s  %s\n' "$hash" "$1"
EOF2
cat > "$TMP/bin/sudo" <<EOF2
#!/usr/bin/env bash
touch "$TMP/sudo-called"
exit 1
EOF2
chmod +x "$TMP/bin/"*

OUTPUT="$(PATH="$TMP/bin:/usr/bin:/bin" bash "$TMP/repo/scripts/update.sh" 2>&1)"
[[ -e "$TMP/downloaded" ]] || { echo "expected a stale binary to be downloaded" >&2; exit 1; }
grep -qx 'new-release' "$TMP/repo/state/stunmesh-go" || { echo "expected state/stunmesh-go to hold the new release" >&2; exit 1; }
[[ -x "$TMP/repo/state/stunmesh-go" ]] || { echo "updated binary is not executable" >&2; exit 1; }
[[ "$OUTPUT" == *"updated to v9.9.9"* ]] || { echo "expected an updated message, got: $OUTPUT" >&2; exit 1; }
[[ ! -e "$TMP/sudo-called" ]] || { echo "expected no restart when stunmesh-go is not running" >&2; exit 1; }

rm -f "$TMP/downloaded"
OUTPUT="$(PATH="$TMP/bin:/usr/bin:/bin" bash "$TMP/repo/scripts/update.sh" 2>&1)"
[[ ! -e "$TMP/downloaded" ]] || { echo "expected no download when the binary is already current" >&2; exit 1; }
[[ "$OUTPUT" == *"already v9.9.9"* ]] || { echo "expected an already-current message, got: $OUTPUT" >&2; exit 1; }

printf 'NODE=A\n' > "$TMP/repo/state/settings.env"
rm -f "$TMP/repo/state/settings.env"
set +e
OUTPUT="$(PATH="$TMP/bin:/usr/bin:/bin" bash "$TMP/repo/scripts/update.sh" 2>&1)"
STATUS=$?
set -e
(( STATUS != 0 )) || { echo "expected update to refuse before setup" >&2; exit 1; }
[[ "$OUTPUT" == *"Run make setup first"* ]] || { echo "expected a setup hint, got: $OUTPUT" >&2; exit 1; }

echo "ok: update fetches only a newer release and leaves a stopped daemon alone"
