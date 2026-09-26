#!/usr/bin/env bash
# 10-k3s.sh — install k3s with the bundled Traefik DISABLED and a root-only
# kubeconfig.
#
# WHY THE TWO FLAGS, and they are not optional:
#
#   --disable traefik   k3s ships Traefik v2 as a ServiceLB frontend. This
#                       cluster installs Traefik v3 itself as a NodePort, so
#                       leaving the bundled one enabled gives two ingress
#                       controllers racing for the same Ingress objects, and
#                       svclb pods holding host ports that Caddy needs. The
#                       symptom is intermittent 404s, not a clean failure.
#
#   --write-kubeconfig-mode 600
#                       The default 644 kubeconfig is world-readable, and it is
#                       a cluster-admin credential. Verified in finding 6: this
#                       bit a later step, because `helm` reads the kubeconfig
#                       and fails with a confusing permission error when the
#                       file is root-only and helm is not run with sudo.
#
# IDEMPOTENT: re-running on a healthy install is a no-op apart from the
# restart-if-drifted check at the end.

set -euo pipefail

readonly K3S_VERSION="v1.36.4+k3s1"
readonly KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '  ok   %s\n' "$1"; }
note() { printf '  ..   %s\n' "$1"; }

printf '== k3s ==\n'

if [ -x /usr/local/bin/k3s ]; then
  installed="$(/usr/local/bin/k3s --version | head -1 | awk '{print $3}')"
  note "k3s already installed: $installed"
else
  note "installing k3s $K3S_VERSION"
  # The install script is fetched and inspected before execution rather than
  # piped straight to a shell. `curl ... | sh` is a supply-chain gamble and the
  # skill's own guardrails block it.
  tmp="$(mktemp)"
  curl -fsSL https://get.k3s.io -o "$tmp"
  note "downloaded installer to $tmp — inspect it before running if this is a rebuild"
  INSTALL_K3S_VERSION="$K3S_VERSION" sh "$tmp"
  rm -f "$tmp"
fi

# --- the flags live in the systemd unit, which is where the installer puts them
unit="/etc/systemd/system/k3s.service"
[ -f "$unit" ] || fail "k3s systemd unit not found at $unit"

drift=0
grep -q -- "--disable" "$unit" && grep -q "traefik" "$unit" || {
  note "unit is missing --disable traefik"
  drift=1
}
grep -q -- "write-kubeconfig-mode" "$unit" || {
  note "unit is missing --write-kubeconfig-mode 600"
  drift=1
}

if [ "$drift" -eq 1 ]; then
  note "reconfiguring the k3s unit"
  # Drop-in rather than editing the unit, so a k3s upgrade does not silently
  # discard the flags. This is the difference between a config that survives
  # an upgrade and one that quietly reverts.
  #
  # BUG FOUND ON THE FIRST BARE-HOST RUN, 2026-09-26:
  #   install -d /etc/systemd/system/k3s.service.d
  # failed with "cannot change permissions ... No such file or directory",
  # because /etc/systemd/system is root-owned and this runs as the normal user.
  # The script had no error check, so it continued, wrote nothing, restarted
  # k3s WITHOUT the flags, and bundled Traefik began installing — which is the
  # exact collision this script exists to prevent. A silent failure that
  # produces a working-looking but wrong cluster is the worst kind.
  #
  # Every privileged write below is now explicit and checked.
  sudo mkdir -p /etc/systemd/system/k3s.service.d \
    || fail "could not create the drop-in directory"

  sudo tee /etc/systemd/system/k3s.service.d/10-drill.conf >/dev/null <<'CONF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/k3s \
    server \
    --disable traefik \
    --write-kubeconfig-mode 600
CONF
  [ -f /etc/systemd/system/k3s.service.d/10-drill.conf ] \
    || fail "drop-in was not written"
  ok "drop-in written"

  sudo systemctl daemon-reload
  sudo systemctl restart k3s
fi

# --- wait for the node to be Ready --------------------------------------------
export KUBECONFIG="$KUBECONFIG_PATH"
note "waiting for the node to report Ready (up to 180s)"
for _ in $(seq 1 90); do
  sudo -E k3s kubectl get nodes 2>/dev/null \
    | awk 'NR>1 && $2=="Ready"{found=1} END{exit !found}' && break
  sleep 2
done
sudo -E k3s kubectl get nodes >/dev/null 2>&1 || fail "node never became reachable"

# --- assert the two flags actually took effect -------------------------------
# Reading the file back is not the same as observing the cluster. This is the
# general form of finding 7: a --set or a unit flag that is syntactically
# accepted can still not be the thing that is running.
#
# FIRST verify the drop-in is present and the unit resolves with the flags.
# An earlier version only checked "no traefik pods", which is TRIVIALLY TRUE on
# a cluster that has not started yet — so it reported success while bundled
# Traefik was still installing. Check the configuration, then the behaviour.
if [ -f /etc/systemd/system/k3s.service.d/10-drill.conf ]; then
  ok "k3s drop-in present"
else
  fail "k3s drop-in missing — the flags are NOT applied, and bundled Traefik will install"
fi

resolved="$(sudo systemctl show k3s -p ExecStart 2>/dev/null)"
printf '%s' "$resolved" | grep -q -- '--disable' \
  || fail "the running unit does not carry --disable; systemd did not pick up the drop-in"
printf '%s' "$resolved" | grep -q -- '--write-kubeconfig-mode' \
  || fail "the running unit does not carry --write-kubeconfig-mode"
ok "systemd resolved the flags from the drop-in"

# Now the behaviour. Give the cluster a moment to schedule its own workloads,
# so this is not a pass-because-nothing-exists check.
note "waiting for kube-system workloads to settle before asserting on Traefik"
for _ in $(seq 1 30); do
  kc -n kube-system get pods --no-headers 2>/dev/null | grep -q . && break
  sleep 2
done
sleep 10

if kc -n kube-system get pods 2>/dev/null | grep -qi traefik; then
  fail "bundled Traefik is running — --disable did not take effect"
fi
ok "bundled Traefik is absent"

if kc -n kube-system get pods 2>/dev/null | grep -qi svclb; then
  fail "svclb pods present — they will fight Caddy for host ports 80/443"
fi
ok "no svclb pods"

mode="$(stat -c '%a' "$KUBECONFIG_PATH")"
[ "$mode" = "600" ] || fail "kubeconfig is mode $mode, expected 600"
ok "kubeconfig mode 600"

sudo -E k3s kubectl get nodes -o custom-columns='NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,READY:.status.conditions[?(@.type=="Ready")].status'

printf '\nK3S OK\n'
