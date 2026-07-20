#!/usr/bin/env bash
# lib.sh — shared constants and helpers; callers cd to repo root first

STATE="state"
WG_CONF_NAME="stunmesh0"
WG_CONF="$STATE/${WG_CONF_NAME}.conf"
OS="$(uname -s)"
WG_NAME_FILE="/var/run/wireguard/${WG_CONF_NAME}.name"

_valid_ipv4() {
  local ip="$1" octet
  local -a octets
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

_save_settings() {
  local tmp
  mkdir -p "$STATE"
  tmp="$(mktemp "$STATE/.settings.env.XXXXXX")"
  if ! printf '%s\n' \
    "NODE=$NODE" \
    "SELF_IP=$SELF_IP" \
    "PEER_IP=$PEER_IP" \
    "PEER_KEY=$PEER_KEY" \
    "PEER_SSH_USER=$PEER_SSH_USER" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$STATE/settings.env"
}

# macOS: dynamic utunX recorded in the name file; Linux: interface keeps the conf name
_wg_running() {
  if [[ "$OS" == "Darwin" ]]; then
    [[ -f "$WG_NAME_FILE" ]]
  else
    [[ -d "/sys/class/net/${WG_CONF_NAME}" ]]
  fi
}

# inspect real config files; print one problem per line (empty = clean)
_config_problems() {
  local pub="" peer="" priv="" yaml_peer="" target=""
  [[ -f "$STATE/wg.key" ]] && pub="$(wg pubkey < "$STATE/wg.key" 2>/dev/null || true)"

  if [[ -f "$WG_CONF" ]]; then
    # sed, not awk with '=' as FS: WireGuard keys themselves end in '='
    peer="$(sed -nE 's/^PublicKey *= *//p' "$WG_CONF" | head -1)"
    priv="$(sed -nE 's/^PrivateKey *= *//p' "$WG_CONF" | head -1)"
    case "$peer" in *'<'*) echo "$WG_CONF: PublicKey is still a placeholder" ;; esac
    if [[ -n "$pub" && "$peer" == "$pub" ]]; then
      echo "$WG_CONF: PublicKey is this machine's OWN key (must be the other machine's)"
    fi
    if [[ -n "${PEER_KEY:-}" && -n "$peer" && "$peer" != *'<'* && "$peer" != "$PEER_KEY" ]]; then
      echo "$WG_CONF: PublicKey differs from settings.env PEER_KEY"
    fi
    if [[ -n "$priv" && "$priv" != *'<'* && -n "$pub" ]]; then
      if [[ "$(printf '%s' "$priv" | wg pubkey 2>/dev/null)" != "$pub" ]]; then
        echo "$WG_CONF: PrivateKey does not match wg.key"
      fi
    fi
  elif [[ -n "${PEER_KEY:-}" ]]; then
    echo "$WG_CONF: missing (re-run make setup)"
  fi

  if [[ -f "$STATE/config.yaml" ]]; then
    yaml_peer="$(sed -nE 's/^ *public_key: "([^"]*)".*/\1/p' "$STATE/config.yaml" | head -1)"
    target="$(sed -nE 's/^ *target: "([^"]*)".*/\1/p' "$STATE/config.yaml" | head -1)"
    case "$yaml_peer" in *'<'*) echo "$STATE/config.yaml: public_key is still a placeholder" ;; esac
    if [[ -n "$pub" && "$yaml_peer" == "$pub" ]]; then
      echo "$STATE/config.yaml: public_key is this machine's OWN key (must be the other machine's)"
    fi
    if [[ -n "${PEER_KEY:-}" && -n "$yaml_peer" && "$yaml_peer" != *'<'* && "$yaml_peer" != "$PEER_KEY" ]]; then
      echo "$STATE/config.yaml: public_key differs from settings.env PEER_KEY"
    fi
    if [[ -n "$target" && -n "${PEER_IP:-}" && "$target" != "$PEER_IP" ]]; then
      echo "$STATE/config.yaml: ping target is $target but peer IP is $PEER_IP"
    fi
  fi
  return 0
}

# pid from pidfile iff it is a live stunmesh-go (guards PID reuse after crash/reboot)
_stunmesh_pid() {
  local pid
  [[ -f "$STATE/stunmesh.pid" ]] || return 1
  pid="$(cat "$STATE/stunmesh.pid")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
    *stunmesh-go*) echo "$pid" ;;
    *) return 1 ;;
  esac
}
