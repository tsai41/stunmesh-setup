#!/usr/bin/env bash
# ssh_play_test.sh — `make play` (ssh.sh play): copies one peer file into
# state/play/ over ssh and opens it; failures leave no partial file.
# Everything runs with stubbed ssh/open; no real tunnel is touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/scripts" "$TMP/repo/state" "$TMP/bin" "$TMP/home"
cp "$ROOT/scripts/ssh.sh" "$ROOT/scripts/lib.sh" "$TMP/repo/scripts/"
cat > "$TMP/repo/state/settings.env" <<EOF
NODE=B
SELF_IP=10.66.0.2
PEER_IP=10.66.0.1
PEER_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
PEER_SSH_USER=bob
DHT_ENDPOINT=
SSH_KEY_AUTH=
EOF

cat > "$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$STUB_LOG"
[[ "${SSH_RC:-0}" == 0 ]] || exit "$SSH_RC"
printf 'VIDEO-BYTES'
EOF
cat > "$TMP/bin/open" <<'EOF'
#!/usr/bin/env bash
echo "open $*" >> "$STUB_LOG"
EOF
chmod +x "$TMP/bin/"*

export STUB_LOG="$TMP/stub.log"
export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
run() { (cd "$TMP/repo" && bash scripts/ssh.sh play "$@"); }
fail() { echo "FAIL: $*" >&2; exit 1; }
DEST="$TMP/repo/state/play/demo v2.mp4"

: > "$STUB_LOG"
run --file "/Users/alice/my demos/demo v2.mp4" >"$TMP/out" 2>&1 || fail "play should succeed: $(cat "$TMP/out")"
[[ "$(cat "$DEST")" == "VIDEO-BYTES" ]] || fail "file not saved under its own name"
grep -q 'ssh bob@10.66.0.1 cat -- /Users/alice/my\\ demos/demo\\ v2.mp4' "$STUB_LOG" ||
  fail "remote path not quoted once for the remote shell: $(cat "$STUB_LOG")"
grep -q 'open state/play/demo v2.mp4' "$STUB_LOG" || fail "file not opened"
[[ ! -e "$DEST.part" ]] || fail "partial file left behind"

: > "$STUB_LOG"
run >"$TMP/out" 2>&1 && fail "missing FILE must fail"
grep -q 'FILE=' "$TMP/out" || fail "usage hint missing"
run --file "/some/dir/" >"$TMP/out" 2>&1 && fail "directory path must fail"
[[ ! -s "$STUB_LOG" ]] || fail "ssh ran despite a bad FILE"

rm -f "$DEST"
: > "$STUB_LOG"
SSH_RC=1 run --file "/x/gone.mp4" >"$TMP/out" 2>&1 && fail "ssh failure must fail"
grep -q 'Could not read' "$TMP/out" || fail "failure message missing"
[[ -z "$(ls "$TMP/repo/state/play")" ]] || fail "failed copy left a file"
! grep -q '^open' "$STUB_LOG" || fail "opened despite a failed copy"

echo "ssh_play_test: ok"
