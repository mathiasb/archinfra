# Homelab network

## Machines

| Machine | Role | Key specs |
|---------|------|-----------|
| koala | GPU inference, k3s cluster, Gitea | RTX 5070, Arch Linux |
| iguana | Services, builds | M2 Ultra Mac |
| flamingo | Daily driver, edge | Mac mini |
| piguard | Gateway, DNS, proxy, LiteLLM | <!-- TODO: hardware --> |

All machines are connected via **Tailscale** mesh. LAN connectivity is also available on the home network.

## DNS

External DNS is managed via **Cloudflare** (see `terraform/` for zone config).

Internal DNS: <!-- TODO: document DNS resolver (Pi-hole / dnsmasq / router) and which hostnames resolve to LAN IPs internally -->

## Nginx Proxy Manager (NPM)

NPM runs on **piguard** and proxies all public-facing services.

### Proxy hosts

| Hostname | Target | Notes |
|----------|--------|-------|
| gitea.d-ma.be | koala:<!-- NodePort --> | HTTPS only — see Gitea SSH note below |
| <!-- TODO: other hosts --> | | |

### Gitea SSH access

Gitea SSH is exposed as a k3s NodePort on port **30022** on koala. HTTP/HTTPS access works via NPM. SSH git operations currently require one of:

- From within the cluster: `ssh://git@gitea-ssh.gitea.svc.cluster.local:22`
- Direct NodePort: `ssh -p 30022 git@<koala-LAN-IP>` (LAN only)
- **Recommended fix**: configure NPM TCP stream proxy to forward an external port (e.g., 2222) to koala:30022, then add SSH config on clients:
  ```
  Host gitea.d-ma.be
    Port 2222
  ```

For now, HTTPS cloning works from all machines: `https://gitea.d-ma.be/mathias/<repo>.git`

## LiteLLM

LiteLLM runs on **piguard** and provides a unified `/v1/chat/completions` endpoint routing to:
- Local models on koala via llama-swap (`http://koala:8080`)
- Cloud APIs (Anthropic, Mistral, etc.) using keys from `/etc/environment`

<!-- TODO: document LiteLLM config file location, port, and model list on piguard -->

API key for LiteLLM (`DMABE_LLMAPI_KEY`) is used by supervisor and other clients.

## llama-swap

llama-swap runs on **koala** at port **8080**, managing GPU model loading/unloading.

<!-- TODO: document llama-swap config location and loaded models -->
