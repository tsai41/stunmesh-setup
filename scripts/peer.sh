#!/usr/bin/env bash
# peer.sh — manage additional WireGuard peers so this machine can act as a hub
# that connects to more than one other node.
#   add     make add-peer NAME=<name> IP=<10.66.0.x> [KEY=<peer pubkey>] [USER=<ssh user>]
#   remove  make remove-peer NAME=<name>
#   list    make peers   (alias: make list-peers)
# Adding the first extra peer migrates the existing 2-node peer into peers.d, so
# peers.d becomes the single source of truth; both state configs are then
# re-rendered from it. Apply the change with make restart (or make start).
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh
. ./scripts/dht.sh

ACTION="${1:-list}"
[[ $# -gt 0 ]] && shift
ARG_NAME=""; ARG_IP=""; ARG_KEY=""; ARG_SSH_USER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) ARG_NAME="$2"; shift 2 ;;
    --ip) ARG_IP="$2"; shift 2 ;;
    --key) ARG_KEY="$2"; shift 2 ;;
    --ssh-user) ARG_SSH_USER="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

_load_settings

[[ -f "$STATE/wg.key" ]] || { echo "✗ Run make setup first (no keypair yet)" >&2; exit 1; }
PUB_KEY="$(wg pubkey < "$STATE/wg.key" 2>/dev/null || true)"

_write_peer() {  # <name> <key> <ip> <ssh_user>
  mkdir -p "$PEERS_DIR"
  chmod 700 "$PEERS_DIR" 2>/dev/null || true
  ( umask 077
    printf 'KEY=%s\nIP=%s\nSSH_USER=%s\n' "$2" "$3" "$4" > "$PEERS_DIR/$1.env" )
}

# first extra peer: fold the legacy settings.env peer into peers.d so the store
# holds every peer and nothing is emitted twice
_migrate_legacy() {
  _peers_dir_active && return 0
  [[ -n "${PEER_KEY:-}" ]] || return 0
  _write_peer "$(_other_node | tr '[:upper:]' '[:lower:]')" "$PEER_KEY" "${PEER_IP:-}" "${PEER_SSH_USER:-}"
}

# re-render both state configs from peers.d. keeps the interface name and DHT
# endpoint already chosen (start.sh reconciles both on the next start anyway)
_regenerate() {
  local iface="$WG_CONF_NAME" endpoint="$DHT_PUBLIC_ENDPOINT" existing
  if [[ -f "$STATE/config.yaml" ]]; then
    existing="$(sed -nE 's/^  "([^"]*)":.*/\1/p' "$STATE/config.yaml" | head -1)"
    [[ -n "$existing" ]] && iface="$existing"
    existing="$(sed -nE 's/^ *endpoint: "([^"]*)".*/\1/p' "$STATE/config.yaml" | head -1)"
    [[ -n "$existing" ]] && endpoint="$existing"
  fi
  ( umask 077; _render_wg_conf "$SELF_IP" "$(cat "$STATE/wg.key")" > "$WG_CONF" )
  _render_config_yaml "$iface" "$endpoint" > "$STATE/config.yaml"
}

case "$ACTION" in
  list)
    echo "this node:  ${NODE:-?}  ${SELF_IP:-?}"
    [[ -n "$PUB_KEY" ]] && echo "  key:      $PUB_KEY"
    echo
    if [[ "$(_peer_count)" == "0" ]]; then
      echo "No peers configured yet. Add one: make add-peer NAME=<name> IP=<10.66.0.x> KEY=<pubkey>"
      exit 0
    fi
    echo "can reach $(_peer_count) node(s):"
    # the handshake column is dropped rather than filled with "-" when wg tells
    # us nothing (interface down, or sudo would have to prompt)
    HANDSHAKES="$(_wg_handshakes)"
    if [[ -n "$HANDSHAKES" ]]; then
      printf '%-16s %-18s %-15s %s\n' NAME IP 'LAST HANDSHAKE' KEY
    else
      printf '%-16s %-18s %s\n' NAME IP KEY
    fi
    while IFS=$'\t' read -r name key ip _; do
      if [[ -n "$HANDSHAKES" ]]; then
        printf '%-16s %-18s %-15s %s\n' "$name" "$ip" "$(_ago "$(_handshake_for "$key" "$HANDSHAKES")")" "$key"
      else
        printf '%-16s %-18s %s\n' "$name" "$ip" "$key"
      fi
    done < <(_all_peers)
    if [[ -z "$HANDSHAKES" ]] && _wg_running; then
      echo
      echo "(live handshake times need root: sudo -v && make peers)"
    fi
    echo
    echo "ssh into one: make ssh PEER=<name>"
    ;;

  add)
    [[ -n "$ARG_NAME" ]] || { echo "✗ NAME is required: make add-peer NAME=<name> IP=<10.66.0.x> KEY=<pubkey>" >&2; exit 1; }
    _valid_peer_name "$ARG_NAME" || { echo "✗ Invalid NAME: use letters, numbers, '.', '_' or '-'" >&2; exit 1; }
    [[ "$ARG_NAME" == "peer" ]] && { echo "✗ NAME 'peer' is reserved; pick another" >&2; exit 1; }
    [[ -n "$ARG_IP" ]] || { echo "✗ IP is required (a free address in the mesh /24, e.g. 10.66.0.3)" >&2; exit 1; }
    _valid_ipv4 "$ARG_IP" || { echo "✗ Invalid IPv4: $ARG_IP" >&2; exit 1; }
    if [[ -n "${SELF_IP:-}" ]]; then
      [[ "${ARG_IP%.*}" == "${SELF_IP%.*}" ]] || { echo "✗ $ARG_IP is not in this machine's /24 (${SELF_IP%.*}.0/24)" >&2; exit 1; }
      [[ "$ARG_IP" == "$SELF_IP" ]] && { echo "✗ $ARG_IP is this machine's own IP" >&2; exit 1; }
    fi
    if [[ -n "$ARG_SSH_USER" && ! "$ARG_SSH_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "✗ Invalid SSH user: $ARG_SSH_USER" >&2; exit 1
    fi

    # migrate first so a collision check sees the legacy peer too
    _migrate_legacy

    if [[ -f "$PEERS_DIR/$ARG_NAME.env" ]]; then
      echo "✗ Peer '$ARG_NAME' already exists — remove it first or pick another name" >&2; exit 1
    fi
    while IFS=$'\t' read -r name key ip _; do
      [[ "$ip" == "$ARG_IP" ]] && { echo "✗ IP $ARG_IP is already used by peer '$name'" >&2; exit 1; }
    done < <(_all_peers)

    if [[ -z "$ARG_KEY" && -t 0 ]]; then
      while :; do
        read -r -p "Paste peer '$ARG_NAME' public key: " ARG_KEY
        [[ -n "$ARG_KEY" ]] || { echo "  ✗ a key is required"; continue; }
        break
      done
    fi
    [[ -n "$ARG_KEY" ]] || { echo "✗ KEY is required: make add-peer NAME=$ARG_NAME IP=$ARG_IP KEY=<pubkey>" >&2; exit 1; }
    [[ "$ARG_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "✗ Invalid peer key: expected a 44-character base64 public key" >&2; exit 1; }
    [[ -n "$PUB_KEY" && "$ARG_KEY" == "$PUB_KEY" ]] && { echo "✗ That is this machine's OWN key; paste the other machine's key" >&2; exit 1; }
    while IFS=$'\t' read -r name key ip _; do
      [[ "$key" == "$ARG_KEY" ]] && { echo "✗ That key is already used by peer '$name'" >&2; exit 1; }
    done < <(_all_peers)

    _write_peer "$ARG_NAME" "$ARG_KEY" "$ARG_IP" "$ARG_SSH_USER"
    _regenerate
    echo "✓ Added peer '$ARG_NAME' ($ARG_IP). Total peers: $(_peer_count)"
    echo "  Apply it: make restart   (reloads the WireGuard interface with the new peer)"
    ;;

  remove)
    [[ -n "$ARG_NAME" ]] || { echo "✗ NAME is required: make remove-peer NAME=<name>" >&2; exit 1; }
    _migrate_legacy
    if [[ ! -f "$PEERS_DIR/$ARG_NAME.env" ]]; then
      echo "✗ No peer named '$ARG_NAME'. See: make list-peers" >&2; exit 1
    fi
    rm -f "$PEERS_DIR/$ARG_NAME.env"
    if _peers_dir_active; then
      _regenerate
      echo "✓ Removed peer '$ARG_NAME'. Total peers: $(_peer_count)"
      echo "  Apply it: make restart   (reloads the WireGuard interface)"
    else
      echo "✓ Removed peer '$ARG_NAME'. No peers left in the hub store."
      echo "  The 2-node peer in settings.env (if any) is used again; re-render with make setup / make start."
    fi
    ;;

  *)
    echo "usage: $0 add|remove|list [--name <name>] [--ip <ip>] [--key <pubkey>] [--ssh-user <user>]" >&2
    exit 1
    ;;
esac
