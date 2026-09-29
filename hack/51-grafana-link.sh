#!/usr/bin/env bash
# 51-grafana-link.sh - reconnect the host Grafana data source after a rebuild.
#
# The dilemma this solves: the host Grafana (bzdotfiles services/monitoring)
# is the dashboard, and its Prometheus data source points at the in-cluster
# Prometheus ClusterIP. A cluster rebuild gives Prometheus a NEW ClusterIP,
# silently leaving the dashboard pointing at a dead address. The acceptance
# drill detects it; this step repairs it, idempotently.
#
# Run after 50-gitops.sh (and before 99-acceptance.sh). Safe to run any time:
# if the data source already points at the current ClusterIP, nothing changes.
#
# Credentials: the same GF_ADMIN_USER / GF_ADMIN_PASSWORD used by the Grafana
# compose. They are read from the environment, or from the bzdotfiles
# services/.env file when present. Never hard-code a credential here.
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"
GRAFANA_NS="${GRAFANA_NS:-monitoring}"
PROM_SVC="${PROM_SVC:-kube-prometheus-stack-prometheus}"
PROM_PORT="${PROM_PORT:-9090}"
ENV_DIR="${BZDOTFILES:-$HOME/repos/bzdotfiles}/services"

ADMIN_USER="${GF_ADMIN_USER:-}"
ADMIN_PASS="${GF_ADMIN_PASSWORD:-}"
if [ -z "$ADMIN_USER" ] && [ -f "$ENV_DIR/.env" ]; then
  # shellcheck disable=SC1091
  . "$ENV_DIR/.env"
  ADMIN_USER="${GF_ADMIN_USER:-}"
  ADMIN_PASS="${GF_ADMIN_PASSWORD:-}"
fi
if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
  echo "error: GF_ADMIN_USER/GF_ADMIN_PASSWORD not set and $ENV_DIR/.env not found" >&2
  exit 1
fi

IP=$(kubectl get svc -n "$GRAFANA_NS" "$PROM_SVC" -o jsonpath='{.spec.clusterIP}')
if [ -z "$IP" ]; then
  echo "error: no clusterIP for $GRAFANA_NS/$PROM_SVC - is the cluster up?" >&2
  exit 1
fi
TARGET="http://${IP}:${PROM_PORT}"
echo "prometheus reachable at $TARGET"

auth=(-u "$ADMIN_USER:$ADMIN_PASS")
list=$(curl -sS "${auth[@]}" "$GRAFANA_URL/api/datasources") || {
  echo "error: Grafana API unreachable at $GRAFANA_URL" >&2
  exit 1
}
if printf '%s' "$list" | grep -q '"message":"Invalid username'; then
  echo "error: Grafana rejected the credentials - check GF_ADMIN_USER/GF_ADMIN_PASSWORD" >&2
  exit 1
fi

id=$(printf '%s' "$list" | python3 -c '
import json, sys
ds = json.load(sys.stdin)
for d in ds:
    if d.get("type") == "prometheus":
        print(d.get("id", ""))
        break
')
url=$(printf '%s' "$list" | python3 -c '
import json, sys
ds = json.load(sys.stdin)
for d in ds:
    if d.get("type") == "prometheus":
        print(d.get("url", ""))
        break
')

if [ -z "$id" ]; then
  echo "no prometheus data source found - creating one"
  curl -sS "${auth[@]}" -H "Content-Type: application/json" \
    -d "{\"name\":\"k3s-prometheus\",\"type\":\"prometheus\",\"url\":\"$TARGET\",\"access\":\"proxy\"}" \
    "$GRAFANA_URL/api/datasources" >/dev/null
  echo "created data source -> $TARGET"
elif [ "$url" = "$TARGET" ]; then
  echo "data source already points at $TARGET (nothing to do)"
else
  echo "re-pointing data source $id from $url to $TARGET"
  curl -sS "${auth[@]}" -X PATCH -H "Content-Type: application/json" \
    -d "{\"name\":\"k3s-prometheus\",\"type\":\"prometheus\",\"url\":\"$TARGET\",\"access\":\"proxy\"}" \
    "$GRAFANA_URL/api/datasources/$id" >/dev/null
  echo "data source re-pointed -> $TARGET"
fi