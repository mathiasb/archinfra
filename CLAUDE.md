# Repo guidance for Claude Code sessions

This repo controls the koala k3s cluster. Mistakes here can take the
homelab offline. Read this file before suggesting host-level changes.

## Hard rules — do not violate

1. **No host firewall on koala.** Do not enable UFW, do not add it to
   `bootstrap/`, do not write a `fix-ufw-*.sh` script. UFW broke
   kube-router on this host on Apr 24 2026 — see `docs/network.md`. The
   `ufw` package is intentionally absent from `bootstrap/00-packages.sh`.

2. **Do not touch Tailscale's ip rules.** Priorities 5210, 5230, 5250,
   and 5270 with `lookup 52` are normal Tailscale routing rules, not
   kube-router rules. Verify by `ip route show table 52` — if it contains
   only `100.x.x.x` peer routes, the rules are correctly Tailscale-owned.

3. **Never run `ip rule flush`.** The kernel defaults at priorities
   32766 (main) and 32767 (default) are required for IP traffic. Flushing
   the rule table blackholes the host. (Apr 27 2026 incident.)

4. **First response to k3s networking trouble: `systemctl stop k3s`.**
   Don't edit iptables, ip rule, or nft chains as a first move. Stop k3s
   and re-evaluate from a clean state. See `docs/network.md` →
   "If networking breaks while k3s is running".

5. **Diagnose before remediating.** Before suggesting any change to
   iptables, ip rules, or systemd units on koala, gather and present
   evidence. Do not act on a previous Claude session's diagnosis without
   re-checking the current host state — the Apr 27 incident was caused
   by a session acting on an incorrect inherited diagnosis.

## Architecture quick reference

- **Cluster**: single-node k3s on koala, GitOps via Flux watching this repo
- **Network plugins**: flannel (overlay) + kube-router (NetworkPolicy)
- **Mesh**: Tailscale on all hosts (table 52)
- **Firewall**: UCG Max (perimeter) + Tailscale ACLs (mesh). No host firewall.
- **Build/deploy pipeline**: `docs/cd-pipeline.md`
- **Container registries**: `docs/registries.md` (Gitea + local `:5000`)
- **Network topology**: `docs/network.md`

## Active app repos with their own CI/CD

These app repos build and deploy themselves via Gitea Actions; this infra
repo provides the Kustomization-managed manifests they target.

- **`gitea.d-ma.be/mathias/cobalt-dingo`** — Go HTTP service for Fortnox
  AP automation. Builds with buildah, pushes to local `:5000` registry,
  CI patches `k3s/apps/cobalt-dingo/deployment.yaml` and triggers Flux.
  Pinned to koala via `nodeSelector` (registry coupling). Active development.

## When in doubt

Ask the user before:
- Modifying anything under `/etc/` on koala
- Editing `iptables`, `iptables-legacy`, `nft`, or `ip rule`
- Enabling/disabling systemd units that touch networking
- Running scripts that include `ufw`, `iptables-restore`, or `ip rule flush`
- Anything described as "fixing networking" — the safer move is `systemctl stop k3s` and diagnose
