#!/usr/bin/env bash
# 45-reset-app.sh - put the APP LAYER back to nothing, so the run that follows
# builds it from scratch instead of inheriting it.
#
# WHY THIS EXISTS
#
#   A rebuild that inherits the previous run's namespaces is not a rebuild, it is
#   a refresh. 50-gitops.sh handles both cases and is silent about which one it
#   took:
#
#     namespace already exists -> "namespace $ns already exists", print ok, exit 0
#     namespace absent          -> "namespace $ns created up front", print ok, exit 0
#
#   Only the second line is evidence that the from-scratch path works, and the
#   first line looks exactly as convincing. So a warm app layer silently downgrades
#   every later rebuild to a weaker claim than the one you believe you are making
#   -- which is precisely how finding 21a survived a "fixed" run: the fix was right
#   and the run that "proved" it never reached the code it changed.
#
#   Until now the operator had to delete the Applications and namespaces by hand
#   before a proving run. That is test scaffolding wearing a workflow's clothes,
#   and it made the honest thing (a from-zero run) cost five lines of preamble
#   while the default thing (just press rebuild) quietly proved less. This step
#   is the workflow: `rebuild.sh` alone now means "from nothing" on every run, and
#   the from-scratch path is exercised every time by construction rather than by
#   remembering.
#
# WHAT IT TOUCHES -- exactly two names, in two scopes:
#   Application/<name> in namespace argocd, for name in: askvault-prod askvault-dev
#   Namespace/<name>,                     for name in: askvault-prod askvault-dev
#   Nothing else. No node, no storage, no CRD, no other namespace, no other
#   Application, no estate service. 90-teardown.sh has vastly wider authority and
#   is gated behind --yes; this is narrow enough to be unconditional, and the run
#   rebuilds everything it drops six steps later.
#
#   The Application and the Namespace deliberately share a name in this project,
#   so one loop finds both. The two lists are still collected SEPARATELY and
#   asserted separately below, because "Application deleted but namespace still
#   terminating" and the reverse are different failures with different fixes, and
#   a combined check would report them as one indistinguishable "not cold".
#
# WHY IT SKIPS ITSELF
#   A real 90-teardown.sh run lands here with no cluster at all, and a resume from
#   before step 20 has no Argo to ask. Both are correct no-ops, and both are the
#   common case: after a genuine teardown this script has nothing to do. A step
#   that fails on a clean host is a step that makes the from-zero path untestable,
#   which would be a poor trade for a step whose only job is to make that path
#   testable. It skips loudly instead of failing.
#
# WHY THE WAIT IS A POLL AND NOT `kubectl delete --wait`
#   There are TWO things to wait for and they can finish in either order, or
#   neither can finish because a finalizer is holding an object. One bounded poll
#   over the pair reports which of the two is still present; a single unbounded
#   delete hangs on whichever object it happened to be aimed at, and a hang is
#   indistinguishable from slowness without reading the code. Bounded, and the
#   timeout carries the diagnosis.

set -euo pipefail

readonly ARGOCD_NS="argocd"
readonly APP_NS="askvault-prod askvault-dev"
readonly DELETE_TIMEOUT="${DELETE_TIMEOUT:-120}"
readonly POLL_INTERVAL="${POLL_INTERVAL:-5}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '  ok   %s\n' "$1"; }
note() { printf '  ..   %s\n' "$1"; }

export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Finding 19 was a script that called `kc` with no `kc` defined, so every call
# failed and two assertions printed `ok` over the resulting emptiness. The
# function is defined here, in the same file that uses it, for that reason.
kc() { sudo -E k3s kubectl "$@"; }

printf '== reset-app ==\n'

# --- 1. is there anything to reset? -------------------------------------------
# Three ways there is not, all of them normal after a real teardown.
if ! command -v k3s >/dev/null 2>&1; then
  note "k3s is not installed on this host -- nothing has ever been built here"
  ok "nothing to reset (no k3s binary)"
  exit 0
fi

if ! kc get namespace >/dev/null 2>&1; then
  note "k3s is installed but no cluster answers -- nothing to reset"
  ok "nothing to reset (no reachable cluster)"
  exit 0
fi

present_apps=""
present_ns=""
for name in $APP_NS; do
  if kc -n "$ARGOCD_NS" get application "$name" >/dev/null 2>&1; then
    present_apps="$present_apps $name"
  fi
  if kc get namespace "$name" >/dev/null 2>&1; then
    present_ns="$present_ns $name"
  fi
done

# No Application and no namespace means the app layer is already cold, which is
# the state this step exists to produce. Say so, and prove it rather than assume
# it -- the "already cold" branch must be as trustworthy as the delete branch.
if [ -z "$present_apps" ] && [ -z "$present_ns" ]; then
  note "no Application and no Namespace for:$APP_NS"
  ok "app layer is already cold -- 50-gitops will create both namespaces up front"
  exit 0
fi

note "Applications present:$present_apps"
note "Namespaces present:$present_ns"

# --- 2. stop Argo before removing what it owns --------------------------------
# Order is the whole point of this section, and getting it backwards is a race
# that resolves the wrong way without any error. The Application is the object
# that recreates the namespace (syncOptions CreateNamespace=true). Delete the
# namespace first and Argo observes it gone and puts it back within seconds, and
# then 50-gitops.sh takes the "already exists" branch and proves nothing. The
# Application goes first; the poll in section 4 is what proves the race was won
# rather than merely not started.
note "deleting Applications first, so Argo stops reconciling before the namespaces go"
for app in $present_apps; do
  # --wait=false: the bounded poll below is the wait. See the header.
  kc -n "$ARGOCD_NS" delete application "$app" --wait=false
  ok "Application/$app delete requested"
done

# --- 3. now the namespaces ----------------------------------------------------
for ns in $present_ns; do
  kc delete namespace "$ns" --wait=false
  ok "Namespace/$ns delete requested"
done

# --- 4. bounded wait, and the assertion ---------------------------------------
# Reaching the `ok` line below IS the assertion: the loop only breaks when both
# lists are empty, so there is no path that reports cold without having observed
# it. The timeout message carries the diagnosis rather than a bare "timed out",
# because the two possible causes have opposite fixes and the operator cannot
# tell them apart from the outside.
deadline=$(( $(date +%s) + DELETE_TIMEOUT ))
elapsed=0
while :; do
  left_apps=""
  left_ns=""
  for app in $present_apps; do
    if kc -n "$ARGOCD_NS" get application "$app" >/dev/null 2>&1; then
      left_apps="$left_apps $app"
    fi
  done
  for ns in $present_ns; do
    if kc get namespace "$ns" >/dev/null 2>&1; then
      left_ns="$left_ns $ns"
    fi
  done

  if [ -z "$left_apps" ] && [ -z "$left_ns" ]; then
    break
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    fail "the app layer is NOT cold after ${DELETE_TIMEOUT}s.
  still present --  Applications:$left_apps  Namespaces:$left_ns

  An Application that will not delete, and a Namespace that will not leave
  Terminating, have different causes and opposite fixes, so read which of the two
  is stuck before touching anything:

    kc -n $ARGOCD_NS get application <name> -o jsonpath='{.metadata.finalizers[*]}'
    kc get namespace <name> -o jsonpath='{.metadata.finalizers[*]}'
    kc get namespace <name> -o jsonpath='{.status.conditions[*].type}'

  This script will not strip a finalizer for you: doing that orphans whatever the
  Application still owns, which may be more than the two namespaces named above.
  Re-running 50-gitops.sh from this state would take the 'already exists' branch
  and prove nothing, so fix this first."
  fi

  sleep "$POLL_INTERVAL"
  elapsed=$(( elapsed + POLL_INTERVAL ))
  printf '  ..   waiting for teardown (%ss/%ss)\n' "$elapsed" "$DELETE_TIMEOUT"
done

ok "cold: gone -- Applications:$present_apps Namespaces:$present_ns"
note "50-gitops.sh will now report 'created up front' for both namespaces"
