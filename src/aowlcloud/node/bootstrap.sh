#!/bin/sh
# aowlcloud node bootstrap. Runs once as root: as the OVH rebuild
# postInstallScript, or over SSH for an adopted machine. Idempotent.
# Carries no secrets -- only the operator's PUBLIC key.
set -eu
KEY='__AOWL_SSH_KEY__'
export DEBIAN_FRONTEND=noninteractive

mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
grep -qF "$KEY" /root/.ssh/authorized_keys || echo "$KEY" >> /root/.ssh/authorized_keys

# Key-only SSH. Written before anything that could fail halfway.
mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
  > /etc/ssh/sshd_config.d/10-aowl.conf
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

for i in 1 2 3 4 5; do apt-get update && break; sleep 10; done
apt-get install -y --no-install-recommends docker.io wireguard-tools nftables jq curl ca-certificates iproute2
systemctl enable --now docker

mkdir -p /etc/aowl /var/lib/aowl /var/lib/aowl/builds /var/lib/aowl-keys
chmod 700 /var/lib/aowl-keys /etc/aowl
# The mesh private key is born here and never leaves this machine.
[ -s /var/lib/aowl-keys/wg.key ] || (umask 077; wg genkey > /var/lib/aowl-keys/wg.key)

printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/60-aowl.conf
sysctl -q -p /etc/sysctl.d/60-aowl.conf || true

date -u +%FT%TZ > /var/lib/aowl/bootstrapped
echo "aowl bootstrap ok"
