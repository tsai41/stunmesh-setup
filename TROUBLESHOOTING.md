# Peer-side troubleshooting

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
