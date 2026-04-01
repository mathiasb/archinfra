#!/bin/bash
set -euo pipefail

source /home/mathias/infra/bootstrap/config.sh
source /etc/restic-hetzner.env

# Override SSH key path for root
BACKUP_SSH_KEY="/root/.ssh/id_backup"

PASS="${RESTIC_PASSWORD_FILE}"
SFTP_CMD="ssh -i ${BACKUP_SSH_KEY} ${USERNAME}@${PIBLOCK_HOST} -s sftp"
BASE_PIBLOCK="sftp:${USERNAME}@${PIBLOCK_HOST}:${PIBLOCK_BACKUP_PATH}"
BASE_HETZNER="s3:https://hel1.your-objectstorage.com/koala-restic-backup"
LOG_DIR=${DATA_DISK_MOUNT}/logs/backup
LOG=${LOG_DIR}/$(date +%Y-%m-%d).log

mkdir -p "${LOG_DIR}"
exec >> "${LOG}" 2>&1
echo "=== Backup started: $(date) ==="

PIBLOCK_FREE=$(ssh -i "${BACKUP_SSH_KEY}" "${USERNAME}@${PIBLOCK_HOST}" \
  "df ${PIBLOCK_BACKUP_PATH} --output=avail | tail -1")
if [ "${PIBLOCK_FREE}" -lt 52428800 ]; then
  echo "ERROR: piblock has less than 50 GB free. Aborting."
  exit 1
fi

echo "--- koala-data → piblock ---"
restic -r "${BASE_PIBLOCK}/koala-data" --password-file "${PASS}" \
  -o sftp.command="${SFTP_CMD}" \
  backup /data/jupyter /data/projects /data/repos \
  --exclude /data/cache

echo "--- koala-data → hetzner ---"
restic -r "${BASE_HETZNER}" --password-file "${PASS}" \
  backup /data/jupyter /data/projects /data/repos \
  --exclude /data/cache

echo "--- koala-home → piblock ---"
restic -r "${BASE_PIBLOCK}/koala-home" --password-file "${PASS}" \
  -o sftp.command="${SFTP_CMD}" \
  backup /home/${USERNAME} --exclude /home/${USERNAME}/.cache

echo "--- koala-infra → piblock ---"
restic -r "${BASE_PIBLOCK}/koala-infra" --password-file "${PASS}" \
  -o sftp.command="${SFTP_CMD}" \
  backup /opt/bin /etc/fail2ban /etc/systemd/system /etc/ufw

echo "--- pruning piblock ---"
for repo in koala-data koala-home koala-infra; do
  restic -r "${BASE_PIBLOCK}/${repo}" --password-file "${PASS}" \
    -o sftp.command="${SFTP_CMD}" \
    forget --prune \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 3
done

echo "--- pruning hetzner ---"
restic -r "${BASE_HETZNER}" --password-file "${PASS}" \
  forget --prune \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 3

echo "=== Backup finished: $(date) ==="
