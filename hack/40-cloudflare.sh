#!/usr/bin/env bash
# 40-cloudflare.sh — point the tunnel's hostname at Traefik's NodePort.
#
# WHAT THIS SCRIPT DOES NOT DO, DELIBERATELY:
#
#   It does not create the tunnel, and it does not create the DNS record.
#   `prod-zachara-tunnel` is a NAMED object on a Cloudflare account, and
#   `askvault.zachara.dev` is a DNS record in that account's zone. Neither can
#   be recreated from this repository, by this script, or by anyone without
#   account access. That is a permanent property of this deployment and it is
#   stated rather than papered over.
#
#   What this script does is the part that IS reproducible: write the ingress
#   rule that binds that existing hostname to the local NodePort, and verify
#   the whole chain answers.
#
# WHY THE RULE POINTS AT localhost:30080 AND NOT AT THE APP:
#
#   cloudflared terminates the tunnel on the host and forwards to a local port.
#   It knows nothing about Kubernetes. Traefik's NodePort is the seam, and the
#   Ingress inside the cluster decides which host lands on which Service. The
#   catch-all `http_status:404` at the end is load-bearing: without it,
#   cloudflared serves an unmatched hostname from the FIRST rule, which makes
#   typos look like successful routing.
#
# IDEMPOTENT: the ingress list is regenerated in full from this script's own
# view, and the previous config is backed up before being replaced.

set -euo pipefail

readonly CONFIG="/etc/cloudflared/config.yml"
readonly CF_HOSTNAME="${CF_HOSTNAME:-askvault.zachara.dev}"
readonly NODEPORT_HTTP=30080

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '  ok   %s\n' "$1"; }
note() { printf '  ..   %s\n' "$1"; }

printf '== cloudflare tunnel route ==\n'

# --- read the config ONCE, with privilege -------------------------------------
# BUG FOUND ON THE FIRST BARE-HOST RUN, 2026-09-27:
#     awk: fatal: cannot open file `/etc/cloudflared/config.yml': Permission denied
#
# The config is mode 600, root-owned. Every one of the six awk/grep reads below
# was unprivileged, so the script died on the first one. Sprinkling `sudo` on
# each call would be six chances to forget one — and a later read that fails
# quietly returns an empty string, which on THIS script means "the rule is
# missing, rewrite the file". That is a permission error masquerading as a
# routing decision, and it would have rewritten a working tunnel config.
#
# So: read once, into a variable, and assert the read worked. Everything below
# inspects $cfg and cannot silently see an empty file.
cfg="$(sudo cat "$CONFIG" 2>/dev/null || true)"
[ -n "$cfg" ] || fail "cannot read $CONFIG (permission or missing file).
This script needs sudo to read the tunnel config. Do not continue: an unreadable
config looks identical to an empty one, and the rewrite path would then clobber
a working tunnel."
ok "read $CONFIG ($(printf '%s\n' "$cfg" | wc -l) lines)"

config_status() { sudo stat -c '%a root:%U' "$CONFIG" 2>/dev/null || echo "unknown"; }
note "mode: $(config_status)"

systemctl is-active --quiet cloudflared || fail "cloudflared service is not active"
ok "cloudflared service active"

tunnel="$(printf '%s\n' "$cfg" | awk '$1=="tunnel:"{print $2}')"
[ -n "$tunnel" ] || fail "no 'tunnel:' line in $CONFIG"
note "existing tunnel: $tunnel (NOT created by this script, and not recreatable by it)"

# --- is the hostname already routed correctly? --------------------------------
# Inspect the ALREADY-READ config. A failure here must not be able to look like
# "no route exists".
if printf '%s\n' "$cfg" | awk -v h="$CF_HOSTNAME" -v p="$NODEPORT_HTTP" '
      $1=="-" && $2=="hostname:" && $3==h {inh=1; next}
      inh && $1=="service:" {print $2; exit}
    ' | grep -qx "http://localhost:${NODEPORT_HTTP}"; then
  ok "$CF_HOSTNAME already routes to http://localhost:${NODEPORT_HTTP}"
else
  note "writing the ingress rule for $CF_HOSTNAME -> http://localhost:${NODEPORT_HTTP}"

  backup="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  sudo cp -p "$CONFIG" "$backup"
  sudo chmod 600 "$backup"
  ok "backed up existing config to $backup"

  # PRESERVE every pre-existing rule; only add or replace ours. Rewriting the
  # whole file from a template would silently drop the other hostnames on this
  # tunnel, which is the kind of blast radius a "small" script should never
  # have.
  #
  # The python reads the ALREADY-PRIVILEGED copy from a temp file and writes the
  # result to stdout. Two reasons:
  #
  #   1. It cannot fail on permissions, because it never opens the real config.
  #   2. `... | python3 <<'PY' | tee` does NOT work. A heredoc replaces that
  #      command's stdin, so the piped config is silently discarded and python
  #      reads its SCRIPT from stdin instead (shellcheck SC2259). A path
  #      argument is unambiguous.
  #
  # The result is written with privilege and the mode reasserted, because `cp`
  # onto an existing file keeps the destination's mode but `tee` would not.
  tmp_in="$(mktemp)"
  tmp_out="$(mktemp)"
  printf '%s\n' "$cfg" > "$tmp_in"

  python3 - "$tmp_in" "$CF_HOSTNAME" "$NODEPORT_HTTP" > "$tmp_out" <<'PY'
import sys

path, host, port = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()

try:
    idx = next(i for i, l in enumerate(lines) if l.strip() == "ingress:")
except StopIteration:
    sys.exit("no 'ingress:' block found")

head, rules = lines[:idx + 1], lines[idx + 1:]

out, skip = [], False
for l in rules:
    stripped = l.strip()
    if stripped.startswith("- hostname:"):
        skip = stripped.split("hostname:", 1)[1].strip() == host
        if not skip:
            out.append(l)
        continue
    if skip and stripped.startswith("service:"):
        continue
    if stripped.startswith("- service:") or stripped.startswith("service:"):
        continue
    out.append(l)

while out and not out[-1].strip():
    out.pop()

out += [
    f"  - hostname: {host}",
    f"    service: http://localhost:{port}",
    "  - service: http_status:404",
]

sys.stdout.write("\n".join(head + out) + "\n")
PY

  # Refuse to install an obviously broken result. A config missing its ingress
  # block or its catch-all takes the WHOLE tunnel down, including hostnames that
  # have nothing to do with this project.
  cleanup() { rm -f "$tmp_in" "$tmp_out"; }

  grep -q '^ingress:' "$tmp_out" || { cleanup; fail "generated config has no ingress block — refusing to apply"; }
  grep -q 'http_status:404' "$tmp_out" || { cleanup; fail "generated config lost the catch-all — refusing to apply"; }
  grep -q "$CF_HOSTNAME" "$tmp_out" || { cleanup; fail "generated config lacks $CF_HOSTNAME — refusing to apply"; }

  # BLAST-RADIUS GUARD: every hostname that existed before must still exist.
  for other in $(printf '%s\n' "$cfg" | awk '$1=="-" && $2=="hostname:"{print $3}'); do
    [ "$other" = "$CF_HOSTNAME" ] && continue
    grep -q "$other" "$tmp_out" || { cleanup; fail "generated config DROPPED $other — refusing to apply"; }
  done

  sudo cp "$tmp_out" "$CONFIG"
  cleanup
  sudo chmod 600 "$CONFIG"
  note "restarting cloudflared"
  systemctl restart cloudflared
  sleep 5
fi

systemctl is-active --quiet cloudflared || fail "cloudflared did not come back after restart"
ok "cloudflared restarted and active"

# --- read the config back -----------------------------------------------------
# Reads from $cfg, the already-privileged copy. Not from the file.
resolved="$(printf '%s\n' "$cfg" | awk -v h="$CF_HOSTNAME" '
    $1=="-" && $2=="hostname:" && $3==h {inh=1; next}
    inh && $1=="service:" {print $2; exit}')"
[ "$resolved" = "http://localhost:${NODEPORT_HTTP}" ] \
  || fail "$CF_HOSTNAME resolves to '$resolved', expected http://localhost:${NODEPORT_HTTP}"
ok "$CF_HOSTNAME -> $resolved"

tail_rule="$(printf '%s\n' "$cfg" | awk '$1=="-" && $2=="service:"{print $3}' | tail -1)"
[ "$tail_rule" = "http_status:404" ] \
  || fail "no catch-all 404 rule at the end — unmatched hostnames would be served by the first rule"
ok "catch-all http_status:404 present"

# --- the chain, from outside the cluster -------------------------------------
# WHAT THIS CAN AND CANNOT ASSERT, and the distinction matters for the order the
# scripts run in.
#
#   40-cloudflare.sh runs BEFORE 50-gitops.sh. At this point the tunnel is
#   configured correctly but no Ingress exists, so a 404 is the CORRECT and
#   EXPECTED response — not a failure. An earlier version failed here, which
#   would have blocked a perfectly good rebuild at step 5 of 8.
#
#   The chain cannot be fully asserted until GitOps has applied the Ingress.
#   99-acceptance.sh is where that belongs, and it does assert it.
#
# So this step verifies what it is responsible for (the route), and reports the
# end-to-end result without treating the normal mid-rebuild state as an error.
note "asserting the chain: cloudflared -> Caddy/Traefik"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${CF_HOSTNAME}/" || true)"
note "https://${CF_HOSTNAME}/ -> HTTP $code"

case "$code" in
  200)
    ok "the public hostname serves the app — full chain is live"
    ;;
  404)
    # Expected before 50-gitops.sh. The tunnel is doing its job; the cluster
    # simply has no Ingress for this host yet.
    note "404 is EXPECTED at this stage: no Ingress exists until 50-gitops.sh"
    ok "route configured; end-to-end verification happens at 99-acceptance.sh"
    ;;
  502|503|504)
    fail "gateway error $code — cloudflared is up but nothing answered behind it.
Check, in order: Traefik listening on :${NODEPORT_HTTP}; an Ingress for this
hostname (50-gitops.sh). Run 30-traefik.sh then 50-gitops.sh." ;;
  000)
    fail "no response at all — check DNS for ${CF_HOSTNAME} and 'systemctl status cloudflared'" ;;
  *)
    fail "unexpected HTTP $code" ;;
esac

printf '\nCLOUDFLARE ROUTE OK\n'
printf 'NOTE: the tunnel and the DNS record are account-side and are NOT reproduced by this script.\n'
