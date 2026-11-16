#!/usr/bin/env bash
# ssh_forward_test.sh — `make forward` (ssh.sh forward): -L args per port,
# port validation, local-port clash, fzf multi-pick of the peer's listening ports.
# Everything runs with stubbed ssh/nc/fzf; no real tunnel is touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/scripts" "$TMP/repo/state" "$TMP/bin" "$TMP/home"
cp "$ROOT/scripts/ssh.sh" "$ROOT/scripts/lib.sh" "$TMP/repo/scripts/"
cat > "$TMP/repo/state/settings.env" <<EOF
NODE=A
SELF_IP=10.66.0.1
PEER_IP=10.66.0.2
PEER_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
PEER_SSH_USER=bob
DHT_ENDPOINT=
SSH_KEY_AUTH=
EOF

cat > "$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$STUB_LOG"
# the port-listing call passes a single remote command string after user@host
if [[ "$*" == *lsof* ]]; then
  printf '3000\tnode\n8080\tpython\n5432\tpostgres\n'
fi
exit "${SSH_RC:-0}"
EOF
cat > "$TMP/bin/nc" <<'EOF'
#!/usr/bin/env bash
port="${*: -1}"
[[ " ${NC_BUSY_PORTS:-} " == *" $port "* ]]
EOF
cat > "$TMP/bin/fzf" <<'EOF'
#!/usr/bin/env bash
grep -E "^(3000|8080)"
EOF
chmod +x "$TMP/bin/"*

export STUB_LOG="$TMP/stub.log"
export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
run() { (cd "$TMP/repo" && bash scripts/ssh.sh forward "$@"); }
fail() { echo "FAIL: $*" >&2; exit 1; }

: > "$STUB_LOG"
run --ports "3000 8080" >"$TMP/out" 2>&1 || fail "explicit ports should succeed"
grep -q -- '-L 127.0.0.1:3000:localhost:3000 -L 127.0.0.1:8080:localhost:8080 bob@10.66.0.2' "$STUB_LOG" ||
  fail "expected one ssh -N with both -L forwards: $(cat "$STUB_LOG")"
grep -q -- '-N' "$STUB_LOG" || fail "ssh must run with -N"

: > "$STUB_LOG"
run --ports "3000,9000" >/dev/null 2>&1 || fail "comma-separated ports should work"
grep -q -- '-L 127.0.0.1:9000:localhost:9000' "$STUB_LOG" || fail "comma list not split"

: > "$STUB_LOG"
run --ports "70000" >"$TMP/out" 2>&1 && fail "out-of-range port must fail"
grep -q 'Invalid port' "$TMP/out" || fail "invalid-port message missing"
run --ports "abc" >/dev/null 2>&1 && fail "non-numeric port must fail"
[[ ! -s "$STUB_LOG" ]] || fail "ssh ran despite invalid ports"

NC_BUSY_PORTS="3000" run --ports "3000" >"$TMP/out" 2>&1 && fail "busy local port must fail"
grep -q 'already in use' "$TMP/out" || fail "busy-port message missing"

# no --ports and no terminal: refuse instead of guessing
run </dev/null >"$TMP/out" 2>&1 && fail "no ports and no tty must fail"
grep -q 'PORTS=' "$TMP/out" || fail "usage hint missing"

# fzf path needs a tty on stdin and stderr; script(1) provides one
if command -v script >/dev/null 2>&1; then
  : > "$STUB_LOG"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    script -q /dev/null bash -c "cd '$TMP/repo' && bash scripts/ssh.sh forward" >"$TMP/out" 2>&1 || true
  else
    script -qec "cd '$TMP/repo' && bash scripts/ssh.sh forward" /dev/null >"$TMP/out" 2>&1 || true
  fi
  grep -q -- '-L 127.0.0.1:3000:localhost:3000 -L 127.0.0.1:8080:localhost:8080' "$STUB_LOG" ||
    fail "fzf-picked ports not forwarded: $(cat "$STUB_LOG")"
  ! grep -q 'localhost:5432' "$STUB_LOG" || fail "unpicked port was forwarded"
fi

echo "ssh_forward_test: ok"
