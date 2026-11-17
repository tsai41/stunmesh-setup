# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Wrapper scripts building a WireGuard P2P tunnel between machines using upstream [stunmesh-go](https://github.com/tjjh89017/stunmesh-go) (GPL-2.0, downloaded as a release binary at setup — never vendored). The default is two machines (node A `10.66.0.1`, node B `10.66.0.2`); a node can also act as a hub reaching several peers (`make add-peer`, see `docs/hub.md`). Endpoints are exchanged over OpenDHT: the public Jami proxy (`dhtproxy3.jami.net`) by default, or a local docker `dhtnode` only when explicitly chosen (`make dht-local-up && make dht-use-local`) — `start.sh` never starts Docker on its own. Scripts are MIT. User-facing docs live in `docs/`, indexed by `docs/README.md`.

## File map

- `scripts/setup.sh` — one-time per machine: check-only dependency preflight (never installs), download binary, generate wg keypair, write `state/settings.env` + `state/stunmesh0.conf`
- `scripts/start.sh` / `stop.sh` / `restart.sh` — lifecycle: require the selected DHT endpoint to be reachable → wg-quick → stunmesh-go (root, pidfile; runs with cwd `state/`)
- `scripts/dht.sh` — DHT endpoint selection and health checks, sourced by others; never invokes Docker. `dht-local.sh` owns the explicit Docker lifecycle, `dht-mode.sh` persists the chosen endpoint
- `scripts/peer.sh` — hub mode: `add-peer` / `remove-peer` / `peers` (alias `list-peers`)
- `scripts/ssh.sh` — `connect` / `proxy` (SOCKS5 `ssh -D`) / `forward` (fzf-pick the peer's listening ports, `ssh -L` to the same local ports) / `play` (copy one peer file into `state/play/` and open it) / `setup` / `key` (macOS-only key login) / `teardown`. `PEER=<name>` picks a hub peer by name, not IP
- `scripts/launchd.sh` / `launchd-install.sh` + `launchd/macos/` — macOS boot-time LaunchDaemon
- `scripts/update.sh` — downloads the latest verified stunmesh-go binary; restarts only the daemon when it is running
- `scripts/status.sh`, `scripts/next.sh` — `make status`; `make next` prints the single next step from local state
- `scripts/lib.sh` — shared: `STATE`, `OS`, `WG_CONF_NAME`, `WG_CONF`, `_wg_running`, `_stunmesh_pid`, `_install_stunmesh_go`; all scripts `cd` to repo root first
- `compose.yaml` — dhtnode container; port bound to loopback; `container_name` pinned
- `examples/` — sample `settings.env`, `stunmesh0.conf`, `config.yaml`
- `Makefile` — thin launcher over the scripts
- Runtime files live under `state/` (gitignored as a directory); `docs/state-files.md` says which are secret

## Two-machine order

Each machine only needs the OTHER's public key before its own `make start`:

1. Node A: `make setup NODE=A` → prints A's public key; no peer key yet, press Enter
2. Send A's key to node B (public keys are not secret)
3. Node B: `make setup NODE=B` → paste A's key; B prints its own key → send back to A. B can `make start` already
4. Node A: `make setup NODE=A` again → paste B's key → `make start`
5. Verify: `ping 10.66.0.2` (from A) / `ping 10.66.0.1` (from B); punching takes ~1-2 min after both are up

## Invariants — do not break

- Key direction: `--peer-key` is always the OTHER machine's public key; setup.sh rejects the machine's own key. Keep that guard.
- `dedup: false` in the opendht plugin config is mandatory (values expire in 10 min).
- macOS interface is dynamic `utunX` (real name in `/var/run/wireguard/stunmesh0.name`); Linux is fixed `stunmesh0`. Never hardcode utun names.
- `start.sh` must not clobber an existing `config.yaml` — it only rewrites the interface-name line; `setup.sh` syncs its `public_key` line.
- Dependency checks stay check-only: print install hints, never install. Docker is never started implicitly.
- Never commit runtime files; private key material must not appear in tracked files or command output.
- The repo is public: tests, docs and examples use made-up hostnames, users, keys and IPs (the tunnel range `10.66.0.x` is fine), never real ones.

## Verify changes

`make check` bundles the static gates (bash syntax, ShellCheck, `docker compose config`, whitespace) and needs `shellcheck` installed (`brew install shellcheck`). `make test` runs every `tests/*_test.sh` through `tests/run.sh`; each test is self-contained (fake `HOME`, copied scripts, stubbed `ssh`/`nc`/`fzf`/`open`) and never touches the real `state/` or tunnel. Run one directly:

```bash
bash tests/ssh_forward_test.sh
```

New `scripts/ssh.sh` subcommands follow the same shape: a `case "$ACTION"` branch, a `--flag` in the argument loop, a Makefile target passing the flag, and a test that stubs the external tools.

Real tunnel verification needs both machines: `make start` on each, then ping across.
