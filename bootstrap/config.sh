# koala bootstrap configuration
# Edit these values before running bootstrap scripts

# Machine
HOSTNAME="koala"
TIMEZONE="Europe/Stockholm"
USERNAME="mathias"

# Network
KOALA_LAN_IP="10.0.1.20"
PIGUARD_LAN_IP="10.0.1.1"
PIBLOCK_HOST="piblock"
PIBLOCK_BACKUP_PATH="/mnt/backup/restic"

# Services
GITEA_URL="https://gitea.d-ma.be"
GITEA_USER="mathias"
INFRA_REPO="https://github.com/mathiasb/archinfra.git"

# Ports
LLAMA_SWAP_PORT="31234"
GRAFANA_PORT="31300"
PROMETHEUS_PORT="31900"
INGRESS_HTTP_PORT="30080"
INGRESS_HTTPS_PORT="30443"

# Paths
DATA_DISK_MOUNT="/data"
RESTIC_PASSWORD_FILE="/data/backups/restic-password"
BACKUP_SSH_KEY="$HOME/.ssh/id_backup"
MODELS_YML="/data/projects/gocrwl/llama-swap/models.yml"

# NVIDIA
NVIDIA_DRIVER_VERSION="595.58.03"
