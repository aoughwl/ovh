## The cluster spec: one JSON file that says exactly what the cloud is --
## machines, private mesh, firewall, services, ingress, and per-session pools.
## Parsing is strict: unknown keys and bad values are errors, because a typo
## in a firewall spec should never silently become "allow".

import std/[json, os, strutils, tables, sets, net, sequtils]

type
  SpecError* = object of CatchableError

  PublicPort* = object
    port*: int
    proto*: string          ## tcp | udp
    hostPort*: int          ## defaults to port
    `from`*: seq[string]    ## source CIDRs; empty = anyone

  Pool* = object
    size*: int
    isolate*: bool          ## own network per session, no session<->session traffic
    internet*: bool         ## sessions may reach the internet
    maxLifetimeSec*: int    ## recycle a session after this long (0 = never)
    egressIps*: seq[string] ## round-robin source IPs for session egress (extra IPs on the node)

  Service* = object
    name*: string
    image*, build*: string  ## exactly one; build is a local dir with a Dockerfile
    placeOn*: seq[string]   ## node names or "label:x"
    port*: int              ## container port reachable by ingress/mesh (0 = none)
    routes*: seq[string]    ## hostnames served through ingress (TLS by Caddy)
    public*: seq[PublicPort]
    env*: OrderedTable[string, string]
    secretEnv*: OrderedTable[string, string] ## VAR -> secret name
    volumes*: seq[string]
    cmd*: seq[string]
    cpus*: float
    memory*, shmSize*: string
    dockerArgs*: seq[string] ## raw extra `docker run` flags: the escape hatch
    pool*: Pool             ## size 0 = a plain single-instance service

  Node* = object
    name*: string
    plan*, datacenter*, os*: string
    host*: string           ## set = adopt an existing machine instead of ordering
    labels*: seq[string]
    meshIp*: string
    extraIps*: seq[string]

  Spec* = object
    cluster*: string
    dir*: string            ## directory of the spec file; build paths resolve here
    subsidiary*: string
    maxMonthlyEUR*: float
    sshKeyPath*: string
    sshFrom*: seq[string]
    meshCidr*: string
    meshPort*: int
    nodes*: OrderedTable[string, Node]
    services*: OrderedTable[string, Service]
    ingressNodes*: seq[string]
    ingressEmail*: string
    rawRules*: seq[string]  ## verbatim nft rules appended to the input chain
    rollbackSec*: int

proc fail(msg: string) = raise newException(SpecError, msg)

proc checkKeys(j: JsonNode, where: string, allowed: openArray[string]) =
  if j.kind != JObject: fail(where & ": expected an object")
  for k in j.keys:
    if k notin allowed: fail(where & ": unknown key '" & k & "' (allowed: " & allowed.join(", ") & ")")

proc strs(j: JsonNode, where: string): seq[string] =
  if j.isNil: return
  if j.kind == JString: return @[j.getStr]
  if j.kind != JArray: fail(where & ": expected a list of strings")
  for x in j:
    if x.kind != JString: fail(where & ": expected strings")
    result.add x.getStr

proc validName(s: string): bool =
  s.len in 1..40 and s[0] in Letters and s.allIt(it in Letters + Digits + {'-'})

proc validCidr*(s: string): bool =
  let parts = s.split('/')
  if parts.len > 2 or not isIpAddress(parts[0]): return false
  if parts.len == 2:
    try:
      let n = parseInt(parts[1])
      return n in 0..(if ':' in parts[0]: 128 else: 32)
    except ValueError: return false
  true

proc parseDuration(s, where: string): int =
  if s == "": return 0
  let unit = s[^1]
  let n = try: parseInt(s[0 ..< ^1]) except ValueError: (fail(where & ": bad duration " & s); 0)
  case unit
  of 's': n
  of 'm': n * 60
  of 'h': n * 3600
  else: (fail(where & ": duration needs s/m/h suffix: " & s); 0)

proc meshAddr*(cidr: string, idx: int): string =
  ## idx-th host address inside an IPv4 /24-or-larger mesh (1-based).
  let base = cidr.split('/')[0].split('.').mapIt(parseInt(it))
  let v = (base[0] shl 24) + (base[1] shl 16) + (base[2] shl 8) + base[3] + idx
  [v shr 24 and 255, v shr 16 and 255, v shr 8 and 255, v and 255].mapIt($it).join(".")

proc parseSpec*(j: JsonNode, dir = "."): Spec =
  j.checkKeys("spec", ["cluster", "ovh", "access", "mesh", "nodes", "services",
                       "ingress", "firewall", "rollbackSeconds", "$comment"])
  result.dir = dir
  result.cluster = j{"cluster"}.getStr
  if not validName(result.cluster): fail("cluster: needs a name like 'main'")
  result.rollbackSec = j{"rollbackSeconds"}.getInt(90)
  if result.rollbackSec < 30: fail("rollbackSeconds: at least 30, or a slow reconnect rolls back good config")

  let ovhJ = j{"ovh"}
  var defPlan, defDc, defOs: string
  result.subsidiary = ""   # empty = follow the account's endpoint (US for ovh-us)
  if not ovhJ.isNil:
    ovhJ.checkKeys("ovh", ["subsidiary", "maxMonthly", "maxMonthlyEUR", "plan", "datacenter", "os"])
    result.subsidiary = ovhJ{"subsidiary"}.getStr
    result.maxMonthlyEUR = ovhJ{"maxMonthly"}.getFloat(ovhJ{"maxMonthlyEUR"}.getFloat(0))  # in the account currency
    defPlan = ovhJ{"plan"}.getStr
    defDc = ovhJ{"datacenter"}.getStr
    defOs = ovhJ{"os"}.getStr

  let acc = j{"access"}
  if acc.isNil: fail("access: required -- it decides who can SSH in, and a missing rule locks you out")
  acc.checkKeys("access", ["sshKey", "sshFrom"])
  result.sshKeyPath = acc{"sshKey"}.getStr("~/.ssh/id_ed25519.pub").expandTilde
  result.sshFrom = acc{"sshFrom"}.strs("access.sshFrom")
  if result.sshFrom.len == 0:
    fail("access.sshFrom: list the CIDRs allowed to SSH (use [\"0.0.0.0/0\"] deliberately for anywhere)")
  for c in result.sshFrom:
    if not validCidr(c): fail("access.sshFrom: bad CIDR " & c)

  let mesh = j{"mesh"}
  result.meshCidr = "10.77.0.0/24"
  result.meshPort = 51820
  if not mesh.isNil:
    mesh.checkKeys("mesh", ["cidr", "port"])
    result.meshCidr = mesh{"cidr"}.getStr(result.meshCidr)
    result.meshPort = mesh{"port"}.getInt(51820)
  if not validCidr(result.meshCidr) or ':' in result.meshCidr:
    fail("mesh.cidr: must be an IPv4 CIDR")

  let nodesJ = j{"nodes"}
  if nodesJ.isNil or nodesJ.len == 0: fail("nodes: at least one node")
  var idx = 0
  var seenMesh = initHashSet[string]()
  for name, n in nodesJ:
    inc idx
    if not validName(name): fail("nodes." & name & ": bad name")
    n.checkKeys("nodes." & name, ["plan", "datacenter", "os", "host", "labels", "meshIp", "extraIps"])
    var node = Node(name: name, plan: n{"plan"}.getStr(defPlan), datacenter: n{"datacenter"}.getStr(defDc),
                    os: n{"os"}.getStr(defOs), host: n{"host"}.getStr,
                    labels: n{"labels"}.strs("nodes." & name & ".labels"),
                    meshIp: n{"meshIp"}.getStr(meshAddr(result.meshCidr, idx)),
                    extraIps: n{"extraIps"}.strs("nodes." & name & ".extraIps"))
    if node.host == "" and (node.plan == "" or node.datacenter == "" or node.os == ""):
      fail("nodes." & name & ": needs plan/datacenter/os (or ovh defaults), or a host to adopt")
    if node.meshIp in seenMesh: fail("nodes." & name & ": duplicate meshIp " & node.meshIp)
    seenMesh.incl node.meshIp
    for ip in node.extraIps:
      if not isIpAddress(ip): fail("nodes." & name & ".extraIps: bad IP " & ip)
    result.nodes[name] = node

  let ing = j{"ingress"}
  if not ing.isNil:
    ing.checkKeys("ingress", ["nodes", "email"])
    result.ingressNodes = ing{"nodes"}.strs("ingress.nodes")
    result.ingressEmail = ing{"email"}.getStr
    for n in result.ingressNodes:
      if n notin result.nodes: fail("ingress.nodes: unknown node " & n)

  let fw = j{"firewall"}
  if not fw.isNil:
    fw.checkKeys("firewall", ["rules"])
    result.rawRules = fw{"rules"}.strs("firewall.rules")
    for r in result.rawRules:
      if ';' in r or '\n' in r or '}' in r: fail("firewall.rules: one rule per entry, no ';' '}' or newlines: " & r)

  for name, s in j{"services"}.getFields:
    let w = "services." & name
    if not validName(name): fail(w & ": bad name")
    s.checkKeys(w, ["image", "build", "on", "port", "routes", "public", "env", "secrets", "volumes",
                    "cmd", "cpus", "memory", "shmSize", "dockerArgs", "pool"])
    var svc = Service(name: name, image: s{"image"}.getStr, build: s{"build"}.getStr,
      placeOn: s{"on"}.strs(w & ".on"), port: s{"port"}.getInt, routes: s{"routes"}.strs(w & ".routes"),
      volumes: s{"volumes"}.strs(w & ".volumes"), cmd: s{"cmd"}.strs(w & ".cmd"),
      cpus: s{"cpus"}.getFloat, memory: s{"memory"}.getStr, shmSize: s{"shmSize"}.getStr,
      dockerArgs: s{"dockerArgs"}.strs(w & ".dockerArgs"))
    if (svc.image == "") == (svc.build == ""): fail(w & ": set exactly one of image / build")
    if svc.build != "" and not dirExists(dir / svc.build): fail(w & ".build: no directory " & (dir / svc.build))
    if svc.placeOn.len == 0: fail(w & ".on: which nodes? (names or \"label:x\")")
    for p in svc.placeOn:
      if not p.startsWith("label:") and p notin result.nodes: fail(w & ".on: unknown node " & p)
    if svc.routes.len > 0:
      if svc.port == 0: fail(w & ": routes need a container port")
      if result.ingressNodes.len == 0: fail(w & ": routes need ingress.nodes")
    for k, v in s{"env"}.getFields: svc.env[k] = (if v.kind == JString: v.getStr else: $v)
    for k, v in s{"secrets"}.getFields: svc.secretEnv[k] = v.getStr
    for p in s{"public"}.getElems:
      p.checkKeys(w & ".public", ["port", "proto", "hostPort", "from"])
      var pp = PublicPort(port: p{"port"}.getInt, proto: p{"proto"}.getStr("tcp"),
                          hostPort: p{"hostPort"}.getInt, `from`: p{"from"}.strs(w & ".public.from"))
      if pp.hostPort == 0: pp.hostPort = pp.port
      if pp.proto notin ["tcp", "udp"] or pp.port notin 1..65535: fail(w & ".public: bad port/proto")
      for c in pp.`from`:
        if not validCidr(c): fail(w & ".public.from: bad CIDR " & c)
      svc.public.add pp
    let pj = s{"pool"}
    if not pj.isNil:
      pj.checkKeys(w & ".pool", ["size", "isolate", "internet", "maxLifetime", "egressIps"])
      svc.pool = Pool(size: pj{"size"}.getInt, isolate: pj{"isolate"}.getBool(true),
        internet: pj{"internet"}.getBool(true),
        maxLifetimeSec: parseDuration(pj{"maxLifetime"}.getStr, w & ".pool.maxLifetime"),
        egressIps: pj{"egressIps"}.strs(w & ".pool.egressIps"))
      if svc.pool.size notin 1..250: fail(w & ".pool.size: 1..250 per node")
      if svc.public.len > 0: fail(w & ": a pool cannot publish fixed public ports (sessions would collide)")
    result.services[name] = svc

  # Pools get 10.<100+k>.<i>.0/24 per session; keep k inside a private range.
  if toSeq(result.services.values).countIt(it.pool.size > 0) > 100: fail("services: at most 100 pools")
  for s in result.services.values:
    for ip in s.pool.egressIps:
      var owned = false
      for n in result.nodes.values:
        if ip in n.extraIps: owned = true
      if not owned: fail("services." & s.name & ".pool.egressIps: " & ip & " is not in any node's extraIps")

proc loadSpec*(path: string): Spec =
  parseSpec(parseFile(path), path.absolutePath.parentDir)

proc nodesFor*(sp: Spec, svc: Service): seq[string] =
  for n in sp.nodes.values:
    for p in svc.placeOn:
      if p == n.name or (p.startsWith("label:") and p[6..^1] in n.labels):
        if n.name notin result: result.add n.name
