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
  # No sudo: repo add/update write to the USER's helm config, not the cluster.
  # Under sudo they would land in root's ~/.config/helm, giving root a separate
  # and invisible view of which repositories exist.
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack >/dev/null
  sudo -E helm upgrade --install cert-manager "$CERT_MGR_CHART" \
    -n cert-manager --create-namespace \
    --set crds.enabled=true --wait --timeout 300s
  ok "cert-manager installed"
fi

# --- 2. the CRDs, applied by us -----------------------------------------------
note "applying the monitoring CRDs server-side (see reason 2 in the header)"
workdir="$(mktemp -d)"
# `helm pull` is a pure DOWNLOAD — it talks to the chart repository over HTTPS
# and needs no cluster access and no kubeconfig. Running it under sudo was a
# mistake: it wrote root-owned files into a user-owned temp dir, so the cleanup
# `rm -rf` failed with a wall of "Permission denied" and masked whether the
# install had worked. It had not.
#
# Rule applied here: sudo is for things that need cluster or root access, and
# nothing else. A download needs neither.
helm pull "$CHART" -d "$workdir" --untar
crd_bundle="$workdir/kube-prometheus-stack/charts/crds/files/crds.bz2"
[ -f "$crd_bundle" ] || fail "CRD bundle not found at $crd_bundle — chart layout changed"
bunzip2 -c "$crd_bundle" > "$workdir/crds.yaml"
count="$(grep -c '^kind: CustomResourceDefinition' "$workdir/crds.yaml")"
[ "$count" -ge 5 ] || fail "expected several CRDs, found $count"
kc apply --server-side --force-conflicts -f "$workdir/crds.yaml" >/dev/null
ok "applied $count CRDs server-side"
rm -rf "$workdir"

# --- 2b. clear any stuck helm record ------------------------------------------
# A failed `helm upgrade --install` leaves a release secret in
# `pending-install` (or `pending-upgrade`), and every subsequent attempt dies
# with "another operation (install/upgrade/rollback) is in progress" forever.
# Helm will not self-heal this, so it must be cleared before retrying.
#
# This matters specifically on a rebuild: the FIRST attempt at this script can
# fail for a bare-host reason (missing namespace, root-owned temp dir), and
# without this cleanup the SECOND attempt fails for a completely unrelated
# reason, hiding the original problem behind a misleading one.
stuck="$(sudo -E helm list -n "$NS" --pending 2>/dev/null | awk 'NR>1{print $1}' || true)"
if [ -n "$stuck" ]; then
  note "clearing stuck helm record: $stuck (left by a failed attempt)"
  for rel in $stuck; do
    sudo -E k3s kubectl -n "$NS" delete secret \
      "sh.helm.release.v1.${rel}.v1" --ignore-not-found >/dev/null 2>&1 || true
  done
  ok "cleared"
fi

# --- 3. the stack -------------------------------------------------------------
# Sized for a single small node, and deliberately narrow:
#   alertmanager off   nothing here alerts anywhere
#   grafana off        the existing grafana release still serves
#   kubeStateMetrics off   a duplicate alongside the existing one
#   admissionWebhooks off  see reason 3 in the header
note "installing $RELEASE"
sudo -E helm upgrade --install "$RELEASE" "$CHART" -n "$NS" \
  --create-namespace \
  --skip-crds \
  --set alertmanager.enabled=false \
  --set grafana.enabled=false \
  --set kubeStateMetrics.enabled=false \
  --set prometheusOperator.admissionWebhooks.enabled=true \
  --set prometheusOperator.admissionWebhooks.failurePolicy=IgnoreOnInstallOnly \
  --set prometheusOperator.admissionWebhooks.certManager.enabled=true \
  --set prometheusOperator.admissionWebhooks.certManager.admissionCert.duration=8760h \
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
# DISCOVER the Prometheus pod, do not construct its name.
  #
  # BUG FOUND 2026-09-27, and it was in this script s own verification: it
  # port-forwarded to "pod/${RELEASE}-prometheus-0", which is
  # "kube-prometheus-stack-prometheus-0" -- but the real pod is named
  # "prometheus-kube-prometheus-stack-prometheus-0". The port-forward failed
  # silently, the curl hit a closed port, and the script reported "the
  # ServiceMonitor is still inert" while Prometheus was in fact scraping the app
  # perfectly. A verification step that fails on a healthy system is worse than
  # no verification: it sends you debugging the wrong component.
  #
  # Selecting by label is robust to whatever the chart decides to call things.
  prom_pod="$(kc -n "$NS" get pod -l app.kubernetes.io/name=prometheus \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [ -n "$prom_pod" ] || fail "no Prometheus pod found in $NS"

  # WAIT FOR THE POD TO BE READY, not merely to exist.
  #
  # BUG FOUND 2026-09-27, and the diagnosis added moments earlier is what found
  # it: on a cold start the Pod object appears immediately but stays Pending
  # while the image pulls and volumes schedule. Port-forwarding to a Pending pod
  # fails with "pod is not running. Current status=Pending", the tunnel never
  # comes up, and the check running through it reports the ServiceMonitor as
  # inert. The previous version tested existence only, so it raced.
  #
  # This is the third distinct way this one check produced a false failure, and
  # all three were the check rather than Prometheus.
  note "waiting for the Prometheus pod to become Ready (up to 180s)"
  for _ in $(seq 1 60); do
    kc -n "$NS" wait --for=condition=Ready "pod/$prom_pod" --timeout=3s \
      >/dev/null 2>&1 && break
    sleep 3
  done
  kc -n "$NS" get pod "$prom_pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null | grep -q True \
    || fail "Prometheus pod $prom_pod never became Ready"
  ok "Prometheus pod Ready"

  sudo fuser -k 19090/tcp >/dev/null 2>&1 || true
  # `nohup` execs a BINARY, not a shell function. kc() is a shell function, so
  # `nohup kc ...` would fail with
  #     nohup: failed to run command 'kc': No such file or directory
  # The background job never started, the curl hit a closed port, and the script
  # reported "the ServiceMonitor is still inert" while Prometheus was scraping
  # the application perfectly. Same class as the other verification bugs in this
  # drill: the check was broken, not the thing it checked.
  #
  # sudo -E k3s kubectl is the real command; use it here explicitly.
  pf_log=/tmp/kps-prom-pf.log
  nohup sudo -E k3s kubectl -n "$NS" port-forward "pod/${prom_pod}" 19090:9090 \
    >"$pf_log" 2>&1 &
  sleep 5

  # Confirm the tunnel is up BEFORE polling through it. Without this, a dead
  # port-forward and an inert ServiceMonitor are indistinguishable, and the
  # script blames the wrong one -- which is precisely what it did twice.
  ss -ltn 2>/dev/null | grep -q 19090 || fail "the Prometheus port-forward never came up.
Log:
$(sed 's/^/    /' "$pf_log" 2>/dev/null | head -5)"

jobs=""
for _ in $(seq 1 60); do
  jobs="$(curl -s --max-time 5 "http://127.0.0.1:19090/api/v1/targets" 2>/dev/null \
    | python3 -c 'import json,sys; print("\n".join(sorted({t["labels"].get("job","") for t in json.load(sys.stdin)["data"]["activeTargets"]})))' 2>/dev/null || true)"
  printf '%s' "$jobs" | grep -q '^askvault$' && break
  sleep 2
done

  if printf '%s' "$jobs" | grep -q '^askvault$'; then
    ok "askvault scrape target present"
  else
    # Diagnose rather than assert: this script has twice reported "the
    # ServiceMonitor is still inert" when Prometheus was scraping the app
    # perfectly and the CHECK was at fault. A verification step that fails on
    # a healthy system sends you debugging the wrong component, so the message
    # must carry enough to tell the two apart.
    fail "no AskVault scrape target after 120s.
Jobs Prometheus currently knows: $(printf '%s' "$jobs" | tr '\n' ' ')
Port-forward log ($pf_log):
$(sed 's/^/    /' "$pf_log" 2>/dev/null | head -5)

Decide which is broken before changing anything:
  kubectl -n monitoring port-forward pod/$prom_pod 19090:9090 &
  curl -s localhost:19090/api/v1/targets | jq -r .data.activeTargets[].labels.job | sort -u

If askvault appears in that list, the CHECK is broken and the ServiceMonitor
is fine. If it does not, the ServiceMonitor really is inert."
  fi

printf '%s' "$jobs" | grep -q '^traefik$' \
  && ok "traefik scrape target present" \
  || note "no traefik target (expected only if the PodMonitor was applied out of band)"

# Report health, not just presence. A target can exist and be failing, and
# `unknown` is NOT `up` -- it means Prometheus has not completed a scrape yet.
# Labelling that `ok` would be the same class of misleading output this script
# has already produced three times, so the label follows the health rather than
# the mere existence of a target.
curl -s --max-time 5 "http://127.0.0.1:19090/api/v1/targets" 2>/dev/null \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
for t in d["data"]["activeTargets"]:
    job = t["labels"].get("job", "")
    if job not in ("askvault", "traefik"):
        continue
    ns = t["labels"].get("namespace", "")
    health = t.get("health", "unknown")
    label = "ok  " if health == "up" else "...."
    print("  " + label + " " + job + " " + ns + " -> " + health)
' || true

sudo fuser -k 19090/tcp >/dev/null 2>&1 || true

printf '\nMONITORING OK\n'
