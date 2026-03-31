# scripts

Host-level scripts and systemd units deployed directly to koala (not via k3s).

## backup-koala.sh
Restic backup to piblock. Deployed to `/opt/bin/backup-koala.sh`.
Runs nightly at 03:00 via `restic-backup.timer`.

### Deploy/update
```bash
sudo cp scripts/backup-koala.sh /opt/bin/backup-koala.sh
sudo chmod +x /opt/bin/backup-koala.sh
sudo cp scripts/restic-backup.service /etc/systemd/system/
sudo cp scripts/restic-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now restic-backup.timer
```
