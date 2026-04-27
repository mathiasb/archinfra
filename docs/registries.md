# Container registries

The koala cluster uses two registries with different ownership models.

## Gitea registry — `gitea.d-ma.be`

Default registry for all Flux-managed apps. Authenticated, TLS, fronted by NPM.

- **Apps using it**: `supervisor`, `ingestion`, `infra-mcp`
- **Image format**: `gitea.d-ma.be/mathias/<repo>:<sha>`
- **Push creds**: `REGISTRY_CREDS` Gitea org secret (`mathias:<token>`)
- **Pull creds**: SOPS-encrypted `gitea-registry` Secret in each app namespace, sourced from `k3s/apps/imagepullsecret/secret.enc.yaml`
- **CD flow**: see `docs/cd-pipeline.md` — buildctl → skopeo push → CI patches `infra` repo → Flux reconciles

## Local registry — `localhost:5000`

In-cluster Docker registry with `hostNetwork: true` so it binds directly to
koala's `localhost:5000`. Used for fast-iteration apps where the round-trip
through Gitea + Flux would slow development meaningfully.

- **Manifest**: `k3s/apps/registry/` (Flux-managed since v0.2.0)
- **Storage**: hostPath `/var/lib/registry` on koala
- **TLS**: none (plain HTTP) — k3s containerd is configured to allow
  insecure pulls via `/etc/rancher/k3s/registries.yaml` (provisioned at
  bootstrap from `scripts/k3s-registries.yaml`)
- **Apps using it**: `cobalt-dingo`
- **Image format**: `localhost:5000/<name>:<sha>` and `:<semver-tag>`

### Why hostNetwork?

containerd (the image puller) runs on the koala host. When containerd sees
an image reference like `localhost:5000/cobalt-dingo:abc123`, it resolves
`localhost` to `127.0.0.1` on the host. The registry pod must therefore
bind on the host's network namespace, not the pod network. Hence
`hostNetwork: true` + `hostPort: 5000`.

A `Service` would not help — containerd doesn't go through cluster DNS.

### Constraint: pods using `localhost:5000` images must run on koala

Other nodes (when added) won't have a `localhost:5000` registry. Any
deployment using a `localhost:5000` image must pin to koala via:
```yaml
nodeSelector:
  kubernetes.io/hostname: koala
```

If the cluster expands beyond a single node, options are:
1. Run the registry as a DaemonSet (pulls duplicated per-node)
2. Switch the apps to `gitea-registry` (Gitea-fronted, multi-node-friendly)
3. Reconfigure `registries.yaml` to point at koala's tailscale IP

### Bootstrap

A fresh koala bootstrap configures k3s for the local registry by copying
`scripts/k3s-registries.yaml` to `/etc/rancher/k3s/registries.yaml` (see
`bootstrap/03-k3s.sh`). The registry pod itself is then deployed by Flux
as part of the `apps` Kustomization.

The `cobalt-dingo` repo previously contained `scripts/setup-koala-registry.sh`
that performed the same steps; that script is obsolete and should be removed
from cobalt-dingo. The registry is now Flux-managed.
