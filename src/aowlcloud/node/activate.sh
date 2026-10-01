#!/bin/sh
# Make the machine match /etc/aowl. Idempotent; used by apply, rollback, boot.
set -eu
B=/etc/aowl
M=$B/manifest.json
SD=/etc/systemd/system
[ -f "$M" ] || { echo "no manifest"; exit 0; }

# --- extra public IPs (for pinned session egress) ---------------------------
dev=$(ip route show default | awk '{print $5; exit}')
want=$(jq -r '.extraIps[]' "$M")
for ip in $(cat /var/lib/aowl/extra-ips 2>/dev/null); do
  echo "$want" | grep -qx "$ip" || ip addr del "$ip/32" dev "$dev" 2>/dev/null || true
done
for ip in $want; do
  ip -o addr show dev "$dev" | grep -q " $ip/" || ip addr add "$ip/32" dev "$dev"
done
echo "$want" > /var/lib/aowl/extra-ips

# --- firewall (persisted across reboot by aowl-firewall.service) ------------
nft -f $B/nftables.nft
cat > $SD/aowl-firewall.service <<'EOF'
[Unit]
Description=aowl firewall
Before=network-pre.target docker.service
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/aowl/nftables.nft
[Install]
WantedBy=multi-user.target
EOF

# --- mesh -------------------------------------------------------------------
mkdir -p /etc/wireguard
if ! cmp -s $B/wg0.conf /etc/wireguard/wg0.conf; then
  install -m 600 $B/wg0.conf /etc/wireguard/wg0.conf
  systemctl enable -q wg-quick@wg0
  systemctl restart wg-quick@wg0
else
  systemctl enable -q --now wg-quick@wg0
fi

# --- images built from uploaded project sources -----------------------------
jq -r '.builds[] | "\(.service) \(.tag)"' "$M" | while read -r svc tag; do
  docker image inspect "$tag" >/dev/null 2>&1 && continue
  echo "building $tag"
  docker build -q -t "$tag" - < /var/lib/aowl/builds/"$svc".tar
done

# --- units ------------------------------------------------------------------
cat > $SD/aowl.target <<'EOF'
[Unit]
Description=all aowl services
[Install]
WantedBy=multi-user.target
EOF
changed=""
for f in $SD/aowl-*.service; do
  [ -e "$f" ] || continue
  n=$(basename "$f")
  [ "$n" = aowl-firewall.service ] && continue
  if [ ! -e "$B/units/$n" ]; then
    base=${n%.service}
    case $base in
      *@) systemctl stop "$base*" 2>/dev/null || true
          rm -f "$SD"/aowl.target.wants/"$base"* ;;
      *)  systemctl disable -q --now "$n" 2>/dev/null || true ;;
    esac
    rm -f "$f"
  fi
done
for f in $B/units/*.service; do
  [ -e "$f" ] || continue
  n=$(basename "$f")
  cmp -s "$f" "$SD/$n" || { install -m 644 "$f" "$SD/$n"; changed="$changed $n"; }
done
systemctl daemon-reload
systemctl enable -q aowl-firewall.service aowl.target

want_units=$(jq -r '.units[]' "$M")
# stop instances no longer wanted (e.g. a pool shrank)
systemctl list-units --all --plain --no-legend 'aowl-*' | awk '{print $1}' | while read -r u; do
  case $u in aowl-firewall.service|aowl-rollback.*) continue ;; esac
  echo "$want_units" | grep -qx "$u" || systemctl disable -q --now "$u" 2>/dev/null || true
done
for u in $want_units; do
  tmpl=$(echo "$u" | sed 's/@[^.]*\./@./')
  if echo " $changed " | grep -q " $tmpl "; then
    systemctl enable -q "$u"; systemctl restart "$u"
  else
    systemctl enable -q --now "$u"
  fi
done
systemctl reset-failed 'aowl-*' 2>/dev/null || true
echo "active: $(echo "$want_units" | wc -w) units"
