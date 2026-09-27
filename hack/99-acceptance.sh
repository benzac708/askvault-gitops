#!/usr/bin/env bash
# 99-acceptance.sh — the drill gate. Every check here exists because its
# absence hid a real failure during the 2026-09-26 drill, and in each case the
# cluster looked healthy from the outside at the time.
#
# This script is READ-ONLY. It asserts and reports; it never fixes. A gate that
# repairs what it finds cannot tell you the rebuild worked.

set -uo pipefail

readonly ARGOCD_NS="argocd"
readonly APP_NS="askvault-prod"
readonly PUBLIC_HOST="${PUBLIC_HOST:-askvault.zachara.dev}"
readonly NODEPORT_HTTP=30080
readonly NODEPORT_HTTPS=30443

PASS=0
FAIL=0

ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '  ....  %s\n' "$1"; }
head_() { printf '\n-- %s\n' "$1"; }

export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kc() { sudo -E k3s kubectl "$@"; }

printf '== acceptance ==\n'

# --- 1. cluster shape ---------------------------------------------------------
head_ "cluster"
ver="$(kc get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null)"
case "$ver" in
  v1.*) ok "node kubelet $ver" ;;
  *)    bad "node version unreadable: '$ver'" ;;
esac

ready="$(kc get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
[ "$ready" = "True" ] && ok "node Ready" || bad "node not Ready ('$ready')"

# --- 2. the two flags that were nearly lost ----------------------------------
head_ "host-port invariants"
if kc -n kube-system get pods 2>/dev/null | grep -qi svclb; then
  bad "svclb present — Traefik is one binding away from colliding with Caddy"
else
  ok "no svclb"
fi

if kc -n kube-system get pods 2>/dev/null | grep -qi traefik; then
  bad "bundled k3s Traefik is running alongside ours"
else
  ok "only one Traefik"
fi

ttype="$(kc -n traefik get svc traefik -o jsonpath='{.spec.type}' 2>/dev/null)"
[ "$ttype" = "NodePort" ] && ok "traefik Service is NodePort" || bad "traefik Service type '$ttype'"

tnp="$(kc -n traefik get svc traefik -o jsonpath='{range .spec.ports[*]}{.nodePort}{" "}{end}' 2>/dev/null)"
printf '%s' "$tnp" | grep -qw "$NODEPORT_HTTP"  && ok "web NodePort $NODEPORT_HTTP"     || bad "web NodePort missing (got '$tnp')"
printf '%s' "$tnp" | grep -qw "$NODEPORT_HTTPS" && ok "websecure NodePort $NODEPORT_HTTPS" || bad "websecure NodePort missing (got '$tnp')"

if ss -ltn 2>/dev/null | grep -qE ':80[[:space:]]'; then
  owner="$(sudo ss -ltnp 2>/dev/null | awk '/:80 /{print $NF}' | head -1)"
  case "$owner" in
    *caddy*) ok "host :80 owned by caddy" ;;
    *)       bad "host :80 owned by '$owner', expected caddy — LoadBalancer Traefik would break this" ;;
  esac
else
  bad "nothing is listening on host :80"
fi

# --- 3. GitOps is actually reconciling ---------------------------------------
head_ "argo cd"
if ! command -v argocd >/dev/null 2>&1; then
  bad "argocd CLI missing — cannot check sync state"
else
  sudo fuser -k 18443/tcp >/dev/null 2>&1 || true
  nohup sudo -E k3s kubectl -n "$ARGOCD_NS" port-forward svc/argocd-server 18443:443 \
    >/tmp/argocd-accept-pf.log 2>&1 &
  for _ in $(seq 1 20); do
    curl -sk -o /dev/null --max-time 2 https://localhost:18443/healthz && break
    sleep 1
  done
  pw="$(kc -n "$ARGOCD_NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
  if [ -n "$pw" ] && argocd login localhost:18443 --username admin --password "$pw" --insecure >/dev/null 2>&1; then
    for app in askvault-prod askvault-dev; do
      # Synced AND Healthy is the gate. Synced alone is ALSO the state Argo
      # reports while a pod crash-loops on an unpullable image, which is exactly
      # the failure this project spent the longest on.
      # Read the JSON, not the table. `argocd app list`'s default columns are
      # documented as NAME CLUSTER NAMESPACE PROJECT STATUS HEALTH, and the awk
      # version of this check indexed columns 4/5 and parsed the PROJECT as the
      # sync status — reported as "sync is 'askvault'". A gate that misreads its
      # own input is worse than no gate, so this uses -o json.
      app_json="$(argocd app get "$app" -o json 2>/dev/null || true)"
      sync="$(printf '%s' "$app_json"   | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",{}).get("sync",{}).get("status",""))' 2>/dev/null)"
      health="$(printf '%s' "$app_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",{}).get("health",{}).get("status",""))' 2>/dev/null)"
      [ "$sync" = "Synced" ]    && ok "$app Synced"   || bad "$app sync is '$sync', expected Synced"
      [ "$health" = "Healthy" ] && ok "$app Healthy"  || bad "$app health is '$health', expected Healthy"
    done
  else
    bad "could not authenticate to argocd"
  fi
fi

# --- 4. the app is running and answering in-cluster --------------------------
head_ "application"
pods_ready="$(kc -n "$APP_NS" get deploy askvault -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ "${pods_ready:-0}" -ge 1 ] && ok "deployment has $pods_ready ready replica" || bad "no ready replicas"

for probe in healthz readyz; do
  code="$(kc -n "$APP_NS" exec deploy/askvault -- \
    python -c "import urllib.request,sys; print(urllib.request.urlopen('http://127.0.0.1:8000/${probe}').status)" 2>/dev/null || echo 000)"
  [ "$code" = "200" ] && ok "/${probe} returns 200 in-cluster" || bad "/${probe} returned '$code' in-cluster"
done

# --- 5. the public edge, and the path restriction ----------------------------
head_ "public edge"
pcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${PUBLIC_HOST}/" 2>/dev/null || echo 000)"
[ "$pcode" = "200" ] && ok "https://${PUBLIC_HOST}/ -> 200" || bad "https://${PUBLIC_HOST}/ -> $pcode"

# L2 is a real property only if it is asserted from OUTSIDE. /metrics and
# /healthz must 404 at the edge; reaching them from inside the cluster above is
# a different claim. If these ever return 200, the Ingress paths have widened.
for path in metrics healthz readyz; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${PUBLIC_HOST}/${path}" 2>/dev/null || echo 000)"
  [ "$code" = "404" ] && ok "/${path} 404 at the edge (path restriction holds)" \
                      || bad "/${path} returned $code at the edge, expected 404 — the Ingress paths widened"
done

# --- 6. a real answer, grounded in the corpus --------------------------------
head_ "answer quality"
resp="$(curl -s --max-time 45 -X POST "https://${PUBLIC_HOST}/chat" \
  -H 'Content-Type: application/json' \
  -d '{"question":"Who can approve access to production systems?"}' 2>/dev/null || true)"
answer="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("answer",""))' 2>/dev/null || true)"
model="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("model",""))' 2>/dev/null || true)"
ncites="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("citations",[])))' 2>/dev/null || echo 0)"

[ -n "$answer" ] && ok "got an answer" || bad "no answer returned"
[ "${ncites:-0}" -ge 1 ] && ok "$ncites citations returned" || bad "answer had no citations"
case "$answer" in
  *manager*) ok "answer is grounded in the corpus ('manager' appears in samples/onboarding.md)" ;;
  *)         bad "answer does not match the corpus: '$answer'" ;;
esac
note "model: ${model:-unknown}"

# --- 7. nothing wedged -------------------------------------------------------
head_ "termination and leaks"
terminating="$(kc get ns --no-headers 2>/dev/null | awk '$2=="Terminating"{print $1}' | tr '\n' ' ')"
[ -z "$terminating" ] && ok "no namespaces stuck Terminating" || bad "terminating: $terminating"

if kc get validatingwebhookconfiguration -o name 2>/dev/null | grep -qiE 'prometheus|admission'; then
  # A webhook existing is NOT the failure. The failure is a LEaked one: a
  # webhook whose backing Service is gone, because with failurePolicy=Fail it
  # refuses every matching apply cluster-wide and names the webhook rather than
  # the missing Service. Check the thing that actually breaks, not the name.
  # (An earlier version of this check flagged cert-manager-webhook, which is
  # healthy and legitimate -- a gate with false positives gets bypassed.)
  leaked=0
  for wh in $(kc get validatingwebhookconfiguration -o name 2>/dev/null | grep -iE 'prometheus|admission'); do
    svc="$(kc get "$wh" -o jsonpath='{.webhooks[0].clientConfig.service.name}' 2>/dev/null)"
    ns="$(kc get "$wh" -o jsonpath='{.webhooks[0].clientConfig.service.namespace}' 2>/dev/null)"
    if [ -n "$svc" ] && ! kc -n "$ns" get svc "$svc" >/dev/null 2>&1; then
      leaked=$((leaked+1))
      bad "$(basename "$wh") points at missing service $ns/$svc"
    fi
  done
  [ "$leaked" -eq 0 ] && ok "all admission webhooks have live backing services"
else
  ok "no leaked webhooks"
fi

# --- 8. the secret really is a secret ---------------------------------------
head_ "secret hygiene"
cm_keys="$(kc -n "$APP_NS" get configmap askvault-config -o jsonpath='{.data}' 2>/dev/null || true)"
case "$cm_keys" in
  *llm_api_key*|*API_KEY*) bad "the API key is in the ConfigMap — it must live in a Secret" ;;
  *)                       ok "no credential in the ConfigMap" ;;
esac

# --- 9. the platform underneath the app ---------------------------------------
head_ "platform health"
# Every namespace this drill builds must be fully Running. A gate that only
# inspects the askvault path cannot tell you the cluster is coming apart around
# it, and "the app answers" stays true for a surprisingly long time while pods
# elsewhere are dead.
for ns in kube-system argocd traefik cert-manager monitoring askvault-prod askvault-dev; do
  # Columns are: NAME READY STATUS RESTARTS AGE. So the phase is $3 and the
  # ready ratio is $2. Assert BOTH: a pod can be Running with 0/1 containers
  # ready, which is what a failing readiness probe produces, and "Running" alone
  # would pass it. $2 != $1 is short for "ready count != total count" after
  # splitting on "/".
  bad_pods="$(kc -n "$ns" get pods --no-headers 2>/dev/null \
    | awk '{
        split($2, r, "/");
        if ($3 != "Running" && $3 != "Completed" && $3 != "Succeeded") next_ok = 0;
        else if (r[1] != r[2]) next_ok = 0;
        else next_ok = 1;
        if (!next_ok) print $1" ("$3" "$2")";
      }' \
    | tr '\n' ' ')"
  if [ -z "$bad_pods" ]; then
    n="$(kc -n "$ns" get pods --no-headers 2>/dev/null | wc -l)"
    ok "$ns: all $n pods Running"
  else
    bad "$ns has unhealthy pods: $bad_pods"
  fi
done

# metrics-server is easy to leave out and hard to notice missing until something
# asks for resource metrics. Assert the API answers, not that a Pod exists.
if kc top nodes >/dev/null 2>&1; then
  ok "metrics-server answers (kubectl top works)"
else
  bad "metrics-server is not serving metrics — kubectl top fails, so any HPA is blind"
fi

# --- 10. cert-manager, a hard dependency of the monitoring chart --------------
head_ "cert-manager"
for d in cert-manager cert-manager-cainjector cert-manager-webhook; do
  rdy="$(kc -n cert-manager get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  [ "${rdy:-0}" -ge 1 ] && ok "$d has ${rdy} ready" || bad "$d has no ready replicas"
done

# Deployments being Ready is not the same as certificates being ISSUED. The
# operator's admission webhook cert is what 31-monitoring.sh depends on.
issued="$(kc get certificate -A --no-headers 2>/dev/null | awk '$3=="True"' | wc -l)"
if [ "${issued:-0}" -ge 1 ]; then
  ok "$issued Certificate(s) issued"
else
  bad "no Certificate reports Ready=True — the monitoring webhook cert is not issued"
fi

# --- 11. monitoring is only useful if something READS it ----------------------
head_ "monitoring integration"
prom_pod="$(kc -n monitoring get pod -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -n "$prom_pod" ]; then
  ok "Prometheus pod present ($prom_pod)"
  # uptime is a real signal: a Prometheus that just restarted has lost its
  # retention window, so this reports how long it has actually been collecting.
  uptime="$(kc -n monitoring get pod "$prom_pod" -o jsonpath='{.status.startTime}' 2>/dev/null)"
  note "Prometheus started ${uptime:-unknown}"
  pstate="$(kc -n monitoring get sts prometheus-kube-prometheus-stack-prometheus \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  [ "${pstate:-0}" -ge 1 ] && ok "Prometheus StatefulSet Ready" || bad "Prometheus StatefulSet not Ready"
else
  bad "no Prometheus pod in monitoring"
fi

# Port-forward and query the real API. Assert a scrape TARGET exists and is up,
# and that the application's own metric is queryable end to end -- a target being
# present but never returning a sample proves nothing.
if [ -n "$prom_pod" ]; then
  sudo fuser -k 19090/tcp >/dev/null 2>&1 || true
  pf_log=/tmp/accept-prom-pf.log
  nohup sudo -E k3s kubectl -n monitoring port-forward "pod/${prom_pod}" 19090:9090 \
    >"$pf_log" 2>&1 &
  for _ in $(seq 1 20); do
    curl -s -o /dev/null --max-time 2 http://127.0.0.1:19090/-/healthy && break
    sleep 1
  done

  if ! curl -s --max-time 5 http://127.0.0.1:19090/-/healthy 2>/dev/null | grep -qi healthy; then
    bad "could not reach the Prometheus API to verify scraping.
Log:
$(sed 's/^/    /' "$pf_log" 2>/dev/null | head -5)"
  else
    up_targets="$(curl -s --max-time 8 "http://127.0.0.1:19090/api/v1/targets" 2>/dev/null \
      | python3 -c '
import json, sys
d = json.load(sys.stdin)
for t in d["data"]["activeTargets"]:
    if t["labels"].get("job") == "askvault" and t.get("health") == "up":
        print(t["labels"].get("namespace", ""))
' 2>/dev/null | tr '\n' ' ')"
    case "$up_targets" in
      *askvault-prod*) ok "Prometheus scraping askvault-prod (health=up)" ;;
      *)               bad "askvault-prod is not an 'up' scrape target (got: '${up_targets:-none}')" ;;
    esac
    case "$up_targets" in
      *askvault-dev*)  ok "Prometheus scraping askvault-dev (health=up)" ;;
      *)               note "askvault-dev not yet 'up' (may still be on its first scrape interval)" ;;
    esac

    # The end-to-end claim: the application's own metric is retrievable through
    # PromQL. This is what proves the scrape produces DATA, not just a target.
    nsamples="$(curl -s --max-time 8 \
      "http://127.0.0.1:19090/api/v1/query?query=askvault_llm_calls_total" 2>/dev/null \
      | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("data",{}).get("result",[])))' 2>/dev/null || echo 0)"
    [ "${nsamples:-0}" -ge 1 ] \
      && ok "PromQL returns $nsamples series for askvault_llm_calls_total" \
      || bad "askvault_llm_calls_total query returned no series — scraping produces no data"

    # Silence the shell's "Killed" job notice: fuser killing the backgrounded
    # port-forward is normal teardown, but the message lands mid-report and reads
    # like a failure. Wait for it so it is reaped here, not after the verdict.
    sudo fuser -k 19090/tcp >/dev/null 2>&1 || true
    wait 2>/dev/null || true
  fi
fi

# The estate Grafana is the READER. Monitoring with no consumer is a shelf of
# unread dashboards, so the integration claim is: it answers, and it can reach
# Prometheus across the runtime boundary (a docker container to a clusterIP).
gcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:3000/api/health 2>/dev/null || echo 000)"
if [ "$gcode" = "200" ]; then
  ok "estate Grafana answers on :3000"
  prom_ip="$(kc -n monitoring get svc kube-prometheus-stack-prometheus \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  if [ -n "$prom_ip" ] && docker exec grafana sh -c \
      "wget -qO- --timeout=5 http://${prom_ip}:9090/-/healthy 2>/dev/null | grep -qi healthy" 2>/dev/null; then
    ok "Grafana can reach the in-cluster Prometheus (${prom_ip}:9090)"
  else
    bad "Grafana cannot reach Prometheus at ${prom_ip:-<no clusterIP>}:9090 — the datasource would fail"
  fi
else
  # NOT a hard failure: the estate Grafana is not part of what this drill builds,
  # and the rebuild is not supposed to manage it. Its absence means monitoring has
  # no in-estate reader, which is worth saying out loud but not failing the gate.
  note "estate Grafana not answering on :3000 (code $gcode) — not built by this drill, so not a gate failure"
fi

# --- verdict -----------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'PASS %d   FAIL %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf 'ACCEPTANCE: PASS\n'
  exit 0
fi
printf 'ACCEPTANCE: FAIL\n'
exit 1
