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

# settings.env schema — a new setting is added here and nowhere else
SETTINGS_VARS=(NODE SELF_IP PEER_IP PEER_KEY PEER_SSH_USER)

# clear every setting: an exported PEER_IP must never stand in for a missing
# settings.env, and `make ssh PEER_IP=...` does put one in the recipe environment
_reset_settings() {
  local var
  for var in "${SETTINGS_VARS[@]}"; do
    eval "$var="
  done
}

# default any setting the caller never assigned, so `set -u` cannot trip
_init_settings() {
  local var
  for var in "${SETTINGS_VARS[@]}"; do
    eval ": \${$var:=}"
  done
}

# the peer key is always the OTHER node's; messages name it rather than say "the key"
_other_node() { [[ "${NODE:-}" == "A" ]] && echo B || echo A; }

_is_setting() {
  local candidate
  for candidate in "${SETTINGS_VARS[@]}"; do
    [[ "$candidate" == "$1" ]] && return 0
  done
  return 1
}

# settings.env is parsed, never sourced: sourcing runs whatever the file holds,
# and a subshell does not contain that — it can redefine printf, exit early to
# fake an empty config, or eat the stdin setup is prompting on.
_load_settings() {
  local line key
  _reset_settings
  [[ -f "$STATE/settings.env" ]] || return 0
  # an unreadable file must not read as "no settings": setup would take that for
  # a fresh machine and write defaults straight over it
  [[ -r "$STATE/settings.env" ]] || { echo "✗ Cannot read $STATE/settings.env" >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"  # a CRLF file would leave a CR on the end of every value
    # indentation and `export` are tolerated because this file used to be sourced
    # and still looks like a shell script; the value keeps every later '=', which
    # WireGuard keys end in
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    if _is_setting "$key"; then
      printf -v "$key" '%s' "${BASH_REMATCH[3]}"
    fi
  done < "$STATE/settings.env"
  return 0
}

_save_settings() {
  local tmp var out=""
  _init_settings  # callers normally _load_settings first; this only keeps `set -u` quiet
  mkdir -p "$STATE"
  for var in "${SETTINGS_VARS[@]}"; do
    # a newline would split into a line the reader reads back as another setting
    case "${!var}" in
      *$'\n'*) echo "✗ $var contains a newline and cannot be saved" >&2; return 1 ;;
    esac
    out="$out$var=${!var}"$'\n'
  done
  tmp="$(mktemp "$STATE/.settings.env.XXXXXX")"
  if ! printf '%s' "$out" > "$tmp"; then
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

# the peer-key checks both config files need; <file> <field name> <key> <own pubkey>
_peer_key_problems() {
  local file="$1" field="$2" key="$3" pub="$4"
  case "$key" in
    '') return 0 ;;
    *'<'*) echo "$file: $field is still a placeholder"; return 0 ;;
  esac
  if [[ -n "$pub" && "$key" == "$pub" ]]; then
    echo "$file: $field is this machine's OWN key (must be the other machine's)"
  fi
  if [[ -n "${PEER_KEY:-}" && "$key" != "$PEER_KEY" ]]; then
    echo "$file: $field differs from settings.env PEER_KEY"
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
    _peer_key_problems "$WG_CONF" PublicKey "$peer" "$pub"
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
    _peer_key_problems "$STATE/config.yaml" public_key "$yaml_peer" "$pub"
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

# SIGTERM + poll for stunmesh-go to exit; pidfile is removed in every path.
# returns 1 if it was running but didn't stop, 0 otherwise
_stop_stunmesh() {
  local rc=0 pid
  if pid="$(_stunmesh_pid)"; then
    if sudo kill "$pid"; then
      for _ in {1..20}; do
        _stunmesh_pid >/dev/null || break
        sleep 0.1
      done
      if _stunmesh_pid >/dev/null; then
        echo "✗ stunmesh-go did not stop after SIGTERM" >&2
        rc=1
      else
        echo "    stopped"
      fi
    else
      echo "✗ failed to stop stunmesh-go (pid $pid)" >&2
      rc=1
    fi
  else
    echo "    not running"
  fi
  rm -f "$STATE/stunmesh.pid"
  return "$rc"
}
