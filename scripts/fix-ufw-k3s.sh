#!/bin/bash
# Fix UFW + k3s networking on koala.
#
# Problem: UFW was bootstrapped (setting iptables-legacy INPUT policy to DROP),
# then disabled. The DROP policy persists, blocking pod-to-host traffic
# (including k8s API access). Pods in namespaces without NetworkPolicies
# have no kube-router chain and their traffic falls to DROP.
#
# Solution: Re-enable UFW with the correct rules, including k3s pod/service CIDRs.
#
# Usage: sudo bash fix-ufw-k3s.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo bash $0"
  exit 1
fi

echo "=== Current UFW status ==="
ufw status verbose || true

echo ""
echo "=== Resetting UFW to clean state ==="
ufw --force reset

echo ""
echo "=== Configuring rules ==="
ufw default deny incoming
ufw default allow outgoing

# Core access
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp

# Tailscale mesh — all traffic
ufw allow in on tailscale0

# k3s API — also via Tailscale (redundant with above, explicit for clarity)
ufw allow in on tailscale0 to any port 6443

# k3s pod and service CIDRs — required for pod-to-host traffic
# (API server access, NodePort routing, etc.)
ufw allow from 10.42.0.0/16
ufw allow from 10.43.0.0/16

echo ""
echo "=== Enabling UFW ==="
ufw --force enable

echo ""
echo "=== Verifying ==="
ufw status numbered

echo ""
echo "=== Checking iptables-legacy INPUT policy ==="
INPUT_POLICY=$(iptables-legacy -L INPUT -n 2>/dev/null | head -1 | grep -oP '\(policy \K[A-Z]+')
echo "INPUT policy: ${INPUT_POLICY}"
if [ "$INPUT_POLICY" = "DROP" ]; then
  echo "Policy is DROP — UFW is managing it correctly."
else
  echo "WARNING: Expected DROP, got ${INPUT_POLICY}"
fi

echo ""
echo "=== Testing pod-to-API connectivity ==="
# Quick check: can a pod reach the API server?
if kubectl run ufw-verify --image=curlimages/curl:latest --restart=Never \
  --command -- curl -sk --connect-timeout 5 https://kubernetes.default.svc:443/api 2>/dev/null; then
  sleep 8
  RESULT=$(kubectl logs ufw-verify 2>/dev/null | head -1)
  kubectl delete pod ufw-verify --force 2>/dev/null || true
  if echo "$RESULT" | grep -q "versions"; then
    echo "Pod-to-API connectivity: OK"
  else
    echo "Pod-to-API connectivity: FAILED (response: ${RESULT:-empty})"
    echo "You may need to restart k3s: sudo systemctl restart k3s"
  fi
else
  echo "Could not create test pod — check kubectl access"
fi

echo ""
echo "=== Done ==="
