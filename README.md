# aowlcloud

Order OVH VPS, then run exactly what you declare on them: machines, private
mesh, firewall, services, TLS ingress, and pools of isolated per-session
containers (e.g. one browser per session, each with its own network and
egress IP). One spec file describes the whole cloud, and one binary manages it.

```
aowlcloud up examples/website.json --confirm
```

## Two halves

**A. OVH lifecycle** (`src/aowlcloud/ovh.nim`, `vps.nim`): a signed API client,
the VPS catalog, cart ordering, order tracking, rebuild, rescue mode, reboot,
console, and termination.

**B. What runs on the machines** (`spec.nim`, `render.nim`, `remote.nim`,
`node/`): a pure renderer turns the spec into per-node files, and SSH pushes
them with a dead-man rollback.

## Safety rules (why B is built the way it is)

| Risk | What stops it |
|---|---|
| Buying by accident | `order` is a dry run that builds a real cart and prices it. `--confirm` is required to check out, and `ovh.maxMonthly` (account currency) caps the whole cluster. |
| Buying twice | A node with a pending order is never ordered again; state is in `~/.aowlcloud/clusters/`. |
| Wiping a machine | `rebuild`/`terminate` need the VPS name typed back (`--yes-i-mean NAME`). Automatic bootstrap only rebuilds never-deployed nodes. |
| Locking yourself out | Every apply arms a timer on the node **before** anything goes live. The controller must reconnect over a **new** SSH session and confirm; otherwise the node restores its last confirmed config (or bare SSH on a first apply). One unconfirmed node halts the rollout. |
| A typo opening a port | Unknown spec keys are errors, and SSH sources must be listed explicitly. Docker-published ports, which skip the INPUT chain, are fenced in FORWARD: only declared public ports are reachable from outside. |
| Firewall syntax error | `nft -c` validates on the node before the timer is armed. A rejected bundle changes nothing. |
| Secrets leaking | Secrets live in `~/.aowlcloud/secrets/<cluster>.json`, travel over SSH into 0600 env files, and are never in the spec, user-data, plan output or the local applied record. The WireGuard private key is generated on the node and never leaves it. |
| Clobbering Docker's firewall | aowlcloud only owns `table inet aowl` and `table ip aowlnat`; it never flushes the ruleset. |
| Everything broken | `aowlcloud vps rescue SN on` boots OVH's rescue system, and `vps console SN` gives KVM. |

Every money/destroy/apply action is appended to `~/.aowlcloud/audit.log`.

## Getting started

1. Create an OVH application. US account: https://api.us.ovhcloud.com/createApp/ (EU: eu.api.ovh.com, CA: ca.api.ovh.com).
2. `aowlcloud auth --endpoint ovh-us --app-key K --app-secret S`, then open the printed URL to approve a
   **scoped** key: read everything; write only cart, VPS and order.
3. `aowlcloud whoami` and `aowlcloud catalog` (the catalog needs no key).
4. Copy an example spec, set `access.sshFrom` to your IP, and set `ovh.maxMonthly`.
5. `aowlcloud order spec.json` to see the price. Then run `aowlcloud up spec.json --confirm`.

Build: `nim c -o:bin/aowlcloud.exe src/aowlcloud.nim` (Nim 2.2, no packages).

## The spec

```jsonc
{
  "cluster": "farm",
  "ovh":    { "maxMonthly": 30, "plan": "vps-2027-model1", "datacenter": "US-EAST-VA", "os": "Debian 12" },
  "access": { "sshKey": "~/.ssh/id_ed25519.pub", "sshFrom": ["203.0.113.5/32"] },
  "mesh":   { "cidr": "10.77.0.0/24", "port": 51820 },       // WireGuard between all nodes
  "rollbackSeconds": 90,
  "nodes": {
    "web1":  { "labels": ["control"] },                       // ordered from OVH
    "farm1": { "plan": "vps-le-2-2-40", "labels": ["farm"], "extraIps": ["…"] },
    "home":  { "host": "192.0.2.7" }                          // adopt any existing Linux box
  },
  "ingress":  { "nodes": ["web1"], "email": "you@example.com" }, // Caddy, automatic TLS
  "firewall": { "rules": ["tcp dport 9100 ip saddr 10.77.0.0/24 accept"] }, // raw nft, verbatim
  "services": {
    "site": { "build": "./site", "on": ["web1"], "port": 80, "routes": ["example.com"] },
    "game": { "image": "itzg/minecraft-server", "on": ["web1"],
              "public": [{ "port": 25565, "from": ["0.0.0.0/0"] }], "volumes": ["mc:/data"] },
    "browser": {
      "build": "./browser", "on": ["label:farm"], "port": 9222, "cpus": 1, "memory": "1g", "shmSize": "1g",
      "pool": { "size": 8, "isolate": true, "internet": true, "maxLifetime": "30m", "egressIps": ["…"] }
    }
  }
}
```

Service keys: `image` or `build` (a local dir with a Dockerfile, shipped and built on the node,
tagged by content hash), `on`, `port`, `routes`, `public`, `env`, `secrets` (`VAR -> secret name`),
`volumes`, `cmd`, `cpus`, `memory`, `shmSize`, `dockerArgs` (raw `docker run` flags, for anything
not modelled), `pool`.

### How traffic flows

- **Ingress:** Caddy on the ingress nodes (host network, 80/443) → `meshIp:port` of every replica on any node, over WireGuard.
- **Service ports** are published on the node's **mesh IP only** (plain service: `20000+i`; pool session *s*: `30000+250·k+s`). The public internet cannot reach them.
- **Public ports** are published only when declared, optionally limited to source CIDRs.
- **Pools:** session *s* of pool *k* is the systemd instance `aowl-<svc>@s`, with:
  - its own Docker bridge `aw<k>s<s>` (`10.<100+k>.<s>.0/24`, inter-container traffic off)
  - `AOWL_SESSION=s` in its environment, and per-session named volumes
  - optional SNAT to one of the node's extra IPs

  Sessions can reach the internet only: not the host, the mesh, other sessions or private ranges. Replies to the mesh are allowed, so a controller can drive them. `maxLifetime` recycles a session into a fresh container.

## Commands

See `aowlcloud` with no arguments. Day to day: `plan` (diff vs. what is confirmed), `apply`,
`status` (units, mesh handshakes, last apply result), `logs`, `ssh`, `rollback`.

## Tests

- `nim c -r tests/tall.nim`: signing (checked against Python's hashlib), spec validation, rendering, tar format (read by GNU tar).
- `nim c -r --threads:on tests/tovh.nim`: the cart sequence and money/destroy guards against a mock OVH.
- `wsl -u root -e bash tests/node_harness.sh`: real kernel nftables, `systemd-analyze verify`, pool wrappers, and the full apply/confirm/rollback state machine using the real node scripts. Runs inside a private mount+net namespace, so the host is untouched.

Not yet exercised: a real OVH order, and Docker/WireGuard on a live node. The first `up` should be
watched: a cheap VPS (about $4–6/mo) with `website.json`.

## Limits

- VPS has no nested virtualisation, so "each session its own OS" means its own container image and kernel namespaces, not its own kernel. Per-session VMs need a dedicated server (KVM/Firecracker), which would be a different backend for `pool`.
- Extra IPs for egress must be ordered and routed to the VPS in OVH first. aowlcloud then adds them to the interface and SNATs to them.
- IPv4 is filtered per declared source. IPv6 is dropped except SSH from listed v6 sources.
