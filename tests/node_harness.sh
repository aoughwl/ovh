#!/bin/bash
# Runs the REAL node scripts against the REAL kernel nftables and systemd's
# unit verifier -- inside a private mount + network namespace, so the host
# (your WSL) is never touched. Only docker/systemctl/wg/ip are stubbed.
#   wsl -u root -e bash tests/node_harness.sh
set -u
if [ -z "${AOWL_INNER:-}" ]; then
  exec env AOWL_INNER=1 unshare --mount --net --propagation private bash "$0" "$@"
fi
cd "$(dirname "$0")"
T=$PWD; OUT=$T/out; NODE=$T/../src/aowlcloud/node
pass=0; failn=0
ok()   { echo "  ok   $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL $*"; failn=$((failn+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

ip link set lo up
for d in /etc/aowl /var/lib/aowl /var/lib/aowl-keys /usr/local/sbin /etc/systemd/system /etc/wireguard /tmp; do
  mkdir -p "$d"; mount -t tmpfs tmpfs "$d"
done
H=/tmp/h; mkdir -p $H/bin
LOG=$H/log; : > $LOG

# ---- stubs (log every call; keep just enough state) -------------------------
cat > $H/bin/systemctl <<'EOF'
#!/bin/sh
echo "systemctl $*" >> /tmp/h/log
case "$*" in
  "is-active -q aowl-rollback.timer") [ -f /tmp/h/timer ] ;;
  "stop aowl-rollback.timer") rm -f /tmp/h/timer ;;
  list-units*) : ;;
  *) : ;;
esac
EOF
cat > $H/bin/systemd-run <<'EOF'
#!/bin/sh
echo "systemd-run $*" >> /tmp/h/log; touch /tmp/h/timer
EOF
for c in docker wg logger; do printf '#!/bin/sh\necho "%s $*" >> /tmp/h/log\n' $c > $H/bin/$c; done
cat > $H/bin/ip <<'EOF'
#!/bin/sh
echo "ip $*" >> /tmp/h/log
case "$*" in "route show default") echo "default via 192.0.2.1 dev eth0" ;; esac
EOF
cat > $H/bin/nft <<'EOF'
#!/bin/sh
echo "nft $*" >> /tmp/h/log; exec /usr/sbin/nft "$@"
EOF
chmod +x $H/bin/*
export PATH=$H/bin:$PATH

echo "== firewall: rendered rulesets load into a real kernel"
for b in site-web1 web1 farm1; do
  if nft -f $OUT/$b/nftables.nft 2>$H/err; then ok "$b loads"; else bad "$b: $(cat $H/err)"; fi
done
check "reload is idempotent (delete+recreate)" "nft -f $OUT/farm1/nftables.nft"
check "farm1 snat rules present" "nft list table ip aowlnat | grep -q 'snat to 203.0.113.11'"
nft flush ruleset

echo "== systemd: units pass systemd-analyze verify"
for b in site-web1 web1 farm1; do
  for u in $OUT/$b/units/*.service; do
    n=$(basename "$u")
    tmp=$H/units; rm -rf $tmp; mkdir -p $tmp; cp "$u" $tmp/; chmod 644 $tmp/*
    printf '[Unit]\nDescription=stub\n' > $tmp/aowl.target
    printf '[Service]\nExecStart=/bin/true\n' > $tmp/docker.service
    v=$n; case $n in *@.service) v=${n%@.service}@3.service; cp "$u" "$tmp/$v"; chmod 644 "$tmp/$v" ;; esac
    msg=$(cd $tmp && SYSTEMD_UNIT_PATH=$tmp: /usr/bin/systemd-analyze verify --man=no "$tmp/$v" 2>&1 \
          | grep -v -e 'wg-quick@' -e 'docker.service' -e '^$' -e 'Command /usr/bin/docker is not executable')
    if [ -z "$msg" ]; then ok "$b/$n"; else bad "$b/$n: $msg"; fi
  done
done

echo "== pool: session 3's wrapper computes its own name/subnet/port"
u=$OUT/farm1/units/aowl-browser@.service
sd_exec() {  # run one Exec line for instance 3 the way systemd would: no shell, its own word splitting
  python3 - "$1" "$u" <<'PY'
import shlex, subprocess, sys, re
key, unit = sys.argv[1], sys.argv[2]
line = next(l for l in open(unit) if l.startswith(key + "="))
line = re.sub(r"^[^=]*=-?", "", line.strip()).replace("/usr/bin/docker", "docker")
line = line.replace("%i", "3").replace("$$", "@DOLLAR@").replace("%%", "%")
argv = [w.replace("@DOLLAR@", "$") for w in shlex.split(line)]
sys.exit(subprocess.call(argv))
PY
}
: > $LOG
sd_exec ExecStart
check "container name aowl-browser-3" "grep -q -- '--name aowl-browser-3 ' $LOG"
check "host port 30003 on the mesh IP" "grep -q -- '-p 10.77.0.2:30003:9222' $LOG"
check "AOWL_SESSION=3" "grep -q 'AOWL_SESSION=3' $LOG"
: > $LOG
cp $NODE/aowl-net $H/aowl-net; sed -i 's/^docker network inspect.*/false && exit 0/' $H/aowl-net
sh $H/aowl-net aowl-browser-3 --subnet 10.100.3.0/24 --bridge aw0s3
check "isolated session network: own subnet, own bridge, icc off" \
  "grep -q 'network create --driver bridge --label aowl=1 --subnet 10.100.3.0/24 -o com.docker.network.bridge.name=aw0s3 -o com.docker.network.bridge.enable_icc=false aowl-browser-3' $LOG"

echo "== dead-man apply / confirm / rollback (real scripts)"
stage() {  # stage <bundle> -> upload dir the way the controller lays it out
  rm -rf $H/up; mkdir -p $H/up/node; cp -r $OUT/$1 $H/up/bundle; cp $NODE/* $H/up/node/
}
: > $LOG
stage site-web1
sh $H/up/node/apply.sh 60 > $H/o 2>&1; rc=$?
check "apply A succeeds" "[ $rc -eq 0 ]"
check "timer armed before the firewall went live" \
  "[ \$(grep -n '^systemd-run' $LOG | cut -d: -f1) -lt \$(grep -n '^nft -f /etc/aowl/nftables.nft' $LOG | cut -d: -f1) ]"
check "A is live" "grep -q '\"cluster\": \"web\"' /etc/aowl/manifest.json && nft list table inet aowl >/dev/null"
check "confirm disarms" "/usr/local/sbin/aowl-confirm | grep -qx confirmed && [ ! -f $H/timer ]"

stage farm1
sh $H/up/node/apply.sh 60 > $H/o 2>&1
check "apply B goes live, pending" "grep -q '\"node\": \"farm1\"' /etc/aowl/manifest.json && [ -f $H/timer ]"
check "env files are 0600" "[ \$(stat -c %a /etc/aowl/env/browser.env) = 600 ]"
stage site-web1
sh $H/up/node/apply.sh 60 > $H/o 2>&1; rc=$?
check "second apply refused while one is unconfirmed" "[ $rc -eq 3 ]"
/usr/local/sbin/aowl-rollback >/dev/null 2>&1          # the timer firing
check "rollback restored A" "grep -q '\"cluster\": \"web\"' /etc/aowl/manifest.json"
check "rollback restored A's firewall (no farm snat)" "! nft list ruleset | grep -q 'snat to 203.0.113'"
rm -f $H/timer
check "late confirm reports the rollback" "/usr/local/sbin/aowl-confirm >/dev/null 2>&1; [ \$? -eq 4 ]"

stage site-web1
echo "this is not nft" > $H/up/bundle/nftables.nft
: > $LOG
sh $H/up/node/apply.sh 60 > $H/o 2>&1; rc=$?
check "invalid firewall rejected before anything changes" "[ $rc -ne 0 ] && ! grep -q '^systemd-run' $LOG"
check "live config untouched by the rejected apply" "grep -q '\"cluster\": \"web\"' /etc/aowl/manifest.json"

rm -rf /etc/aowl/* /var/lib/aowl/*; nft flush ruleset
stage farm1
sh $H/up/node/apply.sh 60 > $H/o 2>&1
/usr/local/sbin/aowl-rollback >/dev/null 2>&1
check "first-ever apply rolls back to bare SSH (no aowl tables)" \
  "! nft list tables | grep -q aowl"

echo; echo "passed $pass, failed $failn"
[ $failn -eq 0 ]
