#!/usr/bin/env bash
# peers_list_test.sh — `make peers` (peer.sh list) and the status peers line:
# both must name every configured peer, print the other end's key, and never
# block on sudo when the handshake times are unavailable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/scripts" "$TMP/repo/state" "$TMP/bin"
cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/dht.sh" "$ROOT/scripts/peer.sh" "$ROOT/scripts/status.sh" "$TMP/repo/scripts/"

SELFPUB='ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ='
KEYA='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
KEYC='CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC='

cat > "$TMP/bin/wg" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
  pubkey) cat >/dev/null; echo '$SELFPUB' ;;
  show) printf '%s\t%s\n' '$KEYA' "\$(( \$(date +%s) - 90 ))" ;;
esac
MOCK
# a real sudo would prompt; this mock stands in for one that is already cached
cat > "$TMP/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "-n" ]] && shift
exec "$@"
MOCK
cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"ipv4":{"good":3}}'
MOCK
cat > "$TMP/bin/jq" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
echo 3
MOCK
cat > "$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

cd "$TMP/repo"
printf 'private-key\n' > state/wg.key
cat > state/settings.env <<SETTINGS
NODE=B
SELF_IP=10.66.0.2
PEER_IP=10.66.0.1
PEER_KEY=$KEYA
PEER_SSH_USER=karen
SETTINGS

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- the 2-node peer from settings.env is listed, with both keys --------------
OUT="$(./scripts/peer.sh list)" || fail "peer.sh list exited non-zero"
[[ "$OUT" == *"$SELFPUB"* ]] || fail "own key missing: $OUT"
[[ "$OUT" == *"$KEYA"* ]] || fail "peer key missing: $OUT"
grep -q '^a  *10\.66\.0\.1' <<< "$OUT" || fail "peer row missing: $OUT"

# --- extra peers are listed too ----------------------------------------------
./scripts/peer.sh add --name c --ip 10.66.0.3 --key "$KEYC" >/dev/null || fail "add c"
OUT="$(./scripts/peer.sh list)" || fail "peer.sh list exited non-zero after add"
[[ "$OUT" == *"can reach 2 node(s)"* ]] || fail "peer count wrong: $OUT"
[[ "$OUT" == *"$KEYC"* ]] || fail "added peer key missing: $OUT"

# --- status names the peers so the summary answers "who can I reach?" ---------
OUT="$(bash ./scripts/status.sh)" || fail "status.sh exited non-zero"
[[ "$OUT" == *"peers:       2"* ]] || fail "status peer count missing: $OUT"
[[ "$OUT" == *"a 10.66.0.1"* && "$OUT" == *"c 10.66.0.3"* ]] || fail "status peer names missing: $OUT"

# --- handshake helpers: read wg only through a non-prompting sudo -------------
printf 'utun9\n' > "$TMP/name"
BLOB="$(bash -c ". scripts/lib.sh; OS=Darwin; WG_NAME_FILE='$TMP/name'; _wg_handshakes")"
[[ "$BLOB" == "$KEYA"* ]] || fail "handshakes not read: $BLOB"
AGE="$(bash -c '. scripts/lib.sh; _ago "$(_handshake_for "$1" "$2")"' _ "$KEYA" "$BLOB")"
[[ "$AGE" == "1m ago" ]] || fail "expected '1m ago', got '$AGE'"

# a down interface (or a sudo that would prompt) degrades to no handshake column,
# never to a password prompt or a failure
BLOB="$(bash -c '. scripts/lib.sh; OS=Darwin; WG_NAME_FILE=/nope/absent.name; _wg_handshakes')" \
  || fail "_wg_handshakes failed with the interface down"
[[ -z "$BLOB" ]] || fail "expected no handshakes with the interface down: $BLOB"
[[ "$(bash -c '. scripts/lib.sh; _ago ""')" == "-" ]] || fail "unknown age should print '-'"
[[ "$(bash -c '. scripts/lib.sh; _ago 0')" == "never" ]] || fail "epoch 0 should print 'never'"

echo "ok"
