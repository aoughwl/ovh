## Elastic groups: grow and shrink a set of hourly Public Cloud instances.
##
## Every member is written to state *before* we wait on it, so a crash
## mid-scale never leaves an instance we do not know about (and therefore
## never one we would keep paying for silently). Deletion only ever touches
## instance ids recorded in state.

import std/[json, strutils, tables, times, os, algorithm, sequtils, osproc]
import ovh, cloud, spec, state, remote

type ScaleError* = object of CatchableError

proc members*(st: ClusterState, group: string): seq[string] =
  for k, v in st.nodes:
    if v.group == group: result.add k

proc memberTuples*(st: ClusterState): seq[(string, string, string, string)] =
  for k, v in st.nodes:
    if v.group != "": result.add (k, v.group, v.ip, v.meshIp)

proc hourlyTotal*(st: ClusterState): float =
  for v in st.nodes.values: result += v.hourly

proc allocMesh(sp: Spec, st: ClusterState): string =
  var used: seq[string]
  for v in st.nodes.values: used.add v.meshIp
  for n in sp.nodes.values: used.add n.meshIp
  for i in dynamicMeshStart .. 250:
    let a = meshAddr(sp.meshCidr, i)
    if a notin used: return a
  raise newException(ScaleError, "mesh is full")

proc nextName(st: ClusterState, group: string): string =
  var hi = 0
  for m in members(st, group):
    try: hi = max(hi, parseInt(m.rsplit('-', 1)[1])) except ValueError: discard
  group & "-" & $(hi + 1)

proc instanceName(sp: Spec, member: string): string = "aowl-" & sp.cluster & "-" & member

proc waitReady(o: Ovh, project: string, sp: Spec, st: var ClusterState, member: string,
               log: proc (s: string)): bool =
  ## ACTIVE + public IP, then SSH, then the bootstrap marker (cloud-init ran
  ## our script as userData). If cloud-init did not, bootstrap over SSH.
  let id = st.nodes[member].instanceId
  let deadline = epochTime() + 900
  while epochTime() < deadline:
    let i = o.instance(project, id)
    if i.status == "ERROR": (log "  " & member & ": instance ERROR"; return false)
    if i.status == "ACTIVE" and i.ip != "":
      st.nodes[member].ip = i.ip
      st.save()
      break
    sleep 10_000
  if st.nodes[member].ip == "": (log "  " & member & ": never became ACTIVE"; return false)
  forgetHost(st.nodes[member].ip)
  let root = Target(host: st.nodes[member].ip, user: "root")
  for _ in 1..60:
    let pub = readWgPub(root)
    if pub != "":
      st.nodes[member].wgPub = pub
      st.nodes[member].bootstrapped = true
      st.save()
      return true
    sleep 10_000
  log "  " & member & ": no bootstrap marker; bootstrapping over ssh as debian"
  let r = adoptBootstrap(sp, Target(host: st.nodes[member].ip, user: "debian"))
  if r.code != 0: (log r.output; return false)
  let pub = readWgPub(root)
  if pub == "": return false
  st.nodes[member].wgPub = pub
  st.nodes[member].bootstrapped = true
  st.save()
  true

proc plan*(o: Ovh, sp: Spec, st: ClusterState, group: string, want: int): (int, float, float) =
  ## (delta, flavor hourly price, resulting cluster hourly total)
  let g = sp.groups[group]
  let n = clamp(want, g.min, g.max)
  let sub = if sp.subsidiary != "": sp.subsidiary else: defaultSubsidiary(o.creds.endpoint)
  let prices = o.hourlyPrices(sub)
  if g.flavor notin prices: raise newException(ScaleError, "no hourly price for flavor " & g.flavor)
  let p = prices[g.flavor]
  let delta = n - members(st, group).len
  (delta, p, hourlyTotal(st) + max(delta, 0).float * p)

proc grow(o: Ovh, sp: Spec, st: var ClusterState, group: string, count: int, price: float,
          log: proc (s: string)): int =
  let g = sp.groups[group]
  let project = o.resolveProject(sp.cloudProject)
  let flavor = o.flavorId(project, g.region, g.flavor)
  let image = o.imageId(project, g.region, g.image)
  let key = o.ensureSshKey(project, g.region, "aowl-" & sp.cluster, readFile(sp.sshKeyPath).strip)
  let userData = bootstrapScript(sp)
  var created: seq[string]
  for _ in 1..count:
    let m = nextName(st, group)
    let inst = o.createInstance(project, g.region, instanceName(sp, m), flavor, image, key, userData)
    st.nodes[m] = NodeState(group: group, instanceId: inst.id, meshIp: allocMesh(sp, st),
                            hourly: price, createdAt: getTime().toUnix)
    st.save()                                  # recorded before we wait on it
    audit "CLOUD-CREATE " & sp.cluster & "/" & m & " id=" & inst.id & " " & g.flavor & " " & $price & "/h"
    log "  created " & m & " (" & inst.id & ")"
    created.add m
  for m in created:
    if waitReady(o, project, sp, st, m, log):
      inc result
      log "  " & m & " ready at " & st.nodes[m].ip & ", mesh " & st.nodes[m].meshIp

proc shrink*(o: Ovh, sp: Spec, st: var ClusterState, victims: seq[string], log: proc (s: string)) =
  let project = o.resolveProject(sp.cloudProject)
  for m in victims:
    let id = st.nodes[m].instanceId
    if id == "": continue
    try:
      o.deleteInstance(project, id)
    except OvhError as e:
      if e.status != 404: raise
    audit "CLOUD-DELETE " & sp.cluster & "/" & m & " id=" & id
    st.nodes.del m
    st.save()
    let d = appliedDir(sp.cluster, m)
    if dirExists(d): removeDir(d)
    log "  deleted " & m

proc newestFirst(st: ClusterState, group: string): seq[string] =
  result = members(st, group)
  result.sort(proc (a, b: string): int = cmp(st.nodes[b].createdAt, st.nodes[a].createdAt))

proc scaleTo*(o: Ovh, sp: Spec, st: var ClusterState, group: string, want: int,
              confirm: bool, log: proc (s: string)): bool =
  ## Returns true when membership changed (the caller then re-applies so the
  ## mesh and every peer's firewall learn about it).
  if group notin sp.groups: raise newException(ScaleError, "unknown group " & group)
  let (delta, price, total) = plan(o, sp, st, group, want)
  let n = members(st, group).len
  log group & ": " & $n & " -> " & $(n + delta) & " members (" & sp.groups[group].flavor & " at " &
      formatFloat(price, ffDecimal, 4) & "/h; cluster " & formatFloat(total, ffDecimal, 4) & "/h, cap " &
      formatFloat(sp.maxHourly, ffDecimal, 4) & ")"
  if delta == 0: return false
  if delta > 0 and total > sp.maxHourly + 1e-9:
    raise newException(ScaleError, "refused: over ovh.maxHourly")
  if not confirm:
    log "  dry run -- add --confirm"
    return false
  if delta > 0: discard grow(o, sp, st, group, delta, price, log)
  else: shrink(o, sp, st, newestFirst(st, group)[0 ..< -delta], log)
  true

proc demand*(cmd: string): int =
  ## The autoscaler's signal: any shell command that prints a number
  ## (queue depth, pending builds, a curl to a metrics endpoint...).
  let (o, code) = execCmdEx(cmd)
  if code != 0: raise newException(ScaleError, "demand command failed: " & o)
  parseInt(o.strip.splitLines[^1].strip)

proc autoscaleTick*(o: Ovh, sp: Spec, st: var ClusterState, group: string, want: int,
                    log: proc (s: string)): bool =
  ## Up immediately; down only after members stayed surplus for scaleDownAfter.
  let g = sp.groups[group]
  let target = clamp(want, g.min, g.max)
  let cur = members(st, group)
  if target > cur.len:
    for m in cur: st.nodes[m].surplusSince = 0
    return scaleTo(o, sp, st, group, target, true, log)
  let order = newestFirst(st, group)
  let surplus = order[0 ..< cur.len - target]
  let now = getTime().toUnix
  var victims: seq[string]
  for m in order:
    if m in surplus:
      if st.nodes[m].surplusSince == 0: st.nodes[m].surplusSince = now
      elif now - st.nodes[m].surplusSince >= g.scaleDownAfterSec: victims.add m
    else:
      st.nodes[m].surplusSince = 0
  st.save()
  if victims.len > 0:
    log group & ": " & $victims.len & " member(s) idle for " & $g.scaleDownAfterSec & "s"
    shrink(o, sp, st, victims, log)
    return true
  false
