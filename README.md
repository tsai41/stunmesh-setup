# stunmesh-setup

Wrapper scripts to connect two machines (macOS / Linux) over WireGuard with [stunmesh-go](https://github.com/tjjh89017/stunmesh-go) and a self-hosted OpenDHT proxy in docker. No public IP, no server of your own to run — only public STUN servers and a public DHT bootstrap node.

All hole punching, encryption, and DHT publishing is upstream work by [@tjjh89017](https://github.com/tjjh89017) — this repo only wraps install and start.

## How it works

Endpoint exchange is the core problem of P2P: each side must learn the other's public IP:port. stunmesh-go supports several storage backends for this (Cloudflare DNS, OpenDHT, external plugins); **this setup uses the built-in OpenDHT plugin with a dockerized local DHT proxy** — endpoints travel over the public DHT network, so no DNS zone, account, or API token is needed.

- Each machine runs a local `dhtnode` (docker compose, see [`compose.yaml`](compose.yaml); REST proxy bound to loopback only), bootstrapped to `bootstrap.jami.net:4222`
- stunmesh-go discovers its public IP:port via STUN and publishes it (Curve25519-encrypted) to the DHT
- Peer endpoints update automatically; tunnel IPs: node A `10.66.0.1`, node B `10.66.0.2`

## Requirements

Scripts only check and print install hints — they never install anything.

- Docker with the compose plugin (daemon running); macOS: Docker Desktop or `brew install colima docker docker-compose`; Linux: `docker-compose-plugin` package
- macOS: `wireguard-go`, `wireguard-tools`, `jq` via [Homebrew](https://brew.sh)
- Linux: kernel >= 5.6 (older needs wireguard-dkms), `wireguard-tools`, `jq`, `curl`, `sha256sum` (coreutils)

stunmesh-go itself needs no manual install: setup downloads the official prebuilt release binary (v1.9.0) from [upstream releases](https://github.com/tjjh89017/stunmesh-go/releases) and verifies its pinned SHA-256 before installing it. Existing binaries that do not match the pinned release are replaced with a verified copy.

The OpenDHT container is pinned to the official `v4.1.1` multi-architecture image digest, so both machines run the same immutable image.

> [!NOTE]
> App Store WireGuard is sandboxed and not supported — same constraint as upstream.

## Install

Clone anywhere (a path without spaces, outside cloud-synced folders — `wg.key` is a secret and logs churn). Everything stays inside the repo folder.

Setup is interactive: it prints **this machine's key to send away**, then **asks** you to paste the other machine's key — just press Enter if you don't have it yet and run setup again later. You never need to remember when to pass which key; rejects the wrong one. (`PEER_KEY=<KEY>` still works for non-interactive use. Lost? `make next` always prints the next step.)

1. On node A: `make setup NODE=A` → send the printed key to B, press Enter at the prompt (no key from B yet)
2. On node B: `make setup NODE=B` → paste A's key at the prompt; send B's printed key back to A
3. On node A: `make setup NODE=A` again → paste B's key at the prompt

Setup is done when **both** machines have the other's key. Keys are public, not secrets — chat/AirDrop is fine.

Custom tunnel IPs: `IP=<self> PEER_IP=<peer>` (same /24; defaults A=10.66.0.1, B=10.66.0.2). Must mirror each other on the two machines — A's `IP` is B's `PEER_IP` and vice versa. Re-runs keep previously set IPs. These Make variables may also be exported as environment variables before running `make setup`.

## Usage

```bash
make start       # dhtnode + WireGuard + stunmesh-go (asks sudo)
ping 10.66.0.2   # from node A; B pings 10.66.0.1; ~1-2 min to punch through
make stop
```

`make start` verifies that stunmesh-go stays alive before reporting success. If a later startup stage fails, it rolls back only the DHT/WireGuard components started by that invocation. `make stop` attempts every cleanup stage even if one fails.

Other targets: `make status` (DHT health + WireGuard + project pidfile), `make logs`, `make next`. (The scripts live in [`scripts/`](scripts/) and can also be run directly, e.g. `./scripts/setup.sh --node A`.)

## SSH over the tunnel

```bash
make ssh                  # ssh <saved user>@<peer tunnel IP>; USER=<name> to override (remembered)
make ssh-setup            # adds a 'stunmesh-peer' Host alias to ~/.ssh/config via one Include line
ssh stunmesh-peer         # then plain ssh works, from anywhere
make ssh-teardown         # removes the Include line again
```

During `make setup`, each machine asks for the other machine's SSH user and remembers it in `state/settings.env`. Press Enter when both machines use the same account name. You can also provide it non-interactively with `make setup ... USER=<name>`.

`make ssh-setup` accepts `HOST=<alias>` for an extra custom alias and `USER=<name>`. The alias config itself lives in `state/ssh.conf`; your `~/.ssh/config` only gains one marked Include line at the top, and existing aliases are never touched (setup refuses a name collision).

Debug:

```bash
tail -f state/stunmesh.log
curl -s http://127.0.0.1:8080/node/info | jq .ipv4.good
```

## Generated files

Everything the scripts generate lives in `state/` — gitignored as a whole (it contains keys). See [`examples/`](examples/) for annotated samples:

- `state/stunmesh0.conf` — WireGuard config, written by setup once the peer key is provided ([example](examples/stunmesh0.conf.example))
- `state/config.yaml` — stunmesh-go config, generated by start if absent ([example](examples/config.yaml.example))

Both are also fine to hand-edit: start never overwrites an existing `config.yaml` — it only refreshes the interface name line (macOS utunX changes per boot). Delete the file to get a fresh generated one.
- `state/settings.env` — node identity (tunnel IPs + peer public key + peer SSH user), atomically written by setup/SSH helpers; not secret
- `state/wg.key` — your WireGuard private key, written by setup
- `state/stunmesh-go` — upstream release binary, plus `stunmesh.log` / `stunmesh.pid` at runtime

## Notes

- macOS interface is a dynamic `utunX`; its interface-name line in `config.yaml` is refreshed on every start. Linux uses fixed `stunmesh0`.
- OpenDHT values expire after 10 minutes; `dedup: false` must stay.
- `state/wg.key` and `state/stunmesh0.conf` contain your private key — gitignored, never share them.
- Symmetric NAT on both sides cannot punch through (upstream limitation).

## Development checks

```bash
make check   # bash syntax, ShellCheck, compose validation, whitespace
make test    # isolated shell tests; never touches the real state/ or tunnel
```

## License

Scripts in this repo are [MIT](LICENSE). stunmesh-go itself is GPL-2.0 (downloaded from upstream at setup time, not bundled here); OpenDHT is MIT.
