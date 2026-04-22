#!/bin/bash
# Force fresh supervisor pod and tail pull errors.
# Run as: bash scripts/check-supervisor-pull.sh (no sudo needed)
set -euo pipefail

echo "=== Forcing fresh rollout ==="
kubectl rollout restart deployment/supervisor -n supervisor

echo "Waiting 20s for new pod to start pulling..."
sleep 20

echo ""
echo "=== Pod status ==="
kubectl get pod -n supervisor -o wide

echo ""
echo "=== Pull events (last 60s) ==="
kubectl get events -n supervisor --sort-by='.lastTimestamp' | tail -20

echo ""
echo "=== k3s containerd pull log (last 60s) ==="
journalctl -u k3s --since "60 seconds ago" | grep -i "gitea\|pull\|mirror\|cert\|auth\|401\|403\|hosts" | tail -30 || true
