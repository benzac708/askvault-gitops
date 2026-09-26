#!/usr/bin/env bash
# 20-argocd.sh — install Argo CD, then install the argocd CLI.
#
# WHY --server-side --force-conflicts IS MANDATORY HERE:
#
#   Argo CD's install.yaml contains CRDs whose schemas exceed the 262144-byte
#   limit on the `kubectl apply` client-side annotation. A plain `kubectl apply`
#   fails with "metadata.annotations: Too long". This is not a formatting
#   preference; without the flag the install simply does not complete.
#
#   The first drill attempt lost time to this because the error message points
#   at the annotation, not at the size limit. Finding 4.
#
# WHY THE CLI IS DOWNLOADED AS A BINARY RATHER THAN `curl | sh`:
#   same supply-chain reason as 10-k3s.sh, and the version must match the
#   server or `argocd app` subcommands report confusing gRPC errors.
#
# IDEMPOTENT: re-applying install.yaml of the same version is a no-op.

set -euo pipefail

readonly ARGOCD_VERSION="v3.5.3"
readonly ARGOCD_NS="argocd"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '  ok   %s\n' "$1"; }
note() { printf '  ..   %s\n' "$1"; }

export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

printf '== argocd ==\n'

# --- 1. the argocd CLI binary -------------------------------------------------
if command -v argocd >/dev/null 2>&1; then
  note "argocd CLI present: $(argocd version --client --short 2>/dev/null || echo unknown)"
else
  note "installing argocd CLI $ARGOCD_VERSION"
  curl -fsSL -o /tmp/argocd \
    "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-arm64"
  install -m 0755 /tmp/argocd "$HOME/.local/bin/argocd"
  rm -f /tmp/argocd
fi
command -v argocd >/dev/null 2>&1 || fail "argocd CLI not on PATH after install"
ok "argocd CLI: $(argocd version --client --short 2>/dev/null || echo present)"

# --- 2. the server ------------------------------------------------------------
if sudo -E k3s kubectl get ns "$ARGOCD_NS" >/dev/null 2>&1; then
  note "namespace $ARGOCD_NS already exists"
else
  sudo -E k3s kubectl create namespace "$ARGOCD_NS"
fi

note "applying Argo CD $ARGOCD_VERSION (server-side; see the header for why)"
curl -fsSL -o /tmp/argocd-install.yaml \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
sudo -E k3s kubectl apply -n "$ARGOCD_NS" --server-side --force-conflicts \
  -f /tmp/argocd-install.yaml
rm -f /tmp/argocd-install.yaml

note "waiting for argocd-server (up to 300s)"
sudo -E k3s kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-server --timeout=300s

# --- 3. assert it is really up, not merely applied ---------------------------
# An Application CRD that exists but whose controller is crash-looping produces
# a cluster that looks installed and reconciles nothing. Check the controller.
#
# C1 REACHES THIS SCRIPT TOO, and it is now understood well enough to state
# exactly. Argo CD's dex-server image is `ghcr.io/dexidp/dex`, and the kubelet's
# anonymous ghcr token request returns 403 on this node. The isolation, proven
# by testing three clients minutes apart on the same image:
#
#   docker pull   succeeds  (reads the docker config `auth` and decodes it)
#   crictl pull   succeeds  (reads containerd registries.yaml)
#   kubelet pull  403       (resolves credentials ONLY from imagePullSecrets)
#
# The kubelet does not consult containerd's registry config when resolving pull
# credentials. That is why a node-level registries.yaml did nothing, and why
# an imagePullSecret is not a workaround but the actual mechanism. Every
# namespace that pulls a ghcr image needs one.
#
# Argo CD does not ship one, so dex sits in ErrImagePull and the install looks
# broken. Fix it the same way as the application namespaces.
if [ -n "${GHCR_PULL_SECRET_SOURCE:-}" ]; then
  note "propagating a ghcr pull secret into $ARGOCD_NS (see the C1 note above)"
  sudo -E k3s kubectl -n askvault-prod get secret ghcr-pull -o yaml 2>/dev/null \
    | grep -vE '^\s+(resourceVersion|uid|creationTimestamp|namespace):' \
    | sudo -E k3s kubectl apply -n "$ARGOCD_NS" -f - >/dev/null \
    && ok "ghcr-pull copied into $ARGOCD_NS" \
    || note "no ghcr-pull in askvault-prod yet — dex may stay in ErrImagePull"
fi

# Attach it to every service account that runs a ghcr image. The kubelet reads
# imagePullSecrets from the SERVICE ACCOUNT as well as the pod spec, so this
# covers pods whose manifests we do not control (Argo CD ships its own).
if sudo -E k3s kubectl -n "$ARGOCD_NS" get secret ghcr-pull >/dev/null 2>&1; then
  for sa in argocd-dex-server argocd-application-controller argocd-repo-server \
            argocd-server argocd-applicationset-controller argocd-notifications-controller; do
    if sudo -E k3s kubectl -n "$ARGOCD_NS" get sa "$sa" >/dev/null 2>&1; then
      sudo -E k3s kubectl -n "$ARGOCD_NS" patch sa "$sa" \
        -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}' >/dev/null 2>&1 \
        && ok "ghcr-pull attached to sa/$sa"
    fi
  done
  # Restart so the kubelet re-resolves with the new secret.
  sudo -E k3s kubectl -n "$ARGOCD_NS" rollout restart deploy/argocd-dex-server >/dev/null 2>&1 || true
fi

for d in argocd-server argocd-repo-server argocd-applicationset-controller; do
  ready="$(sudo -E k3s kubectl -n "$ARGOCD_NS" get deploy "$d" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [ "${ready:-0}" -ge 1 ] || fail "$d has no ready replica"
  ok "$d ready"
done

# dex is not optional in the sense that matters here: Argo CD ships it, and a
# dex stuck in ErrImagePull makes the install look broken and hides a real
# problem behind a noisy one. Check it explicitly rather than letting it fail
# silently in a `get pods` listing nobody reads.
dex_ready="$(sudo -E k3s kubectl -n "$ARGOCD_NS" get deploy argocd-dex-server \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
if [ "${dex_ready:-0}" -ge 1 ]; then
  ok "argocd-dex-server ready"
else
  fail "argocd-dex-server has no ready replica — almost always the kubelet ghcr 403.
Fix: copy a ghcr-pull secret into $ARGOCD_NS and attach it to the
argocd-dex-server ServiceAccount, then restart the deployment. See the C1 note
above for why containerd's registries.yaml does NOT solve this."
fi

sudo -E k3s kubectl -n "$ARGOCD_NS" get pods

# --- 4. the CRDs the later scripts depend on ---------------------------------
for crd in applications.argoproj.io appprojects.argoproj.io; do
  sudo -E k3s kubectl get crd "$crd" >/dev/null 2>&1 \
    || fail "CRD $crd missing — 50-gitops.sh cannot work"
  ok "CRD $crd present"
done

printf '\nARGOCD OK — the initial admin password is in secret argocd-initial-admin-secret\n'
printf 'Retrieve it with:\n'
printf "  sudo -E k3s kubectl -n %s get secret argocd-initial-admin-secret \\\\\n" "$ARGOCD_NS"
printf "    -o jsonpath='{.data.password}' | base64 -d\n"
