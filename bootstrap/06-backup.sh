#!/bin/bash
# Backup: SSH key to piblock, script, systemd timer
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CONFIG_DIR}/config.sh"

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "--- SSH key for backup ---"
if [ ! -f ${BACKUP_SSH_KEY} ]; then
  ssh-keygen -t ed25519 -C "koala-backup" -f ${BACKUP_SSH_KEY} -N ""
  echo ""
  echo "Copy public key to piblock:"
  ssh-copy-id -i ${BACKUP_SSH_KEY}.pub ${USERNAME}@${PIBLOCK_HOST}
else
  echo "Backup SSH key already exists, skipping"
fi

echo "--- Test piblock connection ---"
ssh -i ${BACKUP_SSH_KEY} ${USERNAME}@${PIBLOCK_HOST} "df -h /mnt/backup" || {
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
    -r sftp:${USERNAME}@${PIBLOCK_HOST}:${PIBLOCK_BACKUP_PATH}/koala-data \
    --password-file "${PASS}" \
    -o sftp.command="ssh -i /home/mathias/.ssh/id_backup ${USERNAME}@${PIBLOCK_HOST} -s sftp" \
    snapshots | tail -3
else
  echo "WARNING: restic password not found at ${PASS}"
  echo "Copy it from piblock or your backup and place it at ${PASS}"
fi

echo "--- Backup setup done ---"
