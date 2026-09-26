#!/usr/bin/env bash
# 50-gitops.sh — register the gitops repo with Argo CD and apply the Argo
# objects, so the cluster starts reconciling from Git.
#
# WHY A DEPLOY KEY AND NOT A TOKEN:
#
#   The credential Argo CD holds is a read-only ed25519 deploy key scoped to
#   ONE repository. There is no long-lived token with write access to the app
#   repo or to the cluster. That is the whole point of splitting the repos, and
#   a broad PAT here would quietly undo it.
#
# WHY THE URL FORM IS LOAD-BEARING:
#
#   Argo matches `sourceRepos` and `Application.spec.source.repoURL` by STRING,
#   not by "same repo, different transport". If the repo is registered as
#   git@github.com:owner/repo.git and the AppProject names
#   https://github.com/owner/repo.git, the project permits nothing and the sync
#   is refused with a message about the project that never mentions the URL.
#   All three objects use the same SSH form for that reason.
#
# WHY THE APPPROJECT WHITELIST IS NOT EMPTY:
#
#   `clusterResourceWhitelist: []` is the stricter-looking version and it is
#   functionally broken: Namespace is a CLUSTER-scoped kind, so
#   `syncOptions: CreateNamespace=true` cannot work and auto-sync retries
#   forever with "resource :Namespace is not permitted in project". The
#   whitelist names exactly that one kind. ClusterRole, ClusterRoleBinding,
#   CRD and every other escalation primitive stay forbidden, which is what the
#   project exists to enforce — creating a Namespace grants no permission over
#   anything inside it.
#
# IDEMPOTENT: kubectl apply is declarative; `argocd repo add` is guarded by a
# pre-check because it fails on an already-registered repo.

set -euo pipefail

readonly ARGOCD_NS="argocd"
readonly GITOPS_URL="${GITOPS_URL:-git@github.com:benzac708/askvault-gitops.git}"
readonly DEPLOY_KEY="${DEPLOY_KEY:-$HOME/.ssh/argocd_gitops}"
readonly REPO_NAME="askvault-gitops"
readonly LOCAL_GITOPS="${LOCAL_GITOPS:-$HOME/repos/askvault-gitops}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '  ok   %s\n' "$1"; }
note() { printf '  ..   %s\n' "$1"; }

export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

printf '== gitops ==\n'

# --- 1. the key must PROVE itself before Argo is involved ---------------------
# Skipping this step is how a previous attempt spent an hour debugging Argo for
# a key that was never registered with GitHub at all. Test the transport, not
# only the repo name: `git ls-remote` over HTTPS succeeds via the gh credential
# helper and does NOT exercise the SSH key.
[ -f "$DEPLOY_KEY" ] || fail "deploy key not found at $DEPLOY_KEY
Generate it, then register the PUBLIC half with GitHub:
  ssh-keygen -t ed25519 -C 'argocd/askvault-gitops' -f $DEPLOY_KEY -N ''
  gh repo deploy-key add ${DEPLOY_KEY}.pub -t 'argocd-gitops-readonly' \\
    --repo benzac708/askvault-gitops"
[ -f "${DEPLOY_KEY}.pub" ] || fail "${DEPLOY_KEY}.pub not found"

note "testing the key against GitHub over SSH"
# The config on this host may pin github.com to a different IdentityFile, so
# IdentitiesOnly=yes is required or the wrong key is offered and this reports a
# false failure.
ssh_out="$(ssh -T git@github.com -i "$DEPLOY_KEY" -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new 2>&1 || true)"
case "$ssh_out" in
  *"successfully authenticated"*) ok "key authenticates: ${ssh_out##*Hi }" ;;
  *"Permission denied"*)
    fail "the key does not authenticate (${ssh_out}).
The public half is not registered on the repo. Register it:
  gh repo deploy-key add ${DEPLOY_KEY}.pub -t 'argocd-gitops-readonly' --repo benzac708/askvault-gitops
Do NOT proceed until this check passes." ;;
  *) fail "unexpected ssh result: $ssh_out" ;;
esac

note "testing read access to the gitops repo over the SAME transport"
git ls-remote "$GITOPS_URL" HEAD >/dev/null 2>&1 \
  || fail "cannot read $GITOPS_URL with $DEPLOY_KEY"
ok "read access confirmed"

# --- 2. register the repo with Argo ------------------------------------------
note "waiting for argocd-server to accept a port-forward"
sudo -E k3s kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-server --timeout=180s

# Free the port from any previous attempt. Kill by PORT, not by pattern:
# `pkill -f "port-forward svc/argocd-server"` matches its own command line and
# takes the calling shell with it.
sudo fuser -k 18443/tcp >/dev/null 2>&1 || true
nohup sudo -E k3s kubectl -n "$ARGOCD_NS" port-forward svc/argocd-server 18443:443 \
  >/tmp/argocd-pf.log 2>&1 &
# The port-forward must outlive this script if it is run over SSH, hence nohup.
# Deliberately not captured in a variable or killed on exit: 99-acceptance.sh
# reuses the same tunnel, and killing it here would make the next script fail
# for a reason that has nothing to do with the cluster.
disown 2>/dev/null || true

note "waiting for localhost:18443"
for _ in $(seq 1 30); do
  curl -sk -o /dev/null --max-time 2 https://localhost:18443/healthz && break
  sleep 1
done

pw="$(sudo -E k3s kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)"
argocd login localhost:18443 --username admin --password "$pw" --insecure >/dev/null
ok "logged in to argocd"

if argocd repo list -o url 2>/dev/null | grep -qx "$GITOPS_URL"; then
  ok "repo already registered: $GITOPS_URL"
else
  note "registering $GITOPS_URL"
  argocd repo add "$GITOPS_URL" \
    --ssh-private-key-path "$DEPLOY_KEY" \
    --name "$REPO_NAME"
  ok "repo registered"
fi

status="$(argocd repo list -o wide 2>/dev/null | awk -v u="$GITOPS_URL" '$0 ~ u {print $NF}' | head -1)"
note "repo status: ${status:-unknown}"

# --- 3. apply the Argo objects FROM THE REPO ---------------------------------
# Not from a heredoc in this script. Manifests applied only from a shell do not
# survive a teardown, and the point of this directory is that it does. The repo
# is the source of truth for its own deployment.
[ -d "$LOCAL_GITOPS/argo" ] || fail "$LOCAL_GITOPS/argo not found — clone the gitops repo first"
note "pulling the gitops repo so the applied objects match what is committed"
git -C "$LOCAL_GITOPS" pull --ff-only

sudo -E k3s kubectl apply -f "$LOCAL_GITOPS/argo/appproject.yaml" \
                          -f "$LOCAL_GITOPS/argo/applications.yaml"
ok "AppProject and Applications applied from $LOCAL_GITOPS/argo/"

# --- 4. the string-match assertion, which is the one that actually bites -----
proj="$(sudo -E k3s kubectl -n "$ARGOCD_NS" get appproject askvault -o jsonpath='{.spec.sourceRepos[0]}')"
[ "$proj" = "$GITOPS_URL" ] || fail "AppProject sourceRepos is '$proj', but the repo is registered as '$GITOPS_URL'.
Argo matches by string; these MUST be identical or nothing will sync."

for app in askvault-prod askvault-dev; do
  url="$(sudo -E k3s kubectl -n "$ARGOCD_NS" get application "$app" -o jsonpath='{.spec.source.repoURL}')"
  [ "$url" = "$GITOPS_URL" ] || fail "$app repoURL is '$url', expected '$GITOPS_URL'"
  ok "$app repoURL matches the registered repo"
done

printf '\nGITOPS OK — reconciliation has started.\n'
printf 'Sync + health takes up to a minute. Verify with:\n'
printf '  argocd app list\n'
printf 'Run 99-acceptance.sh once both Applications read Synced AND Healthy.\n'
