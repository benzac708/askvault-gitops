#!/usr/bin/env bash
# 90-teardown.sh — destroy ALL AskVault-related state, host and cluster, down
# to a genuine 0%.
#
# ============================================================================
# THE BOUNDARY, STATED FIRST BECAUSE GETTING IT WRONG IS NOT RECOVERABLE
# ============================================================================
#
# This VPS runs an entire estate that has nothing to do with AskVault:
# ~40 systemd services (activity, analytics, blog, planner, finance, pulse,
# ...), ~12 Docker containers (mercato, umami, caddy, grafana, ...), and a
# cloudflared tunnel. k3s is the ONLY thing on this host that AskVault owns
# outright, so removing k3s removes exactly the AskVault cluster and nothing
# else.
#
# This script therefore NEVER touches:
#   /etc/cloudflared/     the tunnel and its config — shared, and the tunnel ID
#                         is baked into DNS (see askvault-infra-export.md)
#   the cloudflared unit  same
#   /etc/caddy/           serves the whole estate; AskVault only depends on it
#                         owning host ports 80/443
#   docker containers     except an explicit allowlist of AskVault leftovers
#   systemd services      except k3s itself
#   the Cloudflare zone   not reachable from here anyway
#
# ============================================================================
# WHY FULL TEARDOWN INCLUDES k3s
# ============================================================================
#
# The acceptance question is not "does a namespace rebuild" — it is "can this
# be spun back up from total non-existence". Leaving k3s installed would leave
# a cluster-admin credential, a containerd content store, and a CNI in place,
# and the rebuild would then be testing the GitOps layer against a warm host.
# The real test starts from a host with no cluster on it at all.
#
# ============================================================================
# WHY `k3s-uninstall.sh` IS NOT ENOUGH ON ITS OWN
# ============================================================================
#
# Upstream's uninstall removes /etc/rancher/k3s, /var/lib/kubelet, /run/k3s
# and the binary — but it LEAVES:
#     /var/lib/rancher/k3s   (~6.0G: containerd content store, images, agent data)
#     /run/k3s               (~4.7G at runtime; usually released on stop)
#     /etc/rancher/node      the node password
# Leaving /var/lib/rancher/k3s is the subtle one: a rebuild would then pull
# images from a warm content store instead of the network, so a broken registry
# path would NOT be caught. That is precisely the class of hidden state that
# makes a "successful" rebuild a lie, so it is removed explicitly.
#
# ============================================================================
# USAGE
# ============================================================================
#   ./90-teardown.sh              dry run — prints the plan, destroys nothing
#   ./90-teardown.sh --yes        actually destroy
#   ./90-teardown.sh --yes --keep-k3s    namespaces only, leave the cluster
#
# Destruction requires an explicit second signal, on purpose.

set -euo pipefail

readonly ARGOCD_NS="argocd"
readonly APP_NAMESPACES=(askvault-prod askvault-dev)
readonly INFRA_NAMESPACES=(monitoring traefik cert-manager)

# Docker containers that are ours to delete. Everything else on this host
# belongs to the wider estate. An allowlist rather than a pattern, because a
# pattern like "askvault*" would match a container someone names by accident.
readonly OUR_CONTAINERS=(askvault-9h-time)

CONFIRMED=0
KEEP_K3S=0
for arg in "$@"; do
  case "$arg" in
    --yes)      CONFIRMED=1 ;;
    --keep-k3s) KEEP_K3S=1 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '  ok   %s\n' "$1"; }
note() { printf '  ..   %s\n' "$1"; }
step() { printf '\n-- %s\n' "$1"; }

export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Two separate ideas, kept separate on purpose:
#
#   confirm()  reports the planned action and answers "should we act?". It
#              ALWAYS returns 0 so that under `set -e` it can never abort the
#              script. An earlier version returned 1 in dry-run mode, which
#              escaped the `if` and killed the run after step 7 — so the dry
#              run printed half a plan and exited silently, hiding exactly the
#              steps (k3s removal, verification) a reader most needs to see.
#
#   DO_IT is the actual gate. Nothing destructive happens unless this is 1,
#   and it is written explicitly at each call site rather than inferred from a
#   return value.
# The gate is ONLY ever used as an `if` condition, where returning non-zero is
# legal and simply skips the body. That is why it can safely signal "don't act"
# without tripping `set -e`.
#
# An earlier version returned 1 from a function that was called OUTSIDE an `if`
# in one place, which aborted the entire script mid-dry-run and hid steps 8-9.
gate() {
  if [ "$CONFIRMED" -eq 1 ]; then
    return 0
  fi
  printf '  WOULD RUN: %s\n' "$*"
  return 1
}

printf '== teardown ==\n'
if [ "$CONFIRMED" -eq 0 ]; then
  printf 'DRY RUN. Nothing will be deleted. Re-run with --yes to destroy.\n'
fi
if [ "$KEEP_K3S" -eq 1 ]; then
  printf 'MODE: cluster objects only (--keep-k3s). k3s stays installed.\n'
fi

kc() { sudo -E k3s kubectl "$@"; }

# ============================================================================
# 0. GUARD — refuse to run if this does not look like the host we expect
# ============================================================================
step "0. estate guard"
# If k3s is absent there is nothing cluster-side to do, and the host steps
# below still apply. But if we are on a host where the estate lives, the
# allowlist must not match it. Assert the allowlist is still narrow.
if [ "${#OUR_CONTAINERS[@]}" -gt 3 ]; then
  fail "OUR_CONTAINERS has grown to ${#OUR_CONTAINERS[@]} entries — review before running.
This script deletes containers by name and a widened list is how it eats someone else's service."
fi
ok "container allowlist is ${#OUR_CONTAINERS[@]} entr(y|ies): ${OUR_CONTAINERS[*]}"

estate_svc="cloudflared"
if systemctl is-active --quiet "$estate_svc" 2>/dev/null; then
  ok "$estate_svc is active and WILL BE LEFT RUNNING"
fi

# ============================================================================
# 1. Application objects FIRST
# ============================================================================
# An Argo Application carries a finalizer. Delete the argocd namespace first
# and nothing is left to remove the finalizer, so the namespace sits in
# Terminating forever WITH NO ERROR. Findings 1 and 2.
step "1. Argo CD Applications (must precede the argocd namespace)"
if kc get ns "$ARGOCD_NS" >/dev/null 2>&1; then
  for app in $(kc -n "$ARGOCD_NS" get applications.argoproj.io -o name 2>/dev/null || true); do
    if gate "kubectl -n $ARGOCD_NS delete $app --wait=true --timeout=120s"; then
      kc -n "$ARGOCD_NS" delete "$app" --wait=true --timeout=120s || true
      ok "deleted $app"
    fi
  done
else
  ok "no argocd namespace (already torn down)"
fi

# ============================================================================
# 2. Application namespaces
# ============================================================================
step "2. application namespaces"
for ns in "${APP_NAMESPACES[@]}"; do
  if kc get ns "$ns" >/dev/null 2>&1; then
    if gate "kubectl delete namespace $ns --wait=false"; then
      kc delete namespace "$ns" --wait=false || true
      ok "deletion requested: $ns"
    fi
  else
    ok "$ns absent"
  fi
done

# ============================================================================
# 3. Helm releases (before their namespaces, or helm fights the deletion)
# ============================================================================
step "3. helm releases"
if command -v helm >/dev/null 2>&1 && kc get ns monitoring >/dev/null 2>&1; then
  for rel in $(sudo -E helm list -A -q 2>/dev/null || true); do
    ns="$(sudo -E helm list -A 2>/dev/null | awk -v r="$rel" '$1==r{print $2}')"
    [ -n "$ns" ] || continue
    case "$rel" in
      kube-prometheus-stack|prometheus|grafana|traefik|cert-manager)
        if gate "helm uninstall $rel -n $ns"; then
          sudo -E helm uninstall "$rel" -n "$ns" || true
          ok "uninstalled $rel from $ns"
        fi ;;
      *) note "leaving unrelated release: $rel ($ns)" ;;
    esac
  done
else
  ok "no reachable helm releases"
fi

# ============================================================================
# 4. Infra namespaces (cluster-scoped CRDs are handled in step 6)
# ============================================================================
step "4. infrastructure namespaces"
for ns in "${INFRA_NAMESPACES[@]}"; do
  if kc get ns "$ns" >/dev/null 2>&1; then
    if gate "kubectl delete namespace $ns --wait=false"; then
      kc delete namespace "$ns" --wait=false || true
      ok "deletion requested: $ns"
    fi
  else
    ok "$ns absent"
  fi
done

# ============================================================================
# 5. wait, and report honestly rather than assuming
# ============================================================================
step "5. wait for namespaces to finish terminating"
if [ "$CONFIRMED" -eq 1 ] && [ "$KEEP_K3S" -eq 1 ]; then
  for _ in $(seq 1 120); do
    left="$(kc get ns --no-headers 2>/dev/null | awk '$2=="Terminating"{print $1}' | tr '\n' ' ')"
    [ -z "$left" ] && break
    sleep 2
  done
  left="$(kc get ns --no-headers 2>/dev/null | awk '$2=="Terminating"{print $1}' | tr '\n' ' ')"
  if [ -n "$left" ]; then
    printf '\nSTUCK: still Terminating: %s\n' "$left"
    printf 'The conditions name the blocker. Read them rather than inferring:\n'
    printf '  kubectl get ns -o json | jq -r %s\n' \
      "'.items[] | .metadata.name as \$n | (.status.conditions // [])[] | \"\\(\): \\(.type) \\(.message // \"\")\"'"
    exit 1
  fi
  ok "cluster objects gone"
else
  note "skipped (dry run, or k3s is about to be removed wholesale)"
fi

# ============================================================================
# 6. Docker leftovers
# ============================================================================
step "6. AskVault docker leftovers (allowlist only)"
for c in "${OUR_CONTAINERS[@]}"; do
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
    if gate "docker rm -f $c"; then
      docker rm -f "$c" >/dev/null && ok "removed container $c"
    fi
  else
    ok "container $c absent"
  fi
done

# Leftover AskVault images. Removed because a warm image cache is exactly the
# hidden state that lets a rebuild "succeed" without exercising the registry.
step "7. AskVault images (so the rebuild really pulls from ghcr)"
if [ "$CONFIRMED" -eq 1 ]; then
  imgs="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E '^(ghcr\.io/benzac708/askvault|askvault:)' || true)"
  if [ -n "$imgs" ]; then
    printf '%s\n' "$imgs" | while read -r i; do
      docker rmi -f "$i" >/dev/null 2>&1 && ok "removed image $i" || note "could not remove $i"
    done
  else
    ok "no askvault images"
  fi
else
  # `gate` signals "skip" with a non-zero return, so it is only safe
  # inside an `if`. Called bare it aborts the script under `set -e`,
  # which is what happened here: the dry run was cut off before step 8
  # and silently never showed the k3s teardown or the verification.
  gate "docker rmi the askvault images" || true
fi

# ============================================================================
# 8. k3s itself — the actual 0%
# ============================================================================
step "8. k3s (the host layer)"
if [ "$KEEP_K3S" -eq 1 ]; then
  note "skipped (--keep-k3s)"
elif [ ! -x /usr/local/bin/k3s-uninstall.sh ]; then
  note "k3s-uninstall.sh not present — k3s does not appear to be installed"
else
  if gate "k3s-uninstall.sh   (stops and removes k3s, its units, /etc/rancher/k3s, /var/lib/kubelet)"; then
    sudo /usr/local/bin/k3s-uninstall.sh || true
    ok "k3s uninstalled"
  fi

  # Upstream LEAVES these, and leaving them means a rebuild that never touches
  # the registry. This is the difference between a real 0% and a warm one.
  if gate "rm -rf /var/lib/rancher/k3s /etc/rancher/node   (containerd content store + node password)"; then
    sudo rm -rf /var/lib/rancher/k3s /etc/rancher/node
    ok "removed /var/lib/rancher/k3s and /etc/rancher/node"
  fi

  # /run is tmpfs, but a stopped-but-not-reaped runtime can hold it open.
  if gate "rm -rf /run/k3s /run/flannel /var/log/pods /var/log/containers"; then
    sudo rm -rf /run/k3s /run/flannel /var/log/pods /var/log/containers
    ok "removed runtime and pod log dirs"
  fi

  # The systemd drop-in added by hack/10-k3s.sh must go too, or a fresh install
  # inherits flags that were meant for the old unit.
  if gate "rm -rf /etc/systemd/system/k3s.service.d"; then
    sudo rm -rf /etc/systemd/system/k3s.service.d
    sudo systemctl daemon-reload
    ok "removed k3s unit drop-in"
  fi
fi

# ============================================================================
# 9. VERIFY, don't assert
# ============================================================================
step "9. verification"
if [ "$CONFIRMED" -eq 0 ]; then
  note "skipped in dry run"
else
  if [ "$KEEP_K3S" -eq 0 ]; then
    [ -x /usr/local/bin/k3s ] && fail "k3s binary still present" || ok "k3s binary gone"
    [ -d /var/lib/rancher/k3s ] && fail "/var/lib/rancher/k3s still present — rebuild would reuse cached images" || ok "containerd store gone"
    [ -d /etc/rancher/k3s ] && fail "/etc/rancher/k3s still present" || ok "/etc/rancher/k3s gone"
    systemctl is-active --quiet k3s && fail "k3s unit still active" || ok "k3s unit inactive"
  fi

  # The estate must be untouched. Assert it rather than assuming it.
  systemctl is-active --quiet cloudflared && ok "cloudflared still active (untouched)" \
    || fail "cloudflared is NOT active — this script should not have affected it"
  [ -f /etc/cloudflared/config.yml ] && ok "tunnel config intact" || fail "tunnel config missing"
  [ -f /etc/caddy/Caddyfile ] && ok "Caddyfile intact" || fail "Caddyfile missing"

  # And the app should now be unreachable — that is the expected, honest state.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://askvault.zachara.dev/ 2>/dev/null || echo 000)"
  case "$code" in
    200) note "askvault.zachara.dev still returns 200 — the teardown did NOT take effect" ;;
    502|503|504) ok "askvault.zachara.dev -> $code (tunnel up, nothing behind it: correct)" ;;
    000|404) ok "askvault.zachara.dev -> $code (expected during teardown)" ;;
    *) note "askvault.zachara.dev -> $code" ;;
  esac
fi

printf '\nTEARDOWN %s\n' "$([ "$CONFIRMED" -eq 1 ] && echo COMPLETE || echo 'PLANNED (dry run)')"
printf 'LEFT RUNNING, by design: cloudflared, Caddy, and every other estate service.\n'
printf 'TO REBUILD: hack/00-preflight.sh -> 10-k3s.sh -> 20-argocd.sh -> 30-traefik.sh\n'
printf '            -> 40-cloudflare.sh -> 50-gitops.sh -> 31-monitoring.sh -> 99-acceptance.sh\n'
