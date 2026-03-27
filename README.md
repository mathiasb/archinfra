# koala infra

GitOps repository for koala. Watched by Flux CD.

## Layout
- k3s/apps/    — per-service Helm values and manifests
- k3s/system/  — namespaces, RBAC, ingress, cert-manager
- k3s/flux/    — Flux bootstrap manifests
- terraform/   — Cloudflare DNS, firewall config
- scripts/     — health checks, benchmarks
- docs/        — runbooks and architecture notes
