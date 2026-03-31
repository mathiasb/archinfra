#!/bin/bash
# Backup: SSH key to piblock, script, systemd timer
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "--- SSH key for backup ---"
if [ ! -f ~/.ssh/id_backup ]; then
  ssh-keygen -t ed25519 -C "koala-backup" -f ~/.ssh/id_backup -N ""
  echo ""
  echo "Copy public key to piblock:"
  ssh-copy-id -i ~/.ssh/id_backup.pub mathias@piblock
else
  echo "Backup SSH key already exists, skipping"
fi

echo "--- Test piblock connection ---"
ssh -i ~/.ssh/id_backup mathias@piblock "df -h /mnt/backup" || {
  echo "ERROR: Cannot reach piblock. Check SSH key and connectivity."
  exit 1
}

echo "--- Backup script ---"
sudo cp "${INFRA_DIR}/scripts/backup-koala.sh" /opt/bin/backup-koala.sh
sudo chmod +x /opt/bin/backup-koala.sh

echo "--- Systemd units ---"
sudo cp "${INFRA_DIR}/scripts/restic-backup.service" /etc/systemd/system/
sudo cp "${INFRA_DIR}/scripts/restic-backup.timer"   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now restic-backup.timer

echo "--- Verify restic repos are reachable ---"
PASS=/data/backups/restic-password
if [ -f "${PASS}" ]; then
  restic \
    -r sftp:mathias@piblock:/mnt/backup/restic/koala-data \
    --password-file "${PASS}" \
    -o sftp.command="ssh -i /home/mathias/.ssh/id_backup mathias@piblock -s sftp" \
    snapshots | tail -3
else
  echo "WARNING: restic password not found at ${PASS}"
  echo "Copy it from piblock or your backup and place it at ${PASS}"
fi

echo "--- Backup setup done ---"
