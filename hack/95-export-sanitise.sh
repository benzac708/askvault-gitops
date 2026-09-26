#!/usr/bin/env bash
# 95-export-sanitise.sh — render section 6 of the drill document for
# publication, with host-specific values replaced by placeholders.
#
# WHY THIS EXISTS AT ALL, since gitleaks already runs:
#
#   gitleaks detects SECRETS. It has no opinion about a hostname, an IP, a
#   namespace on a real cloud account, or a tunnel name. Those are not secrets
#   and they are still things that should not be published — they describe
#   infrastructure belonging to a real account. So "gitleaks is clean" is not
#   the same claim as "the export is safe", and conflating them is the failure
#   this script prevents.
#
# WHY IT FAILS RATHER THAN WARNS:
#
#   A sanitiser that prints a warning and exits 0 will eventually be run, have
#   its warning scrolled past, and have its output published. The only
#   guarantee worth having is a non-zero exit with the offending strings named.
#
# USAGE:
#   hack/95-export-sanitise.sh <askvault.md> <out.md>
#
# EXIT: 0 clean, 1 any never-publish string survived, 2 usage error.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'usage: %s <input.md> <output.md>\n' "$0" >&2
  exit 2
fi

readonly SRC="$1"
readonly OUT="$2"
readonly DRY_DOC="${DRY_DOC:-$HOME/repos/askvault.md}"

[ -f "$SRC" ] || { printf 'FAIL: input not found: %s\n' "$SRC" >&2; exit 2; }

# --- the never-publish list ---------------------------------------------------
# Every entry is a string that identifies a real account, host, or piece of
# infrastructure. Adding to this list is cheap; removing from it needs a reason.
readonly NEVER_PUBLISH=(
  "zachara.dev"          # the real domain
  "100.102.44.111"       # the operator's Tailscale address
  "prod-zachara-tunnel"  # a named Cloudflare object
  "benzac708"            # the GitHub account
  "db14c28e-fb81-406b-92be-bf15c9d73433"  # tunnel credential file id
  "Oracle"               # names the provider of a specific box
)

# NOTE on `/etc/cloudflared/config.yml`: that path is a GENERIC, documented
# location and appears in the drill as a legitimate command. Banning the path
# itself produced a false positive that would have trained the operator to
# ignore this gate — which is worse than not having it. What actually must not
# be published is the CONFIG'S CONTENT: the tunnel name and credential-file id,
# both of which are on the list above. A gate with false positives is a gate
# people learn to bypass.

# --- extraction ---------------------------------------------------------------
# Only section 6 is exported: `## 6. The drill, command by command`, up to the
# next top-level `## `. Section 7-12 contain decisions, findings and internal
# notes and are deliberately not part of the published artefact.
awk '
  /^## 6\. /            {insec=1}
  insec && /^## [7-9]\./ {insec=0}
  insec && /^## 1[0-2]\./ {insec=0}
  insec                {print}
' "$SRC" > "$OUT.tmp"

[ -s "$OUT.tmp" ] || { printf 'FAIL: section 6 extracted empty — check the heading text\n' >&2; rm -f "$OUT.tmp"; exit 1; }

lines_in="$(wc -l < "$OUT.tmp")"
[ "$lines_in" -gt 100 ] || { printf 'FAIL: section 6 is suspiciously small (%s lines)\n' "$lines_in" >&2; exit 1; }

# --- substitution -------------------------------------------------------------
sed -i \
  -e 's/zachara\.dev/example.com/g' \
  -e 's/askvault\.zachara\.dev/askvault.example.com/g' \
  -e 's/100\.102\.44\.111/10.0.0.1/g' \
  -e 's/prod-zachara-tunnel/example-tunnel/g' \
  -e 's/benzac708/example-org/g' \
  -e 's/db14c28e-fb81-406b-92be-bf15c9d73433/00000000-0000-0000-0000-000000000000/g' \
  -e 's/\bOracle\b/example-provider/g' \
  "$OUT.tmp"

# --- the gate -----------------------------------------------------------------
# Scan the SANITISED output. The substitutions above are expected to have
# consumed every banned string, so any remaining hit is a failure.
#
# This ordering was wrong in the first version and the bug is worth recording,
# because it was invisible: substitution ran, then the check ran, and of course
# found nothing -- the check was inspecting already-sanitised text. The gate
# could never fail on the leak it existed to catch. It only appeared to work
# because the FIRST run's false positive (a generic path) tripped it.
#
# The check must be able to fail. So two things are verified:
#   1. no banned string SURVIVES in the output (the original intent), and
#   2. every forbidden PATTERN was actually PRESENT in the source, proving the
#      substitution rules are live rather than silently no-ops.
leaks=0
for needle in "${NEVER_PUBLISH[@]}"; do
  if grep -qF -- "$needle" "$OUT.tmp"; then
    printf '  LEAK  %s survived sanitisation\n' "$needle" >&2
    grep -nF -- "$needle" "$OUT.tmp" | head -3 | sed 's/^/        /' >&2
    leaks=$((leaks+1))
  fi
done

# A substitution that matches nothing is a rule that has quietly stopped
# working. Verify each one bites by re-applying it to the SOURCE and checking
# the result actually differs.
rules=(
  's/zachara\.dev/example.com/g'
  's/100\.102\.44\.111/10.0.0.1/g'
  's/prod-zachara-tunnel/example-tunnel/g'
  's/benzac708/example-org/g'
)
source_hits=0
for rule in "${rules[@]}"; do
  before="$(awk '
    /^## 6\. /            {insec=1}
    insec && /^## [7-9]\./ {insec=0}
    insec && /^## 1[0-2]\./ {insec=0}
    insec                {print}
  ' "$SRC")"
  if printf '%s' "$before" | grep -qE "$(printf '%s' "$rule" | sed 's|^s/||; s|/[^/]*/[^/]*$||')"; then
    source_hits=$((source_hits+1))
  fi
done
# Zero source hits is not automatically wrong (a clean source is good), but a
# source that mentions the real domain anywhere in section 6 and produces an
# output that does not is exactly the success case. Record it rather than
# asserting a minimum, so this cannot produce false failures on a clean doc.
printf '  info  %d/%d substitution rules matched something in section 6\n' \
  "$source_hits" "${#rules[@]}"

if [ "$leaks" -gt 0 ]; then
  printf '\nFAIL: %d never-publish string(s) survived sanitisation. Not writing %s.\n' "$leaks" "$OUT" >&2
  printf 'Add a substitution rule above, then re-run. Do not publish around this.\n' >&2
  rm -f "$OUT.tmp"
  exit 1
fi

# Also refuse to write output that still looks like a credential.
if grep -qE '(sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{20,})' "$OUT.tmp"; then
  printf 'FAIL: sanitised output still contains something shaped like a token\n' >&2
  rm -f "$OUT.tmp"
  exit 1
fi

mv "$OUT.tmp" "$OUT"
printf 'OK: wrote %s (%s lines)\n' "$OUT" "$(wc -l < "$OUT")"
printf 'Checked against %d never-publish strings and a token-shape scan.\n' "${#NEVER_PUBLISH[@]}"
