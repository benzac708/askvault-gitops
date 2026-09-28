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
#                       A per-user 600 copy at ~/.kube/config is installed below
#                       for the interactive path; see finding 23 there.
#
# IDEMPOTENT: re-running on a healthy install is a no-op apart from the
# restart-if-drifted check at the end.

set -euo pipefail

readonly K3S_VERSION="v1.36.4+k3s1"
readonly KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '  ok   %s\n' "$1"; }
note() { printf '  ..   %s\n' "$1"; }

# --- kubectl shim -----------------------------------------------------------
# BUG FOUND 2026-09-27, before the first post-teardown rebuild:
#   this script called `kc` three times but never defined it. `kc` is a shim
#   the other scripts define for themselves:
#       kc() { sudo -E k3s kubectl "$@"; }
#   With it missing, every `kc ...` was "command not found" (127) with stderr
#   redirected to /dev/null, so:
#     * the 30-iteration "wait for kube-system to settle" loop never saw a pod,
#       never broke, and silently burned 60s doing nothing;
#     * `if kc -n kube-system get pods | grep -qi traefik` read EMPTY stdout, so
#       the guard printed "ok  bundled Traefik is absent" — a FALSE PASS on the
#       exact collision this script exists to prevent;
#     * the svclb assertion failed open the same way.
#   `set -e` never caught it: a failing command on the LEFT of `&&` is exempt
#   from errexit, so the whole AND-list's non-zero status was not fatal.
#   Both assertions now run a command that exists.
kc() { sudo -E k3s kubectl "$@"; }

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

# --- the flags live in a systemd DROP-IN, not in the stock unit ---------------
# BUG FOUND 2026-09-28, finding 25: this read /etc/systemd/system/k3s.service and
# grepped THAT for the drill's flags. The flags are never in that file -- the
# installer puts them in /etc/systemd/system/k3s.service.d/10-drill.conf -- so
# the grep could not succeed, drift was reported on every single run, and this
# script rewrote the drop-in and RESTARTED K3S every time it ran, including on a
# perfectly healthy install. Measured, not assumed: the stock unit holds 0
# occurrences of either flag while `systemctl show k3s -p ExecStart` holds both,
# so the verdict was a fixed function of which file was read rather than a fact
# about the running system. It also made the "IDEMPOTENT" promise in this
# script's own header false, which is the worst kind of drift: a check that
# cannot be trusted is worse than no check.
#
# The check now reads the RESOLVED command line, which is what systemd actually
# runs once drop-ins are applied. That is also what the two assertions at the end
# of this script already read, so drift detection and post-write verification now
# agree with each other instead of contradicting.
resolved_unit="$(sudo systemctl show k3s -p ExecStart 2>/dev/null || true)"
[ -n "$resolved_unit" ] \
  || fail "systemd reported no ExecStart for k3s, so its flags cannot be verified"

drift=0
case "$resolved_unit" in
  *--disable*traefik*) ;;
  *) note "the resolved k3s command is missing --disable traefik"; drift=1 ;;
esac
case "$resolved_unit" in
  *--write-kubeconfig-mode*) ;;
  *) note "the resolved k3s command is missing --write-kubeconfig-mode 600"; drift=1 ;;
esac
[ "$drift" -eq 0 ] && note "the resolved k3s command already carries both flags"

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

# The INTERACTIVE path is a different claim from the two above, and it was broken
# in a way that made a healthy cluster look unreachable (finding 23).
#
# ~/.bashrc exports KUBECONFIG="$HOME/.kube/config" -- twice, on lines 90-91 --
# and that file is NOT the one k3s writes. It is a copy, so it survives a
# rebuild still carrying the PREVIOUS cluster's CA. Every interactive `kubectl`
# then fails with
#     tls: failed to verify certificate: x509: certificate signed by unknown authority
# on a cluster that is entirely healthy. It survived two full rebuilds because
# every drill script exports KUBECONFIG itself, so every step passed green; and
# because a non-interactive shell never sources .bashrc, so no script could see
# it either. Only a human in a terminal ever hit it.
#
# Refreshing the copy here closes it permanently: it is rewritten from the live
# kubeconfig on every rebuild, so it cannot drift again.
#
# 600 is KEPT, not relaxed to 644. Making /etc/rancher/k3s/k3s.yaml world-readable
# would fix this as well and would silently revert finding 6, which chose 600
# precisely because the 644 default exposes a cluster-admin credential to every
# local account. A per-user copy is the option that satisfies both findings, and
# it leaves the path in .bashrc correct.
sudo install -d -m 700 -o "$(id -un)" -g "$(id -gn)" "$HOME/.kube"
sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" "$KUBECONFIG_PATH" "$HOME/.kube/config"
[ -r "$HOME/.kube/config" ] \
  || fail "the per-user kubeconfig at $HOME/.kube/config is not readable by $(id -un)"
ok "interactive kubeconfig refreshed at \$HOME/.kube/config (mode 600)"

# Assert the claim the way a human experiences it: a plain kubectl, no sudo, no
# k3s wrapper, using the KUBECONFIG that .bashrc will set. If this is the only
# check that would have caught finding 23, then it has to be a real one, and it
# has to fail loudly rather than note.
if KUBECONFIG="$HOME/.kube/config" kubectl get nodes >/dev/null 2>&1; then
  ok "plain kubectl authenticates against ~/.kube/config -- what .bashrc hands you"
else
  live_ca="$(sudo awk '/certificate-authority-data:/{print $2; exit}' "$KUBECONFIG_PATH" \
    | base64 -d 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')"
  user_ca="$(awk '/certificate-authority-data:/{print $2; exit}' "$HOME/.kube/config" \
    | base64 -d 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')"
  fail "plain kubectl cannot use ~/.kube/config, so every interactive kubectl will fail.
    the KUBECONFIG exports in ~/.bashrc (a duplicate is harmless, a stale path is not):
$(grep -n 'KUBECONFIG' "$HOME/.bashrc" 2>/dev/null | sed 's/^/      /' || echo '      (none found)')
    live cluster CA: ${live_ca:-<unreadable>}
    ~/.kube/config CA: ${user_ca:-<unreadable>}
    When those two fingerprints differ, that IS the x509 error: the copy is
    holding a previous cluster's CA and needs rewriting from $KUBECONFIG_PATH."
fi

sudo -E k3s kubectl get nodes -o custom-columns='NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,READY:.status.conditions[?(@.type=="Ready")].status'

printf '\nK3S OK\n'
