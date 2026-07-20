# AGENTS.md

Guide for AI agents working in this repo.

## What this is

Wrapper scripts building a WireGuard P2P tunnel between exactly two machines (node A `10.66.0.1`, node B `10.66.0.2`) using upstream [stunmesh-go](https://github.com/tjjh89017/stunmesh-go) (GPL-2.0, downloaded as a release binary at setup — never vendored) and a local OpenDHT proxy managed by docker compose. Scripts are MIT.

## File map

- `scripts/setup.sh` — one-time per machine: check-only dependency preflight (never installs), download binary, generate wg keypair, write `state/settings.env` + `state/stunmesh0.conf`
- `scripts/start.sh` / `scripts/stop.sh` — lifecycle: compose up dhtnode → wait DHT bootstrap → wg-quick → stunmesh-go (root, pidfile; runs with cwd `state/`)
- `scripts/next.sh` — state-machine guide printing the single next step (`make next`)
- `scripts/lib.sh` — shared: `STATE`, `OS`, `WG_CONF_NAME`, `WG_CONF`, `_wg_running`, `_stunmesh_pid`; all scripts `cd` to repo root first
- `compose.yaml` — dhtnode container; port bound to loopback; `container_name` pinned
- `Makefile` — thin launcher: `setup NODE=A PEER_KEY=…`, `start`, `stop`, `status`, `logs`, `next`
- Runtime files (all under `state/`, gitignored as a directory): `settings.env` (metadata, not secret), `wg.key` + `stunmesh0.conf` (SECRETS), `config.yaml`, `stunmesh.log`, `stunmesh.pid`, `stunmesh-go` binary

## Two-machine order

Setup spans two machines; each one only needs the OTHER's public key before its own `make start`. The canonical sequence:

1. Node A: `make setup NODE=A` → prints A's public key; no peer key yet, press Enter
2. Send A's key to node B (public keys are not secret)
3. Node B: `make setup NODE=B` → paste A's key; B prints its own key → send back to A. B can `make start` already — no need to wait for A
4. Node A: `make setup NODE=A` again → paste B's key → `make start`
5. Verify from either side: `ping 10.66.0.2` (A) / `ping 10.66.0.1` (B); punching takes ~1-2 min after both are up

When unsure which step a machine is on, run `make next` — it inspects local state and prints the exact next command, including what to run on the other machine.

## Invariants — do not break

- Key direction: `--peer-key` is always the OTHER machine's public key; setup.sh rejects the machine's own key. Keep that guard.
- `dedup: false` in the opendht plugin config is mandatory (values expire in 10 min).
- macOS interface is dynamic `utunX` (real name in `/var/run/wireguard/stunmesh0.name`); Linux is fixed `stunmesh0`. Never hardcode utun names.
- `start.sh` must not clobber an existing `config.yaml` — it only rewrites the interface-name line; `setup.sh` syncs its `public_key` line.
- Dependency checks stay check-only: print install hints, never install.
- Never commit runtime files; private key material must not appear in tracked files or command output.

## Verify changes

```bash
bash -n scripts/*.sh && shellcheck scripts/*.sh   # SC1090 warning is expected
docker compose config >/dev/null
make -n setup NODE=A PEER_KEY=x && make status && ./scripts/setup.sh --node X  # error paths
```

Real tunnel verification needs both machines: `make start` on each, then `ping 10.66.0.2` / `10.66.0.1`.
