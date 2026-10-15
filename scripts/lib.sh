#!/usr/bin/env bash
# lib.sh — shared constants and helpers; callers cd to repo root first

STATE="state"
WG_CONF_NAME="stunmesh0"
WG_CONF="$STATE/${WG_CONF_NAME}.conf"
OS="$(uname -s)"
WG_NAME_FILE="/var/run/wireguard/${WG_CONF_NAME}.name"
# extra peers for the hub use-case live one-per-file here; when it holds any
# peer it is the source of truth, otherwise the single legacy peer in
# settings.env is used (so a plain 2-node setup never grows this directory)
PEERS_DIR="$STATE/peers.d"

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
SETTINGS_VARS=(NODE SELF_IP PEER_IP PEER_KEY PEER_SSH_USER DHT_ENDPOINT SSH_KEY_AUTH)

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

# peer names become file names under peers.d and interface/peer keys in the
# generated configs, so hold them to the same safe charset as ssh aliases
_valid_peer_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# any file under peers.d means the hub store is in use
_peers_dir_active() { compgen -G "$PEERS_DIR/*.env" >/dev/null 2>&1; }

# emit one record per configured peer: name<TAB>key<TAB>ip<TAB>ssh_user.
# peers.d wins when populated; otherwise synthesize the legacy single peer from
# settings.env (callers _load_settings first). peers.d/*.env is parsed, never
# sourced, for the same reason settings.env is.
_all_peers() {
  local f name key ip ssh_user line
  if _peers_dir_active; then
    for f in "$PEERS_DIR"/*.env; do
      [[ -e "$f" ]] || continue
      name="$(basename "$f" .env)"
      key=""; ip=""; ssh_user=""
      while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(KEY|IP|SSH_USER)=(.*)$ ]] || continue
        case "${BASH_REMATCH[1]}" in
          KEY) key="${BASH_REMATCH[2]}" ;;
          IP) ip="${BASH_REMATCH[2]}" ;;
          SSH_USER) ssh_user="${BASH_REMATCH[2]}" ;;
        esac
      done < "$f"
      printf '%s\t%s\t%s\t%s\n' "$name" "$key" "$ip" "$ssh_user"
    done
    return 0
  fi
  [[ -n "${PEER_KEY:-}" ]] || return 0
  name="$(_other_node | tr '[:upper:]' '[:lower:]')"
  printf '%s\t%s\t%s\t%s\n' "$name" "$PEER_KEY" "${PEER_IP:-}" "${PEER_SSH_USER:-}"
}

# grep -c exits 1 on zero peers; keep the count assignment from tripping set -e
_peer_count() { _all_peers | grep -c . || true ; }

# look up one field of one peer by name; <name> <col: 2=key 3=ip 4=ssh_user>
_peer_field() {
  _all_peers | awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c; exit }'
}

# render state/stunmesh0.conf for every configured peer. >1 peer uses /32 so the
# AllowedIPs never overlap (WireGuard rejects overlap); a lone peer keeps the
# /24 the 2-node flow has always written. <self-ip> <private-key>
_render_wg_conf() {
  local self_ip="$1" privkey="$2" count name key ip allowed
  count="$(_peer_count)"
  printf '[Interface]\nPrivateKey = %s\nAddress = %s/24\n' "$privkey" "$self_ip"
  while IFS=$'\t' read -r name key ip _; do
    [[ -n "$key" ]] || continue
    if (( count > 1 )); then allowed="$ip/32"; else allowed="${self_ip%.*}.0/24"; fi
    printf '\n[Peer]  # %s\nPublicKey = %s\nAllowedIPs = %s\nPersistentKeepalive = 25\n' \
      "$name" "$key" "$allowed"
  done < <(_all_peers)
}

# render state/config.yaml (stunmesh-go DHT config) with one peer block each.
# <interface-name> <dht-endpoint>
_render_config_yaml() {
  local iface="$1" dht_endpoint="$2" name key ip
  printf -- '---\nrefresh_interval: "1m"\nlog:\n  level: "info"\ninterfaces:\n  "%s":\n    protocol: "ipv4"\n    peers:\n' "$iface"
  while IFS=$'\t' read -r name key ip _; do
    [[ -n "$key" ]] || continue
    printf '      "%s":\n        public_key: "%s"\n        plugin: dht\n        protocol: "ipv4"\n        ping:\n          enabled: true\n          target: "%s"\n          interval: "30s"\n          timeout: "5s"\n' \
      "$name" "$key" "$ip"
  done < <(_all_peers)
  printf 'stun:\n  addresses:\n    - "stun.l.google.com:19302"\n    - "stun1.l.google.com:19302"\nplugins:\n  dht:\n    type: builtin\n    name: opendht\n    endpoint: "%s"\n    timeout: "15s"\n    dedup: false\n' \
    "$dht_endpoint"
}

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

# live interface name, or 1 when it is not up. macOS records the dynamic utunX
# in a root-only file, so reading it needs sudo we are not willing to prompt for
_wg_iface() {
  if [[ "$OS" == "Darwin" ]]; then
    [[ -f "$WG_NAME_FILE" ]] || return 1
    sudo -n cat "$WG_NAME_FILE" 2>/dev/null || return 1
  else
    [[ -d "/sys/class/net/${WG_CONF_NAME}" ]] || return 1
    echo "$WG_CONF_NAME"
  fi
}

# "<peer key><TAB><handshake epoch>" per live peer. Empty when the interface is
# down or wg cannot be read without a password prompt: listing peers is a
# read-only question and must never block on sudo.
_wg_handshakes() {
  local iface
  iface="$(_wg_iface)" || return 0
  sudo -n wg show "$iface" latest-handshakes 2>/dev/null || true
}

# handshake epoch for one peer key out of a _wg_handshakes blob; empty if absent
_handshake_for() {  # <key> <blob>
  [[ -n "$2" ]] || return 0
  awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' <<< "$2"
}

# an epoch as an age a human reads at a glance; "-" unknown, "never" = 0
_ago() {  # <epoch>
  local now age
  [[ "$1" =~ ^[0-9]+$ ]] || { echo "-"; return 0; }
  (( $1 == 0 )) && { echo "never"; return 0; }
  now="$(date +%s)"
  age=$(( now - $1 ))
  (( age < 0 )) && age=0
  if (( age < 60 )); then echo "${age}s ago"
  elif (( age < 3600 )); then echo "$(( age / 60 ))m ago"
  elif (( age < 86400 )); then echo "$(( age / 3600 ))h ago"
  else echo "$(( age / 86400 ))d ago"; fi
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

  # hub store active: validate each peer record instead of the single legacy peer.
  # the generated configs are rendered straight from these records, so checking
  # the records is what matters (settings.env PEER_KEY may be stale after add-peer)
  if _peers_dir_active; then
    local name key ip
    while IFS=$'\t' read -r name key ip _; do
      case "$key" in
        '') echo "$PEERS_DIR/$name.env: KEY is empty" ;;
        *'<'*) echo "$PEERS_DIR/$name.env: KEY is still a placeholder" ;;
        *) [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || echo "$PEERS_DIR/$name.env: KEY is not a valid 44-character base64 public key"
           [[ -n "$pub" && "$key" == "$pub" ]] && echo "$PEERS_DIR/$name.env: KEY is this machine's OWN key" ;;
      esac
      if [[ -z "$ip" ]]; then
        echo "$PEERS_DIR/$name.env: IP is empty"
      elif ! _valid_ipv4 "$ip"; then
        echo "$PEERS_DIR/$name.env: IP is not a valid IPv4: $ip"
      fi
    done < <(_all_peers)
    return 0
  fi

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

# pid from pidfile iff it is a live ssh (guards PID reuse after crash/reboot)
_proxy_pid() {
  local pid
  [[ -f "$STATE/proxy.pid" ]] || return 1
  pid="$(cat "$STATE/proxy.pid")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
    *ssh) echo "$pid" ;;
    *) return 1 ;;
  esac
}

# SIGTERM + poll for the SOCKS proxy ssh to exit; pidfile is removed in every
# path. returns 1 if it was running but didn't stop, 0 otherwise
_stop_proxy() {
  local rc=0 pid
  if pid="$(_proxy_pid)"; then
    if kill "$pid" 2>/dev/null; then
      for _ in {1..20}; do
        _proxy_pid >/dev/null || break
        sleep 0.1
      done
      if _proxy_pid >/dev/null; then
        echo "✗ proxy ssh did not stop after SIGTERM" >&2
        rc=1
      else
        echo "    stopped"
      fi
    else
      echo "✗ failed to stop proxy (pid $pid)" >&2
      rc=1
    fi
  else
    echo "    not running"
  fi
  rm -f "$STATE/proxy.pid"
  return "$rc"
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

_sha256() {
  if [[ "$OS" == "Darwin" ]]; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# Fetch the newest release unless state/stunmesh-go already has its checksum.
# STUNMESH_UPDATED is consumed by scripts/update.sh after this function returns.
_install_stunmesh_go() {
  local release_json bin oskey archkey expected actual tmp
  export STUNMESH_UPDATED=0
  echo "==> Looking up latest stunmesh-go release"
  release_json="$(curl -fsSL https://api.github.com/repos/tjjh89017/stunmesh-go/releases/latest)"
  STUNMESH_VERSION="$(jq -r '.tag_name' <<<"$release_json")"
  [[ -n "$STUNMESH_VERSION" && "$STUNMESH_VERSION" != "null" ]] || { echo "✗ could not determine latest stunmesh-go release" >&2; return 1; }
  echo "    latest: ${STUNMESH_VERSION}"

  case "$OS" in
    Darwin) oskey="darwin" ;;
    Linux) oskey="linux" ;;
    *) echo "✗ Unsupported OS: $OS" >&2; return 1 ;;
  esac
  case "$OS/$(uname -m)" in
    Darwin/arm64) archkey="arm64" ;;
    Darwin/x86_64) archkey="amd64" ;;
    Linux/arm64|Linux/aarch64) archkey="arm64" ;;
    Linux/x86_64) archkey="amd64" ;;
    *) echo "✗ Unsupported arch: $(uname -m)" >&2; return 1 ;;
  esac
  bin="stunmesh-${oskey}-${archkey}-${STUNMESH_VERSION}"
  expected="$(jq -r --arg name "$bin" '.assets[] | select(.name == $name) | .digest' <<<"$release_json" | sed 's/^sha256://')"
  [[ -n "$expected" && "$expected" != "null" ]] || { echo "✗ no release asset named ${bin}" >&2; return 1; }

  if [[ -f "$STATE/stunmesh-go" ]] && [[ "$(_sha256 "$STATE/stunmesh-go")" == "$expected" ]]; then
    chmod +x "$STATE/stunmesh-go"
    echo "    already present, skipping"
    return 0
  fi

  echo "==> Downloading stunmesh-go ${STUNMESH_VERSION}"
  [[ ! -e "$STATE/stunmesh-go" ]] || echo "    existing binary differs from ${STUNMESH_VERSION}; downloading"
  tmp="$(mktemp "$STATE/.stunmesh-go.XXXXXX")"
  if ! curl -fSL --progress-bar -o "$tmp" \
    "https://github.com/tjjh89017/stunmesh-go/releases/download/${STUNMESH_VERSION}/${bin}"; then
    rm -f "$tmp"
    return 1
  fi
  actual="$(_sha256 "$tmp")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$tmp"
    echo "✗ stunmesh-go checksum mismatch: expected $expected, got $actual" >&2
    return 1
  fi
  chmod +x "$tmp"
  mv "$tmp" "$STATE/stunmesh-go"
  export STUNMESH_UPDATED=1
}
