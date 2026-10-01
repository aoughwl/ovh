## Part A: the OVH VPS lifecycle -- catalog, order, discover, rebuild, rescue,
## reboot, terminate. Everything that costs money or destroys data goes through
## a guard that needs an explicit `confirm`; without it these procs only
## report what they *would* do.

import std/[json, os, strutils, algorithm, sequtils]
import ovh

type
  Plan* = object
    code*: string
    monthlyEUR*: float     ## catalog price, before tax
    datacenters*, oses*: seq[string]

  Quote* = object
    cartId*: string
    itemId*: int64
    withTaxEUR*: float
    planCode*: string
    lines*: seq[string]

  GuardError* = object of CatchableError

proc catalog*(o: Ovh, subsidiary = "FR", all = false): seq[Plan] =
  ## Monthly VPS plans, cheapest first. Promo/commitment variants are hidden
  ## unless `all`, since they lock you into 12/24 months.
  let c = o.call("GET", "/order/catalog/public/vps", nil,
                 [("ovhSubsidiary", subsidiary)], auth = false)
  for p in c["plans"]:
    let code = p["planCode"].getStr
    if not all and ("degressivity" in code or "percent" in code): continue
    var price = -1.0
    for pr in p["pricings"]:
      if pr["interval"].getInt == 1 and "renew" in pr["capacities"].getElems.mapIt(it.getStr):
        price = pr["price"].getBiggestInt.float / 1e8
        break
    if price < 0: continue
    var plan = Plan(code: code, monthlyEUR: price)
    for cf in p{"configurations"}.getElems:
      let vals = cf{"values"}.getElems.mapIt(it.getStr)
      case cf["name"].getStr
      of "vps_datacenter": plan.datacenters = vals
      of "vps_os": plan.oses = vals
      else: discard
    result.add plan
  result.sort(proc (a, b: Plan): int = cmp(a.monthlyEUR, b.monthlyEUR))

# --- ordering ---------------------------------------------------------------

proc quote*(o: Ovh, subsidiary, planCode, datacenter, osName, label: string): Quote =
  ## Builds a real cart and prices it. Spends nothing: a cart that is never
  ## checked out expires on its own.
  let cart = o.post("/order/cart", %*{"ovhSubsidiary": subsidiary, "description": label})
  result.cartId = cart["cartId"].getStr
  result.planCode = planCode
  let cp = "/order/cart/" & result.cartId
  discard o.post(cp & "/assign")
  let item = o.post(cp & "/vps", %*{"planCode": planCode, "duration": "P1M",
                                     "pricingMode": "default", "quantity": 1})
  result.itemId = item["itemId"].getBiggestInt
  let ip = cp & "/item/" & $result.itemId
  for req in o.get(ip & "/requiredConfiguration"):
    let lbl = req["label"].getStr
    let value = case lbl
      of "vps_datacenter": datacenter
      of "vps_os": osName
      else: ""
    if value == "":
      if req{"required"}.getBool: raise newException(GuardError, "cart needs unknown config " & lbl)
      continue
    discard o.post(ip & "/configuration", %*{"label": lbl, "value": value})
  let preview = o.get(cp & "/checkout")
  result.withTaxEUR = preview["prices"]["withTax"]["value"].getFloat
  for d in preview{"details"}.getElems:
    result.lines.add d{"description"}.getStr & "  " & d{"totalPrice"}{"text"}.getStr

proc checkout*(o: Ovh, q: Quote, confirm: bool): JsonNode =
  if not confirm:
    raise newException(GuardError, "checkout refused: pass --confirm to spend " &
                       formatFloat(q.withTaxEUR, ffDecimal, 2) & " EUR")
  o.post("/order/cart/" & q.cartId & "/checkout",
         %*{"autoPayWithPreferredPaymentMethod": true, "waiveRetractationPeriod": false})

proc orderStatus*(o: Ovh, orderId: int64): string =
  o.get("/me/order/" & $orderId & "/status").getStr

proc orderedServices*(o: Ovh, orderId: int64): seq[string] =
  ## The VPS names an order delivered (detail.domain), once delivered.
  for d in o.get("/me/order/" & $orderId & "/details"):
    let det = o.get("/me/order/" & $orderId & "/details/" & $d.getBiggestInt)
    let dom = det{"domain"}.getStr
    if dom.startsWith("vps") and dom notin result: result.add dom

# --- running VPS ------------------------------------------------------------

proc list*(o: Ovh): seq[string] = o.get("/vps").getElems.mapIt(it.getStr)
proc info*(o: Ovh, sn: string): JsonNode = o.get("/vps/" & sn)

proc publicIpv4*(o: Ovh, sn: string): string =
  for ip in o.get("/vps/" & sn & "/ips"):
    if ':' notin ip.getStr: return ip.getStr

proc waitTask*(o: Ovh, sn: string, task: JsonNode, timeoutSec = 1800) =
  if task.kind != JObject or not task.hasKey("id"): return
  let id = task["id"].getBiggestInt
  var waited = 0
  while waited < timeoutSec:
    let t = o.get("/vps/" & sn & "/tasks/" & $id)
    case t["state"].getStr
    of "done": return
    of "error", "cancelled": raise newException(OvhError, "task " & $id & " " & t["state"].getStr)
    else: discard
    sleep 5000
    waited += 5

proc requireName(sn, typed: string, what: string) =
  if typed != sn:
    raise newException(GuardError, what & " refused: repeat the exact VPS name (" & sn &
                       ") with --yes-i-mean")

proc findImage*(o: Ovh, sn, wanted: string): string =
  ## Image ids are per VPS; match by name, case-insensitive, exact first.
  var partial = ""
  for id in o.get("/vps/" & sn & "/images/available"):
    let img = o.get("/vps/" & sn & "/images/available/" & id.getStr)
    let name = img{"name"}.getStr
    if cmpIgnoreCase(name, wanted) == 0: return id.getStr
    if partial == "" and wanted.toLowerAscii in name.toLowerAscii: partial = id.getStr
  if partial == "": raise newException(GuardError, "no image matching '" & wanted & "' on " & sn)
  partial

proc rebuild*(o: Ovh, sn, image, pubKey, postInstall, typedName: string): JsonNode =
  ## Reinstall WIPES THE DISK. Needs the VPS name typed back.
  requireName(sn, typedName, "rebuild")
  o.post("/vps/" & sn & "/rebuild", %*{"imageId": o.findImage(sn, image),
    "publicSshKey": pubKey, "postInstallScript": postInstall, "doNotSendPassword": true})

proc setRescue*(o: Ovh, sn: string, on: bool): JsonNode =
  ## Rescue is the out-of-band path when networking is broken: netboot the
  ## rescue image and reboot. OVH mails the rescue root password.
  discard o.put("/vps/" & sn, %*{"netbootMode": (if on: "rescue" else: "local")})
  o.post("/vps/" & sn & "/reboot")

proc reboot*(o: Ovh, sn: string): JsonNode = o.post("/vps/" & sn & "/reboot")

proc consoleUrl*(o: Ovh, sn: string): string =
  o.post("/vps/" & sn & "/getConsoleUrl").getStr

proc terminate*(o: Ovh, sn, typedName: string): JsonNode =
  ## Starts termination; OVH emails a token that confirmTermination needs.
  requireName(sn, typedName, "terminate")
  o.post("/vps/" & sn & "/terminate")

proc confirmTermination*(o: Ovh, sn, token, typedName: string): JsonNode =
  requireName(sn, typedName, "confirm-terminate")
  o.post("/vps/" & sn & "/confirmTermination", %*{"token": token,
    "reason": "NOT_NEEDED_ANYMORE", "futureUse": "NOT_REPLACING_SERVICE",
    "commentary": "aowlcloud", "commentaryReason": "aowlcloud", "commentaryFutureUse": "aowlcloud"})
