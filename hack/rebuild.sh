#!/usr/bin/env bash
# rebuild.sh — run the whole rebuild, in the one order that works, from a host
# that has been torn down to 0%.
#
# NOT part of the numbered series it runs. It is the thing that runs the series,
# which is why it has no number prefix — a number here would claim a place in
# the dependency order that it does not occupy.
#
# WHY THIS IS A FILE AND NOT A FOR LOOP TYPED AT THE PROMPT
#
#   The obvious one-liner is:
#       for s in 00-preflight 10-k3s ...; do bash hack/$s.sh || break; done
#   and it is WRONG. `cmd || break` leaves the for loop's exit status at 0, so
#   the whole construct exits 0 EVEN WHEN A STEP FAILED. A rebuild that died at
#   50-gitops reports success to whatever ran it.
#
#   `set -e` does not rescue it: the failing command sits on the left of `||`,
#   which is exempt from errexit, and errexit is not consulted for the exit
#   status of the list. This script keeps a failure count and exits non-zero.
#
#   That is the 20th instance of this project's one recurring bug class: every
#   failure so far has been in a CHECK or an ORCHESTRATOR, never in the
#   infrastructure. A gate that fails open is the same defect as an assertion
#   that passes for the wrong reason — it is worse, because an assertion is
#   noticed and a gate is trusted.
#
# SECOND JOB: fail BEFORE burning eight minutes.
#   50-gitops.sh builds the askvault-llm secret from OPENROUTER_API_KEY. Finding
#   that out at step 7 of 8, after six green steps, is an expensive way to learn
#   about a missing variable. An undeclared prerequisite that fails loudly up
#   front beats one that fails halfway.
#
# THIRD JOB: state the order ONCE, with the reason.
#   The number prefix reads like it encodes the sequence. It does not.
#   31-monitoring.sh runs AFTER 50-gitops.sh, not before it, because a
#   ServiceMonitor has nothing to scrape until the Deployment exists. Numbering
#   is thematic, order is dependency. Believing otherwise yields a green run
#   with an empty dashboard.
#
# No --yes gate, deliberately: unlike 90-teardown.sh this does not destroy
# anything. It is additive. The one destructive thing in the drill is teardown,
# and that is where the confirmation belongs.

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

HACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HACK_DIR

# THE ORDER. Dependency, not numeric sort. This array is the single source of
# truth for the sequence; nothing else may reorder it.
readonly ALL_STEPS=(
  00-preflight    # host facts, ports, tooling. Changes nothing.
  10-k3s          # the cluster
  20-argocd       # GitOps. Needs the cluster.
  30-traefik      # ingress. Needs the cluster.
  40-cloudflare   # edge rule -> Traefik NodePort. Needs 30.
  50-gitops       # the app. Needs Argo CD (20) and a published endpoint (40).
  31-monitoring   # AFTER 50, not before: the ServiceMonitor scrapes the app.
  99-acceptance   # the gate. Needs the whole platform up.
)

fail() { printf 'FAIL: %s\n' "$1" >&2; }
ok()   { printf '  ok   %s\n' "$1"; }
note() { printf '  ..   %s\n' "$1"; }

usage() {
  cat <<'HELP'
rebuild.sh — rebuild k3s + Argo CD + Traefik + the app, in dependency order.

USAGE
  rebuild.sh                          run every step, stop at the first failure
  rebuild.sh --from 50-gitops        start at a step, continue to the end
  rebuild.sh --only 50-gitops,99-acceptance
                                      run just these, in the order given
  rebuild.sh --list                   print the step order and exit
  rebuild.sh --help                   this text

EXIT STATUS
  0   every selected step passed
  1   a step failed, or a prerequisite was missing before any step ran
  2   bad usage

NOTES
  The run stops at the first failing step on purpose. Running the remaining
  steps on a broken foundation produces a second, misleading failure that
  hides the first one.
HELP
}

is_step() {
  local candidate="$1" s
  for s in "${ALL_STEPS[@]}"; do
    if [ "$s" = "$candidate" ]; then return 0; fi
  done
  return 1
}

# --- parse -------------------------------------------------------------------
mode=full
want=""
steps=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from)
      [ "$#" -ge 2 ] || { fail "--from needs a step name"; usage >&2; exit 2; }
      mode=from
      want="$2"
      shift 2
      ;;
    --only)
      [ "$#" -ge 2 ] || { fail "--only needs a comma-separated step list"; usage >&2; exit 2; }
      mode=only
      want="$2"
      shift 2
      ;;
    --list)
      printf '%s\n' "${ALL_STEPS[@]}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

case "$mode" in
  full)
    steps=("${ALL_STEPS[@]}")
    ;;
  from)
    idx=-1
    i=0
    for s in "${ALL_STEPS[@]}"; do
      if [ "$s" = "$want" ]; then idx=$i; break; fi
      i=$((i + 1))
    done
    if [ "$idx" -lt 0 ]; then
      fail "unknown step: $want"
      printf '       known steps: %s\n' "${ALL_STEPS[*]}" >&2
      exit 2
    fi
    steps=("${ALL_STEPS[@]:idx}")
    ;;
  only)
    IFS=',' read -r -a requested <<<"$want"
    for r in "${requested[@]}"; do
      if ! is_step "$r"; then
        fail "unknown step: $r"
        printf '       known steps: %s\n' "${ALL_STEPS[*]}" >&2
        exit 2
      fi
      steps+=("$r")
    done
    ;;
esac

[ "${#steps[@]}" -gt 0 ] || { fail "no steps selected"; exit 2; }

# --- the one prerequisite, before step 1 -------------------------------------
# Checked here, not discovered at step 7. Same reasoning as 00-preflight.sh:
# a precondition check must only require what the run actually needs, and it
# must say so before the expensive part starts.
needs_key=0
for s in "${steps[@]}"; do
  if [ "$s" = "50-gitops" ]; then needs_key=1; break; fi
done

if [ "$needs_key" -eq 1 ] && [ -z "${OPENROUTER_API_KEY:-}" ]; then
  fail "OPENROUTER_API_KEY is not set, and this run includes 50-gitops"
  note "50-gitops.sh builds the askvault-llm secret from that variable"
  note "export OPENROUTER_API_KEY=... and re-run, or --only to skip it"
  exit 1
fi

# --- run ---------------------------------------------------------------------
printf '== rebuild ==\n'
case "$mode" in
  full) note "full rebuild, ${#steps[@]} steps" ;;
  from) note "from $want onward, ${#steps[@]} steps" ;;
  only) note "only ${#steps[*]}, ${#steps[@]} steps" ;;
esac
if [ "$needs_key" -eq 1 ]; then
  ok "OPENROUTER_API_KEY present (len ${#OPENROUTER_API_KEY})"
else
  note "OPENROUTER_API_KEY not needed by this selection"
fi
printf '\n'

passed=0
failed=""
rc=0
ran=()
start_all=$(date +%s)

for s in "${steps[@]}"; do
  script="$HACK_DIR/$s.sh"
  if [ ! -f "$script" ]; then
    fail "missing script: $script"
    exit 1
  fi

  t0=$(date +%s)
  printf -- '---------- %s ----------\n' "$s"
  if bash "$script"; then
    rc=0
  else
    rc=$?
  fi
  t1=$(date +%s)
  ran+=("$s")

  if [ "$rc" -eq 0 ]; then
    printf -- '---------- %s  PASS  (%ss)\n\n' "$s" "$((t1 - t0))"
    passed=$((passed + 1))
  else
    printf -- '---------- %s  FAIL  rc=%s  (%ss)\n\n' "$s" "$rc" "$((t1 - t0))"
    failed="$s"
    break
  fi
done

total=$(( $(date +%s) - start_all ))

# --- summary -----------------------------------------------------------------
printf '== summary ==\n'

if [ -z "$failed" ]; then
  ok "$passed/${#steps[@]} steps passed in ${total}s"
  printf '\nREBUILD COMPLETE\n'
  exit 0
fi

# What never ran, so the next command is obvious instead of a guess.
notrun=()
past_failure=0
for s in "${steps[@]}"; do
  if [ "$past_failure" -eq 1 ]; then
    notrun+=("$s")
    continue
  fi
  if [ "$s" = "$failed" ]; then past_failure=1; fi
done

note "$passed/${#steps[@]} steps passed, stopped at $failed, ${total}s total"
note "ran:      ${ran[*]}"
if [ "${#notrun[@]}" -gt 0 ]; then
  note "not run:  ${notrun[*]}"
fi
# Resume from the step that FAILED, not from the first unrun one. The failed
# step is the one that needs re-running after it is fixed; starting past it
# would build on top of the thing that is broken.
note "resume:   bash $HACK_DIR/rebuild.sh --from $failed"
printf '\nREBUILD FAILED at %s (rc=%s)\n' "$failed" "$rc"
exit 1
