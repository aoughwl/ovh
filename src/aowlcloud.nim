## aowlcloud -- OVH lifecycle (part A) + declarative node/network/service
## control (part B). See README.md.

import std/[os, strutils, json, tables, sequtils, times, terminal]
import aowlcloud/[ovh, vps, state, spec, render, remote]

const usage = """
aowlcloud -- order, run and network OVH VPS from one spec file

Part A: OVH lifecycle
  auth --app-key K --app-secret S [--endpoint ovh-us]   get a scoped consumer key
  whoami                                                 test credentials
  catalog [--subsidiary US] [--all]                      VPS plans, cheapest first
  vps list | info SN | console SN | reboot SN
  vps rescue SN on|off                                   out-of-band recovery boot
  vps rebuild SN --image NAME --yes-i-mean SN            WIPES the disk
  vps terminate SN --yes-i-mean SN                       OVH emails a token
  vps confirm-terminate SN --token T --yes-i-mean SN

Part B: the cluster, from SPEC (a JSON file)
  check SPEC                     validate the spec
  order SPEC [--confirm]         quote (and with --confirm, buy) missing nodes
  sync SPEC                      pick up delivered orders: name + IP
  bootstrap SPEC [--node N] [--user U] [--yes-i-mean-it]
                                 OVH node: rebuild with key+bootstrap (only
                                 automatic on never-deployed nodes); adopted
                                 host: bootstrap over ssh
  plan SPEC [--node N]           render and diff against what is confirmed
  apply SPEC [--node N]          push with dead-man rollback, one node at a time
  up SPEC [--confirm]            order -> sync -> bootstrap -> apply
  status SPEC                    units, mesh handshakes, last apply result
  ssh SPEC NODE [CMD...]
  logs SPEC NODE UNIT
  rollback SPEC NODE             restore the previous confirmed config now

Credentials: ~/.aowlcloud/ovh.json or OVH_* env. Secrets for services:
~/.aowlcloud/secrets/<cluster>.json. Nothing secret lives in the spec.
"""

type Args = object
  pos: seq[string]
  flags: Table[string, string]

proc parseArgs(): Args =
  let ps = commandLineParams()
  var i = 0
  while i < ps.len:
    let a = ps[i]
    if a.startsWith("--"):
      let kv = a[2..^1].split('=', 1)
      if kv.len == 2: result.flags[kv[0]] = kv[1]
      elif i + 1 < ps.len and not ps[i + 1].startsWith("--") and
           kv[0] notin ["confirm", "all", "yes-i-mean-it"]:
        result.flags[kv[0]] = ps[i + 1]; inc i
      else: result.flags[kv[0]] = "true"
    else: result.pos.add a
    inc i

proc flag(a: Args, k: string, def = ""): string = a.flags.getOrDefault(k, def)
proc has(a: Args, k: string): bool = k in a.flags
proc need(a: Args, i: int, what: string): string =
  if a.pos.len <= i: quit "missing " & what & "\n\n" & usage, 2
  a.pos[i]

proc say(s: string) = echo s
proc warn(s: string) = styledEcho fgYellow, s
proc bad(s: string) = styledEcho fgRed, s

proc client(): Ovh = newOvh(loadCreds())

# --- part A -------------------------------------------------------------------

proc cmdAuth(a: Args) =
  var c = loadCreds()
  if a.has("endpoint"): c.endpoint = a.flag("endpoint")
  if a.has("app-key"): c.appKey = a.flag("app-key")
  if a.has("app-secret"): c.appSecret = a.flag("app-secret")
  if c.appKey == "" or c.appSecret == "":
    quit "create an application first at " & baseUrl(c.endpoint).replace("/1.0", "") &
         "/createApp/ then: aowlcloud auth --app-key K --app-secret S", 2
  let (ck, url) = newOvh(c).requestCredential()
  c.consumerKey = ck
  saveCreds(c)
  say "saved to " & credsPath()
  say "approve the key (scoped: read all; write only cart/VPS/order) at:\n  " & url

proc cmdVps(a: Args) =
  let o = client()
  let sub = a.need(1, "vps subcommand")
  case sub
  of "list":
    for sn in o.list():
      let i = o.info(sn)
      say sn & "  " & i{"state"}.getStr & "  " & i{"model"}{"name"}.getStr & "  " &
          i{"zone"}.getStr & "  " & o.publicIpv4(sn)
  of "info": say pretty(o.info(a.need(2, "VPS name")))
  of "console": say o.consoleUrl(a.need(2, "VPS name"))
  of "reboot":
    let sn = a.need(2, "VPS name")
    audit "reboot " & sn
    o.waitTask(sn, o.reboot(sn)); say "rebooted"
  of "rescue":
    let sn = a.need(2, "VPS name")
    let on = a.need(3, "on|off") == "on"
    audit "rescue " & sn & " " & $on
    o.waitTask(sn, o.setRescue(sn, on))
    say (if on: "in rescue mode; OVH has emailed the rescue root password" else: "booted from disk")
  of "rebuild":
    let sn = a.need(2, "VPS name")
    let key = readFile(a.flag("key", "~/.ssh/id_ed25519.pub").expandTilde).strip
    audit "rebuild " & sn & " image=" & a.flag("image")
    o.waitTask(sn, o.rebuild(sn, a.flag("image", "Debian 12"), key, "", a.flag("yes-i-mean")))
    say "rebuilt"
  of "terminate":
    let sn = a.need(2, "VPS name")
    audit "terminate-request " & sn
    discard o.terminate(sn, a.flag("yes-i-mean"))
    say "termination requested; OVH emails a token -> vps confirm-terminate"
  of "confirm-terminate":
    let sn = a.need(2, "VPS name")
    audit "terminate-confirm " & sn
    discard o.confirmTermination(sn, a.flag("token"), a.flag("yes-i-mean"))
    say "termination confirmed"
  else: quit usage, 2

# --- part B -------------------------------------------------------------------

proc monthlyTotal(st: ClusterState): float =
  for n in st.nodes.values:
    if n.orderStatus in ["pending", "delivered"]: result += n.monthlyEUR

proc cmdOrder(sp: Spec, st: var ClusterState, confirm: bool) =
  let o = client()
  for n in sp.nodes.values:
    if n.host != "": continue
    let ns = st.nodes.getOrDefault(n.name)
    if ns.serviceName != "" or ns.orderStatus == "pending":
      continue                                   # idempotent: never order twice
    let q = o.quote((if sp.subsidiary != "": sp.subsidiary else: defaultSubsidiary(o.creds.endpoint)), n.plan, n.datacenter, n.os, "aowlcloud:" & sp.cluster & ":" & n.name)
    let total = monthlyTotal(st) + q.withTaxEUR
    say n.name & ": " & n.plan & " @ " & n.datacenter & " (" & n.os & ") = " &
        formatFloat(q.withTaxEUR, ffDecimal, 2) & " incl. tax; cluster would be " &
        formatFloat(total, ffDecimal, 2) & "/month"
    for l in q.lines: say "    " & l
    if sp.maxMonthlyEUR <= 0 or total > sp.maxMonthlyEUR:
      bad "  refused: over ovh.maxMonthly (" & $sp.maxMonthlyEUR & ")"
      continue
    if not confirm:
      warn "  dry run -- add --confirm to buy"
      continue
    let ord = o.checkout(q, confirm)
    var s = st.nodes.getOrDefault(n.name)
    s.orderId = ord["orderId"].getBiggestInt
    s.orderStatus = "pending"
    s.monthlyEUR = q.withTaxEUR
    st.nodes[n.name] = s
    st.save()
    audit "ORDER " & sp.cluster & "/" & n.name & " order=" & $s.orderId & " price=" & $q.withTaxEUR
    say "  ordered #" & $s.orderId & (if ord{"url"}.getStr != "": "  pay/inspect: " & ord["url"].getStr else: "")

proc cmdSync(sp: Spec, st: var ClusterState) =
  let o = client()
  for name, ns in st.nodes.mpairs:
    if ns.orderStatus == "pending":
      let status = o.orderStatus(ns.orderId)
      say name & ": order #" & $ns.orderId & " " & status
      if status == "delivered":
        let svcs = o.orderedServices(ns.orderId)
        if svcs.len > 0:
          ns.serviceName = svcs[0]
          ns.orderStatus = "delivered"
      elif status in ["cancelled", "cancelling"]:
        ns.orderStatus = "cancelled"
    if ns.serviceName != "" and ns.ip == "":
      ns.ip = o.publicIpv4(ns.serviceName)
      say name & ": " & ns.serviceName & " " & ns.ip
  for n in sp.nodes.values:                       # adopted hosts
    if n.host != "":
      var s = st.nodes.getOrDefault(n.name)
      s.ip = n.host
      st.nodes[n.name] = s
  st.save()

proc cmdBootstrap(sp: Spec, st: var ClusterState, a: Args) =
  for n in sp.nodes.values:
    if a.has("node") and a.flag("node") != n.name: continue
    var ns = st.nodes.getOrDefault(n.name)
    if ns.bootstrapped and not a.has("again"): continue
    if n.host != "":
      let t = Target(host: n.host, user: a.flag("user", "root"))
      say n.name & ": bootstrapping adopted host " & n.host & " as " & t.user
      let r = adoptBootstrap(sp, t)
      if r.code != 0: (bad r.output; continue)
      ns.ip = n.host
    else:
      if ns.serviceName == "": (warn n.name & ": not delivered yet (run sync)"; continue)
      if ns.appliedHash != "" and not a.has("yes-i-mean-it"):
        bad n.name & ": already deployed; re-bootstrapping WIPES it -- pass --yes-i-mean-it"
        continue
      let o = client()
      say n.name & ": rebuilding " & ns.serviceName & " with " & n.os & " + bootstrap (wipes disk)"
      audit "BOOTSTRAP-REBUILD " & sp.cluster & "/" & n.name & " " & ns.serviceName
      o.waitTask(ns.serviceName, o.rebuild(ns.serviceName, n.os, readFile(sp.sshKeyPath).strip,
                 bootstrapScript(sp), ns.serviceName))
      if ns.ip == "": ns.ip = o.publicIpv4(ns.serviceName)
      forgetHost(ns.ip)
    let t = Target(host: ns.ip, user: "root")
    say n.name & ": waiting for ssh + bootstrap"
    if not waitSsh(t): (bad n.name & ": ssh never came up -- try `vps console` / `vps rescue`"; continue)
    var pub = ""
    for _ in 1..60:
      pub = readWgPub(t)
      if pub != "": break
      sleep 10_000
    if pub == "": (bad n.name & ": bootstrap did not finish (see /var/log on the node)"; continue)
    ns.wgPub = pub
    ns.bootstrapped = true
    st.nodes[n.name] = ns
    st.save()
    say n.name & ": ready, mesh key " & pub

proc lineDiff(a, b: string): seq[string] =
  ## Small LCS diff; bundles are tiny.
  let x = a.splitLines
  let y = b.splitLines
  var L = newSeqWith(x.len + 1, newSeq[int](y.len + 1))
  for i in countdown(x.high, 0):
    for j in countdown(y.high, 0):
      L[i][j] = if x[i] == y[j]: L[i+1][j+1] + 1 else: max(L[i+1][j], L[i][j+1])
  var i, j = 0
  while i < x.len or j < y.len:
    if i < x.len and j < y.len and x[i] == y[j]: (inc i; inc j)
    elif j < y.len and (i == x.len or L[i][j+1] >= L[i+1][j]): (result.add "+ " & y[j]; inc j)
    else: (result.add "- " & x[i]; inc i)

proc renderAll(sp: Spec, st: ClusterState, only: string): OrderedTable[string, Bundle] =
  let secrets = loadSecrets(sp.cluster)
  var warnings: seq[string]
  for n in sp.nodes.keys:
    if only != "" and n != only: continue
    result[n] = renderNode(sp, st, n, secrets, warnings)
  for w in warnings: warn "note: " & w

proc cmdPlan(sp: Spec, st: ClusterState, only: string) =
  for node, b in renderAll(sp, st, only):
    let d = appliedDir(sp.cluster, node)
    if st.nodes.getOrDefault(node).appliedHash == bundleHash(b):
      say node & ": up to date"; continue
    say "== " & node
    for p, content in b:
      if p.startsWith("env/"):
        say "  ~ " & p & " (secret values not shown)"; continue
      let old = if fileExists(d / p): readFile(d / p) else: ""
      if old == content: continue
      say (if old == "": "  + " else: "  ~ ") & p
      for l in lineDiff(old, content): say "      " & l
    if dirExists(d):
      for f in walkDirRec(d, relative = true):
        let rel = f.replace('\\', '/')
        if rel notin b: say "  - " & rel

proc cmdApply(sp: Spec, st: var ClusterState, only: string): bool =
  result = true
  for node, b in renderAll(sp, st, only):
    if not st.nodes.getOrDefault(node).bootstrapped:
      warn node & ": not bootstrapped, skipped"; continue
    if st.nodes[node].appliedHash == bundleHash(b):
      say node & ": up to date"; continue
    say node & ": applying (rollback armed for " & $sp.rollbackSec & "s)"
    audit "APPLY " & sp.cluster & "/" & node & " " & bundleHash(b)
    case applyNode(sp, st, node, b, say)
    of aoConfirmed:
      st.save(); say node & ": confirmed"
    of aoRejected, aoUnconfirmed:
      st.save()
      bad "stopping: later nodes untouched"   # canary: one bad node halts the rollout
      return false

proc cmdStatus(sp: Spec, st: ClusterState) =
  for n in sp.nodes.keys:
    let ns = st.nodes.getOrDefault(n)
    say "== " & n & "  " & ns.serviceName & "  " & ns.ip & "  mesh " & sp.nodes[n].meshIp &
        (if ns.bootstrapped: "" else: "  (not bootstrapped)")
    if not ns.bootstrapped: continue
    let r = ssh(targetFor(sp, st, n),
      "echo \"last apply: $(cat /var/lib/aowl/last-result 2>/dev/null)\"; " &
      "systemctl list-units --all --plain --no-legend 'aowl-*' | awk '{printf \"  %-40s %s/%s\\n\",$1,$3,$4}'; " &
      "wg show wg0 latest-handshakes 2>/dev/null | awk '{print \"  mesh peer\",$1,\"handshake\",($2==0?\"never\":systime()-$2\"s ago\")}'")
    say r.output.strip

proc main() =
  let a = parseArgs()
  if a.pos.len == 0: quit usage, 0
  try:
    case a.pos[0]
    of "auth": cmdAuth(a)
    of "whoami":
      let me = client().get("/me")
      say me{"nichandle"}.getStr & "  " & me{"ovhSubsidiary"}.getStr
    of "catalog":
      for p in client().catalog(a.flag("subsidiary", defaultSubsidiary(loadCreds().endpoint)), a.has("all")):
        say alignLeft(p.code, 44) & align(formatFloat(p.monthlyEUR, ffDecimal, 2), 8) & " " & p.currency & "/mo  " &
            p.datacenters.join(",")
    of "vps": cmdVps(a)
    else:
      let sp = loadSpec(a.need(1, "SPEC"))
      var st = state.load(sp.cluster)
      case a.pos[0]
      of "check":
        var w: seq[string]
        for n in sp.nodes.keys: discard renderNode(sp, st, n, loadSecrets(sp.cluster), w)
        say "ok: " & $sp.nodes.len & " nodes, " & $sp.services.len & " services"
      of "order": cmdOrder(sp, st, a.has("confirm"))
      of "sync": cmdSync(sp, st)
      of "bootstrap": cmdBootstrap(sp, st, a)
      of "plan": cmdPlan(sp, st, a.flag("node"))
      of "apply":
        if not cmdApply(sp, st, a.flag("node")): quit 1
      of "up":
        cmdOrder(sp, st, a.has("confirm"))
        let deadline = epochTime() + 3 * 3600
        while true:
          cmdSync(sp, st)
          if toSeq(st.nodes.values).allIt(it.orderStatus != "pending"): break
          if epochTime() > deadline: quit "orders still pending; rerun `up` later", 1
          sleep 60_000
        cmdBootstrap(sp, st, a)
        if not cmdApply(sp, st, ""): quit 1
        # peers that bootstrapped after their neighbours were applied need the
        # full mesh: a second pass only touches nodes whose bundle changed
        if not cmdApply(sp, st, ""): quit 1
      of "status": cmdStatus(sp, st)
      of "ssh":
        let node = a.need(2, "NODE")
        let t = targetFor(sp, st, node)
        if a.pos.len > 3: (let r = ssh(t, a.pos[3..^1].join(" ")); echo r.output; quit r.code)
        quit execShellCmd("ssh -o UserKnownHostsFile=" & quoteShell(home() / "known_hosts") &
                          " root@" & t.host)
      of "logs":
        let r = ssh(targetFor(sp, st, a.need(2, "NODE")), "journalctl -n 200 --no-pager -u " &
                    quoteShell(a.need(3, "UNIT")))
        echo r.output
      of "rollback":
        let node = a.need(2, "NODE")
        audit "ROLLBACK " & sp.cluster & "/" & node
        echo ssh(targetFor(sp, st, node), "/usr/local/sbin/aowl-rollback").output
        st.nodes[node].appliedHash = ""
        st.save()
      else: quit usage, 2
  except SpecError as e: bad "spec: " & e.msg; quit 1
  except GuardError as e: bad e.msg; quit 1
  except OvhError as e: bad "OVH: " & e.msg; quit 1

when isMainModule: main()
