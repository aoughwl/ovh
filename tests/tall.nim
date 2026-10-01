## Offline tests: signing, spec validation, rendering, tar format.
## Also writes rendered bundles to tests/out/ for tests/node_harness.sh,
## which validates them against a real kernel/nft/systemd in WSL.

import std/[unittest, json, os, strutils, tables, sequtils, osproc]
import ../src/aowlcloud/[ovh, spec, state, render, tarball]

const ex = currentSourcePath().parentDir.parentDir / "examples"
let outDir = currentSourcePath().parentDir / "out"

putEnv("AOWLCLOUD_HOME", currentSourcePath().parentDir / "home")
createDir(home() / "secrets")
writeFile(home() / "secrets" / "farm.json", $(%*{"farm_api_token": "s3cret-token"}))

proc base(): JsonNode =
  %*{"cluster": "t", "access": {"sshFrom": ["1.2.3.4/32"]},
     "ovh": {"plan": "p", "datacenter": "GRA", "os": "Debian 12"},
     "nodes": {"a": {}}, "services": {}}

proc expectSpecError(j: JsonNode, frag: string) =
  try:
    discard parseSpec(j, ex)
    checkpoint "no error, expected: " & frag
    fail()
  except SpecError as e:
    if frag notin e.msg:
      checkpoint "got: " & e.msg
      fail()

proc farmState(): ClusterState =
  result.name = "farm"
  result.nodes["web1"] = NodeState(ip: "198.51.100.1", wgPub: "PUBweb1=", bootstrapped: true)
  result.nodes["farm1"] = NodeState(ip: "198.51.100.2", wgPub: "PUBfarm1=", bootstrapped: true)

suite "ovh":
  test "signature matches the reference (python hashlib)":
    check sign("AS", "CK", "GET", "https://eu.api.ovh.com/1.0/me", "", 1700000000) ==
      "$1$2bb81c13bcb1eea93ff50b12bd571dc7699f3913"
  test "endpoints":
    check baseUrl("ovh-ca") == "https://ca.api.ovh.com/1.0"
    expect ValueError: discard baseUrl("nope")

suite "spec validation":
  test "examples parse":
    check loadSpec(ex / "website.json").nodes.len == 1
    check loadSpec(ex / "browserfarm.json").services["browser"].pool.size == 8
  test "ssh access must be explicit":
    var j = base(); j["access"] = %*{}
    expectSpecError(j, "sshFrom")
  test "unknown keys are errors, not ignored":
    var j = base(); j["firewal"] = %*{}
    expectSpecError(j, "unknown key 'firewal'")
  test "bad cidr":
    var j = base(); j["access"]["sshFrom"] = %*["1.2.3.4/33"]
    expectSpecError(j, "bad CIDR")
  test "image xor build":
    var j = base(); j["services"] = %*{"s": {"on": ["a"]}}
    expectSpecError(j, "exactly one of image / build")
  test "routes need ingress":
    var j = base(); j["services"] = %*{"s": {"image": "x", "on": ["a"], "port": 80, "routes": ["x.com"]}}
    expectSpecError(j, "ingress")
  test "egress ip must belong to a node":
    var j = base(); j["services"] = %*{"s": {"image": "x", "on": ["a"], "pool": {"size": 2, "egressIps": ["9.9.9.9"]}}}
    expectSpecError(j, "not in any node's extraIps")
  test "raw firewall rules cannot smuggle extra statements":
    var j = base(); j["firewall"] = %*{"rules": ["accept; flush ruleset"]}
    expectSpecError(j, "one rule per entry")
  test "pools cannot publish fixed public ports":
    var j = base(); j["services"] = %*{"s": {"image": "x", "on": ["a"], "public": [{"port": 25}], "pool": {"size": 2}}}
    expectSpecError(j, "pool cannot publish")
  test "mesh addresses":
    check meshAddr("10.77.0.0/24", 1) == "10.77.0.1"
    check meshAddr("10.77.0.0/16", 300) == "10.77.1.44"

suite "render":
  let sp = loadSpec(ex / "browserfarm.json")
  let st = farmState()
  var w: seq[string]
  let web = renderNode(sp, st, "web1", loadSecrets("farm"), w)
  let farm = renderNode(sp, st, "farm1", loadSecrets("farm"), w)

  test "firewall: ssh only from declared sources, mesh only from peers":
    let n = farm["nftables.nft"]
    check "tcp dport 22 ip saddr { 0.0.0.0/0 } accept" in n
    check "udp dport 51820 ip saddr { 198.51.100.1 } accept" in n
    check "policy drop" in n
    check "tcp dport { 80, 443 }" notin n          # farm1 is not ingress
    check "tcp dport { 80, 443 }" in web["nftables.nft"]
    check "tcp dport 9100 ip saddr 10.77.0.0/24 accept" in n
  test "firewall: sessions are internet-only and docker DNAT is fenced":
    let n = farm["nftables.nft"]
    check "iifname \"aw*\" drop" in n
    check "iifname \"aw*\" ip daddr { 10.0.0.0/8" in n
    check "ct status dnat ct original ip daddr != { 127.0.0.0/8, 10.77.0.2 } drop" in n
  test "egress: sessions alternate across the node's extra IPs":
    let n = farm["nftables.nft"]
    check "ip saddr 10.100.1.0/24 oifname != \"aw*\" snat to 203.0.113.10" in n
    check "ip saddr 10.100.2.0/24 oifname != \"aw*\" snat to 203.0.113.11" in n
    check "ip saddr 10.100.8.0/24" in n
    check "snat" notin web["nftables.nft"].split("table ip aowlnat")[1].replace("srcnat", "")
  test "mesh: peers with endpoints, no private key in config":
    check "PublicKey = PUBweb1=" in farm["wg0.conf"]
    check "Endpoint = 198.51.100.1:51820" in farm["wg0.conf"]
    check "Address = 10.77.0.2/24" in farm["wg0.conf"]
    check "PrivateKey" notin farm["wg0.conf"]
  test "pool: template unit, 8 sessions, recycled":
    let m = parseJson(farm["manifest.json"])
    check m["units"].len == 8
    check m["units"][0].getStr == "aowl-browser@1.service"
    let u = farm["units/aowl-browser@.service"]
    check "RuntimeMaxSec=1800" in u
    check "aowl %i" in u
    check m["builds"][0]["tag"].getStr.startsWith("aowl/browser:")
  test "ingress: caddy load-balances every session over the mesh":
    let c = web["Caddyfile"]
    check "farm.example.com {" in c
    check "10.77.0.1:20000" in c                      # control on web1
    check not ("10.77.0.2:30001" in c)                # browser has no routes
    check "aowl-ingress.service" in parseJson(web["manifest.json"])["units"].getElems.mapIt(it.getStr)
  test "secrets land only in env files":
    check "API_TOKEN=s3cret-token" in web["env/control.env"]
    for k, v in web:
      if not k.startsWith("env/"): check "s3cret" notin v
  test "missing secret is an error":
    expect SpecError: discard renderNode(sp, st, "web1", newJObject(), w)
  test "unbootstrapped peer is left out with a note":
    var st2 = farmState()
    st2.nodes["web1"].wgPub = ""
    var w2: seq[string]
    let b = renderNode(sp, st2, "farm1", loadSecrets("farm"), w2)
    check "[Peer]" notin b["wg0.conf"]
    check w2.len == 1
  test "render is deterministic":
    var w3: seq[string]
    check bundleHash(renderNode(sp, st, "farm1", loadSecrets("farm"), w3)) == bundleHash(farm)

  test "write bundles for the node harness":
    removeDir(outDir)
    for (name, b) in [("web1", web), ("farm1", farm)]:
      for k, v in b:
        createDir((outDir / name / k).parentDir)
        writeFile(outDir / name / k, v)
    var w4: seq[string]
    let site = loadSpec(ex / "website.json")
    var stw = ClusterState(name: "web")
    stw.nodes["web1"] = NodeState(ip: "198.51.100.9", bootstrapped: true)
    for k, v in renderNode(site, stw, "web1", newJObject(), w4):
      createDir((outDir / "site-web1" / k).parentDir)
      writeFile(outDir / "site-web1" / k, v)

suite "tar":
  test "ustar written by us is read by GNU tar":
    let t = tar(@[("node/apply.sh", "#!/bin/sh\necho hi\n", 0o755), ("bundle/env/x.env", "A=1\n", 0o600)])
    check t.len mod 512 == 0
    writeFile(outDir / "t.tar", t)
    let (o, code) = execCmdEx("wsl -e tar -tvf " & quoteShell((outDir / "t.tar").replace('\\', '/').replace("C:", "/mnt/c")))
    check code == 0
    check "-rwxr-xr-x" in o and "node/apply.sh" in o
    check "-rw-------" in o
