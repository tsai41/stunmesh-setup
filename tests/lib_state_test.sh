#!/usr/bin/env bash
# SC2034: _save_settings reads the SETTINGS_VARS by name, so they look unused here.
# SC2030/SC2031: each case runs in a subshell precisely so its settings do not
# reach the next one; "the change might be lost" is the point.
# shellcheck disable=SC2034,SC2030,SC2031
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
mkdir state
. "$ROOT/scripts/lib.sh"

if _valid_ipv4 999.1.2.3; then
  echo "expected IPv4 validation to reject octets over 255" >&2
  exit 1
fi
_valid_ipv4 10.66.0.1

NODE=A
SELF_IP=10.66.0.1
PEER_IP=10.66.0.2
PEER_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
PEER_SSH_USER="peer-login"
_save_settings

EXPECTED="$(printf '%s\n' \
  'NODE=A' \
  'SELF_IP=10.66.0.1' \
  'PEER_IP=10.66.0.2' \
  'PEER_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=' \
  'PEER_SSH_USER=peer-login')"
ACTUAL="$(cat state/settings.env)"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "shared settings writer produced unexpected content" >&2; exit 1; }

# a fresh shell must read every setting back, so a re-run can reuse them.
# PEER_KEY matters most: it ends in '=', so splitting on the last one loses it.
(
  unset NODE SELF_IP PEER_IP PEER_KEY PEER_SSH_USER
  _load_settings
  [[ "$NODE" == "A" && "$SELF_IP" == "10.66.0.1" && "$PEER_IP" == "10.66.0.2" \
     && "$PEER_KEY" == "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" \
     && "$PEER_SSH_USER" == "peer-login" ]] \
    || { echo "_load_settings did not restore the saved settings" >&2; exit 1; }
)

# a value cannot forge a second settings line; without this guard _save_settings
# would write it out and the reader would take the tail as another setting
(
  _reset_settings
  NODE=$'A\nPEER_KEY=injected'
  if _save_settings 2>/dev/null; then
    echo "_save_settings accepted a newline inside a value" >&2
    exit 1
  fi
)

# hand-edited files: a CRLF line ending, an `export` prefix left over from when
# this file was sourced, and indentation must all still load
printf 'NODE=A\r\n  SELF_IP=10.66.0.1\r\nexport PEER_IP=10.66.0.2\r\n' > state/settings.env
(
  _load_settings
  [[ "$NODE" == "A" && "$SELF_IP" == "10.66.0.1" && "$PEER_IP" == "10.66.0.2" ]] \
    || { echo "a hand-edited settings.env did not load cleanly" >&2; exit 1; }
)

# an unreadable file must fail loudly: read as "no settings", setup would take
# the machine for a fresh one and write defaults over it
if [[ "$(id -u)" != 0 ]]; then  # root can read it regardless
  printf 'NODE=A\n' > state/settings.env
  chmod 000 state/settings.env
  if (_load_settings) 2>/dev/null; then
    chmod 600 state/settings.env
    echo "_load_settings reported success on an unreadable file" >&2
    exit 1
  fi
  chmod 600 state/settings.env
fi

# settings.env written before a setting existed must not trip `set -u`
printf 'NODE=A\nSELF_IP=10.66.0.1\nPEER_IP=10.66.0.2\nPEER_KEY=OLD\n' > state/settings.env
(
  unset NODE SELF_IP PEER_IP PEER_KEY PEER_SSH_USER
  _load_settings
  [[ -z "$PEER_SSH_USER" ]] || { echo "expected a missing setting to default to empty" >&2; exit 1; }
)

# settings.env is data, not code. Every line below is an escape that works the
# moment anyone "simplifies" _load_settings back into a `.` of the file.
RCE_PROOF="$TMP/rce-proof"  # inside TMP: a fixed path collides with a parallel run
{
  printf 'NODE=B\n'
  printf 'vars=(STATE)\n'                              # pick the reader's own key list
  printf 'STATE=/tmp/pwned\nWG_CONF=/tmp/pwned.conf\n' # redirect where keys get written
  # shellcheck disable=SC2016  # literal text: the reader must not expand it
  printf 'PEER_KEY=$(touch %s)\n' "$RCE_PROOF"
  printf 'exit 0\n'                                    # cut the read short
  printf 'PEER_IP=10.66.0.9\n'                         # ...this must still arrive
} > state/settings.env
# the checks run in a subshell an `exit` in settings.env could skip past, so the
# sentinel — not the subshell's status — is what proves they actually ran
(
  _load_settings
  [[ "$STATE" == "state" && "$WG_CONF" == "state/stunmesh0.conf" ]] \
    || { echo "settings.env redefined shell state outside the schema" >&2; exit 1; }
  # shellcheck disable=SC2016
  [[ "$PEER_KEY" == '$(touch '"$RCE_PROOF"')' ]] \
    || { echo "a value was expanded instead of taken literally" >&2; exit 1; }
  [[ "$NODE" == "B" && "$PEER_IP" == "10.66.0.9" ]] \
    || { echo "_load_settings dropped a schema value" >&2; exit 1; }
  : > state/escape-checks-ran
)
[[ -e state/escape-checks-ran ]] || { echo "settings.env cut the escape checks short" >&2; exit 1; }
[[ ! -e "$RCE_PROOF" ]] || { echo "settings.env executed code" >&2; rm -f "$RCE_PROOF"; exit 1; }
rm -f state/escape-checks-ran

# every caller runs under `set -e`; an unknown key must neither fail the load nor
# cost the settings around it
printf 'UNKNOWN=x\nNODE=A\nALSO_UNKNOWN=y\n' > state/settings.env
_load_settings
[[ "$NODE" == "A" ]] || { echo "an unknown key displaced a real setting" >&2; exit 1; }

# `make ssh PEER_IP=...` exports it into the recipe environment; a missing
# settings.env must not silently inherit it and point ssh at another host
rm -f state/settings.env
(
  export PEER_IP=203.0.113.9 NODE=Z
  _load_settings
  [[ -z "$PEER_IP" && -z "$NODE" ]] \
    || { echo "environment leaked in as a substitute for settings.env" >&2; exit 1; }
)

echo "ok: shared state helpers validate IPv4 and load settings without leaking scope"
