#!/usr/bin/env bash
# 31-monitoring.sh — install kube-prometheus-stack so the committed
# ServiceMonitor is actually consumed.
#
# WHY THE STACK AND NOT THE PLAIN `prometheus` CHART:
#
#   A ServiceMonitor is a custom resource. It means nothing unless an OPERATOR
#   reconciles it, and the plain chart has no operator — it scrapes from a
#   file-based config dir. The result is the worst kind of wrong: the object
#   exists, `kubectl get servicemonitor` returns a row, and nothing is
#   collected. The repo claimed a capability it did not have. Finding 19.
#
#   Verified before this change: 10 active targets, no `askvault`, no
#   `traefik`. Verified after: both present and `up`.
#
# THREE THINGS THAT WILL BITE, all hit during the first attempt:
#
#   1. cert-manager is a hard dependency. Install it FIRST (finding 5).
#
#   2. The CRDs conflict on install. Helm's client-side apply sees a stale
#      `argocd-controller` entry in the CRDs' managedFields and refuses with
#      "conflict with argocd-controller". The Argo Applications do not manage
#      monitoring, so that ownership is inert — but it is permanent and cannot
#      be patched away, because it is re-asserted. The fix is to apply the CRDs
#      OURSELVES with `--server-side --force-conflicts` (which takes ownership
#      cleanly, exactly as the Argo CD install needed — finding 4) and then
#      install the chart with `--skip-crds`.
#
#      The CRDs live in a subchart as a bz2 bundle, NOT in the templates, so
#      `helm template --include-crds` is the only way to extract them:
#        helm pull ... --untar && bunzip2 charts/crds/files/crds.bz2
#
#   3. The admission-webhook patch hook pulls from ghcr.io, and the kubelet's
#      anonymous ghcr token request returns 403 on this node (finding). The
#      chart exposes NO imagePullSecrets key for that job, so it cannot be
#      configured. The webhook is optional for this use case, so it is
#      disabled — and when disabled the dead ValidatingWebhookConfiguration is
#      left behind pointing at a Service that no longer exists. With
#      failurePolicy=Ignore it is harmless, but it is noise that looks like a
#      problem, so it is deleted explicitly.
#
# IDEMPOTENT: upgrade --install with a full explicit --set list.

set -euo pipefail

readonly NS="monitoring"
readonly RELEASE="kube-prometheus-stack"
readonly CHART="prometheus-community/kube-prometheus-stack"
readonly CERT_MGR_CHART="jetstack/cert-manager"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '  ok   %s\n' "$1"; }
note() { printf '  ..   %s\n' "$1"; }

export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

printf '== monitoring ==\n'

kc() { sudo -E k3s kubectl "$@"; }

# --- 1. cert-manager first ----------------------------------------------------
note "cert-manager is a hard dependency of this chart"
if kc get ns cert-manager >/dev/null 2>&1 \
   && kc -n cert-manager get deploy cert-manager >/dev/null 2>&1; then
  ok "cert-manager already installed"
else
  sudo -E helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  sudo -E helm repo update jetstack >/dev/null
  sudo -E helm upgrade --install cert-manager "$CERT_MGR_CHART" \
    -n cert-manager --create-namespace \
    --set crds.enabled=true --wait --timeout 300s
  ok "cert-manager installed"
fi

# --- 2. the CRDs, applied by us -----------------------------------------------
note "applying the monitoring CRDs server-side (see reason 2 in the header)"
workdir="$(mktemp -d)"
sudo -E helm pull "$CHART" -d "$workdir" --untar
crd_bundle="$workdir/kube-prometheus-stack/charts/crds/files/crds.bz2"
[ -f "$crd_bundle" ] || fail "CRD bundle not found at $crd_bundle — chart layout changed"
bunzip2 -c "$crd_bundle" > "$workdir/crds.yaml"
count="$(grep -c '^kind: CustomResourceDefinition' "$workdir/crds.yaml")"
[ "$count" -ge 5 ] || fail "expected several CRDs, found $count"
kc apply --server-side --force-conflicts -f "$workdir/crds.yaml" >/dev/null
ok "applied $count CRDs server-side"
rm -rf "$workdir"

# --- 3. the stack -------------------------------------------------------------
# Sized for a single small node, and deliberately narrow:
#   alertmanager off   nothing here alerts anywhere
#   grafana off        the existing grafana release still serves
#   kubeStateMetrics off   a duplicate alongside the existing one
#   admissionWebhooks off  see reason 3 in the header
note "installing $RELEASE"
sudo -E helm upgrade --install "$RELEASE" "$CHART" -n "$NS" \
  --skip-crds \
  --set alertmanager.enabled=false \
  --set grafana.enabled=false \
  --set kubeStateMetrics.enabled=false \
  --set prometheusOperator.admissionWebhooks.enabled=false \
  --set prometheusOperator.admissionWebhooks.patch.enabled=false \
  --set prometheus.prometheusSpec.retention=3d \
  --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
  --set prometheus.prometheusSpec.resources.limits.memory=1Gi \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 600s
ok "installed"

# --- 4. clear the dead webhook ------------------------------------------------
if kc get validatingwebhookconfiguration kube-prometheus-stack-admission >/dev/null 2>&1; then
  note "removing the dead admission webhook (no Service behind it)"
  kc delete validatingwebhookconfiguration kube-prometheus-stack-admission
fi
ok "no dead webhook"

# --- 5. the operator must be RUNNING, not merely applied ---------------------
for _ in $(seq 1 30); do
  kc -n "$NS" get deploy "$RELEASE-operator" >/dev/null 2>&1 && break
  sleep 2
done
ready="$(kc -n "$NS" get deploy "$RELEASE-operator" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${ready:-0}" -ge 1 ] || fail "the operator has no ready replica — nothing will consume ServiceMonitors"
ok "operator ready"

# --- 6. the check that tells the truth ---------------------------------------
# `kubectl get servicemonitor` returning a row proves the object exists, never
# that it is collected. The Prometheus API is the only honest source.
note "waiting for the operator to pick up the ServiceMonitors (up to 120s)"
sudo fuser -k 19090/tcp >/dev/null 2>&1 || true
nohup kc -n "$NS" port-forward "pod/${RELEASE}-prometheus-0" 19090:9090 \
  >/tmp/kps-prom-pf.log 2>&1 &
sleep 5

jobs=""
for _ in $(seq 1 60); do
  jobs="$(curl -s --max-time 5 "http://127.0.0.1:19090/api/v1/targets" 2>/dev/null \
    | python3 -c 'import json,sys; print("\n".join(sorted({t["labels"].get("job","") for t in json.load(sys.stdin)["data"]["activeTargets"]})))' 2>/dev/null || true)"
  printf '%s' "$jobs" | grep -q '^askvault$' && break
  sleep 2
done

printf '%s' "$jobs" | grep -q '^askvault$' \
  || fail "no 'askvault' scrape target after 120s — the ServiceMonitor is still inert"
ok "askvault scrape target present"

printf '%s' "$jobs" | grep -q '^traefik$' \
  && ok "traefik scrape target present" \
  || note "no traefik target (expected only if the PodMonitor was applied out of band)"

# Report health, not just presence. A target can exist and be failing.
curl -s --max-time 5 "http://127.0.0.1:19090/api/v1/targets" 2>/dev/null \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
for t in d["data"]["activeTargets"]:
    job = t["labels"].get("job", "")
    if job in ("askvault", "traefik"):
        print(f"  ok   {job} {t[\"labels\"].get(\"namespace\",\"\")} -> {t[\"health\"]}")
' || true

sudo fuser -k 19090/tcp >/dev/null 2>&1 || true

printf '\nMONITORING OK\n'
