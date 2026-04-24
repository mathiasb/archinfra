#!/bin/bash
# System configuration: snapper, fail2ban, UFW, SSH, reflector
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CONFIG_DIR}/config.sh"

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "--- Snapper ---"
if ! snapper -c root list &>/dev/null; then
  sudo umount /.snapshots 2>/dev/null || true
  sudo rm -rf /.snapshots
  sudo snapper -c root create-config /
  sudo mount -a
  sudo snapper -c root set-config \
    NUMBER_LIMIT=10 \
    NUMBER_LIMIT_IMPORTANT=5 \
    TIMELINE_CREATE=yes \
    TIMELINE_LIMIT_HOURLY=3 \
    TIMELINE_LIMIT_DAILY=7 \
    TIMELINE_LIMIT_WEEKLY=2 \
    TIMELINE_LIMIT_MONTHLY=1
  sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
  sudo snapper -c root create --description "post-bootstrap"
else
  echo "Snapper already configured, skipping"
fi

echo "--- fail2ban ---"
if [ ! -f /etc/fail2ban/jail.d/koala.conf ]; then
  sudo cp "${INFRA_DIR}/scripts/etc/fail2ban/jail.d/koala.conf" \
    /etc/fail2ban/jail.d/koala.conf
  sudo systemctl enable --now fail2ban
else
  echo "fail2ban already configured, skipping"
fi

echo "--- UFW ---"
if ! sudo ufw status | grep -q "Status: active"; then
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow ssh comment 'SSH access'
  sudo ufw allow 80/tcp comment 'HTTP - public services via piguard/NPM'
  sudo ufw allow 443/tcp comment 'HTTPS - public services via piguard/NPM'
  sudo ufw allow in on tailscale0 to any port 6443 comment 'k3s API - Tailscale mesh only'
  sudo ufw allow in on tailscale0 comment 'All traffic within Tailscale mesh'
  sudo ufw allow from 10.42.0.0/16 comment 'k3s pod CIDR'
  sudo ufw allow from 10.43.0.0/16 comment 'k3s service CIDR'
  sudo ufw --force enable
else
  echo "UFW already active, skipping"
fi

echo "--- SSH hardening ---"
if grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config 2>/dev/null || \
   ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
  sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  sudo systemctl reload sshd
  echo "SSH hardened"
else
  echo "SSH already hardened, skipping"
fi

echo "--- Services ---"
sudo systemctl enable --now NetworkManager
sudo systemctl enable --now sshd
sudo systemctl enable --now tailscaled
sudo systemctl enable --now smartd
sudo systemctl enable fstrim.timer

echo "--- vconsole ---"
if [ ! -f /etc/vconsole.conf ]; then
  echo "KEYMAP=us" | sudo tee /etc/vconsole.conf
  sudo mkinitcpio -P
fi

echo "--- System configuration done ---"
