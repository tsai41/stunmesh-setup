# Hub: connect to more than one machine

The 2-node flow links exactly two machines. To make **this** machine a hub that
reaches several others — B, C, D… each a normal single-peer node that only knows
this one — add the extra peers to a peer store. B↔C traffic through the hub
(routing/forwarding) is out of scope; this is the "hub talks to each spoke"
topology.

## Add a peer

Each other machine sets itself up pointing at the hub, then sends its public key
back. On a spoke, override the tunnel IP so every node has a distinct address in
the mesh /24:

```bash
# on spoke C (hub is 10.66.0.2 in this example)
make setup NODE=B IP=10.66.0.3 PEER_IP=10.66.0.2 PEER_KEY=<hub public key>
# it prints C's public key — send that to the hub
```

On the hub:

```bash
make add-peer NAME=c IP=10.66.0.3 KEY=<C's public key>
make restart          # reload WireGuard with the new peer (full stop + start)
```

`NAME` is a short label (letters/digits/`.`/`_`/`-`). `IP` must be a free address
in the hub's /24. `KEY=` may be omitted for an interactive prompt.

The first `add-peer` folds the original 2-node peer into the store (named after
the other node, `a` or `b`) so every peer lives in one place. From then on the
store is the source of truth: `state/stunmesh0.conf` and `state/config.yaml` are
re-rendered from it, and **`make setup` should not be re-run with a `PEER_KEY`**
(it writes the single-peer config and would drop the extra peers).

## Manage peers

```bash
make peers                      # name / IP / key of every peer, plus this node's own key
                                # (alias: make list-peers; add sudo -v first for handshake ages)
make remove-peer NAME=c         # drop one, then make restart
```

Removing the last extra peer leaves a single peer, which reverts to the /24
`AllowedIPs` the 2-node flow uses.

## Reach a specific peer

`make ssh` / `make proxy` default to the first peer with several configured;
choose another by name:

```bash
make ssh PEER=c
make proxy PEER=c
```

## What the store changes

- **AllowedIPs**: one peer keeps `/24` (unchanged); two or more use `/32` each,
  since WireGuard rejects overlapping AllowedIPs across peers on one interface.
- **Storage**: `state/peers.d/<name>.env` (`KEY` / `IP` / `SSH_USER`), one file
  per peer, `0600`. Absent on a plain 2-node setup — nothing here changes it.
- **Spokes are unchanged**: each other machine is an ordinary single-peer node
  that only knows the hub; only the hub holds multiple peers.

Every peer exchanges endpoints over the DHT independently
([how it works](how-it-works.md)), so the invariants there still hold per peer.
