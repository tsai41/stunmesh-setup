#!/usr/bin/env bash
# lib.sh — shared constants and helpers, sourced by setup.sh / start.sh / stop.sh

WG_CONF_NAME="stunmesh0"
OS="$(uname -s)"
WG_NAME_FILE="/var/run/wireguard/${WG_CONF_NAME}.name"

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
  local conf="${WG_CONF_NAME}.conf" pub="" peer="" priv="" yaml_peer="" target=""
  [[ -f wg.key ]] && pub="$(wg pubkey < wg.key 2>/dev/null || true)"

  if [[ -f "$conf" ]]; then
    # sed, not awk with '=' as FS: WireGuard keys themselves end in '='
    peer="$(sed -nE 's/^PublicKey *= *//p' "$conf" | head -1)"
    priv="$(sed -nE 's/^PrivateKey *= *//p' "$conf" | head -1)"
    case "$peer" in *'<'*) echo "$conf: PublicKey is still a placeholder" ;; esac
    if [[ -n "$pub" && "$peer" == "$pub" ]]; then
      echo "$conf: PublicKey is this machine's OWN key (must be the other machine's)"
    fi
    if [[ -n "${PEER_KEY:-}" && -n "$peer" && "$peer" != *'<'* && "$peer" != "$PEER_KEY" ]]; then
      echo "$conf: PublicKey differs from settings.env PEER_KEY"
    fi
    if [[ -n "$priv" && "$priv" != *'<'* && -n "$pub" ]]; then
      if [[ "$(printf '%s' "$priv" | wg pubkey 2>/dev/null)" != "$pub" ]]; then
        echo "$conf: PrivateKey does not match wg.key"
      fi
    fi
  elif [[ -n "${PEER_KEY:-}" ]]; then
    echo "$conf: missing (re-run ./setup.sh --node ${NODE:-A} --peer-key <KEY>)"
  fi

  if [[ -f config.yaml ]]; then
    yaml_peer="$(sed -nE 's/^ *public_key: "([^"]*)".*/\1/p' config.yaml | head -1)"
    target="$(sed -nE 's/^ *target: "([^"]*)".*/\1/p' config.yaml | head -1)"
    case "$yaml_peer" in *'<'*) echo "config.yaml: public_key is still a placeholder" ;; esac
    if [[ -n "$pub" && "$yaml_peer" == "$pub" ]]; then
      echo "config.yaml: public_key is this machine's OWN key (must be the other machine's)"
    fi
    if [[ -n "${PEER_KEY:-}" && -n "$yaml_peer" && "$yaml_peer" != *'<'* && "$yaml_peer" != "$PEER_KEY" ]]; then
      echo "config.yaml: public_key differs from settings.env PEER_KEY"
    fi
    if [[ -n "$target" && -n "${PEER_IP:-}" && "$target" != "$PEER_IP" ]]; then
      echo "config.yaml: ping target is $target but peer IP is $PEER_IP"
    fi
  fi
  return 0
}

# pid from pidfile iff it is a live stunmesh-go (guards PID reuse after crash/reboot)
_stunmesh_pid() {
  local pid
  [[ -f stunmesh.pid ]] || return 1
  pid="$(cat stunmesh.pid)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
    *stunmesh-go*) echo "$pid" ;;
    *) return 1 ;;
  esac
}
