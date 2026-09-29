#!/usr/bin/env bash
# 00-preflight.sh - verify the host before installing anything.
#
# WHY THIS EXISTS. The first drill attempt discovered two occupied host ports by
# having Traefik silently fail to bind. A port collision found here costs ten
# seconds; found later it costs an afternoon, because the symptom is "the
# ingress controller is up but nothing routes".
#
# This script CHANGES NOTHING. It only refuses to continue if the host does not
# match what the rest of the sequence assumes.

set -euo pipefail

readonly HOST_PORTS_RESERVED=(80 443 8080 30080 30443)
readonly MIN_FREE_DISK_GB=20
readonly MIN_RAM_GB=8

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '  ok   %s\n' "$1"; }
note() { printf '  ..   %s\n' "$1"; }

printf '== preflight ==\n'

# --- architecture. The whole image path assumes arm64. ------------------------
arch="$(uname -m)"
[ "$arch" = "aarch64" ] || fail "expected aarch64, got $arch - the images in this drill are arm64-only"
ok "architecture: $arch"

# --- memory. Zero swap by design, so RAM headroom is a hard constraint. -------
ram_gb="$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)"
[ "$ram_gb" -ge "$MIN_RAM_GB" ] || fail "need >= ${MIN_RAM_GB}G RAM, have ${ram_gb}G"
ok "memory: ${ram_gb}G"

swap_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
[ "$swap_kb" -eq 0 ] || note "swap is enabled (${swap_kb}kB); this drill assumes none"
ok "swap: $([ "$swap_kb" -eq 0 ] && echo none || echo present)"

# --- disk ---------------------------------------------------------------------
disk_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
[ "$disk_gb" -ge "$MIN_FREE_DISK_GB" ] || fail "need >= ${MIN_FREE_DISK_GB}G free, have ${disk_gb}G"
ok "disk free: ${disk_gb}G"

# --- the tooling every later script needs -------------------------------------
# NOTE ON PATH: non-interactive SSH does NOT source .profile, so ~/.local/bin is
# absent and `uv`, `trivy`, `hadolint` are "command not found" even though they
# work interactively. That asymmetry hid for nine phases of manual drilling.
# Every script in this directory exports PATH explicitly for that reason.
export PATH="$HOME/.local/bin:$PATH"

# REQUIRED tools must already exist. OPTIONAL ones may be absent on a bare host
# because a LATER script installs them.
#
# BUG FOUND ON THE FIRST BARE-HOST RUN, 2026-09-26: this script demanded
# `kubectl` and `k3s`, and both are created BY 10-k3s.sh. On a host that had
# just been torn down to 0%, preflight failed immediately with
# "kubectl not found" - meaning the first step of the rebuild could never pass
# on the very host state it exists to verify. A precondition check must only
# require what its OWN step needs, never what a later step provides.
# docker is genuinely required before any of this: the rebuild does not install
# it, and a missing docker would only surface several steps later.
command -v docker >/dev/null 2>&1 || fail "docker not found on PATH (the rebuild does not install it)"
ok "found docker (required)"

for tool in k3s kubectl helm; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "found $tool"
  else
    note "$tool absent - installed by a later script, expected on a bare host"
  fi
done

# --- the reserved ports must be free, OR already owned by us -----------------
# `ss` needs root for the owning-process column. Absence of the column is not
# evidence of a free port, which is exactly how the original collision hid.
busy=""
for p in "${HOST_PORTS_RESERVED[@]}"; do
  if ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then
    busy="$busy $p"
  fi
done
if [ -n "$busy" ]; then
  note "ports already listening:$busy"
  note "80/443 should belong to Caddy only. 30080/30443 are Traefik's NodePorts."
  note "Confirm with: sudo ss -ltnp | grep -E ':(80|443|30080|30443)\\s'"
else
  ok "reserved ports free: ${HOST_PORTS_RESERVED[*]}"
fi

# --- kubeconfig, if a cluster is already present ------------------------------
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
  mode="$(stat -c '%a' /etc/rancher/k3s/k3s.yaml)"
  [ "$mode" = "600" ] || fail "/etc/rancher/k3s/k3s.yaml is mode $mode, expected 600"
  ok "existing kubeconfig is mode 600"
else
  note "no cluster yet - 10-k3s.sh will create one"
fi

printf '\nPREFLIGHT OK\n'
