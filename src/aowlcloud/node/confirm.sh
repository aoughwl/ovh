#!/bin/sh
# Run by the controller over a NEW ssh connection: reaching this script at
# all proves the new config left the node reachable. Disarms the rollback.
set -eu
if ! systemctl is-active -q aowl-rollback.timer; then
  if [ "$(cat /var/lib/aowl/last-result 2>/dev/null)" = rolled-back ]; then
    echo "too late: the node already rolled back" >&2; exit 4
  fi
  echo "nothing pending"; exit 0
fi
systemctl stop aowl-rollback.timer
systemctl reset-failed aowl-rollback.service 2>/dev/null || true
echo confirmed > /var/lib/aowl/last-result
echo confirmed
