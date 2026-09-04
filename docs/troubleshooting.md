# Troubleshooting

`make next` prints the single next step for the current state; `make status` shows which of the three components (DHT, WireGuard, stunmesh-go) are up. Start with those, then find your symptom below.

## This machine — `make start` and local state

**`make start` says "DHT endpoint unavailable".** The selected DHT endpoint is not reachable. The default is the public Jami proxy, so check the network and retry. Docker is never started automatically; if you deliberately selected the local endpoint, start it with `make dht-local-up`, or return to the default with `make dht-use-public`.

**Both machines are running but ping never succeeds.** Punching takes 1-2 minutes after the *second* machine starts; wait before digging. If it stays down, check `state/stunmesh.log` on both sides — the endpoint each side published must be a public IP:port. If both machines sit behind symmetric NAT, hole punching cannot work at all (upstream limitation); one side needs a different network.

**The local `dhtnode` does not start.** It is an explicit Docker option, so inspect it separately with `docker compose logs dhtnode`; it is not managed by `make start` or `make stop`.

**A leftover tunnel from a manual setup.** An older hand-rolled `wg0.conf` uses a different interface name and IP range, so it will not collide, but having two tunnels up makes it unclear which one carries traffic. Take it down first: `sudo wg-quick down /path/to/wg0.conf`.

**Config files disagree with each other.** `make start` and `make next` both refuse to run when the peer key in `state/stunmesh0.conf` or `state/config.yaml` is a placeholder, is this machine's own key, or differs from `state/settings.env`. Re-running `make setup` regenerates and re-syncs them.

## Peer-side — tunnel up but the peer can't find you

Your `stunmesh.log` keeps repeating this on the *other* machine, every refresh cycle:

```
WRN endpoint is unavailable or not ready error="no value found for key: ..." controller=establish
```

That means the other side successfully published its own endpoint to the DHT, but it can never find **yours**. Check these on this machine, in order:

1. **Is `stunmesh-go` even running here?**
   ```bash
   make status
   ```
   If it shows "not running" or crashed, nothing was ever published — start it with `make start`.

2. **Did this machine actually publish its endpoint?**
   ```bash
   tail -f state/stunmesh.log
   ```
   Look for `discovered IPv4 endpoint` and `store endpoint` lines for your own device. Missing means you're stuck before publish — usually:
   - Outbound STUN traffic blocked (`stun.l.google.com:19302`)
   - No DHT bootstrap reachable — check with `make status` (`dht good` should be > 0)

3. **Has your WireGuard key changed?**
   ```bash
   wg pubkey < state/wg.key
   ```
   Compare this against the public key you originally sent to the other machine during `make setup`. If `state/wg.key` was ever deleted/regenerated, your identity changed and the old key will never resolve again — you'd need to re-exchange keys via `make setup`.

4. **Can this machine go to sleep?** A sleeping machine stops publishing, so the peer loses the tunnel until it wakes and republishes. On a Mac check `pmset -g` (look at `sleep`); keep it awake while running with `caffeinate -i -w $(cat state/stunmesh.pid)` or disable sleep in System Settings > Energy.

5. **Just started?** Give it 2-3 refresh cycles (~2-3 min) before assuming it's broken — `daemon` republishes roughly every 60s.

If all five check out on this machine and the problem persists, send back:
- Output of `make status`
- Last ~30 lines of `state/stunmesh.log`
