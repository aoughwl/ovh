## Part B transport: SSH to nodes, bootstrap, and the confirmed apply.
## Uses the system `ssh`; no agent daemon, no long-lived secret on the node.

import std/[osproc, os, streams, strutils, times, json, tables]
import spec, state, render, tarball

const
  nodeBootstrap* = staticRead("node/bootstrap.sh")
  nodeFiles = [("node/apply.sh", staticRead("node/apply.sh")),
               ("node/activate.sh", staticRead("node/activate.sh")),
               ("node/rollback.sh", staticRead("node/rollback.sh")),
               ("node/confirm.sh", staticRead("node/confirm.sh")),
               ("node/aowl-net", staticRead("node/aowl-net"))]

type
  SshResult* = object
    code*: int
    output*: string

  Target* = object
    host*, user*: string

proc knownHosts(): string = home() / "known_hosts"

proc sshArgs(t: Target, connectTimeout = 10): seq[string] =
  @["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
    "-o", "UserKnownHostsFile=" & knownHosts(), "-o", "ConnectTimeout=" & $connectTimeout,
    "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
    t.user & "@" & t.host]

proc ssh*(t: Target, cmd: string, input = "", connectTimeout = 10): SshResult =
  ## Exit 255 means ssh itself failed (unreachable / refused), not the command.
  createDir(home())
  let exe = findExe("ssh")
  if exe == "": raise newException(OSError, "ssh not found on PATH")
  let p = startProcess(exe, args = sshArgs(t, connectTimeout) & @[cmd],
                       options = {poStdErrToStdOut, poUsePath})
  if input.len > 0: p.inputStream.write(input)
  p.inputStream.close()
  result.output = p.outputStream.readAll()
  result.code = p.waitForExit()
  p.close()

proc forgetHost*(host: string) =
  ## After a rebuild the host key changes; drop the old one.
  if fileExists(knownHosts()):
    discard execCmdEx("ssh-keygen -R " & quoteShell(host) & " -f " & quoteShell(knownHosts()))

proc sudo(t: Target, cmd: string): string =
  if t.user == "root": cmd else: "sudo -n sh -c " & quoteShell(cmd)

proc targetFor*(sp: Spec, st: ClusterState, node: string): Target =
  let ns = st.nodes.getOrDefault(node)
  let host = if sp.nodes[node].host != "": sp.nodes[node].host else: ns.ip
  if host == "": raise newException(ValueError, node & ": no address yet (not delivered/synced)")
  Target(host: host, user: "root")

proc waitSsh*(t: Target, timeoutSec = 900): bool =
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    if ssh(t, "true").code == 0: return true
    sleep 10_000
  false

proc bootstrapScript*(sp: Spec): string =
  let key = readFile(sp.sshKeyPath).strip
  if not key.startsWith("ssh-"): raise newException(ValueError, sp.sshKeyPath & " is not a public key")
  nodeBootstrap.replace("__AOWL_SSH_KEY__", key)

proc adoptBootstrap*(sp: Spec, t: Target): SshResult =
  ## Existing machine reachable with the operator's key (as root or a sudoer).
  ssh(t, sudo(t, "sh -s"), input = bootstrapScript(sp), connectTimeout = 15)

proc readWgPub*(t: Target): string =
  let r = ssh(t, "test -f /var/lib/aowl/bootstrapped && wg pubkey < /var/lib/aowl-keys/wg.key")
  if r.code == 0: r.output.strip else: ""

# --- apply --------------------------------------------------------------------

proc appliedDir*(cluster, node: string): string = home() / "applied" / cluster / node

proc uploadTar(b: Bundle): string =
  var es: seq[TarEntry]
  for (p, d) in nodeFiles: es.add (p, d, 0o755)
  for p, d in b: es.add ("bundle/" & p, d, if p.startsWith("env/"): 0o600 else: 0o644)
  tar(es)

type ApplyOutcome* = enum aoConfirmed, aoRejected, aoUnconfirmed

proc applyNode*(sp: Spec, st: var ClusterState, node: string, b: Bundle,
                log: proc (s: string)): ApplyOutcome =
  let t = targetFor(sp, st, node)

  # project sources first: only what the node does not already have
  let manifest = parseJson(b["manifest.json"])
  for bl in manifest["builds"]:
    let (svc, tag) = (bl["service"].getStr, bl["tag"].getStr)
    if ssh(t, "docker image inspect " & quoteShell(tag) & " >/dev/null 2>&1").code == 0: continue
    log "  uploading source for " & svc & " (" & tag & ")"
    let r = ssh(t, "mkdir -p /var/lib/aowl/builds && cat > /var/lib/aowl/builds/" & svc & ".tar",
                input = tarDir(sp.dir / sp.services[svc].build))
    if r.code != 0: (log "  upload failed: " & r.output; return aoRejected)

  let up = ssh(t, "rm -rf /var/lib/aowl/up && mkdir -p /var/lib/aowl/up && " &
                  "cat > /var/lib/aowl/up.tar && tar -xf /var/lib/aowl/up.tar -C /var/lib/aowl/up && " &
                  "sh /var/lib/aowl/up/node/apply.sh " & $sp.rollbackSec,
               input = uploadTar(b), connectTimeout = 15)
  for l in up.output.strip.splitLines: log "  | " & l
  if up.code != 0 and up.code != 255:
    log "  apply rejected on node (nothing live changed if validation failed)"
    return aoRejected
  if up.code == 255:
    log "  connection dropped during apply -- trying to confirm anyway"

  # Fresh connection: proves the node is reachable under the NEW config.
  let deadline = epochTime() + float(sp.rollbackSec - 10)
  while epochTime() < deadline:
    let c = ssh(t, "/usr/local/sbin/aowl-confirm", connectTimeout = 8)
    if c.code == 0 and ("confirmed" in c.output or "nothing pending" in c.output):
      st.nodes[node].appliedHash = bundleHash(b)
      let d = appliedDir(sp.cluster, node)
      removeDir(d)
      for p, content in b:
        if p.startsWith("env/"): continue          # secrets are not kept in the local record
        createDir((d / p).parentDir)
        writeFile(d / p, content)
      return aoConfirmed
    if c.code == 4: break
    sleep 3000
  log "  NOT CONFIRMED: " & node & " restores its previous config within " & $sp.rollbackSec & "s of apply"
  aoUnconfirmed
