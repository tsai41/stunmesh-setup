# stunmesh-setup

Connect two machines (macOS / Linux) into one private encrypted network — SSH between them, copy files, reach local services, as if they sat on the same LAN. Neither machine needs a public IP, a VPS, or an account anywhere: the tunnel is built by hole punching through public STUN servers and a public DHT bootstrap node.

Wrapper scripts around [stunmesh-go](https://github.com/tjjh89017/stunmesh-go), WireGuard, and an OpenDHT proxy (public Jami proxy by default, self-hosted docker fallback). All hole punching, encryption, and DHT publishing is upstream work by [@tjjh89017](https://github.com/tjjh89017) — this repo only wraps install and start.

## How it works

Endpoint exchange is the core problem of P2P: each side must learn the other's public IP:port. stunmesh-go supports several storage backends for this (Cloudflare DNS, OpenDHT, external plugins); **this setup uses the built-in OpenDHT plugin against the public Jami DHT proxy** (`https://dhtproxy3.jami.net`) — endpoints travel over the public DHT network, so no DNS zone, account, or API token is needed.

- `make start` probes the public proxy first; when it is unreachable, it falls back to a local `dhtnode` (docker compose, see [`compose.yaml`](compose.yaml); REST proxy bound to loopback only), bootstrapped to `bootstrap.jami.net:4222`
- stunmesh-go discovers its public IP:port via STUN and publishes it (Curve25519-encrypted) to the DHT
- Peer endpoints update automatically; tunnel IPs: node A `10.66.0.1`, node B `10.66.0.2`

## Requirements

Scripts only check and print install hints — they never install anything.

- Optional: Docker with the compose plugin (daemon running) — only needed for the local `dhtnode` fallback when the public DHT proxy is unreachable; macOS: Docker Desktop or `brew install colima docker docker-compose`; Linux: `docker-compose-plugin` package
- macOS: `wireguard-go`, `wireguard-tools`, `jq` via [Homebrew](https://brew.sh)
- Linux: kernel >= 5.6 (older needs wireguard-dkms), `wireguard-tools`, `jq`, `curl`, `sha256sum` (coreutils)

stunmesh-go itself needs no manual install: setup downloads the official prebuilt release binary (v1.9.0) from [upstream releases](https://github.com/tjjh89017/stunmesh-go/releases) and verifies its pinned SHA-256 before installing it. Existing binaries that do not match the pinned release are replaced with a verified copy.

The fallback OpenDHT container is pinned to the official `v4.1.1` multi-architecture image digest, so both machines run the same immutable image.

> [!NOTE]
> App Store WireGuard is sandboxed and not supported — same constraint as upstream.

## Install

Clone anywhere (a path without spaces, outside cloud-synced folders — `wg.key` is a secret and logs churn). Everything stays inside the repo folder.

Setup is interactive: it prints **this machine's key to send away**, then **asks** you to paste the other machine's key — just press Enter if you don't have it yet and run setup again later. You never need to remember when to pass which key; the wrong one is rejected. `PEER_KEY=` is always the *other* machine's public key — on node A you pass B's, on node B you pass A's — and it still works non-interactively. Lost? `make next` always prints the next step.

1. On node A: `make setup NODE=A` → send the printed key to B, press Enter at the prompt (no key from B yet)
2. On node B: `make setup NODE=B` → paste A's key at the prompt; send B's printed key back to A
3. On node A: `make setup NODE=A` again → paste B's key at the prompt

Setup is done when **both** machines have the other's key. Keys are public, not secrets — chat/AirDrop is fine.

Setup also asks for **the other machine's SSH login name**, so `make ssh` works later without extra flags. Press Enter when both machines use the same account name; pass `USER=<name>` to answer non-interactively. It is remembered in `state/settings.env` and can be changed any time by re-running setup.

Custom tunnel IPs: `IP=<self> PEER_IP=<peer>` (same /24; defaults A=10.66.0.1, B=10.66.0.2). Must mirror each other on the two machines — A's `IP` is B's `PEER_IP` and vice versa. Re-runs keep previously set IPs. These Make variables may also be exported as environment variables before running `make setup`.

## Usage

```bash
make start       # DHT proxy + WireGuard + stunmesh-go (asks sudo)
ping 10.66.0.2   # from node A; B pings 10.66.0.1; ~1-2 min to punch through
make stop
```

**Both machines must be started, and must stay started.** The tunnel is a direct peer-to-peer link with no relay behind it — `make stop` on either side takes the tunnel down for both.

`make start` verifies that stunmesh-go stays alive before reporting success. If a later startup stage fails, it rolls back only the DHT/WireGuard components started by that invocation. `make stop` attempts every cleanup stage even if one fails.

Other targets: `make status` (DHT health + WireGuard + project pidfile), `make logs`, `make next`. (The scripts live in [`scripts/`](scripts/) and can also be run directly, e.g. `./scripts/setup.sh --node A`.)

## SSH over the tunnel

```bash
make ssh                  # ssh <saved user>@<peer tunnel IP>; USER=<name> to override (remembered)
make ssh-setup            # adds a 'stunmesh-peer' Host alias to ~/.ssh/config via one Include line
ssh stunmesh-peer         # then plain ssh works, from anywhere
make ssh-teardown         # removes the Include line again
```

`make ssh-setup` accepts `HOST=<alias>` for an extra custom alias and `USER=<name>`. The alias config itself lives in `state/ssh.conf`; your `~/.ssh/config` only gains one marked Include line at the top, and existing aliases are never touched (setup refuses a name collision). Re-run it after changing the tunnel IP or the peer user.

The peer still needs its own SSH server running and reachable — this only points SSH at the tunnel address.

## Troubleshooting

`make next` inspects the current state and prints the single next step; `make status` shows which of the three components are up. Start with those.

```bash
tail -f state/stunmesh.log                          # stunmesh-go, including punching attempts
curl -s https://dhtproxy3.jami.net/node/info | jq .ipv4.good   # public DHT proxy health
curl -s http://127.0.0.1:8080/node/info | jq .ipv4.good   # fallback dhtnode; 0 means no bootstrap
docker compose logs dhtnode
```

**`make start` fails at "DHT bootstrap failed".** The public proxy was unreachable and the fallback dhtnode found no DHT peers. Usually outbound UDP to `bootstrap.jami.net:4222` is blocked, or the machine has no working network yet.

**Both machines are running but ping never succeeds.** Punching takes 1-2 minutes after the *second* machine starts; wait before digging. If it stays down, check `state/stunmesh.log` on both sides — the endpoint each side published must be a public IP:port. If both machines sit behind symmetric NAT, hole punching cannot work at all (upstream limitation); one side needs a different network.

**`make start` refuses to touch an existing `dhtnode` container.** You previously ran a manual setup that used `docker run --name dhtnode`. The scripts never delete a container they did not create. Inspect it, and remove it only after confirming it is the old one:

```bash
docker inspect dhtnode
docker rm -f dhtnode      # only after confirming it is safe to remove
make start
```

**A leftover tunnel from a manual setup.** An older hand-rolled `wg0.conf` uses a different interface name and IP range, so it will not collide, but having two tunnels up makes it unclear which one carries traffic. Take it down first: `sudo wg-quick down /path/to/wg0.conf`.

**Config files disagree with each other.** `make start` and `make next` both refuse to run when the peer key in `state/stunmesh0.conf` or `state/config.yaml` is a placeholder, is this machine's own key, or differs from `state/settings.env`. Re-running `make setup` regenerates and re-syncs them.

## Generated files

Everything the scripts generate lives in `state/` — gitignored as a whole (it contains keys). See [`examples/`](examples/) for annotated samples:

- `state/stunmesh0.conf` — WireGuard config, written by setup once the peer key is provided ([example](examples/stunmesh0.conf.example))
- `state/config.yaml` — stunmesh-go config, generated by start if absent ([example](examples/config.yaml.example))
- `state/settings.env` — node identity (tunnel IPs + peer public key + peer SSH user), atomically written by setup/SSH helpers; not secret ([example](examples/settings.env.example))
- `state/ssh.conf` — Host alias block, written by `make ssh-setup`
- `state/wg.key` — your WireGuard private key, written by setup
- `state/stunmesh-go` — upstream release binary, plus `stunmesh.log` / `stunmesh.pid` at runtime

`stunmesh0.conf`, `config.yaml`, and `settings.env` are all fine to hand-edit. `settings.env` is read as a plain list of `KEY=VALUE` lines — never executed — so changing one line (say `PEER_SSH_USER`) is a valid alternative to re-running setup. `start` never overwrites an existing `config.yaml`; it only refreshes the interface name line, since the macOS utunX changes per boot. Delete either generated file to get a fresh one.

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
