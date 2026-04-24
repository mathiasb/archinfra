#!/bin/bash
# Allow k3s pod CIDR traffic in iptables-legacy INPUT chain.
# Called by k3s-pod-allow.service at boot, after k3s starts.
#
# Problem: iptables-legacy INPUT policy is DROP (leftover from UFW).
# kube-router only creates per-pod chains for namespaces with NetworkPolicies,
# so pods in other namespaces can't reach the host (including the k8s API).

set -euo pipefail

# Idempotent: check if rule already exists
if ! iptables-legacy -C INPUT -s 10.42.0.0/16 -j ACCEPT 2>/dev/null; then
  iptables-legacy -I INPUT 2 -s 10.42.0.0/16 -j ACCEPT \
    -m comment --comment "k3s pod CIDR"
  echo "Added pod CIDR rule"
else
  echo "Pod CIDR rule already exists"
fi

if ! iptables-legacy -C INPUT -s 10.43.0.0/16 -j ACCEPT 2>/dev/null; then
  iptables-legacy -I INPUT 3 -s 10.43.0.0/16 -j ACCEPT \
    -m comment --comment "k3s service CIDR"
  echo "Added service CIDR rule"
else
  echo "Service CIDR rule already exists"
fi
