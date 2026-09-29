# askvault-gitops

GitOps source of truth for the AskVault estate: Argo CD reconciles the
`askvault-prod` and `askvault-dev` applications on a single-node k3s from this
repository. The application code, tests and CI live in the separate
[`askvault`](https://github.com/benzac708/askvault) repository.

**Live:** https://askvault.zachara.dev

## Why two repositories

| Repository | Contains | Why separate |
|---|---|---|
| `askvault` | Application code, tests, Dockerfile, CI | Written by developers, changes often |
| `askvault-gitops` | Kustomize base, overlays, Argo objects | Read by a cluster at elevated privilege, changes rarely |

The split is a least-privilege boundary: the credential Argo CD holds is a
read-only deploy key scoped to this repository alone. The thing that can
write to the cluster cannot be pushed to by a developer.

## Layout

```
base/                       shared posture: deployment, service, ingress,
                            configmap, servicemonitor, kustomization
overlays/
  dev/                      rolling :main tag, relaxed rate ceilings (mock)
  prod/                     pinned sha, public hostname, openrouter config
argo/                       AppProject + Applications (prod + dev)
hack/                       scripted teardown-and-rebuild, acceptance tests
```

## Promotion

CI publishes `sha-<commit>` and `main` images to ghcr. Prod pins an immutable
tag in `overlays/prod/kustomization.yaml`; promotion is a one-line `newTag`
edit, and rollback is the same line pointing at the previous tag. Argo CD
reconciles with `automated` sync, `prune` and `selfHeal`, so hand-drift is
corrected without being asked.

The difference between dev and prod is namespace, environment label, the three
LLM config keys, the rate ceilings, and the hostname - nothing else. That
constraint is enforced by review, not by a tool; see the base/overlay comments
for what that means in practice.

## Security posture

- Containers run as UID 10001, non-root, with `readOnlyRootFilesystem`,
  dropped capabilities, seccomp, and a measured resource envelope (see
  `base/deployment.yaml`).
- D32 rate ceilings (10 req/min per IP, 15/min and 40/day global) sit below
  the provider's own quota, so the app refuses before the provider does.
- L2 edge: only `/` and `/chat` are routed publicly under the
  `askvault.zachara.dev` host. `/healthz`, `/readyz` and `/metrics` are
  deliberately unreachable from outside the cluster (kubelet and Prometheus
  reach them in-cluster).
- Config is a ConfigMap; the credential is a Secret injected out of band and
  never appears in this repository. Missing Secret or ConfigMap fails the pod
  loudly (`optional` is never set), rather than silently falling back to the
  mock provider.

## CI

`.github/workflows/verify.yml` renders both overlays with checksum-pinned
kustomize on push and pull request. It is currently dormant: the account's
private-repo GitHub Actions minutes are blocked by a failed-payment state, so
this workflow will not run until that is resolved. The same state is why the
application's CI is gated locally via `act` (see the `askvault` README).

## Rebuild

The whole node-and-app lifecycle is scripted in `hack/`, numbered so sort
order is dependency order:

```bash
hack/00-preflight.sh      # verify host facts, enumerate occupied ports
hack/10-k3s.sh            # install k3s (Traefik disabled; Caddy owns 80/443)
hack/20-argocd.sh         # install Argo CD
hack/30-traefik.sh        # Traefik as NodePort 30080/30443
hack/40-cloudflare.sh     # tunnel routes
hack/50-gitops.sh         # apply the Argo objects from this repo
hack/90-teardown.sh       # delete in the correct order
hack/99-acceptance.sh     # the drill asserts
```

`hack/rebuild.test.sh` runs 52 assertions, no cluster, no network. Teardown
order is load-bearing: Argo `Application` objects are deleted before the
`argocd` namespace so an ImageUpdater finalizer cannot deadlock the deletion.

The host edge (Caddy + cloudflared + DNS) is a VPS-level concern tracked in
the estate repo (`services/caddy/Caddyfile`), not here - this repository owns
everything after bootstrap.