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

## Host firewall

**koala does not run a host firewall.** Filtering happens at:

1. **UCG Max** (home gateway) — incoming WAN → public services via piguard/NPM only
2. **Tailscale ACLs** — controls peer-to-peer access on the mesh

Do not enable UFW or any other host firewall on koala. Specifically: do not run
`ufw enable`, do not add a UFW block to `bootstrap/`. The package is excluded
from `bootstrap/00-packages.sh` for this reason.

### Why: Apr 24 2026 incident

UFW had been enabled on koala at some earlier point. When it was later
disabled (`ufw disable` rather than `ufw reset`), the iptables-legacy `INPUT`
chain retained `policy DROP` and the `ufw-*` chain stack. This silently broke
kube-router's network policy sync: `iptables-restore: exit status 4` errors
started appearing in the k3s journal, and pods in namespaces without a
NetworkPolicy could not reach the kube-apiserver.

A remediation script (`scripts/fix-ufw-k3s.sh`, since deleted) attempted
`ufw --force reset` followed by `ufw --force enable`. The `enable` failed
mid-load with `RULE_APPEND` errors, leaving the **nftables** `INPUT` policy
at `DROP` with **zero allow rules**. Within 13 seconds, Tailscale lost
connectivity (UDP, HTTPS, ICMP all blocked); SSH access was lost shortly
after.

The conflict was UFW writing to one iptables backend (nft) while k3s/kube-router
wrote to the other (legacy), with neither aware of the other's state.

### Apr 27 2026 follow-on incident

A separate Claude Code session attempted to recover and misread Tailscale's
standard `ip rule` priorities (5210/5230/5250/5270, table 52) as
kube-router's. It ran `ip rule flush`, removing the kernel default rules at
priorities 32766 (main) and 32767 (default) — fully blackholing IP traffic.
ARP still worked. Reboot recovered.

### Sacred rules — do not violate

- **Never enable UFW or any iptables-managing firewall** on koala. The host
  is firewalled at UCG Max + Tailscale.
- **Never delete `ip rule` priorities 5210, 5230, 5250, or 5270.** These
  are Tailscale's. They are normal. Verify with `ip route show table 52`
  if uncertain — table 52 should contain only Tailscale peer /32 routes.
- **Never run `ip rule flush`.** The kernel defaults at 32766/32767 are
  required for any IP traffic at all.

### If networking breaks while k3s is running

1. From console (TTY1) or IPMI, run `sudo systemctl stop k3s`.
2. Wait 30 seconds. Verify `ping 10.0.1.1` works.
3. If still broken: `sudo systemctl restart NetworkManager`.
4. If still broken: reboot.
5. Do **not** modify `ip rule`, `iptables`, or `nft` chains as a first
   response. Diagnose first; the cause is almost certainly something k3s
   itself installed, and stopping k3s is what reverts it.

### Out-of-band recovery

If SSH is unreachable, the recovery path is the physical console (TTY1 on
koala) or the UCG Max's UI. There is no IPMI on this hardware.

## Backup

koala runs `restic` on a systemd timer (see `scripts/restic-backup.service` and `scripts/restic-backup.timer`), backing up to **piblock** over SSH. The SSH key for piblock is provisioned in `bootstrap/06-backup.sh`.

## llama-swap

llama-swap runs on **koala** at port **31234**, managing GPU model loading/unloading.

- **Config source of truth**: `models.yml` in repo root (koala slots)
- **ConfigMap**: `k3s/apps/ai-stack/llama-swap-configmap.yaml` (generated, do not edit directly)
- **Management**: `task model:apply` regenerates ConfigMap, restarts pod, and commits
- **Status**: `task model:status` shows live vs declared state
