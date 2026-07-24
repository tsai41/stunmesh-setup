# Documentation

Setup and first-run live in the [root README](../README.md); these are the deeper docs, grouped by what you came to do.

### Understand it

- [how-it-works.md](how-it-works.md) — how endpoints are exchanged over the DHT, the public-proxy probe and docker fallback, the trust model, and the invariants (`dedup: false`, `utunX` renaming, sleep) worth knowing.

### Do a task

- [proxy.md](proxy.md) — browse the peer's LAN (its router page, a NAS, printers) through a SOCKS5 proxy over the tunnel.

### Look something up / fix it

- [state-files.md](state-files.md) — what each file under `state/` is, which hold secrets, and what is safe to hand-edit.
- [troubleshooting.md](troubleshooting.md) — `make start` failures on this machine, and the peer-side "endpoint is unavailable" loop.
