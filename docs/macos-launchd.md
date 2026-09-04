# macOS boot-time service

This integration is **for macOS only**. It installs a root `LaunchDaemon`, so
the tunnel starts after boot without waiting for a desktop login. Root is needed
to manage the dynamic WireGuard `utunX` interface without an interactive
`sudo` prompt.

## Install

First complete `make setup` and configure the peer key. From an ordinary
administrator account, run:

```bash
make launchd-install
make launchd-status
```

The installed label is `com.stunmesh.setup`. It starts immediately, starts at
future boots, and retries after an unexpected exit with a 30-second throttle.
The service preserves ownership of `state/config.yaml` for the user who ran the
install command, so ordinary setup and configuration commands keep working.

## Manage it

```bash
make launchd-restart
make launchd-status
make launchd-uninstall
```

`make stop` stops the current tunnel but the service will start it again. Use
`make launchd-uninstall` when you want it to remain stopped.

The supervisor's output is in `/var/log/stunmesh-setup.log`; the daemon log is
still `state/stunmesh.log`.

## DHT and Docker

The boot service uses the endpoint selected in `state/settings.env`. By default
that is the public Jami proxy. It never starts Docker Desktop or the bundled
container. To deliberately use the local Docker DHT instead:

```bash
make dht-local-up
make dht-use-local
make launchd-restart
```

To return to the public proxy, run `make dht-use-public` and restart the
service. If the selected endpoint is unavailable during boot, launchd retries;
inspect the service log rather than assuming Docker will be started for you.

## Sleep

Sleep stops endpoint publishing. The tunnel will republish after wake and the
peer normally reconnects within a few refresh cycles; keep the Mac awake when
continuous reachability matters.
