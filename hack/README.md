# hack/ - the rebuild, scripted

One command rebuilds the whole platform:

```bash
bash ~/repos/askvault/hack/rebuild.sh
```

It travels no credentials at all now - the secrets are Sealed Secrets in Git, decrypted in-cluster; it instead confirms the sealed manifests exist, then runs every step in
dependency order, stops at the first failure, and exits non-zero if any step
failed. `--from <step>`, `--only <a,b>` and `--list` narrow it.

The **whole drill** - destroy the host to 0%, then rebuild it and gate the
result - is also one command:

```bash
bash ~/repos/askvault/hack/rebuild.sh --from-zero --yes
```

That runs `90-teardown.sh --yes` first and then all nine steps. It is the only
mode that destroys the cluster, so it requires a typed `yes` (or `--yes`) and
refuses without a terminal. Use it rather than running `90-teardown.sh` and
then typing the rebuild by hand: that seam used to be bridged by a hand-typed
list printed at the bottom of the teardown, and the list had already drifted.

The scripts are numbered so the **sort order is the dependency order**. Each one
is idempotent, declares its prerequisite, and asserts its own result rather
than trusting that a command succeeded.

| Script | Does | Prerequisite |
|---|---|---|
| `00-preflight.sh` | Verify host facts, ports, tooling. Changes nothing. | bare host |
| `10-k3s.sh` | k3s, Traefik disabled, kubeconfig 0600 | 00 |
| `20-argocd.sh` | Argo CD, server-side apply; argocd CLI | 10 |
| `30-traefik.sh` | Traefik v3 as NodePort, CRDs on (IngressRoute + Middleware), endpoint published | 10 |
| `40-cloudflare.sh` | Tunnel ingress rule → NodePort 30080 | 30 |
| `45-reset-app.sh` | **Drop the app layer** (2 Applications, 2 namespaces) so 50 builds it from nothing. Skips on a clean host. | 20, 40 |
| `50-gitops.sh` | Deploy key, repo registration, AppProject + Applications, both secrets | 20, 40, 45 |
| `31-monitoring.sh` | kube-prometheus-stack, ServiceMonitor, estate Grafana wiring | 50 |
| `rebuild.sh` | **Runs the whole rebuild in order.** `--from-zero` tears down first. Not a step in it. | - |
| `90-teardown.sh` | Destroy in the correct order. Dry-run by default. Ends by printing one command. | - |
| `95-export-sanitise.sh` | Render section 6 for publication; **fails** on any hostname leak | - |
| `99-acceptance.sh` | The drill gate. Read-only. | 50, 31 |
| `rebuild.test.sh` | Unit tests for the orchestrator. Touches no cluster. | - |

## Order that matters

```
rebuild:   00 → 10 → 20 → 30 → 40 → 45 → 50 → 31 → 99   (or: hack/rebuild.sh)
from-zero: 90-teardown --yes → then the nine steps above  (hack/rebuild.sh --from-zero --yes)
teardown:  Applications → app namespaces → helm releases → argocd ns → CRDs
```

The **number prefix is thematic, not positional**, and `31` and `45` are both
proof of it. `31-monitoring.sh` runs *after* `50-gitops.sh`, because a
ServiceMonitor has nothing to scrape until the Deployment it watches exists.
`45-reset-app.sh` runs *before* `50-gitops.sh`, because a warm namespace makes
`50` take its "already exists" branch. Sorting the directory and running
whatever comes out gives a green run with an empty dashboard and - the same
defect, quieter - a green run whose secrets were written into a namespace the
run never created. `rebuild.sh` is the only place the order is encoded; do not
reconstruct it from the filenames.

The teardown order is not cosmetic. An Argo `Application` carries a finalizer;
delete the `argocd` namespace first and nothing is left to remove it, so the
namespace sits in `Terminating` forever **with no error message**. The same
class of trap applies to any operator that owns CRs.

## Why `45-reset-app.sh` exists

Without it, a rebuild inherits the previous run's namespaces. `50-gitops.sh`
handles both cases and prints `ok` for both:

```
namespace already exists  ->  "namespace askvault-prod already exists"    ok, exit 0
namespace absent          ->  "namespace askvault-prod created up front"  ok, exit 0
```

Only the second is evidence that the from-scratch path works, and the first
looks exactly as convincing. So every rebuild after the first would quietly
prove less than the one before it - and "already exists" is why finding 21a
survived a run that was supposed to have fixed it: the fix was correct, and the
run never reached the code it changed.

`45` makes "from nothing" the default on every run. Two properties worth
knowing before you touch it:

- **It deletes the Application before the namespace.** The Application is the
  object that recreates the namespace (`syncOptions CreateNamespace=true`), so
  deleting the namespace first is a race Argo wins within seconds - and then
  `50` takes the "already exists" branch and proves nothing. Verified: zero
  Applications and zero namespaces reappeared in the 20s after the delete.
- **It skips itself on a clean host** - no k3s binary, no cluster, or no Argo
  means "nothing to reset", and that is the *common* case after a real
  `90-teardown.sh`. A step that failed on a clean host would make the from-zero
  path untestable, which is a poor trade for the one step whose entire job is to
  make that path testable.
- **It waits, bounded.** Namespaces really take ~30s to finish terminating. The
  poll prints progress and the timeout carries the diagnosis (an Application and
  a Namespace that will not delete have opposite causes), rather than hanging
  where a hang is indistinguishable from slowness.

To confirm a cold run, look for `created up front` on **both** namespaces in the
`50-gitops` output. If you see `already exists`, the app layer was not cold when
`50` ran and that run proves less than it appears to.

## Why bash and not Terraform

Deliberate, and worth stating rather than leaving as an implied preference.
This is a single-VPS drill; GitOps owns everything after bootstrap. The scripts
exist so the rebuild is reproducible, not because bash is the right answer at
scale - it has no state tracking, no plan/apply, and no drift detection.
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
   A plain `rebuild.sh` is the deliberate exception: `45-reset-app.sh` deletes
   two Applications and two namespaces, and plain `rebuild.sh` takes no
   `--yes`. That asymmetry is the point - `45` is scoped to two namespaces by
   name and rebuilt six steps later, whereas `90` takes the cluster itself.
   A confirmation prompt belongs where the blast radius is unrecoverable, not
   on a step that restores what it removes.

   `--from-zero` removes the asymmetry, because it runs `90` inside `rebuild.sh`.
   So it asks for a typed `yes`, and refuses outright without a tty. `--yes` is
   **rejected when it appears without `--from-zero`** rather than quietly
   ignored: a flag that authorises nothing while claiming to authorise
   something is worse than no flag at all.

   Two more rules `--from-zero` obeys, each because the alternative is a way to
   lose a working host:
   - **The credential is collected before the teardown.** A missing key must
     not be learned by destroying the cluster that could have asked again.
   - **It requires `99-acceptance` in the selection.** `--from-zero --only
     10-k3s` would destroy everything and rebuild a fragment, then call it
     success. That is a mistake, not a use case, so it is refused.
7. **The orchestrator counts failures.** `for s in …; do … || break; done`
   exits **0** when a step fails, because `break` leaves the loop's status at
   zero and `set -e` exempts the left side of `||`. That makes a rebuild that
   died at `50-gitops` report success. `rebuild.sh` keeps a failure count and
   exits non-zero. A gate that fails open is worse than no gate at all.
8. **Collect credentials, don't demand them.** `rebuild.sh` prompts for
   `OPENROUTER_API_KEY` at a hidden `read -rs` when stdin is a terminal, uses
   the variable when it is already set, and refuses with instructions when
   stdin is not a terminal. It used to only refuse, which turned the one
   command that rebuilds everything into two commands and put a hand-typed
   secret on the command line where it lands in shell history. The prompted
   value is `export`ed so the child `50-gitops.sh` sees it and does not ask a
   second time. An empty key is refused: an empty Secret value satisfies a
   required `secretKeyRef`, so the pod would start and answer nothing.
9. **A sequence written twice is wrong in one of the two places.** The teardown
   used to end by printing a hand-typed copy of the rebuild order - and it was
   already missing `45-reset-app.sh`. That copy is what a reader is told to
   follow at the exact moment they have destroyed their cluster, and following
   it rebuilt a warm app layer, so the run never reached the code finding 21a
   was about. Same shape as 21a: a green run that quietly proved less than it
   claimed. There is no list at the bottom of `90-teardown.sh` now. It prints
   one command, and `rebuild.sh` prints the order. Nothing to keep in sync.
10. **"0%" has to be true of every copy.** The teardown verified
    `/etc/rancher/k3s/k3s.yaml` was gone and called the host clean - while a
    second copy of the same cluster-admin credential sat in `~/.kube/config`,
    installed by the finding 23 fix, which the teardown did not know about. The
    check covered the file the reader thinks of and not the file the reader
    uses. A credential is a credential wherever it is kept, so the teardown now
    removes it and asserts on it (`--keep-k3s` is the exception: the cluster
    survives, so its credential must too).

## Tests

The orchestrator is the part that has broken most often, so it is the part
with tests:

```bash
bash ~/repos/askvault/hack/rebuild.test.sh
```

51 assertions, no cluster, no network, a few seconds. It drives the real
`rebuild.sh` and `90-teardown.sh` with stubbed steps and asserts on **the
order things happened in** - in particular that a missing credential refuses
*before* the teardown runs, which is the property that stops a missing key from
costing you a working cluster. Run it after any edit to either script.

## What these scripts cannot reproduce

Three things are account- or host-specific and are **not** recreated by any
script here. Say so rather than implying otherwise:

1. The Cloudflare tunnel (`prod-zachara-tunnel`) - a named object on an account.
2. The DNS record for the public hostname - Cloudflare-side.
3. The image is `linux/arm64` **only**; it will not pull on x86.

`40-cloudflare.sh` configures a tunnel that already exists. It does not create
one, and cannot.
