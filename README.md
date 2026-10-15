# stunmesh-setup

Connect two machines (macOS / Linux) into one private encrypted network — SSH between them, copy files, reach local services, as if they sat on the same LAN. Neither needs a public IP, a VPS, or an account anywhere.

Built on [stunmesh-go](https://github.com/tjjh89017/stunmesh-go) — the NAT hole punching and encryption — plus WireGuard and OpenDHT, all upstream work by [@tjjh89017](https://github.com/tjjh89017). This repo just wraps their install and start; how the tunnel finds each peer and how to self-host the DHT are in [how it works](docs/how-it-works.md).

## Requirements

Scripts only check and print install hints — they never install anything.

- **macOS**: `wireguard-go`, `wireguard-tools`, `jq` via [Homebrew](https://brew.sh)
- **Linux**: kernel >= 5.6 (older needs wireguard-dkms), `wireguard-tools`, `jq`, `curl`, `sha256sum`
- **Optional**: Docker with the compose plugin — only if you explicitly choose the bundled local DHT

**Two hard limits:** App Store WireGuard is sandboxed and unsupported (same as upstream); and if both machines sit behind symmetric NAT, hole punching cannot work at all — one side needs a different network.

stunmesh-go installs itself: setup downloads the latest upstream release binary and verifies it against GitHub's published SHA-256 before use.

## Set up & connect

Clone anywhere outside a cloud-synced folder, in a path without spaces (`state/` holds your keys). Setup is interactive and per-machine — it prints **this machine's key to send away**, then asks for the other's. Keys are public, not secrets (chat/AirDrop is fine); `PEER_KEY=` is always the *other* machine's key. Lost your place? `make next` always prints the next step.

```bash
# 1. node A — prints A's key; press Enter (no key from B yet)
make setup NODE=A
# 2. node B — paste A's key at the prompt; send B's printed key back to A
make setup NODE=B
# 3. node A again — paste B's key
make setup NODE=A
```

Setup is done when **both** machines hold the other's key. It also asks for the peer's SSH login name and accepts custom tunnel IPs — `IP=<self> PEER_IP=<peer>` (same /24; defaults A=`10.66.0.1`, B=`10.66.0.2`). **The IPs must mirror: A's `IP` is B's `PEER_IP`.** Answers are remembered in `state/settings.env` and can be passed non-interactively (`USER=`, `IP=`, `PEER_IP=`).

Then start both machines and connect:

```bash
make start       # DHT + WireGuard + stunmesh-go (asks sudo)
ping 10.66.0.2   # from A; B pings 10.66.0.1; ~1-2 min to punch through
```

**Both machines must be started and stay started** — the tunnel is a direct link with no relay, so `make stop` on either side drops it for both. `make start` verifies stunmesh-go stays alive before reporting success, and rolls back only what that run started if a stage fails.

### macOS: start automatically at boot

After setup has completed and a peer key is configured, install the macOS-only
`LaunchDaemon` from this repo:

```bash
make launchd-install       # asks for sudo once; starts now and at future boots
make launchd-status
```

It runs as root so it can create the WireGuard interface without an interactive
password prompt, and restarts after an unexpected exit. To disable it:

```bash
make launchd-uninstall
```

See [docs/macos-launchd.md](docs/macos-launchd.md) for logs, lifecycle, and
the effect of sleep.

## After it's up

```bash
make ssh          # ssh into the peer over the tunnel (USER=<name> to override, remembered)
make stop         # take the tunnel down (both sides lose it)
make restart
make update       # fetch the latest stunmesh-go release; restart daemon if it is running
make status       # which of DHT / WireGuard / stunmesh-go are up, and which peers this node reaches
make peers        # every node this node is configured to reach, with the other end's key
make next         # the single next step for the current state
```

- **`make ssh-setup`** adds a `stunmesh-peer` Host alias to `~/.ssh/config` (one Include line; existing aliases untouched), so plain `ssh stunmesh-peer` works from anywhere. `make ssh-teardown` removes it.
- **`make ssh-key`** (macOS, optional) sets up key-based login to the peer: creates `~/.ssh/id_ed25519_stunmesh` (reused if present), adds it to the Keychain, installs the public key on the peer (you type its password once) and adds the key lines to the `stunmesh-peer` alias and the peer's IP, so `make ssh` / `make proxy` log in with the key too. The peer needs Remote Login enabled (System Settings → General → Sharing); this only checks, never enables. Run it on the other Mac too for the reverse direction. `make ssh-teardown` prints how to revoke the key on the peer; it never touches the peer.
- **Browse the peer's LAN** — its router page, a NAS, printers: `make proxy` opens a SOCKS5 proxy through the peer. See [docs/proxy.md](docs/proxy.md).

- **Connect to more than one machine** — make this node a hub with `make add-peer` / `remove-peer` / `peers`. See [docs/hub.md](docs/hub.md).

- **Use a local DHT deliberately** — the public Jami proxy is the default. Docker is never started automatically: `make dht-local-up`, then `make dht-use-local`. Return to the public default with `make dht-use-public`.

Scripts also run directly, e.g. `./scripts/setup.sh --node A`.

## Documentation

All under [`docs/`](docs/) — see its [index](docs/README.md) for the same list grouped by purpose.

| Doc | What |
|---|---|
| [how-it-works.md](docs/how-it-works.md) | Endpoint exchange, public/default and local/opt-in DHT, trust model, invariants |
| [macos-launchd.md](docs/macos-launchd.md) | macOS boot-time background service |
| [hub.md](docs/hub.md) | Connect this machine to more than one node (add/remove/list peers) |
| [state-files.md](docs/state-files.md) | What each `state/` file is, which are secret, what's hand-editable |
| [proxy.md](docs/proxy.md) | Browse the peer's LAN over a SOCKS5 proxy |
| [troubleshooting.md](docs/troubleshooting.md) | `make start` failures and the peer-side "endpoint unavailable" loop |

## License

Scripts are [MIT](LICENSE). stunmesh-go is GPL-2.0 (downloaded from upstream at setup, not bundled); OpenDHT is MIT.
