## OVH Public Cloud: hourly instances for burst capacity. Unlike VPS there
## is no cart per machine -- one call creates an instance, one deletes it --
## so this is what groups/autoscaling use.

import std/[json, strutils, tables]
import ovh

type
  Instance* = object
    id*, name*, status*, region*, flavorId*, ip*: string

  CloudError* = object of CatchableError

proc projects*(o: Ovh): seq[string] =
  for p in o.get("/cloud/project"): result.add p.getStr

proc resolveProject*(o: Ovh, configured: string): string =
  if configured != "": return configured
  let ps = o.projects()
  if ps.len == 1: return ps[0]
  if ps.len == 0:
    raise newException(CloudError, "no Public Cloud project: `aowlcloud cloud create-project --confirm`")
  raise newException(CloudError, "several Public Cloud projects; set ovh.cloudProject to one of " & ps.join(", "))

proc createProject*(o: Ovh, subsidiary, description: string, confirm: bool): JsonNode =
  ## A project is free; creating one enables pay-as-you-go billing on the account.
  let cart = o.post("/order/cart", %*{"ovhSubsidiary": subsidiary, "description": description})
  let cp = "/order/cart/" & cart["cartId"].getStr
  discard o.post(cp & "/assign")
  let item = o.post(cp & "/cloud", %*{"planCode": "project", "duration": "P1M",
                                      "pricingMode": "default", "quantity": 1})
  discard o.post(cp & "/item/" & $item["itemId"].getBiggestInt & "/configuration",
                 %*{"label": "description", "value": description})
  let preview = o.get(cp & "/checkout")
  if not confirm:
    return %*{"dryRun": true, "price": preview["prices"]["withTax"]["value"]}
  o.post(cp & "/checkout", %*{"autoPayWithPreferredPaymentMethod": true, "waiveRetractationPeriod": false})

proc parseInstance(j: JsonNode): Instance =
  result = Instance(id: j{"id"}.getStr, name: j{"name"}.getStr, status: j{"status"}.getStr,
                    region: j{"region"}.getStr, flavorId: j{"flavorId"}.getStr)
  for a in j{"ipAddresses"}.getElems:
    if a{"type"}.getStr == "public" and a{"version"}.getInt == 4: result.ip = a{"ip"}.getStr

proc instances*(o: Ovh, project: string): seq[Instance] =
  for j in o.get("/cloud/project/" & project & "/instance"): result.add parseInstance(j)

proc instance*(o: Ovh, project, id: string): Instance =
  parseInstance(o.get("/cloud/project/" & project & "/instance/" & id))

proc regions*(o: Ovh, project: string): seq[string] =
  for r in o.get("/cloud/project/" & project & "/region"): result.add r.getStr

proc flavorId*(o: Ovh, project, region, name: string): string =
  for f in o.get("/cloud/project/" & project & "/flavor", [("region", region)]):
    if f{"name"}.getStr == name and f{"osType"}.getStr == "linux" and f{"available"}.getBool(true):
      return f["id"].getStr
  raise newException(CloudError, "flavor " & name & " not available in " & region)

proc imageId*(o: Ovh, project, region, name: string): string =
  for i in o.get("/cloud/project/" & project & "/image", [("region", region), ("osType", "linux")]):
    if cmpIgnoreCase(i{"name"}.getStr, name) == 0: return i["id"].getStr
  raise newException(CloudError, "image '" & name & "' not found in " & region)

proc ensureSshKey*(o: Ovh, project, region, name, pubKey: string): string =
  for k in o.get("/cloud/project/" & project & "/sshkey", [("region", region)]):
    if k{"name"}.getStr == name: return k["id"].getStr
  o.post("/cloud/project/" & project & "/sshkey",
         %*{"name": name, "publicKey": pubKey, "region": region})["id"].getStr

proc createInstance*(o: Ovh, project, region, name, flavorId, imageId, sshKeyId, userData: string): Instance =
  parseInstance(o.post("/cloud/project/" & project & "/instance", %*{
    "name": name, "region": region, "flavorId": flavorId, "imageId": imageId,
    "sshKeyId": sshKeyId, "userData": userData, "monthlyBilling": false}))

proc deleteInstance*(o: Ovh, project, id: string) =
  discard o.delete("/cloud/project/" & project & "/instance/" & id)

# --- prices: flavor name -> hourly price, from the public catalog ------------

proc hourlyPrices*(o: Ovh, subsidiary: string): Table[string, float] =
  let c = o.call("GET", "/order/catalog/public/cloud", nil, [("ovhSubsidiary", subsidiary)], auth = false)
  for a in c{"addons"}.getElems:
    let pc = a{"planCode"}.getStr
    if pc.endsWith(".consumption"):
      for p in a{"pricings"}.getElems:
        result[pc[0 ..< pc.len - ".consumption".len]] = p{"price"}.getBiggestInt.float / 1e8
        break
