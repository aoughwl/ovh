#!/bin/sh
# apply.sh ROLLBACK_SECONDS  -- run from the unpacked upload dir.
#
# The dead-man switch: validate, snapshot the running config, ARM a timer
# that restores the snapshot, then activate. The controller must reconnect
# over a *fresh* SSH session and run aowl-confirm before the timer fires.
# If the new firewall/mesh/sshd cut it off, the node puts itself back.
set -eu
T=${1:-90}
HERE=$(cd "$(dirname "$0")/.." && pwd)     # upload root: bundle/ + node/
NEW=$HERE/bundle

install -m 0755 "$HERE"/node/aowl-net      /usr/local/sbin/aowl-net
install -m 0755 "$HERE"/node/activate.sh   /usr/local/sbin/aowl-activate
install -m 0755 "$HERE"/node/rollback.sh   /usr/local/sbin/aowl-rollback
install -m 0755 "$HERE"/node/confirm.sh    /usr/local/sbin/aowl-confirm

# 1. validate before touching anything live
nft -c -f "$NEW"/nftables.nft
jq -e . "$NEW"/manifest.json >/dev/null

# 2. never stack two pending applies
if systemctl is-active -q aowl-rollback.timer; then
  echo "an apply is still unconfirmed; confirm or wait for its rollback" >&2; exit 3
fi

# 3. snapshot what is running now
rm -rf /var/lib/aowl/prev
if [ -f /etc/aowl/manifest.json ]; then mkdir -p /var/lib/aowl/prev && cp -a /etc/aowl/. /var/lib/aowl/prev/; fi

# 4. arm the dead-man switch BEFORE the first live change
systemctl reset-failed aowl-rollback.timer aowl-rollback.service 2>/dev/null || true
systemd-run --quiet --unit=aowl-rollback --on-active="${T}s" --timer-property=AccuracySec=1s \
  /usr/local/sbin/aowl-rollback

# 5. go live
mkdir -p /etc/aowl && chmod 700 /etc/aowl
find /etc/aowl -mindepth 1 -delete
cp -a "$NEW"/. /etc/aowl/
chmod 600 /etc/aowl/env/* 2>/dev/null || true
/usr/local/sbin/aowl-activate
echo "applied; awaiting confirm within ${T}s"
