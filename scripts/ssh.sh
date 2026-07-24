#!/usr/bin/env bash
# ssh.sh — SSH to the peer over the tunnel.
#   connect   ssh <user>@PEER_IP (default action)
#   setup     write state/ssh.conf + one Include line at the top of ~/.ssh/config
#   teardown  remove that Include line again
# Usage: make ssh [USER=<name>] / make ssh-setup [HOST=<alias>] [USER=<name>] / make ssh-teardown
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
MANAGED_CONF="$STATE/ssh.conf"
MARKER="# stunmesh-setup managed block (remove: make ssh-teardown)"
FIXED_ALIAS="stunmesh-peer"

ACTION="${1:-connect}"
[[ $# -gt 0 ]] && shift
HOST_ALIAS=""
USER_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST_ALIAS="$2"; shift 2 ;;
    --user) USER_ARG="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

_load_settings

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

if [[ -n "$USER_ARG" ]] && ! _valid_name "$USER_ARG"; then
  echo "✗ Invalid user name: $USER_ARG" >&2
  exit 1
fi
SSH_USER="${USER_ARG:-${PEER_SSH_USER:-$(id -un)}}"

case "$ACTION" in
  connect)
    _require_peer_ip
    if [[ -n "$USER_ARG" && "$USER_ARG" != "$PEER_SSH_USER" ]]; then
      PEER_SSH_USER="$SSH_USER"
      _save_settings
    fi
    # printed locally, so it lands above ssh's password prompt and the remote
    # MOTD — word it as "about to connect", not "logged in"
    MSG="Connecting to ${SSH_USER}@${PEER_IP} — leave the remote shell with exit (or Ctrl-D)"
    if [[ -t 1 ]]; then
      printf '\033[1;30;42m %s \033[0m\n' "$MSG"
    else
      echo "$MSG"
    fi
    RC=0
    ssh "${SSH_USER}@${PEER_IP}" || RC=$?
    # ssh exits with the remote shell's last status, which make would report as a
    # failed target; only ssh's own connection errors (255) are ours to surface
    if (( RC == 255 )); then
      exit 255
    fi
    ;;

  setup)
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

    ALIASES="$FIXED_ALIAS"
    [[ -n "$HOST_ALIAS" && "$HOST_ALIAS" != "$FIXED_ALIAS" ]] && ALIASES="$HOST_ALIAS $FIXED_ALIAS"
    cat > "$MANAGED_CONF" <<EOF
Host $ALIASES
    HostName $PEER_IP
    User $SSH_USER
    ServerAliveInterval 25
EOF
    PEER_SSH_USER="$SSH_USER"
    _save_settings

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
    ;;

  *)
    echo "usage: $0 connect|setup|teardown [--host <alias>] [--user <name>]" >&2
    exit 1
    ;;
esac
