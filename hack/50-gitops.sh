#!/usr/bin/env bash
# 50-gitops.sh - register the gitops repo with Argo CD and apply the Argo
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
#   project exists to enforce - creating a Namespace grants no permission over
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
[ -d "$LOCAL_GITOPS/argo" ] || fail "$LOCAL_GITOPS/argo not found - clone the gitops repo first"
note "pulling the gitops repo so the applied objects match what is committed"
# Fetch and hard-reset the TRACKED files, rather than `pull --ff-only`.
  #
  # BUG FOUND 2026-09-27: `pull --ff-only` aborts if ANY file in the worktree is
  # dirty, and under `set -e` that killed the whole script. It failed on an
  # unrelated local edit to a copy of this very script, meaning a rebuild could
  # be blocked by anything -- and the failure looked like a git problem rather
  # than "the rebuild did not finish".
  #
  # A rebuild should trust Git over whatever happens to be lying in the working
  # tree: the repos ARE the source of truth. So this fetches and resets tracked
  # files to origin. Untracked files are left alone, so nothing a person created
  # by hand is destroyed.
  note "syncing the gitops worktree to origin (tracked files only)"
  git -C "$LOCAL_GITOPS" fetch --quiet origin || fail "cannot fetch $LOCAL_GITOPS"
  git -C "$LOCAL_GITOPS" reset --hard --quiet origin/main \
    || fail "cannot reset $LOCAL_GITOPS to origin/main"
  if [ -n "$(git -C "$LOCAL_GITOPS" status --porcelain --untracked-files=no)" ]; then
    fail "$LOCAL_GITOPS still differs from origin/main after reset - refusing to apply an unknown state"
  fi
  ok "gitops worktree at $(git -C "$LOCAL_GITOPS" rev-parse --short HEAD)"

sudo -E k3s kubectl apply -f "$LOCAL_GITOPS/argo/appproject.yaml" \
                          -f "$LOCAL_GITOPS/argo/applications.yaml"
ok "AppProject and Applications applied from $LOCAL_GITOPS/argo/"

# --- PREREQUISITE: the namespaces, before ANY secret -------------------------
# Both secret sections below write into these two namespaces. Argo creates them
# during its first sync, which is ASYNCHRONOUS: on a cold rebuild they do not
# exist for a second or two after the Applications are applied. Whichever
# secret block runs first loses that race.
#
# FINDING 21a (2026-09-28, first rebuild from a 0% teardown). It was not a
# race, it was an ordering bug in this file. The ghcr-pull block pre-created
# the namespace, carrying a comment that said exactly why. The askvault-llm
# block directly above it did not. Result: `kubectl -n askvault-prod create
# secret askvault-llm` returned 'namespaces "askvault-prod" not found', the
# error was discarded, the script printed GITOPS OK, and both app pods sat in
# CreateContainerConfigError for the rest of the run.
#
# Timestamps from that run, which is what makes this unambiguous rather than
# plausible: Argo created namespace askvault-prod at 11:25:32Z; this script's
# later block created ghcr-pull in it at 11:25:32Z; askvault-llm was never
# created in either namespace, before or after.
#
# Ten lines apart, same logic, opposite outcomes. That asymmetry IS the defect.
#
# So the namespace is created ONCE, here, ahead of both consumers, and
# ASSERTED rather than `|| true`. If it cannot be created then neither secret
# can be, which is precisely the state this script must refuse to pass.
APP_NS="askvault-prod askvault-dev"
for ns in $APP_NS; do
  if sudo -E k3s kubectl get namespace "$ns" >/dev/null 2>&1; then
    note "namespace $ns already exists"
  elif sudo -E k3s kubectl create namespace "$ns" >/dev/null 2>&1; then
    ok "namespace $ns created up front (Argo had not synced it yet)"
  else
    fail "could not create namespace $ns.
Both secret sections below write into it, so neither can succeed. Argo also
manages it (syncOptions CreateNamespace=true), so this should not normally
fail -- if it does, the cluster is not in the state the rest of this script
assumes and continuing would manufacture a green run over a broken one."
  fi
done

# --- 6. the LLM credential the manifests REFERENCE ------------------------

  # --- 6. the LLM credential the manifests REFERENCE ------------------------
  # Same shape as the pull secret above, missed for the same reason: created by
  # hand once, procedure never written down. On the first rebuild the app
  # reported provider=openrouter with key_len=0 -- it believed it was configured
  # for a real model, had no key, and looked completely healthy until someone
  # asked a question and got a 502.
  #
  # WHY THIS IS NOT "paste the key into a file": a file on the host puts the
  # value in a swap file, in editor history, and on disk. D13 exists so the
  # credential is injected out of band and never persisted. Real production
  # would use Sealed Secrets (encrypted in Git, reviewable in a PR) or the
  # External Secrets Operator (fetched from a KMS at runtime). This is the
  # portable primitive those are built on.
  #
  # INTERACTIVE vs UNATTENDED: a prompt would hang forever in CI, so behaviour
  # depends on whether stdin is a terminal.
  #   $OPENROUTER_API_KEY set          -> use it, prompt nothing
  #   unset, stdin IS a tty            -> prompt, silently, no echo
  #   unset, stdin is NOT a tty        -> refuse, and say exactly what to do
  need_llm=0
  for ns in $APP_NS; do
    if ! sudo -E k3s kubectl -n "$ns" get secret askvault-llm >/dev/null 2>&1; then
      need_llm=1
    fi
  done

  if [ "$need_llm" -eq 0 ]; then
    ok "askvault-llm already present in both namespaces"
  else
    key="${OPENROUTER_API_KEY:-}"
    if [ -z "$key" ] && [ -t 0 ]; then
      # -r raw, -s silent, -p prompt: no echo, no history, no file.
      printf '  ..   OpenRouter key needed (input hidden): '
      read -rs key
      printf '\n'
    fi

    if [ -z "$key" ]; then
      fail "askvault-llm is missing and no key was supplied.
Without it the app starts, reports provider=openrouter, and quietly answers with
an empty key until someone asks a question.

Non-interactive (CI, or ssh without -t):
    export OPENROUTER_API_KEY=...
    then re-run this script

Interactive (pasted at a hidden prompt; never echoed, never in shell history,
never written to any file on this host):
    read -rsp 'key: ' K && echo
    OPENROUTER_API_KEY=\$K $0
    unset K

Production would use Sealed Secrets or the External Secrets Operator so the value
never passes through a shell at all. This host has neither."
    fi

    if [ "${#key}" -lt 20 ]; then
      fail "the supplied key is only ${#key} characters -- not a real key.
Refusing to create a Secret that would fail at first use."
    fi

    for ns in $APP_NS; do
      # The apply's stderr is deliberately NOT suppressed. The previous version
      # piped it to /dev/null and then reported the failure as a note, which
      # threw away the only thing that said WHY: the API server's own message.
      # A check that cannot explain itself is a check nobody can act on.
      if sudo -E k3s kubectl -n "$ns" create secret generic askvault-llm \
           --from-literal=api-key="$key" \
           --dry-run=client -o yaml \
           | sudo -E k3s kubectl apply -f -; then
        ok "askvault-llm created in $ns"
      else
        # FINDING 21b: this was `|| note`, and a note stops nothing. The script
        # went on to print GITOPS OK over a rebuild whose app could not start.
        # The credential-missing paths above were already `fail`; this one path
        # was missed, and the commit that claimed to close it did not.
        #
        # It matters out of proportion to its size, because the Deployment
        # references this secret as a REQUIRED secretKeyRef -- no
        # `optional: true`, which was removed deliberately so a missing key is
        # a loud CreateContainerConfigError rather than a healthy pod that
        # quietly 502s at question time. So one missing Secret takes down every
        # downstream check simultaneously: readiness, healthz, the public
        # edge, the answer itself, the Prometheus target. That is how one line
        # here surfaced as 13 acceptance failures that all read like
        # independent infrastructure problems.
        #
        # Per-namespace on purpose, matching the pull secret below: one
        # namespace succeeding and one failing is a real partial state, and
        # reporting it as a pass is how a half-built rebuild gets shipped.
        fail "could not create askvault-llm in $ns.
The kubelet message this prevents is:
  Error: secret \"askvault-llm\" not found   (CreateContainerConfigError)
The API server said why above. If nothing printed above, the namespace is
missing or the API server is unreachable -- re-check section 3."
      fi
    done
    unset key
  fi
  # --- 4. the pull secret the manifests REFERENCE ----------------------------
  # base/deployment.yaml carries `imagePullSecrets: [ghcr-pull]` with no value,
  # which is correct (L1: the reference is in Git, the credential is not). But
  # something must CREATE it, and on the first rebuild nothing did -- the secret
  # had been made by hand in an earlier session and the procedure was never
  # written down. Result: everything synced, Ingress and ServiceMonitor were
  # created, and the pod sat in ImagePullBackOff with "Unable to retrieve some
  # image pull secrets (ghcr-pull)".
  #
  # That is a MISSING REBUILD STEP rather than a bug, and it is exactly the
  # hidden state this exercise exists to expose: a working system whose
  # reproducibility depended on someone remembering.
  #
  # WHY a secret at all, when the package is public: the kubelet's anonymous
  # ghcr token request returns 403 on this node, and the kubelet resolves
  # credentials ONLY from imagePullSecrets (C1).
  if [ -f "$HOME/.docker/config.json" ] \
     && grep -q '"ghcr.io"' "$HOME/.docker/config.json" 2>/dev/null; then
    auth="$(jq -r '.auths["ghcr.io"].auth' "$HOME/.docker/config.json")"
    user="$(printf '%s' "$auth" | base64 -d | cut -d: -f1)"
    token="$(printf '%s' "$auth" | base64 -d | cut -d: -f2-)"

    for ns in $APP_NS; do
      if sudo -E k3s kubectl -n "$ns" create secret docker-registry ghcr-pull \
           --docker-server=ghcr.io \
           --docker-username="$user" \
           --docker-password="$token" \
           --dry-run=client -o yaml \
           | sudo -E k3s kubectl apply -f - >/dev/null 2>&1; then
        ok "ghcr-pull present in $ns"
      else
        # Hard failure, not a note. A namespace without the pull secret cannot
        # start its app, so continuing would print "GITOPS OK" over a rebuild
        # that is visibly broken. Per-namespace on purpose: one namespace
        # succeeding and one failing is a real partial state, not a pass.
        fail "could not create ghcr-pull in $ns.
The app image is ghcr.io/benzac708/askvault and the kubelet resolves
credentials ONLY from imagePullSecrets (C1) -- containerd registries.yaml is
not consulted. Without this secret the pod sits in ImagePullBackOff."
      fi
    done
  else
    # Hard failure, matching 20-argocd.sh. The previous version only noted this
    # and carried on to print "GITOPS OK" -- a gate that announces the failure
    # it just detected, then reports success anyway. 20-argocd.sh already stops
    # earlier for the same missing credential, but this script can be run on its
    # own, and on its own it must not under-report.
    fail "no ghcr.io entry in $HOME/.docker/config.json -- cannot create the pull secret.
The app pod would sit in ImagePullBackOff, so this is not a recoverable state.
Log in first:
  echo \$TOKEN | docker login ghcr.io -u <user> --password-stdin
Same credential source 20-argocd.sh uses; this is the one undeclared
prerequisite of the whole rebuild, so it is checked at both ends."
  fi
# --- 4. the string-match assertion, which is the one that actually bites -----
proj="$(sudo -E k3s kubectl -n "$ARGOCD_NS" get appproject askvault -o jsonpath='{.spec.sourceRepos[0]}')"
[ "$proj" = "$GITOPS_URL" ] || fail "AppProject sourceRepos is '$proj', but the repo is registered as '$GITOPS_URL'.
Argo matches by string; these MUST be identical or nothing will sync."

for app in askvault-prod askvault-dev; do
  url="$(sudo -E k3s kubectl -n "$ARGOCD_NS" get application "$app" -o jsonpath='{.spec.source.repoURL}')"
  [ "$url" = "$GITOPS_URL" ] || fail "$app repoURL is '$url', expected '$GITOPS_URL'"
  ok "$app repoURL matches the registered repo"
done

printf '\nGITOPS OK - reconciliation has started.\n'
printf 'Sync + health takes up to a minute. Verify with:\n'
printf '  argocd app list\n'
printf 'Run 99-acceptance.sh once both Applications read Synced AND Healthy.\n'
