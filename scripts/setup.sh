#!/usr/bin/env bash
# setup.sh — one-time install & configuration (run once per machine, macOS/Linux)
# Usage: make setup NODE=A|B [PEER_KEY=<KEY>] [IP=<self>] [PEER_IP=<peer>]
# Re-run anytime; asks for the peer key. Default IPs: A=10.66.0.1, B=10.66.0.2.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/lib.sh

STUNMESH_VERSION="v1.9.0"
mkdir -p "$STATE"

# pre-scripts/ checkouts keep runtime files in repo root; without this move setup would regenerate the keypair
for f in wg.key settings.env stunmesh0.conf config.yaml stunmesh.log stunmesh.pid stunmesh-go; do
  [[ -e "$f" && ! -e "$STATE/$f" ]] && mv "$f" "$STATE/$f"
done

NODE=""
PEER_KEY=""
SELF_IP=""
PEER_IP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --peer-key) PEER_KEY="$2"; shift 2 ;;
    --ip) SELF_IP="$2"; shift 2 ;;
    --peer-ip) PEER_IP="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

# re-runs reuse previous settings.env values
if [[ -f "$STATE/settings.env" ]]; then
  [[ -z "$PEER_KEY" ]] && PEER_KEY="$(. "./$STATE/settings.env" && echo "${PEER_KEY:-}")"
  [[ -z "$NODE" ]]     && NODE="$(. "./$STATE/settings.env" && echo "${NODE:-}")"
  [[ -z "$SELF_IP" ]]  && SELF_IP="$(. "./$STATE/settings.env" && echo "${SELF_IP:-}")"
  [[ -z "$PEER_IP" ]]  && PEER_IP="$(. "./$STATE/settings.env" && echo "${PEER_IP:-}")"
fi

NODE="$(echo "$NODE" | tr '[:lower:]' '[:upper:]')"
if [[ "$NODE" != "A" && "$NODE" != "B" ]]; then
  echo "usage: make setup NODE=A|B [PEER_KEY=<peer public key>] [IP=<self>] [PEER_IP=<peer>]" >&2
  echo "  use NODE=A on one machine and NODE=B on the other (decides tunnel IP)" >&2
  exit 1
fi

# strict format also keeps shell metacharacters out of settings.env, which gets sourced
if [[ -n "$PEER_KEY" && ! "$PEER_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "✗ Invalid peer key: expected a 44-character base64 WireGuard public key" >&2
  exit 1
fi

if [[ -z "$SELF_IP" ]]; then
  [[ "$NODE" == "A" ]] && SELF_IP="10.66.0.1" || SELF_IP="10.66.0.2"
fi
if [[ -z "$PEER_IP" ]]; then
  [[ "$NODE" == "A" ]] && PEER_IP="10.66.0.2" || PEER_IP="10.66.0.1"
fi
for ip in "$SELF_IP" "$PEER_IP"; do
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "✗ Invalid IPv4 address: $ip" >&2
    exit 1
  fi
done
# wg conf uses a /24 derived from the self IP; both ends must live in it
if [[ "${SELF_IP%.*}" != "${PEER_IP%.*}" ]]; then
  echo "✗ IP $SELF_IP and PEER_IP $PEER_IP are not in the same /24" >&2
  exit 1
fi
if [[ "$SELF_IP" == "$PEER_IP" ]]; then
  echo "✗ IP and PEER_IP must differ" >&2
  exit 1
fi

# check-only by design: report what is missing, never install
echo "==> Checking dependencies"
MISSING=0
_need() {  # _need <command> <install hint>
  if ! command -v "$1" >/dev/null; then
    echo "✗ missing: $1 — install: $2" >&2
    MISSING=1
  fi
}

case "$OS" in
  Darwin)
    # App Store WireGuard is sandboxed and unusable with stunmesh-go; use brew's wireguard-go
    _need wireguard-go "brew install wireguard-go"
    _need wg           "brew install wireguard-tools"
    _need wg-quick     "brew install wireguard-tools"
    _need jq           "brew install jq"
    ;;
  Linux)
    # kernel >= 5.6 ships WireGuard built in; only userspace tools needed
    _need wg       "sudo apt-get install wireguard-tools (or dnf/pacman equivalent)"
    _need wg-quick "sudo apt-get install wireguard-tools (or dnf/pacman equivalent)"
    _need jq       "sudo apt-get install jq (or dnf/pacman equivalent)"
    _need curl     "sudo apt-get install curl (or dnf/pacman equivalent)"
    # warn only: version compare would false-negative on distros that backport WireGuard
    if command -v modinfo >/dev/null && ! modinfo wireguard >/dev/null 2>&1; then
      echo "⚠ WireGuard kernel module not detected (kernel >= 5.6 has it built in);" >&2
      echo "  if 'wg-quick up' fails later, install your distro's wireguard/wireguard-dkms package" >&2
    fi
    ;;
  *) echo "✗ Unsupported OS: $OS (macOS / Linux only)" >&2; exit 1 ;;
esac

if [[ "$OS" == "Darwin" ]]; then
  _need docker "Docker Desktop (https://docker.com/products/docker-desktop) or 'brew install colima docker && colima start'"
else
  _need docker "sudo apt-get install docker.io (or your distro's package)"
fi

if (( MISSING )); then
  echo "✗ Install the missing dependencies above, then re-run make setup" >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "✗ docker compose plugin missing (bundled with Docker Desktop; Linux: docker-compose-plugin package)" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "✗ Cannot talk to Docker daemon." >&2
  echo "  macOS: start Docker Desktop / colima start" >&2
  echo "  Linux: sudo systemctl start docker; if it is running, add yourself to the docker group (sudo usermod -aG docker \$USER, then re-login)" >&2
  exit 1
fi
echo "    ok"

echo "==> Downloading stunmesh-go ${STUNMESH_VERSION}"
case "$OS" in
  Darwin) OSKEY="darwin" ;;
  Linux)  OSKEY="linux" ;;
esac
case "$(uname -m)" in
  arm64|aarch64) BIN="stunmesh-${OSKEY}-arm64-${STUNMESH_VERSION}" ;;
  x86_64)        BIN="stunmesh-${OSKEY}-amd64-${STUNMESH_VERSION}" ;;
  *) echo "✗ Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
if [[ -x "$STATE/stunmesh-go" ]]; then
  echo "    already present, skipping"
else
  curl -fSL --progress-bar -o "$STATE/stunmesh-go" \
    "https://github.com/tjjh89017/stunmesh-go/releases/download/${STUNMESH_VERSION}/${BIN}"
  chmod +x "$STATE/stunmesh-go"
fi

echo "==> Pulling OpenDHT image"
docker compose pull -q

echo "==> WireGuard keypair"
if [[ ! -f "$STATE/wg.key" ]]; then
  (umask 077 && wg genkey > "$STATE/wg.key")
fi
PUB_KEY="$(wg pubkey < "$STATE/wg.key")"

if [[ -n "$PEER_KEY" && "$PEER_KEY" == "$PUB_KEY" ]]; then
  echo "✗ The peer key you provided is this machine's OWN public key." >&2
  echo "  Paste the key printed by the OTHER machine; send yours ($PUB_KEY) to it instead." >&2
  exit 1
fi

echo
echo "════════════════════════════════════════════════════"
echo " This machine's public key — SEND it to the OTHER machine:"
echo "   $PUB_KEY"
echo "════════════════════════════════════════════════════"
echo

if [[ -z "$PEER_KEY" && -t 0 ]]; then
  while :; do
    read -r -p "Paste the key the OTHER machine printed (Enter to skip if you don't have it yet): " ANSWER
    [[ -z "$ANSWER" ]] && break
    if [[ "$ANSWER" == "$PUB_KEY" ]]; then
      echo "  ✗ that is THIS machine's key — you need the one printed on the other machine"
      continue
    fi
    if [[ ! "$ANSWER" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
      echo "  ✗ not a valid key (expected 44-character base64)"
      continue
    fi
    PEER_KEY="$ANSWER"
    break
  done
fi

cat > "$STATE/settings.env" <<EOF
NODE=$NODE
SELF_IP=$SELF_IP
PEER_IP=$PEER_IP
PEER_KEY=$PEER_KEY
EOF

if [[ -z "$PEER_KEY" ]]; then
  echo
  echo "⚠ No peer key yet — that's fine. Send your key above to the other machine,"
  echo "  run setup there, then come back and run make setup again; it will ask"
  echo "  for the key. (Lost? make next)"
  exit 0
fi

# Endpoint omitted on purpose — stunmesh-go fills it in via DHT
(umask 077 && cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = $(cat "$STATE/wg.key")
Address = ${SELF_IP}/24

[Peer]
PublicKey = ${PEER_KEY}
AllowedIPs = ${SELF_IP%.*}.0/24
PersistentKeepalive = 25
EOF
)

# keep a hand-edited config.yaml in sync with the new peer key
if [[ -f "$STATE/config.yaml" ]]; then
  sed -i.bak -E "s|^( *public_key: \").*(\")|\\1${PEER_KEY}\\2|" "$STATE/config.yaml"
  rm -f "$STATE/config.yaml.bak"
fi

echo "✓ Setup complete. Start with: make start"
