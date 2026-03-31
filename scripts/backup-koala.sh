#!/bin/bash
set -euo pipefail

# Source config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../bootstrap/config.sh"

PASS="${RESTIC_PASSWORD_FILE}"
SFTP_CMD="ssh -i ${BACKUP_SSH_KEY} ${USERNAME}@${PIBLOCK_HOST} -s sftp"
BASE="sftp:${USERNAME}@${PIBLOCK_HOST}:${PIBLOCK_BACKUP_PATH}"
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

restic -r "${BASE}/koala-data" --password-file "${PASS}" \
  -o sftp.command="${SFTP_CMD}" \
  backup \
  ${DATA_DISK_MOUNT}/jupyter \
  ${DATA_DISK_MOUNT}/projects \
  ${DATA_DISK_MOUNT}/repos \
  --exclude ${DATA_DISK_MOUNT}/cache

restic -r "${BASE}/koala-home" --password-file "${PASS}" \
  -o sftp.command="${SFTP_CMD}" \
  backup /home/${USERNAME} \
  --exclude /home/${USERNAME}/.cache

restic -r "${BASE}/koala-infra" --password-file "${PASS}" \
  -o sftp.command="${SFTP_CMD}" \
  backup /opt/bin /etc/fail2ban /etc/systemd/system /etc/ufw

for repo in koala-data koala-home koala-infra; do
  restic -r "${BASE}/${repo}" --password-file "${PASS}" \
    -o sftp.command="${SFTP_CMD}" \
    forget --prune \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 3
done

echo "=== Backup finished: $(date) ==="
