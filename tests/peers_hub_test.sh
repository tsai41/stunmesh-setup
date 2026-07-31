#!/usr/bin/env bash
# peers_hub_test.sh — hub multi-peer store: migration, /32 vs /24, collisions,
# config rendering, validation, removal. Mocks wg so it needs no real keypair.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/scripts" "$TMP/repo/state" "$TMP/bin"
cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/dht.sh" "$ROOT/scripts/peer.sh" "$TMP/repo/scripts/"

SELFPUB='ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ='
KEYA='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
KEYC='CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC='

# wg pubkey always returns this machine's key; peer.sh reads it to reject own key
cat > "$TMP/bin/wg" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == pubkey ]]; then cat >/dev/null; echo '$SELFPUB'; fi
EOF
chmod +x "$TMP/bin/wg"
export PATH="$TMP/bin:$PATH"

cd "$TMP/repo"
printf 'private-key\n' > state/wg.key
cat > state/settings.env <<EOF
NODE=B
SELF_IP=10.66.0.2
PEER_IP=10.66.0.1
PEER_KEY=$KEYA
PEER_SSH_USER=karen
EOF

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- add the first extra peer: legacy peer migrates, both become /32 ----------
./scripts/peer.sh add --name c --ip 10.66.0.3 --key "$KEYC" >/dev/null || fail "add c"
[[ -f state/peers.d/a.env ]] || fail "legacy peer not migrated to a.env"
[[ -f state/peers.d/c.env ]] || fail "c.env not written"
grep -Fq "KEY=$KEYA" state/peers.d/a.env || fail "migrated key wrong"
grep -Fq 'SSH_USER=karen' state/peers.d/a.env || fail "migrated ssh user lost"

grep -Fq 'AllowedIPs = 10.66.0.1/32' state/stunmesh0.conf || fail "peer a not /32"
grep -Fq 'AllowedIPs = 10.66.0.3/32' state/stunmesh0.conf || fail "peer c not /32"
[[ "$(grep -c '^\[Peer\]' state/stunmesh0.conf)" == 2 ]] || fail "expected 2 [Peer] blocks"

grep -Fq '"a":' state/config.yaml || fail "config.yaml missing peer a"
grep -Fq '"c":' state/config.yaml || fail "config.yaml missing peer c"
grep -Fq 'target: "10.66.0.3"' state/config.yaml || fail "config.yaml c ping target wrong"
grep -Fq 'dedup: false' state/config.yaml || fail "config.yaml lost dedup:false"

# config validation must be clean with the hub store active
PROBLEMS="$(bash -c '. scripts/lib.sh; _load_settings; _config_problems')"
[[ -z "$PROBLEMS" ]] || fail "config problems: $PROBLEMS"

# --- collisions and invalid input are rejected --------------------------------
./scripts/peer.sh add --name d --ip 10.66.0.1 --key "$KEYA" 2>/dev/null && fail "dup ip accepted"
./scripts/peer.sh add --name c --ip 10.66.0.4 --key "$KEYC" 2>/dev/null && fail "dup name accepted"
./scripts/peer.sh add --name e --ip 10.66.0.5 --key "$SELFPUB" 2>/dev/null && fail "own key accepted"
./scripts/peer.sh add --name f --ip 10.99.0.9 --key "$KEYC" 2>/dev/null && fail "wrong /24 accepted"
./scripts/peer.sh add --name g --ip 10.66.0.2 --key "$KEYC" 2>/dev/null && fail "self ip accepted"
./scripts/peer.sh add --name h --ip 10.66.0.6 --key "not-a-key" 2>/dev/null && fail "bad key accepted"

# --- remove back down to one peer restores the /24 ----------------------------
./scripts/peer.sh remove --name c >/dev/null || fail "remove c"
[[ -f state/peers.d/c.env ]] && fail "c.env not removed"
grep -Fq 'AllowedIPs = 10.66.0.0/24' state/stunmesh0.conf || fail "single peer not /24 after removal"

# --- hand-edited garbage IP in peers.d is caught by validation ----------------
./scripts/peer.sh add --name d --ip 10.66.0.4 --key "$KEYC" >/dev/null || fail "add d"
printf 'KEY=%s\nIP=not-an-ip\nSSH_USER=\n' "$KEYC" > state/peers.d/d.env
PROBLEMS="$(bash -c '. scripts/lib.sh; _load_settings; _config_problems')"
[[ "$PROBLEMS" == *"not a valid IPv4"* ]] || fail "garbage IP not flagged: $PROBLEMS"

# --- _peer_count on an empty store must not abort under set -e -----------------
rm -f state/peers.d/*.env
COUNT="$(bash -c 'set -euo pipefail; . scripts/lib.sh; PEER_KEY=""; _peer_count')" || fail "_peer_count aborted on empty"
[[ "$COUNT" == 0 ]] || fail "empty _peer_count expected 0, got $COUNT"

echo "ok"
