#!/bin/bash
# koala bootstrap orchestrator
# Run from ~/infra after cloning the repo on a fresh Arch install
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG=/tmp/bootstrap-$(date +%Y%m%d-%H%M%S).log

echo "=== koala bootstrap starting $(date) ===" | tee -a "${LOG}"
echo "Logging to ${LOG}"
echo ""

run_step() {
  local script="${SCRIPT_DIR}/${1}"
  local name="${2}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Step: ${name}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  bash "${script}" 2>&1 | tee -a "${LOG}"
  echo ""
}

run_step 00-packages.sh "Install packages"
run_step 01-system.sh   "System configuration"
run_step 02-nvidia.sh   "NVIDIA setup"
run_step 03-k3s.sh      "k3s cluster"
run_step 04-flux.sh     "Flux GitOps"
run_step 05-apps.sh     "Deploy applications"
run_step 06-backup.sh   "Backup setup"

echo "=== Bootstrap complete $(date) ===" | tee -a "${LOG}"
echo ""
echo "Next steps:"
echo "  1. Reboot to verify everything starts cleanly"
echo "  2. SSH back in and run: kubectl get pods -A"
echo "  3. Check Grafana at http://10.0.1.20:31300"
echo "  4. Verify backup: sudo /opt/bin/backup-koala.sh"
