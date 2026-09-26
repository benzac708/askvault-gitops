#!/usr/bin/env bash
# 90-teardown.sh — remove everything, in the order that actually works.
#
# THE ORDER IS THE ENTIRE POINT OF THIS SCRIPT.
#
#   Argo CD `Application` objects must be deleted BEFORE the `argocd`
#   namespace. An Application carries a finalizer that blocks deletion until its
#   controller has processed it; if the controller is gone first (because its
#   namespace was deleted), nothing is left to remove the finalizer and the
#   namespace sits in Terminating forever with no error. Finding 1 and finding 2
#   in the drill document, both learned the hard way.
#
#   The same class of trap applies to the monitoring stack: an operator that
#   owns CRs must have its CRs deleted before the operator, or the CRD deletion
#   blocks. So the sequence is always:
#
#       Applications -> namespaces -> helm releases -> CRDs -> cluster
#
# WHAT THIS DOES NOT TOUCH, DELIBERATELY:
#
#   cloudflared, Caddy, and the Cloudflare tunnel/DNS. Those are host- and
#   account-level and are NOT part of the cluster being rebuilt. Tearing them
#   down would take the whole zachara.dev estate offline, not just AskVault.
#
# IDEMPOTENT AND SAFE BY DEFAULT: running with no arguments prints the plan and
# exits. Passing --yes actually destroys things. This is deliberate: a script
# whose entire purpose is destruction should require a second, explicit signal.

set -euo pipefail

readonly ARGOCD_NS="argocd"
readonly APP_NAMESPACES=(askvault-prod askvault-dev)
readonly OTHER_NAMESPACES=(monitoring traefik)

CONFIRMED=0
[ "${1:-}" = "--yes" ] && CONFIRMED=1

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '  ok   %s\n' "$1"; }
note() { printf '  ..   %s\n' "$1"; }
step() { printf '\n-- %s\n' "$1"; }

export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

confirm() {
  if [ "$CONFIRMED" -eq 1 ]; then
    return 0
  fi
  printf '  WOULD RUN: %s\n' "$*"
  return 1
}

printf '== teardown ==\n'
if [ "$CONFIRMED" -eq 0 ]; then
  printf 'DRY RUN. Nothing will be deleted. Re-run with --yes to actually destroy.\n'
fi

kc() { sudo -E k3s kubectl "$@"; }

# --- 1. Application objects FIRST --------------------------------------------
step "1. Argo CD Applications (must precede the argocd namespace)"
if kc -n "$ARGOCD_NS" get applications.argoproj.io >/dev/null 2>&1; then
  for app in $(kc -n "$ARGOCD_NS" get applications.argoproj.io -o name 2>/dev/null); do
    if confirm "kubectl -n $ARGOCD_NS delete $app --wait=true --timeout=120s"; then
      kc -n "$ARGOCD_NS" delete "$app" --wait=true --timeout=120s || true
      ok "deleted $app"
    fi
  done
  # Give the controller a moment to run the finalizers it just queued.
  if [ "$CONFIRMED" -eq 1 ]; then
    note "waiting for finalizers to clear"
    for _ in $(seq 1 30); do
      kc -n "$ARGOCD_NS" get applications.argoproj.io --no-headers 2>/dev/null | grep -q . || break
      sleep 2
    done
  fi
else
  ok "no Application objects present"
fi

# --- 2. application namespaces ------------------------------------------------
step "2. application namespaces (this is where the running app lives)"
for ns in "${APP_NAMESPACES[@]}"; do
  if kc get ns "$ns" >/dev/null 2>&1; then
    if confirm "kubectl delete namespace $ns --wait=false"; then
      kc delete namespace "$ns" --wait=false || true
      ok "deletion requested for $ns"
    fi
  else
    ok "$ns absent"
  fi
done

# --- 3. helm releases ---------------------------------------------------------
step "3. helm releases (helm first, so it does not fight the namespace deletion)"
if command -v helm >/dev/null 2>&1; then
  for rel in $(sudo -E helm list -A -q 2>/dev/null || true); do
    ns="$(sudo -E helm list -A 2>/dev/null | awk -v r="$rel" '$1==r{print $2}')"
    [ -n "$ns" ] || continue
    case "$rel" in
      traefik|prometheus|grafana|*prometheus*)
        if confirm "helm uninstall $rel -n $ns"; then
          sudo -E helm uninstall "$rel" -n "$ns" || true
          ok "uninstalled $rel from $ns"
        fi ;;
      *) note "leaving unrelated release: $rel ($ns)" ;;
    esac
  done
fi

# --- 4. Argo CD itself --------------------------------------------------------
step "4. the argocd namespace (AFTER its Applications are gone)"
if kc get ns "$ARGOCD_NS" >/dev/null 2>&1; then
  if confirm "kubectl delete namespace $ARGOCD_NS --wait=false"; then
    kc delete namespace "$ARGOCD_NS" --wait=false || true
    ok "deletion requested for $ARGOCD_NS"
  fi
fi

# --- 5. remaining infra namespaces -------------------------------------------
step "5. remaining cluster namespaces"
for ns in "${OTHER_NAMESPACES[@]}"; do
  if kc get ns "$ns" >/dev/null 2>&1; then
    if confirm "kubectl delete namespace $ns --wait=false"; then
      kc delete namespace "$ns" --wait=false || true
      ok "deletion requested for $ns"
    fi
  else
    ok "$ns absent"
  fi
done

# --- 6. leaked cluster-scoped objects ----------------------------------------
# An admission webhook whose namespace is deleted does NOT go away with it. Left
# behind, it blocks every apply cluster-wide with a connection refused, and the
# error names the webhook rather than the namespace it came from.
step "6. leaked cluster-scoped objects from the monitoring stack"
if [ "$CONFIRMED" -eq 1 ]; then
  kc get validatingwebhookconfiguration -o name 2>/dev/null \
    | grep -iE 'prometheus|admission' \
    | while read -r wh; do kc delete "$wh" || true; ok "deleted leaked $wh"; done || true
  for crd in prometheuses.monitoring.coreos.com alertmanagers.monitoring.coreos.com \
             prometheusrules.monitoring.coreos.com servicemonitors.monitoring.coreos.com \
             podmonitors.monitoring.coreos.com; do
    if kc get crd "$crd" >/dev/null 2>&1; then
      kc delete crd "$crd" || true
      ok "deleted CRD $crd"
    fi
  done
else
  confirm "delete leaked webhooks + monitoring CRDs"
fi

# --- 7. wait, and report honestly --------------------------------------------
step "7. wait for namespaces to finish terminating"
if [ "$CONFIRMED" -eq 1 ]; then
  note "up to 240s. A namespace stuck in Terminating with no error is the failure this ordering exists to prevent."
  for _ in $(seq 1 120); do
    left="$(kc get ns --no-headers 2>/dev/null \
      | awk '$2=="Terminating"{print $1}' | tr '\n' ' ')"
    [ -z "$left" ] && break
    sleep 2
  done
  left="$(kc get ns --no-headers 2>/dev/null | awk '$2=="Terminating"{print $1}' | tr '\n' ' ')"
  if [ -n "$left" ]; then
    printf '\nSTUCK: these namespaces are still Terminating: %s\n' "$left"
    printf 'Read the reason rather than guessing — the conditions name the blocker:\n'
    printf '  kubectl get ns -o json | python3 -c '"'"'import json,sys;[print(f"{i[\"metadata\"][\"name\"]}: {c[\"type\"]}: {c.get(\"message\",\"\")}") for i in json.load(sys.stdin)["items"] for c in (i.get("status",{}).get("conditions") or [])]'"'"'\n'
    exit 1
  fi
  ok "all namespaces gone"
else
  note "skipped in dry run"
fi

kc get namespaces
kc get validatingwebhookconfiguration -o name 2>/dev/null | grep -iE 'prometheus|admission' \
  && fail "a leaked webhook survived teardown" || ok "no leaked webhooks"

printf '\nTEARDOWN %s\n' "$([ "$CONFIRMED" -eq 1 ] && echo COMPLETE || echo 'PLANNED (dry run)')"
printf 'Untouched, by design: cloudflared, Caddy, the Cloudflare tunnel and DNS.\n'
