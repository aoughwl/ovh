## Local record of what exists: one JSON file per cluster under ~/.aowlcloud.
## OVH is the source of truth for *what we own*; this file is the source of
## truth for *which spec node each service is*, and it is what makes ordering
## idempotent (a node with a pending order is never ordered twice).

import std/[json, os, times, tables]

type
  NodeState* = object
    serviceName*: string   ## OVH VPS name ("vps-xxxx.vps.ovh.net"), empty until delivered
    orderId*: int64        ## last order placed for this node, 0 if none
    orderStatus*: string   ## pending | delivered | cancelled
    monthlyEUR*: float     ## price with tax at order time, feeds the budget cap
    ip*: string
    host*: string          ## override for adopted (non-OVH) machines
    wgPub*: string         ## WireGuard public key; the private key never leaves the node
    bootstrapped*: bool
    appliedHash*: string   ## hash of the last bundle confirmed on this node
    # Public Cloud group members only (empty for static nodes):
    group*: string         ## spec group this instance belongs to
    instanceId*: string    ## OVH instance id -- only ids recorded here are ever deleted
    meshIp*: string        ## allocated from the dynamic range when the member is created
    hourly*: float         ## price per hour, feeds the hourly budget cap
    createdAt*: int64
    surplusSince*: int64   ## when the autoscaler first found it unneeded (0 = needed)

  ClusterState* = object
    name*: string
    nodes*: OrderedTable[string, NodeState]

proc home*(): string =
  result = getEnv("AOWLCLOUD_HOME", getHomeDir() / ".aowlcloud")

proc statePath*(cluster: string): string = home() / "clusters" / (cluster & ".json")

proc load*(cluster: string): ClusterState =
  result.name = cluster
  let p = statePath(cluster)
  if fileExists(p):
    let j = parseFile(p)
    for k, v in j{"nodes"}.getFields:
      var n = NodeState()                      # field by field: old state files lack new fields
      for name, f in n.fieldPairs:
        if v.hasKey(name): f = v[name].to(typeof(f))
      result.nodes[k] = n

proc save*(s: ClusterState) =
  let p = statePath(s.name)
  createDir(p.parentDir)
  var nodes = newJObject()
  for k, v in s.nodes: nodes[k] = %v
  let tmp = p & ".tmp"
  writeFile(tmp, pretty(%*{"name": s.name, "nodes": nodes}))
  moveFile(tmp, p)   # atomic replace: a crash never leaves half a state file

proc audit*(msg: string) =
  ## Append-only log of every action that spends money, destroys, or changes a node.
  createDir(home())
  let f = open(home() / "audit.log", fmAppend)
  f.writeLine($now().utc & "  " & msg)
  f.close()
