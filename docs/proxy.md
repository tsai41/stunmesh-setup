# Browsing the peer's LAN (SOCKS proxy over SSH)

The tunnel routes only the tunnel IPs (`10.66.0.1` / `10.66.0.2`). Anything
else on the peer's LAN — the router's admin page, a NAS, printers, whatever
answers on `192.168.x.x` over there — is not routed and never will be by this
setup. A SOCKS proxy through the peer covers that: the browser hands its
requests to a local port, SSH carries them over the tunnel, and the peer makes
the actual connection from inside its own LAN.

No extra software, no config on the peer — plain `ssh -D`.

## Start it

```bash
make proxy                            # SOCKS5 on 127.0.0.1:10000, user from state/settings.env
make proxy PROXY_PORT=1080            # different local port
make proxy USER=someone               # different remote user (remembered, like make ssh)
```

Equivalent by hand: `ssh -N -D 127.0.0.1:10000 <user>@10.66.0.2`.

The command stays in the foreground and prints nothing while it works
(`-N` — no remote shell). The pid is recorded in `state/proxy.pid` so
`make stop` can find it.

## Stop it

Any of:

- **Ctrl-C** in the terminal running it
- **`make stop`** — kills the proxy along with the tunnel (the proxy rides the
  tunnel, so it could not have survived anyway; stop just makes it explicit)
- Lost the terminal: `kill $(cat state/proxy.pid)`

Nothing persists after it exits. If Firefox then shows "The proxy server is
refusing connections" on every page, its proxy setting is still pointing at the
dead proxy — switch back to "No proxy" (a dedicated profile avoids this).

## Point Firefox at it

Settings > General > Network Settings > Manual proxy configuration:

- **SOCKS Host** `127.0.0.1`, **Port** `10000`, **SOCKS v5**
- Check **Proxy DNS when using SOCKS v5** — without it, hostnames that only
  the peer's LAN can resolve (router names, mDNS-ish hostnames) fail on this
  machine before the proxy is even consulted
- Leave HTTP/HTTPS proxy fields empty; SOCKS covers everything

Then open e.g. `http://192.168.1.1` — the address of whatever lives on the
peer's LAN, as seen *from the peer*.

Chrome and Safari take proxies from system settings, which would drag every
app's traffic through the peer. Firefox keeps proxy config per-application,
which is why it is the right client here; a dedicated Firefox profile
(`firefox -P`) or container tabs narrow it further to just this browsing.

## Verify

```bash
# proxy up and answering (SOCKS handshake, not just TCP connect)
curl -s --socks5-hostname 127.0.0.1:10000 http://10.66.0.2 -o /dev/null -w '%{http_code}\n'
```

Any HTTP status (even `000` with a refused-connection error from the far end)
means the proxy relayed; `Can't complete SOCKS5 connection` or a connect
failure to `127.0.0.1:10000` means the proxy itself is down.

## Reading a failure

| Symptom | Meaning |
| --- | --- |
| Firefox: "The proxy server is refusing connections" | `make proxy` not running, or wrong port in Firefox |
| Page loads forever, then times out | Proxy up, but the target host is down/unreachable *from the peer* |
| Intranet hostname does not resolve | "Proxy DNS when using SOCKS v5" unchecked |
| `bind: Address already in use` at startup | Port taken locally — `make proxy PROXY_PORT=<other>` |
| "Proxy already running (pid ...)" at startup | One is up already — reuse it, or stop it first |

## Why not route the LAN through WireGuard instead

Adding the peer's LAN subnet to `AllowedIPs` plus NAT on the peer would make
those addresses reachable directly, but it changes the WireGuard config, needs
IP forwarding and packet-filter NAT rules on the peer, and risks colliding
with this machine's own LAN if both sides use the same private subnet. The
SOCKS proxy needs none of that and disappears the moment it exits.
