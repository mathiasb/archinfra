#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../bootstrap/config.sh"

PASS="${RESTIC_PASSWORD_FILE}"
SFTP_CMD="ssh -i ${BACKUP_SSH_KEY} ${USERNAME}@${PIBLOCK_HOST} -s sftp"
BASE_PIBLOCK="sftp:${USERNAME}@${PIBLOCK_HOST}:${PIBLOCK_BACKUP_PATH}"
BASE_HETZNER="s3:https://hel1.your-objectstorage.com/koala-restic-backup"
LOG_DIR=${DATA_DISK_MOUNT}/logs/backup
LOG=${LOG_DIR}/$(date +%Y-%m-%d).log

mkdir -p "${LOG_DIR}"
exec >> "${LOG}" 2>&1
echo "=== Backup started: $(date) ==="

# Pre-flight: confirm piblock has at least 50 GB free
PIBLOCK_FREE=$(ssh -i "${BACKUP_SSH_KEY}" "${USERNAME}@${PIBLOCK_HOST}" \
  "df ${PIBLOCK_BACKUP_PATH} --output=avail | tail -1")
if [ "${PIBLOCK_FREE}" -lt 52428800 ]; then
  echo "ERROR: piblock has less than 50 GB free. Aborting."
  exit 1
fi

backup_to_repo() {
  local repo="${1}"
  local name="${2}"
  shift 2
  echo "--- Backing up to ${name} ---"
  restic -r "${repo}" --password-file "${PASS}" "$@" || \
    echo "WARNING: backup to ${name} failed"
}

# Repo 1: bulk data — both destinations
backup_to_repo "${BASE_PIBLOCK}/koala-data" "piblock" \
  -o sftp.command="${SFTP_CMD}" \
  backup /data/jupyter /data/projects /data/repos \
  --exclude /data/cache

backup_to_repo "${BASE_HETZNER}" "hetzner" \
  backup /data/jupyter /data/projects /data/repos \
  --exclude /data/cache

# Repo 2: home directory — piblock only (less critical for off-site)
backup_to_repo "${BASE_PIBLOCK}/koala-home" "piblock-home" \
  -o sftp.command="${SFTP_CMD}" \
  backup /home/${USERNAME} \
  --exclude /home/${USERNAME}/.cache

# Repo 3: system config — piblock only
backup_to_repo "${BASE_PIBLOCK}/koala-infra" "piblock-infra" \
  -o sftp.command="${SFTP_CMD}" \
  backup /opt/bin /etc/fail2ban /etc/systemd/system /etc/ufw

# Prune piblock repos
for repo in koala-data koala-home koala-infra; do
  restic -r "${BASE_PIBLOCK}/${repo}" \
    --password-file "${PASS}" \
    -o sftp.command="${SFTP_CMD}" \
    forget --prune \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 3
done

# Prune Hetzner repo
restic -r "${BASE_HETZNER}" \
  --password-file "${PASS}" \
  forget --prune \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 3

echo "=== Backup finished: $(date) ==="
