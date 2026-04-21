# koala infra

GitOps repository for the koala k3s cluster. Watched by Flux CD.

## Layout

- `k3s/apps/`   — per-service k8s manifests, reconciled by Flux (`apps` Kustomization)
- `k3s/system/` — namespaces, RBAC, ingress, cert-manager
- `k3s/flux/`   — Flux bootstrap manifests (watches this repo)
- `terraform/`  — Cloudflare DNS, firewall config
- `scripts/`    — host-level scripts and systemd units deployed to koala
- `bootstrap/`  — automated koala setup from a fresh Arch Linux install
- `docs/`       — runbooks and architecture notes

## Key docs

- [Network & machines](docs/network.md) — homelab topology, NPM, LiteLLM, Gitea SSH
- [CD pipeline](docs/cd-pipeline.md) — how services are built and deployed via Gitea Actions + Flux
- [Bootstrap](bootstrap/README.md) — rebuild koala from scratch
