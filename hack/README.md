# hack/ — the rebuild, scripted

Numbered so the **sort order is the dependency order**. Each script is
idempotent, declares its prerequisite, and asserts its own result rather than
trusting that a command succeeded.

| Script | Does | Prerequisite |
|---|---|---|
| `00-preflight.sh` | Verify host facts, ports, tooling. Changes nothing. | bare host |
| `10-k3s.sh` | k3s, Traefik disabled, kubeconfig 0600 | 00 |
| `20-argocd.sh` | Argo CD, server-side apply; argocd CLI | 10 |
| `30-traefik.sh` | Traefik v3 as NodePort, CRDs off, endpoint published | 10 |
| `40-cloudflare.sh` | Tunnel ingress rule → NodePort 30080 | 30 |
| `50-gitops.sh` | Deploy key, repo registration, AppProject + Applications | 20, 40 |
| `31-monitoring.sh` | kube-prometheus-stack, ServiceMonitor, estate Grafana wiring | 50 |
| `rebuild.sh` | **Runs the whole rebuild in order.** Not a step in it. | — |
| `90-teardown.sh` | Destroy in the correct order. Dry-run by default. | — |
| `95-export-sanitise.sh` | Render section 6 for publication; **fails** on any hostname leak | — |
| `99-acceptance.sh` | The drill gate. Read-only. | 50, 31 |

## Order that matters

```
rebuild:   00 → 10 → 20 → 30 → 40 → 50 → 31 → 99   (or: hack/rebuild.sh)
teardown:  Applications → app namespaces → helm releases → argocd ns → CRDs
```

The **number prefix is thematic, not positional.** `31-monitoring.sh` runs
after `50-gitops.sh`, because a ServiceMonitor has nothing to scrape until
the Deployment it watches exists. Sorting the directory and running whatever
comes out gives a green run with an empty dashboard. `rebuild.sh` is the
only place the order is encoded; do not reconstruct it from the filenames.

The teardown order is not cosmetic. An Argo `Application` carries a finalizer;
delete the `argocd` namespace first and nothing is left to remove it, so the
namespace sits in `Terminating` forever **with no error message**. The same
class of trap applies to any operator that owns CRs.

## Why bash and not Terraform

Deliberate, and worth stating rather than leaving as an implied preference.
This is a single-VPS drill; GitOps owns everything after bootstrap. The scripts
exist so the rebuild is reproducible, not because bash is the right answer at
scale — it has no state tracking, no plan/apply, and no drift detection.
Idempotency is written by hand here, which is exactly the work Terraform would
do for you. Naming the gap is worth more than pretending there isn't one.

## Rules these scripts follow

1. **`set -euo pipefail`** on every one.
2. **`export PATH="$HOME/.local/bin:$PATH"`.** Non-interactive SSH does not
   source `.profile`, so `uv`, `trivy`, `helm` and `argocd` are "command not
   found" even though they work interactively.
3. **Never `curl | sh`.** Installers are downloaded, then executed.
4. **Read the rendered object back.** `--set` does not validate key paths, so a
   typo is accepted and silently ignored. Every script asserts on the running
   Deployment, not on the command it just ran.
5. **Assert from outside.** A probe that returns 200 in-cluster is a different
   claim from the same path returning 404 at the edge. Both are checked.
6. **Destruction requires `--yes`.** `90-teardown.sh` is dry-run by default.
7. **The orchestrator counts failures.** `for s in …; do … || break; done`
   exits **0** when a step fails, because `break` leaves the loop's status at
   zero and `set -e` exempts the left side of `||`. That makes a rebuild that
   died at `50-gitops` report success. `rebuild.sh` keeps a failure count and
   exits non-zero. A gate that fails open is worse than no gate at all.

## What these scripts cannot reproduce

Three things are account- or host-specific and are **not** recreated by any
script here. Say so rather than implying otherwise:

1. The Cloudflare tunnel (`prod-zachara-tunnel`) — a named object on an account.
2. The DNS record for the public hostname — Cloudflare-side.
3. The image is `linux/arm64` **only**; it will not pull on x86.

`40-cloudflare.sh` configures a tunnel that already exists. It does not create
one, and cannot.
