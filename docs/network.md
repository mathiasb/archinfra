# Homelab network

## Machines

| Machine | Role | Key specs |
|---------|------|-----------|
| koala | GPU inference, k3s cluster, Gitea | RTX 5070, Arch Linux, LAN: 10.0.1.20 |
| iguana | Services, builds | M2 Ultra Mac, LAN: 10.0.1.25 |
| flamingo | Daily driver, edge | Mac mini |
| piguard | Gateway, DNS, proxy, LiteLLM | Raspberry Pi 4, 1 Gbps direct to UCG Max |
| piblock | Backup target | Raspberry Pi 4, 4 TB external drive |

All machines are connected via **Tailscale** mesh. LAN connectivity is also available on the home network.

## DNS

External DNS is managed via **Cloudflare** (see `terraform/` for zone config).

Internal DNS: handled by **Unifi Cloud Gateway Max** (UCG Max), the home router/gateway. Machines are reachable by hostname on the LAN.

## Nginx Proxy Manager (NPM)

NPM runs on **piguard** and proxies all public-facing services. piguard is physically connected at 1 Gbps directly to the UCG Max.

### Proxy hosts

| Hostname | Target | Notes |
|----------|--------|-------|
| gitea.d-ma.be | koala NodePort | HTTPS only — see Gitea SSH note below |

### Gitea SSH access

Gitea SSH is exposed as a k3s NodePort on port **30022** on koala. HTTP/HTTPS access works via NPM. SSH git operations currently require one of:

- From within the cluster: `ssh://git@gitea-ssh.gitea.svc.cluster.local:22`
- Direct NodePort: `ssh -p 30022 git@10.0.1.20` (LAN only)
- **Recommended fix**: configure NPM TCP stream proxy to forward an external port (e.g., 2222) to koala:30022, then add SSH config on clients:
  ```
  Host gitea.d-ma.be
    Port 2222
  ```

For now, HTTPS cloning works from all machines: `https://gitea.d-ma.be/mathias/<repo>.git`

## LiteLLM

LiteLLM runs on **piguard** via Docker Compose.

- **Config source of truth**: `litellm/config.yaml` in this repo (generated from `models.yml`)
- **Deploy**: `litellm/deploy.sh` (scp + restart) or `task model:apply`
- **Port**: 4000 (accessed as `http://piguard:4000`)
- **API key**: `DMABE_LLMAPI_KEY`
- **Management**: `task model:generate` regenerates config, `task model:apply` deploys it

Environment variables (`LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, API keys) are loaded from the piguard shell environment.

## Backup

koala runs `restic` on a systemd timer (see `scripts/restic-backup.service` and `scripts/restic-backup.timer`), backing up to **piblock** over SSH. The SSH key for piblock is provisioned in `bootstrap/06-backup.sh`.

## llama-swap

llama-swap runs on **koala** at port **31234**, managing GPU model loading/unloading.

- **Config source of truth**: `models.yml` in repo root (koala slots)
- **ConfigMap**: `k3s/apps/ai-stack/llama-swap-configmap.yaml` (generated, do not edit directly)
- **Management**: `task model:apply` regenerates ConfigMap, restarts pod, and commits
- **Status**: `task model:status` shows live vs declared state
