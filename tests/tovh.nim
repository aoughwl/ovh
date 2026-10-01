## Part A against a mock OVH: the exact cart sequence, signing headers, and
## the guards that stand between a command and money/destruction.

import std/[unittest, asynchttpserver, asyncdispatch, json, sequtils, locks]
import ../src/aowlcloud/[ovh, vps]

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
    elif key == "POST /1.0/order/cart/c1/checkout": body = $(%*{"orderId": 42, "url": "https://x/42"})
    elif key == "POST /1.0/vps/vps-1/terminate": body = "\"ok\""
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
    let c = taken().filterIt(it != "GET /1.0/auth/time")
    check c == @["POST /1.0/order/cart", "POST /1.0/order/cart/c1/assign",
                 "POST /1.0/order/cart/c1/vps",
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
