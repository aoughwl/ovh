## Part A against a mock OVH: the exact cart sequence, signing headers, and
## the guards that stand between a command and money/destruction.

import std/[unittest, asynchttpserver, asyncdispatch, json, sequtils, locks]
import std/[os, tables, times, strutils]
import ../src/aowlcloud/[ovh, vps, spec, state, scale]

var gLock: Lock
var gCalls: seq[string]
var gSigned: bool = true
initLock(gLock)

proc serve(port: int) {.thread.} =
  proc cb(req: Request) {.async, gcsafe.} =
    let path = req.url.path
    let key = $req.reqMethod & " " & path
    {.cast(gcsafe).}:
      withLock gLock:
        gCalls.add key
        if path != "/1.0/auth/time" and not req.headers.hasKey("X-Ovh-Signature"): gSigned = false
    var body = "null"
    if path == "/1.0/auth/time": body = "1700000000"
    elif key == "POST /1.0/order/cart": body = $(%*{"cartId": "c1"})
    elif key == "POST /1.0/order/cart/c1/vps": body = $(%*{"itemId": 7})
    elif key == "GET /1.0/order/cart/c1/item/7/requiredConfiguration":
      body = $(%*[{"label": "vps_datacenter", "required": true}, {"label": "vps_os", "required": true}])
    elif key == "GET /1.0/order/cart/c1/checkout":
      body = $(%*{"prices": {"withTax": {"value": 5.39}}, "details": [{"description": "VPS", "totalPrice": {"text": "5.39 EUR"}}]})
    elif key == "GET /1.0/order/cart/c1/vps/options":
      body = $(%*[
        {"family": "storage", "mandatory": true, "planCode": "st-free", "prices": [{"duration": "P1M", "pricingMode": "default", "price": {"value": 0.0}}]},
        {"family": "backup", "mandatory": true, "planCode": "bk-7", "prices": [{"duration": "P1M", "pricingMode": "default", "price": {"value": 1.4}}]},
        {"family": "backup", "mandatory": true, "planCode": "bk-1", "prices": [{"duration": "P1M", "pricingMode": "default", "price": {"value": 0.5}}]},
        {"family": "cpanel", "mandatory": false, "planCode": "cp", "prices": [{"duration": "P1M", "pricingMode": "default", "price": {"value": 22.0}}]}])
    elif key == "POST /1.0/order/cart/c1/vps/options":
      {.cast(gcsafe).}:
        withLock gLock: gCalls.add "option " & parseJson(req.body)["planCode"].getStr
    elif key == "POST /1.0/order/cart/c1/checkout": body = $(%*{"orderId": 42, "url": "https://x/42"})
    elif key == "POST /1.0/vps/vps-1/terminate": body = "\"ok\""
    elif key == "GET /1.0/order/catalog/public/cloud":
      body = $(%*{"addons": [{"planCode": "d2-4.consumption", "pricings": [{"price": 2560000}]}]})
    elif key == "GET /1.0/cloud/project": body = $(%*["proj"])
    await req.respond(Http200, body, newHttpHeaders({"Content-Type": "application/json"}))
  let s = newAsyncHttpServer()
  waitFor s.serve(Port(port), cb)

var th: Thread[int]
createThread(th, serve, 18765)
let o = newOvh(OvhCreds(endpoint: "http://127.0.0.1:18765/1.0", appKey: "k", appSecret: "s", consumerKey: "c"))
for _ in 1..50:
  try: (discard o.call("GET", "/auth/time", auth = false); break)
  except CatchableError: sleepAsync(100).waitFor

proc taken(): seq[string] =
  withLock gLock:
    result = gCalls
    gCalls = @[]

suite "ordering":
  test "quote walks the cart: create, assign, add, configure each required label, preview":
    discard taken()
    let q = o.quote("FR", "vps-2027-model1", "GRA", "Debian 12", "aowlcloud:t:a")
    check q.withTaxEUR == 5.39
    check q.lines.len >= 2   # the chosen mandatory add-ons are shown
    let c = taken().filterIt(it != "GET /1.0/auth/time")
    check c == @["POST /1.0/order/cart", "POST /1.0/order/cart/c1/assign",
                 "POST /1.0/order/cart/c1/vps",
                 "GET /1.0/order/cart/c1/vps/options",
                 "POST /1.0/order/cart/c1/vps/options", "option st-free",
                 "POST /1.0/order/cart/c1/vps/options", "option bk-1",
                 "GET /1.0/order/cart/c1/item/7/requiredConfiguration",
                 "POST /1.0/order/cart/c1/item/7/configuration",
                 "POST /1.0/order/cart/c1/item/7/configuration",
                 "GET /1.0/order/cart/c1/checkout"]
    check "POST /1.0/order/cart/c1/checkout" notin c
  test "checkout without confirm spends nothing":
    let q = o.quote("FR", "p", "GRA", "Debian 12", "l")
    discard taken()
    expect GuardError: discard o.checkout(q, confirm = false)
    check taken().len == 0
  test "checkout with confirm places the order":
    let q = o.quote("FR", "p", "GRA", "Debian 12", "l")
    check o.checkout(q, confirm = true)["orderId"].getInt == 42
  test "every authenticated call was signed":
    check gSigned

suite "destruction guards":
  test "terminate needs the exact name typed back":
    discard taken()
    expect GuardError: discard o.terminate("vps-1", "vps-")
    check taken().len == 0
    discard o.terminate("vps-1", "vps-1")
    check "POST /1.0/vps/vps-1/terminate" in taken()
  test "rebuild needs the exact name typed back":
    expect GuardError: discard o.rebuild("vps-1", "Debian 12", "ssh-ed25519 x", "", "")

suite "elastic groups (mock)":
  putEnv("AOWLCLOUD_HOME", getTempDir() / "aowl-tovh-home")
  let sp = parseSpec(%*{"cluster": "g", "access": {"sshFrom": ["0.0.0.0/0"]},
    "ovh": {"plan": "p", "datacenter": "US-EAST-VA", "os": "Debian 12", "maxHourly": 0.06},
    "nodes": {"ctl": {}},
    "groups": {"builders": {"region": "US-EAST-VA-1", "flavor": "d2-4", "min": 1, "max": 4, "scaleDownAfter": "60s"}},
    "services": {}})
  proc st3(): ClusterState =
    result.name = "g"
    for i in 1..3:
      result.nodes["builders-" & $i] = NodeState(group: "builders", instanceId: "i-" & $i, ip: "x",
        meshIp: "10.77.0." & $(99 + i), hourly: 0.0256, createdAt: 1000 + i)
    result.nodes["ctl"] = NodeState(ip: "y")
  var logs: seq[string]
  proc log(s: string) = logs.add s

  test "price comes from the catalog; over the hourly cap is refused before any create":
    var st = st3()
    discard taken()
    expect ScaleError: discard scaleTo(o, sp, st, "builders", 4, true, log)   # 4*0.0256 > 0.06
    check taken().allIt(not it.startsWith("POST /1.0/cloud"))
  test "dry run changes nothing":
    var st = st3()
    check not scaleTo(o, sp, st, "builders", 1, false, log)
    check members(st, "builders").len == 3
  test "scale down deletes newest first and only recorded ids":
    var st = st3()
    discard taken()
    check scaleTo(o, sp, st, "builders", 1, true, log)
    let c = taken()
    check "DELETE /1.0/cloud/project/proj/instance/i-3" in c
    check "DELETE /1.0/cloud/project/proj/instance/i-2" in c
    check "DELETE /1.0/cloud/project/proj/instance/i-1" notin c
    check members(st, "builders") == @["builders-1"]
  test "min is a floor even if demand is 0":
    var st = st3()
    discard scaleTo(o, sp, st, "builders", 0, true, log)
    check members(st, "builders").len == 1
  test "autoscale waits scaleDownAfter before shrinking":
    var st = st3()
    discard taken()
    check not autoscaleTick(o, sp, st, "builders", 2, log)       # first sight of surplus: mark only
    check st.nodes["builders-3"].surplusSince > 0
    check st.nodes["builders-2"].surplusSince == 0
    check taken().allIt(not it.startsWith("DELETE"))
    st.nodes["builders-3"].surplusSince = getTime().toUnix - 61   # pretend a minute passed
    check autoscaleTick(o, sp, st, "builders", 2, log)
    check "DELETE /1.0/cloud/project/proj/instance/i-3" in taken()
    check members(st, "builders").len == 2
  test "demand back up clears the surplus mark":
    var st = st3()
    discard autoscaleTick(o, sp, st, "builders", 2, log)
    check st.nodes["builders-3"].surplusSince > 0
    discard autoscaleTick(o, sp, st, "builders", 3, log)
    check st.nodes["builders-3"].surplusSince == 0
