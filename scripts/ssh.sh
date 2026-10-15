#!/usr/bin/env bash
# ssh.sh — SSH to the peer over the tunnel.
#   connect   ssh <user>@PEER_IP (default action)
#   proxy     SOCKS5 proxy on 127.0.0.1:<port> through the peer (ssh -D)
#   setup     write state/ssh.conf + one Include line at the top of ~/.ssh/config
#   teardown  remove that Include line again
#   key       macOS only: key-based login to the peer (keygen, Keychain, ssh-copy-id)
# Usage: make ssh [USER=<name>] / make proxy [PROXY_PORT=<port>] [USER=<name>]
#        make ssh-setup [HOST=<alias>] [USER=<name>] / make ssh-teardown
#        make ssh-key [PEER=<name>] [USER=<name>]
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
MANAGED_CONF="$STATE/ssh.conf"
MARKER="# stunmesh-setup managed block (remove: make ssh-teardown)"
FIXED_ALIAS="stunmesh-peer"
KEY_FILE="$SSH_DIR/id_ed25519_stunmesh"
SSH_ADD_BIN="${SSH_ADD_BIN:-/usr/bin/ssh-add}"

ACTION="${1:-connect}"
[[ $# -gt 0 ]] && shift
HOST_ALIAS=""
USER_ARG=""
PEER_ARG=""
PROXY_PORT="10000"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST_ALIAS="$2"; shift 2 ;;
    --user) USER_ARG="$2"; shift 2 ;;
    --peer) PEER_ARG="$2"; shift 2 ;;
    --port) PROXY_PORT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

_load_settings

# hub use-case: pick which peer to reach. an explicit PEER wins; with several
# peers and no PEER, default to the first. a lone/legacy peer keeps settings.env.
# PEER_FROM_STORE stops _save_user writing a store peer's user back to settings.
PEER_FROM_STORE=0
if [[ -n "$PEER_ARG" ]]; then
  [[ "$PEER_ARG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "✗ Invalid peer name: $PEER_ARG" >&2; exit 1; }
  ip="$(_peer_field "$PEER_ARG" 3)"
  [[ -n "$ip" ]] || { echo "✗ No peer named '$PEER_ARG'. See: make list-peers" >&2; exit 1; }
  PEER_IP="$ip"
  PEER_SSH_USER="$(_peer_field "$PEER_ARG" 4)"
  PEER_FROM_STORE=1
elif (( $(_peer_count) > 1 )) && [[ "$ACTION" == "key" ]]; then
  # installing a key needs a peer running sshd; the first peer may be a phone
  _pname=""
  if [[ -t 0 && -t 2 ]] && command -v fzf >/dev/null 2>&1; then
    _pname="$(_all_peers | awk -F'\t' '{ print $1 "\t" $3 }' |
      fzf --prompt='ssh-key peer> ' --delimiter='\t' --height=10 | cut -f1)" || true
  fi
  if [[ -z "$_pname" ]]; then
    echo "✗ Multiple peers; choose one: make ssh-key PEER=<name>" >&2
    _all_peers | awk -F'\t' '{ print "    " $1 "  (" $3 ")" }' >&2
    exit 1
  fi
  PEER_IP="$(_peer_field "$_pname" 3)"
  PEER_SSH_USER="$(_peer_field "$_pname" 4)"
  PEER_FROM_STORE=1
elif (( $(_peer_count) > 1 )); then
  IFS=$'\t' read -r _pname _pkey PEER_IP PEER_SSH_USER < <(_all_peers)
  PEER_FROM_STORE=1
  echo "ℹ Multiple peers; using '$_pname' ($PEER_IP). Pick another with PEER=<name> (see make list-peers)" >&2
fi

_require_peer_ip() {
  if [[ -z "$PEER_IP" ]]; then
    echo "✗ No PEER_IP in $STATE/settings.env — run make setup first" >&2
    exit 1
  fi
}

# the name lands in state/ssh.conf, which ssh Includes: whitespace would let it
# smuggle in another config directive
_valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

_refuse_symlink() {
  if [[ -L "$SSH_CONFIG" ]]; then
    echo "✗ $SSH_CONFIG is a symlink — refusing to rewrite it; manage the Include line yourself:" >&2
    echo "    Include $(pwd -P)/$MANAGED_CONF" >&2
    exit 1
  fi
}

_alias_taken() {  # in the user's own config; our aliases live only in state/ssh.conf
  [[ -f "$SSH_CONFIG" ]] || return 1
  awk -v a="$1" 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i == a) found = 1 } END { exit !found }' "$SSH_CONFIG"
}

_file_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null || echo 600; }

# drop an existing managed block (marker line + the Include line under it)
_strip_managed() { awk -v m="$MARKER" '$0 == m { skip = 2 } skip > 0 { skip--; next } { print }' "$1"; }

_banner() {
  if [[ -t 1 ]]; then
    printf '\033[1;30;42m %s \033[0m\n' "$1"
  else
    echo "$1"
  fi
}

# remember an explicitly chosen user so the next make ssh/proxy reuses it
_save_user() {
  # a store peer's user lives in peers.d, not settings.env — don't write it back
  (( PEER_FROM_STORE )) && return 0
  if [[ -n "$USER_ARG" && "$USER_ARG" != "$PEER_SSH_USER" ]]; then
    PEER_SSH_USER="$SSH_USER"
    _save_settings
  fi
}

if [[ -n "$USER_ARG" ]] && ! _valid_name "$USER_ARG"; then
  echo "✗ Invalid user name: $USER_ARG" >&2
  exit 1
fi
SSH_USER="${USER_ARG:-${PEER_SSH_USER:-$(id -un)}}"

# checks that must pass before anything is written, so a failure leaves nothing behind
_preflight_ssh_conf() {
  _require_peer_ip
  # Include needs OpenSSH >= 7.3; check-only, like the dependency preflight
  VER="$(ssh -V 2>&1 | sed -nE 's/^OpenSSH_([0-9]+)\.([0-9]+).*/\1 \2/p')"
  if [[ -n "$VER" ]]; then
    read -r MAJ MIN <<< "$VER"
    if (( MAJ < 7 || (MAJ == 7 && MIN < 3) )); then
      echo "✗ OpenSSH $MAJ.$MIN lacks Include support (needs >= 7.3); upgrade ssh or use make ssh directly" >&2
      exit 1
    fi
  fi
  if [[ -n "$HOST_ALIAS" ]] && ! _valid_name "$HOST_ALIAS"; then
    echo "✗ Invalid host alias: $HOST_ALIAS" >&2
    exit 1
  fi
  _refuse_symlink

  for ALIAS in ${HOST_ALIAS:+"$HOST_ALIAS"} "$FIXED_ALIAS"; do
    if _alias_taken "$ALIAS"; then
      echo "✗ Host alias '$ALIAS' already exists in $SSH_CONFIG — pick another: make ssh-setup HOST=<alias>" >&2
      exit 1
    fi
  done
}

_write_ssh_conf() {
  ALIASES="$FIXED_ALIAS"
  [[ -n "$HOST_ALIAS" && "$HOST_ALIAS" != "$FIXED_ALIAS" ]] && ALIASES="$HOST_ALIAS $FIXED_ALIAS"
  cat > "$MANAGED_CONF" <<EOF
Host $ALIASES
    HostName $PEER_IP
    User $SSH_USER
    ServerAliveInterval 25
EOF
  if [[ "$SSH_KEY_AUTH" == "1" ]]; then
    cat >> "$MANAGED_CONF" <<EOF
    IdentityFile $KEY_FILE
    IdentitiesOnly yes
    AddKeysToAgent yes
    IgnoreUnknown UseKeychain
    UseKeychain yes
EOF
  fi
}

_install_include() {
  if [[ ! -d "$SSH_DIR" ]]; then
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
  fi
  [[ -f "$SSH_CONFIG" ]] || (umask 077 && : > "$SSH_CONFIG")

  # ssh config does not expand ~ or $HOME reliably across versions; use the real path
  INCLUDE_LINE="Include $(pwd -P)/$MANAGED_CONF"
  MODE="$(_file_mode "$SSH_CONFIG")"
  TMP="$(mktemp "${SSH_CONFIG}.XXXXXX")"
  {
    # marker + Include must sit at the very top: an Include below a Host/Match
    # block would only apply inside that block
    printf '%s\n%s\n' "$MARKER" "$INCLUDE_LINE"
    _strip_managed "$SSH_CONFIG"
  } > "$TMP"
  chmod "$MODE" "$TMP"
  mv "$TMP" "$SSH_CONFIG"

  echo "✓ ssh config ready:"
  echo "    ssh ${HOST_ALIAS:-$FIXED_ALIAS}        (${SSH_USER}@${PEER_IP})"
  echo "  Wrote $MANAGED_CONF; added one Include line to $SSH_CONFIG."
  echo "  IP or user changed later? Re-run make ssh-setup. Undo: make ssh-teardown"
}

case "$ACTION" in
  connect)
    _require_peer_ip
    _save_user
    # printed locally, so it lands above ssh's password prompt and the remote
    # MOTD — word it as "about to connect", not "logged in"
    _banner "Connecting to ${SSH_USER}@${PEER_IP} — leave the remote shell with exit (or Ctrl-D)"
    RC=0
    ssh "${SSH_USER}@${PEER_IP}" || RC=$?
    # ssh exits with the remote shell's last status, which make would report as a
    # failed target; only ssh's own connection errors (255) are ours to surface
    if (( RC == 255 )); then
      exit 255
    fi
    ;;

  proxy)
    _require_peer_ip
    if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || (( PROXY_PORT < 1 || PROXY_PORT > 65535 )); then
      echo "✗ Invalid port: $PROXY_PORT (want 1-65535)" >&2
      exit 1
    fi
    if PID="$(_proxy_pid)"; then
      echo "✗ Proxy already running (pid $PID) — Ctrl-C it or make stop first" >&2
      exit 1
    fi
    _save_user
    _banner "SOCKS5 proxy 127.0.0.1:${PROXY_PORT} via ${SSH_USER}@${PEER_IP} — Ctrl-C or make stop ends it (browser setup: docs/proxy.md)"
    # backgrounded so the pid lands in proxy.pid for make stop; password
    # prompts still work — ssh asks on /dev/tty, not stdin
    RC=0
    ssh -N -D "127.0.0.1:${PROXY_PORT}" "${SSH_USER}@${PEER_IP}" &
    echo $! > "$STATE/proxy.pid"
    trap 'rm -f "$STATE/proxy.pid"' EXIT
    wait $! || RC=$?
    if (( RC == 255 )); then
      exit 255
    fi
    ;;

  setup)
    _preflight_ssh_conf
    _write_ssh_conf
    PEER_SSH_USER="$SSH_USER"
    _save_settings
    _install_include
    ;;

  key)
    if [[ "$OS" != "Darwin" ]]; then
      echo "✗ make ssh-key is macOS only (needs the Apple Keychain); on $OS, set up keys by hand" >&2
      exit 1
    fi
    _require_peer_ip
    command -v ssh-copy-id >/dev/null 2>&1 || { echo "✗ ssh-copy-id not found" >&2; exit 1; }

    # keep a custom alias from an earlier ssh-setup HOST=<alias>
    if [[ -z "$HOST_ALIAS" && -f "$MANAGED_CONF" ]]; then
      HOST_ALIAS="$(awk -v f="$FIXED_ALIAS" '$1 == "Host" { for (i = 2; i <= NF; i++) if ($i != f) { print $i; exit } }' "$MANAGED_CONF")"
    fi
    _preflight_ssh_conf

    # check-only: never enable Remote Login for the user
    if ! nc -z -G 5 "$PEER_IP" 22 >/dev/null 2>&1; then
      echo "✗ $PEER_IP:22 is not reachable over the tunnel" >&2
      echo "  On the OTHER Mac enable System Settings → General → Sharing → Remote Login," >&2
      echo "  and check the tunnel: make status / ping $PEER_IP" >&2
      exit 1
    fi

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    if [[ -f "$KEY_FILE" ]]; then
      if [[ ! -f "$KEY_FILE.pub" ]]; then
        echo "✗ $KEY_FILE exists but $KEY_FILE.pub is missing. Recreate it (asks for the passphrase), then re-run:" >&2
        echo "    ssh-keygen -y -f $KEY_FILE > $KEY_FILE.pub" >&2
        exit 1
      fi
      echo "ℹ Reusing existing key $KEY_FILE"
    else
      echo "ℹ Creating $KEY_FILE — choose a passphrase when asked"
      ssh-keygen -t ed25519 -f "$KEY_FILE" -C "$(hostname)-stunmesh"
    fi

    KEYCHAIN_OK=1
    "$SSH_ADD_BIN" --apple-use-keychain "$KEY_FILE" || {
      KEYCHAIN_OK=0
      echo "⚠ Could not add the key to the Keychain; ssh may ask for its passphrase" >&2
    }

    SSH_KEY_AUTH=1
    _write_ssh_conf
    _install_include
    # reload so a store peer's IP/user are not written into settings.env
    _saved_ip="$PEER_IP"; _saved_user="$PEER_SSH_USER"
    _load_settings
    SSH_KEY_AUTH=1
    (( PEER_FROM_STORE )) || PEER_SSH_USER="$SSH_USER"
    _save_settings
    PEER_IP="$_saved_ip"; PEER_SSH_USER="$_saved_user"

    echo "ℹ Installing the public key on ${SSH_USER}@${PEER_IP} — enter that Mac's password once"
    ssh-copy-id -i "$KEY_FILE.pub" "${SSH_USER}@${PEER_IP}"

    if ssh -o BatchMode=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no "${HOST_ALIAS:-$FIXED_ALIAS}" true; then
      echo "✓ Key login works: ssh ${HOST_ALIAS:-$FIXED_ALIAS}"
      echo "  For login in the other direction, run make ssh-key on the other Mac too."
    else
      if (( ! KEYCHAIN_OK )); then
        echo "✗ Key login failed, and the key was not added to the Keychain/agent. Run: $SSH_ADD_BIN --apple-use-keychain $KEY_FILE — then retry make ssh-key" >&2
      else
        echo "✗ Key login failed. Check ~/.ssh/authorized_keys on the peer (permissions 600, ~/.ssh 700) and run: ssh -vvv ${HOST_ALIAS:-$FIXED_ALIAS}" >&2
      fi
      exit 1
    fi
    if ! nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1; then
      echo "⚠ Remote Login is off on THIS Mac, so the peer cannot log in back." >&2
      echo "  Enable System Settings → General → Sharing → Remote Login." >&2
    fi
    ;;

  teardown)
    if [[ ! -f "$SSH_CONFIG" ]] || ! grep -Fqx "$MARKER" "$SSH_CONFIG"; then
      echo "Nothing to do: no managed block in $SSH_CONFIG"
      exit 0
    fi
    _refuse_symlink
    MODE="$(_file_mode "$SSH_CONFIG")"
    TMP="$(mktemp "${SSH_CONFIG}.XXXXXX")"
    _strip_managed "$SSH_CONFIG" > "$TMP"
    chmod "$MODE" "$TMP"
    mv "$TMP" "$SSH_CONFIG"
    echo "✓ Removed the Include line from $SSH_CONFIG ($MANAGED_CONF kept; delete it if unwanted)"
    if [[ "$SSH_KEY_AUTH" == "1" ]]; then
      echo "ℹ This Mac's public key is still in the peer's authorized_keys. To revoke it, run ON THE PEER:"
      BLOB=""
      [[ -f "$KEY_FILE.pub" ]] && BLOB="$(awk 'NR == 1 { print $2 }' "$KEY_FILE.pub")"
      if [[ -n "$BLOB" ]]; then
        echo "    grep -vF '$BLOB' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp && mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
      else
        echo "    $KEY_FILE.pub not found here; edit ~/.ssh/authorized_keys on the peer and delete the line holding this Mac's key"
      fi
    fi
    ;;

  *)
    echo "usage: $0 connect|proxy|setup|key|teardown [--host <alias>] [--user <name>] [--port <port>]" >&2
    exit 1
    ;;
esac
