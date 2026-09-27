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

# --- 1b. the ghcr pull secret, BEFORE anything pulls --------------------------
#
# C1: the kubelet resolves registry credentials ONLY from imagePullSecrets. It
# never reads containerd's /etc/rancher/k3s/registries.yaml -- that file is what
# `crictl pull` uses, which is why the same image pulls fine by hand and 403s
# from a Pod. Re-proven on this node 2026-09-27, same image, same minute:
#
#   crictl pull ghcr.io/dexidp/dex:v2.45.1   -> success
#   kubelet (no imagePullSecret)             -> 403, 3 of 3 reproducible
#
# Argo CD ships dex pinned to a ghcr image and ships no pull secret, so this
# namespace needs its own. It must exist BEFORE install.yaml is applied: the
# kubelet attempts the pull the moment the Deployment is created, and a failure
# there puts dex into ImagePullBackOff, which makes a working install look
# broken and hides the real problem behind a noisy one.
#
# The source of truth is the same one 50-gitops.sh uses (~/.docker/config.json),
# because that is where the operator's ghcr login already lives. Obtaining the
# credential by a second route would mean two things to keep in sync.
#
# WHY THIS BLOCK REPLACED THE OLD ONE: the previous version was guarded by
# `[ -n "${GHCR_PULL_SECRET_SOURCE:-}" ]`, a variable set nowhere in this repo,
# and it read the secret from askvault-prod -- a namespace created by
# 50-gitops.sh, script 8 of 10. Both defects were invisible until argocd was
# torn down and rebuilt cold, at which point dex went to ErrImagePull and the
# assertion at the bottom of this script fired. The check was right; the setup
# was wrong.
if sudo -E k3s kubectl -n "$ARGOCD_NS" get secret ghcr-pull >/dev/null 2>&1; then
  ok "ghcr-pull already present in $ARGOCD_NS"
elif [ -f "$HOME/.docker/config.json" ] \
   && grep -q '"ghcr.io"' "$HOME/.docker/config.json" 2>/dev/null; then
  auth="$(jq -r '.auths["ghcr.io"].auth' "$HOME/.docker/config.json" 2>/dev/null || true)"
  if [ -n "$auth" ] && [ "$auth" != "null" ]; then
    ghcr_user="$(printf '%s' "$auth" | base64 -d 2>/dev/null | cut -d: -f1)"
    ghcr_token="$(printf '%s' "$auth" | base64 -d 2>/dev/null | cut -d: -f2-)"
    if sudo -E k3s kubectl -n "$ARGOCD_NS" create secret docker-registry ghcr-pull \
         --docker-server=ghcr.io \
         --docker-username="$ghcr_user" \
         --docker-password="$ghcr_token" \
         --dry-run=client -o yaml \
         | sudo -E k3s kubectl apply -f - >/dev/null 2>&1; then
      ok "ghcr-pull created in $ARGOCD_NS (from ~/.docker/config.json)"
    else
      fail "could not create ghcr-pull in $ARGOCD_NS -- dex will not pull"
    fi
  else
    fail "$HOME/.docker/config.json has no usable ghcr.io auth entry.
Log in first:
  echo \$TOKEN | docker login ghcr.io -u <user> --password-stdin
Without it dex cannot pull and this script cannot succeed."
  fi
else
  fail "no $HOME/.docker/config.json with a ghcr.io entry.
Argo CD's dex image is on ghcr and the kubelet needs an imagePullSecret (C1).
Log in first:
  echo \$TOKEN | docker login ghcr.io -u <user> --password-stdin"
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
# The secret is created above, before install.yaml. Nothing to propagate here.
# The service-account attachment below is still required: the kubelet reads
# imagePullSecrets from the ServiceAccount as well as the pod spec, and Argo CD
# ships ServiceAccounts whose pod specs we do not control.

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
# WAIT for dex; do not sample it once. An earlier version read readyReplicas a
# single time and failed the script while dex was still pulling -- the
# deployment was Ready seconds later. A check that samples a transient state and
# calls it a verdict is the same defect that produced three false failures in
# 31-monitoring.sh.
note "waiting for argocd-dex-server to become Ready (up to 180s)"
dex_ready=0
for _ in $(seq 1 60); do
  dex_ready="$(sudo -E k3s kubectl -n "$ARGOCD_NS" get deploy argocd-dex-server \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [ "${dex_ready:-0}" -ge 1 ] && break
  sleep 3
done

if [ "${dex_ready:-0}" -ge 1 ]; then
  ok "argocd-dex-server ready"
else
  # Distinguish the causes rather than assuming the usual one. Both end in
  # "no ready replica" and they have different fixes.
  dex_reason="$(sudo -E k3s kubectl -n "$ARGOCD_NS" get pods \
    -l app.kubernetes.io/name=dex \
    -o jsonpath='{.items[0].status.containerStatuses[0].state}' 2>/dev/null || true)"
  secret_present=no
  sudo -E k3s kubectl -n "$ARGOCD_NS" get secret ghcr-pull >/dev/null 2>&1 && secret_present=yes

  fail "argocd-dex-server has no ready replica after 180s.
ghcr-pull secret in $ARGOCD_NS: $secret_present
pod state: ${dex_reason:-<unreadable>}

If the pod state is waiting/ErrImagePull/ImagePullBackOff with a 403 from
ghcr.io, this is the kubelet credential path (C1): the kubelet resolves
credentials ONLY from imagePullSecrets and never reads containerd's
registries.yaml. Check that the secret exists AND is attached:
  kubectl -n $ARGOCD_NS get secret ghcr-pull
  kubectl -n $ARGOCD_NS get sa argocd-dex-server -o jsonpath='{.imagePullSecrets}'
If the secret is present and attached but the pull still 403s, the credential
inside it is stale -- re-login and recreate it.
If the pod state shows something else (CrashLoopBackOff, config error), the
image pulled and the problem is not credentials."
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
