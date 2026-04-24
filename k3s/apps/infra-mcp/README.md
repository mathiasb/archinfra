# infra-mcp

Infrastructure MCP servers deployed in k3s, providing AI agents with
programmatic access to Gitea and Kubernetes via the Model Context Protocol.

## Components

| Service | Image | Port | NodePort | Purpose |
|---------|-------|------|----------|---------|
| gitea-mcp | gitea/gitea-mcp-server:nightly | 3401 | 30341 | Gitea repos, issues, PRs, actions, files |
| kubernetes-mcp | quay.io/containers/kubernetes-mcp-server:v0.0.60 | 3402 | 30342 | k3s pods, logs, deployments, events (read-only) |

## Setup

### 1. Create Gitea API token

Generate at `https://gitea.d-ma.be/user/settings/applications` with scopes:
- Repository: read
- Issue: read + write
- Organization: read
- User: read

### 2. Create encrypted secret

```bash
cd k3s/apps/infra-mcp
cp secrets.template.yaml secrets.yaml
# Edit secrets.yaml — fill in GITEA_ACCESS_TOKEN
sops -e secrets.yaml > secrets.enc.yaml
rm secrets.yaml
```

### 3. Deploy

Flux reconciles automatically once `secrets.enc.yaml` is committed.
Manual apply if needed:

```bash
kubectl apply -k k3s/apps/infra-mcp/
```

### 4. Verify

```bash
# Gitea MCP
curl -s -X POST http://koala:30341/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

# Kubernetes MCP
curl -s -X POST http://koala:30342/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

### 5. Register in agent context

Add to `~/dev/.context/mcp.json` (or per-project `.context/mcp.json`):

```json
{
  "gitea": {
    "url": "http://koala:30341/mcp",
    "description": "Gitea — repos, issues, PRs, actions, files, releases"
  },
  "kubernetes": {
    "url": "http://koala:30342/mcp",
    "description": "k3s cluster — pods, logs, deployments, events (read-only)"
  }
}
```

Then run `task context:sync` to distribute to all projects.

## Notes

- **kubernetes-mcp** runs with `--read-only` — all write operations are disabled
- **gitea-mcp** uses the official Gitea MCP server (`gitea.com/gitea/gitea-mcp`)
- The `gitea-mcp.Dockerfile` is provided for building a version-pinned image
  if the nightly tag proves unstable. Build and push to the Gitea registry:
  ```bash
  buildctl build --frontend dockerfile.v0 \
    --local context=. --local dockerfile=. \
    --opt filename=gitea-mcp.Dockerfile \
    --output type=oci,dest=/tmp/gitea-mcp.tar
  skopeo copy oci-archive:/tmp/gitea-mcp.tar \
    docker://gitea.d-ma.be/mathias/gitea-mcp:v1.1.0
  ```
- Flux CRDs (Kustomizations, GitRepositories, HelmReleases) are readable via
  the kubernetes-mcp server — the RBAC includes Flux API groups
