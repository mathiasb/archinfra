#!/bin/bash
set -euo pipefail

PASS=/data/backups/restic-password
SFTP_CMD="ssh -i /home/mathias/.ssh/id_backup mathias@piblock -s sftp"
BASE="sftp:mathias@piblock:/mnt/backup/restic"
LOG_DIR=/data/logs/backup
LOG=${LOG_DIR}/$(date +%Y-%m-%d).log

mkdir -p "${LOG_DIR}"
exec >> "${LOG}" 2>&1
echo "=== Backup started: $(date) ==="

# Pre-flight: confirm piblock has at least 50 GB free
PIBLOCK_FREE=$(ssh -i /home/mathias/.ssh/id_backup mathias@piblock \
  "df /mnt/backup --output=avail | tail -1")
if [ "${PIBLOCK_FREE}" -lt 52428800 ]; then
  echo "ERROR: piblock has less than 50 GB free. Aborting."
  exit 1
fi

# Repo 1: bulk data
restic -r "${BASE}/koala-data" \
  --password-file "${PASS}" \
  -o sftp.command="${SFTP_CMD}" \
  backup \
  /data/jupyter \
  /data/projects \
  /data/repos \
  --exclude /data/cache

# Repo 2: home directory
restic -r "${BASE}/koala-home" \
  --password-file "${PASS}" \
  -o sftp.command="${SFTP_CMD}" \
  backup \
  /home/mathias \
  --exclude /home/mathias/.cache

# Repo 3: system config
restic -r "${BASE}/koala-infra" \
  --password-file "${PASS}" \
  -o sftp.command="${SFTP_CMD}" \
  backup \
  /opt/bin \
  /etc/fail2ban \
  /etc/systemd/system \
  /etc/ufw

# Prune
for repo in koala-data koala-home koala-infra; do
  restic -r "${BASE}/${repo}" \
    --password-file "${PASS}" \
    -o sftp.command="${SFTP_CMD}" \
    forget --prune \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 3
done

echo "=== Backup finished: $(date) ==="
