# AGENTS.md

Guide for AI agents working in this repo.

## What this is

Wrapper scripts building a WireGuard P2P tunnel between exactly two machines (node A `10.66.0.1`, node B `10.66.0.2`) using upstream [stunmesh-go](https://github.com/tjjh89017/stunmesh-go) (GPL-2.0, downloaded as a release binary at setup — never vendored) and a local OpenDHT proxy managed by docker compose. Scripts are MIT.

## File map

- `setup.sh` — one-time per machine: check-only dependency preflight (never installs), download binary, generate wg keypair, write `settings.env` + `stunmesh0.conf`
- `start.sh` / `stop.sh` — lifecycle: compose up dhtnode → wait DHT bootstrap → wg-quick → stunmesh-go (root, pidfile)
- `next.sh` — state-machine guide printing the single next step (`make next`)
- `lib.sh` — shared: `OS`, `WG_CONF_NAME`, `_wg_running`, `_stunmesh_pid`
- `compose.yaml` — dhtnode container; port bound to loopback; `container_name` pinned
- `Makefile` — thin launcher: `setup NODE=A PEER_KEY=…`, `start`, `stop`, `status`, `logs`, `next`
- Runtime files (gitignored, in repo root): `settings.env` (metadata, not secret), `wg.key` + `stunmesh0.conf` (SECRETS), `config.yaml`, `stunmesh.log`, `stunmesh.pid`, `stunmesh-go` binary

## Invariants — do not break

- Key direction: `--peer-key` is always the OTHER machine's public key; setup.sh rejects the machine's own key. Keep that guard.
- `dedup: false` in the opendht plugin config is mandatory (values expire in 10 min).
- macOS interface is dynamic `utunX` (real name in `/var/run/wireguard/stunmesh0.name`); Linux is fixed `stunmesh0`. Never hardcode utun names.
- `start.sh` must not clobber an existing `config.yaml` — it only rewrites the interface-name line; `setup.sh` syncs its `public_key` line.
- Dependency checks stay check-only: print install hints, never install.
- Never commit runtime files; private key material must not appear in tracked files or command output.

## Verify changes

```bash
bash -n setup.sh start.sh stop.sh next.sh lib.sh && shellcheck *.sh   # SC1091 info is expected
docker compose config >/dev/null
make -n setup NODE=A PEER_KEY=x && make status && ./setup.sh --node X  # error paths
```

Real tunnel verification needs both machines: `./start.sh` on each, then `ping 10.66.0.2` / `10.66.0.1`.
