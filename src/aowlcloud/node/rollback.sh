#!/bin/sh
# Fired by the dead-man timer (or by hand). Restores the last confirmed
# config; if there never was one, falls back to "no aowl firewall, no mesh,
# no services" -- i.e. plain SSH as it was at bootstrap.
set -u
logger -t aowl "ROLLBACK: apply was not confirmed in time"
if [ -d /var/lib/aowl/prev ]; then
  find /etc/aowl -mindepth 1 -delete
  cp -a /var/lib/aowl/prev/. /etc/aowl/
  /usr/local/sbin/aowl-activate
else
  nft delete table inet aowl 2>/dev/null
  nft delete table ip aowlnat 2>/dev/null
  systemctl stop aowl.target 'aowl-*' 2>/dev/null
  systemctl disable --now wg-quick@wg0 2>/dev/null
  mkdir -p /etc/aowl && find /etc/aowl -mindepth 1 -delete
fi
echo rolled-back > /var/lib/aowl/last-result
