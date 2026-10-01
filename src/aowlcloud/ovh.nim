## Signed OVH API client.
##
## OVH authenticates every call with four headers. The signature is
##   "$1$" & sha1hex(appSecret+consumerKey+METHOD+fullUrl+body+timestamp)
## (fields joined by "+"), where timestamp is *OVH's* clock, not ours -- so
## the client measures the offset against /auth/time once and applies it.

{.warning[Deprecated]: off.}
import std/[httpclient, json, os, strutils, times, sha1, uri]

type
  OvhCreds* = object
    endpoint*: string      ## "ovh-eu" | "ovh-ca" | "ovh-us" | a full base URL
    appKey*, appSecret*, consumerKey*: string

  Ovh* = ref object
    creds*: OvhCreds
    base*: string
    timeDelta: int64
    haveDelta: bool
    http: HttpClient

  OvhError* = object of CatchableError
    status*: int
    body*: string

const endpoints* = {
  "ovh-eu": "https://eu.api.ovh.com/1.0",
  "ovh-ca": "https://ca.api.ovh.com/1.0",
  "ovh-us": "https://api.us.ovhcloud.com/1.0"}

proc baseUrl*(endpoint: string): string =
  for (k, v) in endpoints:
    if k == endpoint: return v
  if endpoint.startsWith("http"): return endpoint.strip(chars = {'/'}, leading = false)
  raise newException(ValueError, "unknown OVH endpoint: " & endpoint)

proc defaultSubsidiary*(endpoint: string): string =
  case endpoint
  of "ovh-us": "US"
  of "ovh-ca": "CA"
  else: "FR"

proc credsPath*(): string = getHomeDir() / ".aowlcloud" / "ovh.json"

proc loadCreds*(): OvhCreds =
  ## Env vars win over ~/.aowlcloud/ovh.json. Credentials never live in a repo.
  if fileExists(credsPath()):
    let j = parseFile(credsPath())
    result.endpoint = j{"endpoint"}.getStr("ovh-eu")
    result.appKey = j{"appKey"}.getStr
    result.appSecret = j{"appSecret"}.getStr
    result.consumerKey = j{"consumerKey"}.getStr
  if result.endpoint == "": result.endpoint = "ovh-eu"
  for (env, field) in [("OVH_ENDPOINT", addr result.endpoint),
                       ("OVH_APPLICATION_KEY", addr result.appKey),
                       ("OVH_APPLICATION_SECRET", addr result.appSecret),
                       ("OVH_CONSUMER_KEY", addr result.consumerKey)]:
    if existsEnv(env): field[] = getEnv(env)

proc saveCreds*(c: OvhCreds) =
  createDir(credsPath().parentDir)
  writeFile(credsPath(), $(%*{"endpoint": c.endpoint, "appKey": c.appKey,
    "appSecret": c.appSecret, "consumerKey": c.consumerKey}))

proc newOvh*(c: OvhCreds): Ovh =
  Ovh(creds: c, base: baseUrl(c.endpoint), http: newHttpClient(timeout = 60_000))

proc sign*(appSecret, consumerKey, meth, url, body: string, ts: int64): string =
  "$1$" & toLowerAscii($secureHash([appSecret, consumerKey, meth, url, body, $ts].join("+")))

proc encodePath(path: string, query: openArray[(string, string)]): string =
  result = path
  if query.len > 0:
    result.add "?" & encodeQuery(query)

proc now(o: Ovh): int64 =
  if not o.haveDelta:
    let server = parseBiggestInt(o.http.getContent(o.base & "/auth/time").strip)
    o.timeDelta = server - getTime().toUnix
    o.haveDelta = true
  getTime().toUnix + o.timeDelta

proc call*(o: Ovh, meth, path: string, body: JsonNode = nil,
           query: openArray[(string, string)] = [], auth = true): JsonNode =
  let url = o.base & encodePath(path, query)
  let payload = if body.isNil: "" else: $body
  var h = newHttpHeaders({"Content-Type": "application/json",
                          "X-Ovh-Application": o.creds.appKey})
  if auth:
    if o.creds.appSecret == "" or o.creds.consumerKey == "":
      raise newException(OvhError, "no OVH credentials: run `aowlcloud auth` first")
    let ts = o.now()
    h["X-Ovh-Timestamp"] = $ts
    h["X-Ovh-Consumer"] = o.creds.consumerKey
    h["X-Ovh-Signature"] = sign(o.creds.appSecret, o.creds.consumerKey, meth, url, payload, ts)
  let resp = o.http.request(url, httpMethod = parseEnum[HttpMethod](meth),
                            body = payload, headers = h)
  let code = resp.code.int
  let text = resp.body
  if code div 100 != 2:
    var e = newException(OvhError, meth & " " & path & " -> " & $code & ": " & text)
    e.status = code
    e.body = text
    raise e
  if text.strip == "": newJNull() else: parseJson(text)

proc get*(o: Ovh, path: string, query: openArray[(string, string)] = []): JsonNode = o.call("GET", path, nil, query)
proc post*(o: Ovh, path: string, body: JsonNode = newJObject()): JsonNode = o.call("POST", path, body)
proc put*(o: Ovh, path: string, body: JsonNode): JsonNode = o.call("PUT", path, body)
proc delete*(o: Ovh, path: string): JsonNode = o.call("DELETE", path)

# --- credential request -------------------------------------------------------

const defaultRules* = [
  ## Scoped: read everything; write only what the lifecycle needs.
  ("GET", "/*"),
  ("POST", "/order/cart"), ("POST", "/order/cart/*"), ("DELETE", "/order/cart/*"),
  ("POST", "/vps/*"), ("PUT", "/vps/*"), ("DELETE", "/vps/*"),
  ("POST", "/me/order/*"),
  ("POST", "/cloud/project/*"), ("PUT", "/cloud/project/*"), ("DELETE", "/cloud/project/*")]

proc requestCredential*(o: Ovh, redirect = ""): (string, string) =
  ## Returns (consumerKey, validationUrl). The user opens the URL once to approve.
  var rules = newJArray()
  for (m, p) in defaultRules: rules.add %*{"method": m, "path": p}
  let body = %*{"accessRules": rules}
  if redirect != "": body["redirection"] = %redirect
  let r = o.call("POST", "/auth/credential", body, auth = false)
  (r["consumerKey"].getStr, r["validationUrl"].getStr)
