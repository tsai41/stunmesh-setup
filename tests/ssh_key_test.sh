#!/usr/bin/env bash
# ssh_key_test.sh — `make ssh-key` (ssh.sh key): key reuse, macOS-only refusal,
# managed ssh.conf key lines, setup re-run, port-22 probes, teardown hint.
# Everything runs under a fake HOME with stubbed ssh tools.
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

REAL_UNAME="$(command -v uname)"
cat > "$TMP/bin/uname" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-s" ]]; then echo "\${FAKE_OS:-Darwin}"; else exec "$REAL_UNAME" "\$@"; fi
EOF
cat > "$TMP/bin/hostname" <<'EOF'
#!/usr/bin/env bash
echo testhost
EOF
cat > "$TMP/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
echo "ssh-keygen $*" >> "$STUB_LOG"
while [[ $# -gt 0 ]]; do [[ "$1" == "-f" ]] && f="$2"; shift; done
echo "PRIVATE-NEW" > "$f"
echo "ssh-ed25519 AAAA testhost-stunmesh" > "$f.pub"
EOF
cat > "$TMP/bin/ssh-add" <<'EOF'
#!/usr/bin/env bash
echo "ssh-add $*" >> "$STUB_LOG"
exit "${SSH_ADD_RC:-0}"
EOF
cat > "$TMP/bin/ssh-copy-id" <<'EOF'
#!/usr/bin/env bash
echo "ssh-copy-id $*" >> "$STUB_LOG"
EOF
cat > "$TMP/bin/nc" <<'EOF'
#!/usr/bin/env bash
host="${*: -2:1}"
echo "nc $host" >> "$STUB_LOG"
[[ " ${NC_FAIL_HOSTS:-} " != *" $host "* ]]
EOF
cat > "$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-V" ]]; then echo "OpenSSH_9.0p1" >&2; exit 0; fi
echo "ssh $*" >> "$STUB_LOG"
exit "${SSH_VERIFY_RC:-0}"
EOF
chmod +x "$TMP/bin/"*

export STUB_LOG="$TMP/stub.log"
export HOME="$TMP/home"
export SSH_ADD_BIN="$TMP/bin/ssh-add"
export PATH="$TMP/bin:$PATH"
KEY="$HOME/.ssh/id_ed25519_stunmesh"
CONF="$TMP/repo/state/ssh.conf"
run() { (cd "$TMP/repo" && bash scripts/ssh.sh "$@"); }
fail() { echo "FAIL: $*" >&2; exit 1; }

: > "$STUB_LOG"
FAKE_OS=Linux run key >"$TMP/out" 2>&1 && fail "non-Darwin must exit non-zero"
grep -q 'macOS only' "$TMP/out" || fail "non-Darwin message missing"
[[ ! -e "$HOME/.ssh" ]] || fail "non-Darwin must not touch ~/.ssh"

: > "$STUB_LOG"
NC_FAIL_HOSTS="10.66.0.2" run key >"$TMP/out" 2>&1 && fail "unreachable port 22 must exit non-zero"
grep -q 'Remote Login' "$TMP/out" || fail "unreachable hint missing"
! grep -q ssh-copy-id "$STUB_LOG" || fail "ssh-copy-id ran despite unreachable peer"
[[ ! -e "$KEY" ]] || fail "key created despite unreachable peer"

: > "$STUB_LOG"
NC_FAIL_HOSTS="127.0.0.1" run key >"$TMP/out" 2>&1 || fail "local Remote Login off must only warn"
grep -q 'THIS Mac' "$TMP/out" || fail "local Remote Login warning missing"
grep -q 'make ssh-key on the other Mac' "$TMP/out" || fail "reverse-login hint missing"
grep -q 'ssh-copy-id -i .*id_ed25519_stunmesh.pub bob@10.66.0.2' "$STUB_LOG" || fail "ssh-copy-id args wrong"
grep -q 'ssh-add --apple-use-keychain' "$STUB_LOG" || fail "ssh-add not called"
grep -qx "    IdentityFile $KEY" "$CONF" || fail "ssh.conf lacks IdentityFile"
for line in "IdentitiesOnly yes" "AddKeysToAgent yes" "IgnoreUnknown UseKeychain" "UseKeychain yes"; do
  grep -qx "    $line" "$CONF" || fail "ssh.conf lacks $line"
done
grep -qx 'SSH_KEY_AUTH=1' "$TMP/repo/state/settings.env" || fail "flag not persisted"
grep -qx 'PEER_IP=10.66.0.2' "$TMP/repo/state/settings.env" || fail "settings clobbered"
grep -qx 'Host stunmesh-peer 10.66.0.2' "$CONF" || fail "Host line lacks the peer IP for make ssh"
IGN="$(grep -n 'IgnoreUnknown UseKeychain' "$CONF" | cut -d: -f1)"
USEK="$(grep -n 'UseKeychain yes' "$CONF" | cut -d: -f1)"
(( IGN < USEK )) || fail "IgnoreUnknown must precede UseKeychain"

echo "PRIVATE-EXISTING" > "$KEY"
: > "$STUB_LOG"
run key >"$TMP/out" 2>&1 || fail "second run failed"
grep -qx 'PRIVATE-EXISTING' "$KEY" || fail "existing key overwritten"
grep -qx 'Host stunmesh-peer 10.66.0.2' "$CONF" || fail "re-run took the peer IP for a custom alias"
! grep -q '^ssh-keygen -t' "$STUB_LOG" || fail "ssh-keygen generated over an existing key"
! grep -q -e '-N' "$STUB_LOG" || fail "passphrase must not be passed to ssh-keygen"

: > "$STUB_LOG"
run key --user carol >"$TMP/out" 2>&1 || fail "key --user failed"
grep -qx 'PEER_SSH_USER=carol' "$TMP/repo/state/settings.env" || fail "USER not persisted by ssh-key"
grep -q 'ssh-copy-id .* carol@10.66.0.2' "$STUB_LOG" || fail "ssh-copy-id ignored USER"
run setup >/dev/null 2>&1 || fail "ssh-setup re-run failed"
grep -qx "    IdentityFile $KEY" "$CONF" || fail "ssh-setup re-run dropped key lines"
grep -qx '    User carol' "$CONF" || fail "plain ssh-setup reverted the user"

# preflight failure must leave no new key behind
cp "$HOME/.ssh/config" "$TMP/config.bak"
mv "$KEY" "$TMP/key.bak"; mv "$KEY.pub" "$TMP/key.pub.bak"
printf 'Host stunmesh-peer\n    HostName x\n' >> "$HOME/.ssh/config"
: > "$STUB_LOG"
run key >"$TMP/out" 2>&1 && fail "taken alias must fail ssh-key"
grep -q "already exists" "$TMP/out" || fail "alias-taken message missing"
! grep -q '^ssh-keygen' "$STUB_LOG" || fail "ssh-keygen ran despite failed preflight"
! grep -q '^ssh-add' "$STUB_LOG" || fail "ssh-add ran despite failed preflight"
[[ ! -e "$KEY" ]] || fail "key created despite failed preflight"
cp "$TMP/config.bak" "$HOME/.ssh/config"

# key without .pub: no regeneration, hint instead
echo "PRIVATE-EXISTING" > "$KEY"
: > "$STUB_LOG"
run key >"$TMP/out" 2>&1 && fail "missing .pub must fail"
grep -q '✗' "$TMP/out" || fail "missing .pub lacks error mark"
grep -q "ssh-keygen -y -f $KEY > $KEY.pub" "$TMP/out" || fail "missing .pub lacks hint command"
! grep -q 'ssh-copy-id' "$STUB_LOG" || fail "ssh-copy-id ran without .pub"
! grep -q '^ssh-keygen' "$STUB_LOG" || fail "ssh-keygen ran on missing .pub"
[[ ! -e "$KEY.pub" ]] || fail ".pub regenerated"

# teardown without .pub: no blob command
run teardown >"$TMP/out" 2>&1 || fail "teardown (no pub) failed"
grep -q 'authorized_keys' "$TMP/out" || fail "teardown lacks revoke instruction"
! grep -q 'grep -vF' "$TMP/out" || fail "teardown printed a blob command without .pub"

# ssh-add failure followed by a failed verify must point at ssh-add
echo "ssh-ed25519 AAAA testhost-stunmesh" > "$KEY.pub"
: > "$STUB_LOG"
SSH_ADD_RC=1 SSH_VERIFY_RC=1 run key >"$TMP/out" 2>&1 && fail "failed verify must exit non-zero"
grep -q 'ssh-add --apple-use-keychain' "$TMP/out" || fail "failure message does not mention ssh-add"

run setup >/dev/null 2>&1 || fail "ssh-setup after failure failed"
run teardown >"$TMP/out" 2>&1 || fail "teardown failed"
grep -q 'authorized_keys' "$TMP/out" || fail "teardown lacks revoke instruction"
grep -q "grep -vF 'AAAA' " "$TMP/out" || fail "teardown lacks blob-based revoke command"
! grep -q 'sed -i' "$TMP/out" || fail "teardown still prints sed -i"
! grep -q 'testhost' "$TMP/out" || fail "teardown still matches by hostname"
! grep -q 'PRIVATE' "$TMP/out" || fail "teardown leaked private key material"

# hub: several peers and no PEER= must not default to the first one
mkdir -p "$TMP/repo/state/peers.d"
printf 'KEY=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=\nIP=10.66.0.4\n' > "$TMP/repo/state/peers.d/aphone.env"
printf 'KEY=DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=\nIP=10.66.0.3\nSSH_USER=dave\n' > "$TMP/repo/state/peers.d/mac.env"
: > "$STUB_LOG"
run key </dev/null >"$TMP/out" 2>&1 && fail "multi-peer ssh-key without PEER must fail"
grep -q 'PEER=<name>' "$TMP/out" || fail "multi-peer hint missing"
grep -q 'aphone  (10.66.0.4)' "$TMP/out" || fail "multi-peer list missing"
! grep -q '^nc' "$STUB_LOG" || fail "multi-peer probed a peer without a choice"
: > "$STUB_LOG"
run key --peer mac </dev/null >"$TMP/out" 2>&1 || fail "ssh-key PEER=mac failed"
grep -q 'ssh-copy-id .* dave@10.66.0.3' "$STUB_LOG" || fail "PEER=mac not used"

# without a terminal, make ssh keeps defaulting to the first peer
: > "$STUB_LOG"
run connect </dev/null >"$TMP/out" 2>&1 || fail "multi-peer connect failed"
grep -q "using 'aphone'" "$TMP/out" || fail "connect lost the first-peer default"
grep -q '@10.66.0.4' "$STUB_LOG" || fail "connect did not use the first peer"

# in a terminal with fzf, the picked peer wins (script(1) supplies the tty)
cat > "$TMP/bin/fzf" <<'EOF'
#!/usr/bin/env bash
grep '^mac'
EOF
chmod +x "$TMP/bin/fzf"
: > "$STUB_LOG"
(cd "$TMP/repo" && script -q /dev/null bash scripts/ssh.sh connect) >"$TMP/out" 2>&1 </dev/null || fail "fzf connect failed"
grep -q 'dave@10.66.0.3' "$STUB_LOG" || fail "fzf choice not used by connect"

echo "ok: ssh-key reuses keys, refuses non-macOS, writes key lines, persists USER, preflights before keygen, prints blob revoke hint, needs PEER on a hub"
