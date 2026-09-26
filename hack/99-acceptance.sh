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
  bad "a leaked admission webhook is present and will block future applies"
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

# --- verdict -----------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'PASS %d   FAIL %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf 'ACCEPTANCE: PASS\n'
  exit 0
fi
printf 'ACCEPTANCE: FAIL\n'
exit 1
