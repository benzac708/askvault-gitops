#!/usr/bin/env bash
# rebuild.sh - run the whole rebuild, in the one order that works, from a host
# that has been torn down to 0%.
#
# NOT part of the numbered series it runs. It is the thing that runs the series,
# which is why it has no number prefix - a number here would claim a place in
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
#   that passes for the wrong reason - it is worse, because an assertion is
#   noticed and a gate is trusted.
#
# SECOND JOB: CHECK THE CREDENTIAL MATERIAL, before burning eight minutes.
#   AskVault's credentials travel as Sealed Secrets
#   (overlays/prod/sealed-secrets.yaml): encrypted in Git, decrypted in-cluster
#   by the sealed-secrets controller, referenced by the manifests as required
#   secretKeyRefs. A rebuild needs no key prompt and no ~/.docker/config.json -
#   the preflight's job is to confirm the sealed manifests exist and carry
#   SealedSecret entries, because discovering they are missing at step 7 of 8,
#   after six green steps, is the expensive way to learn it.
#
# THIRD JOB: make "rebuild" mean rebuild.
#   45-reset-app.sh drops the app layer so 50-gitops.sh creates it from nothing
#   on every run. Without it a warm cluster takes the "namespace already exists"
#   branch, which prints ok and exits 0 and never reaches the code that finding
#   21a was about. A rebuild that inherits its own output is a refresh, and it
#   proves less each time it is run.
#
# FOURTH JOB: state the order ONCE, with the reason.
#   The number prefix reads like it encodes the sequence. It does not, and this
#   array is now the clearest possible demonstration: 45-reset-app runs BEFORE
#   50-gitops, and 31-monitoring runs AFTER it. Numbering is thematic, order is
#   dependency. Believing otherwise yields a green run with an empty dashboard,
#   or a run whose secrets landed in a namespace that was never created.
#
# FIFTH JOB: be the whole drill, not half of it.
#   Until --from-zero existed, the drill was two commands and the seam between
#   them was a hand-typed list printed by 90-teardown.sh. That list had already
#   drifted -- it was missing 45-reset-app.sh -- and a reader who trusted it
#   after a teardown would have rebuilt a warm app layer and never reached the
#   code that finding 21a was about. That is not a documentation bug, it is a
#   silent downgrade of the claim, and it is the same shape as 21a itself.
#   So: one command, one order, one place it is written down.
#
# ON DESTRUCTION -- read this twice, because it is the part that changes.
#   A plain `rebuild.sh` is additive apart from 45-reset-app.sh, which drops two
#   Applications and two namespaces BY NAME and 50-gitops.sh recreates them a
#   few steps later. That asymmetry is why a plain run needs no --yes and never
#   did: what it drops is scoped and rebuilt, whereas 90-teardown.sh takes the
#   cluster itself.
#
#   `rebuild.sh --from-zero` removes that asymmetry, because it runs the
#   teardown. So --from-zero asks for a typed confirmation, refuses outright
#   without a tty, and requires --yes to skip the prompt. --yes is REJECTED
#   when it appears without --from-zero rather than quietly ignored: a flag that
#   authorises nothing and says it authorised something is worse than no flag.
#
#   The order inside this file is therefore not only a dependency order. The
#   credential gate must be able to refuse, and a refusal that arrives AFTER the
#   cluster is destroyed is a refusal that cost the operator their cluster. So
#   the teardown sits after the key is in hand and before step 1, and nothing
#   else in this script may move across that line.

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
  45-reset-app    # app layer back to nothing, so 50 creates it. Skips if no cluster.
  50-gitops       # the app. Needs Argo CD (20), a published endpoint (40), a cold app.
  31-monitoring   # AFTER 50, not before: the ServiceMonitor scrapes the app.
  99-acceptance   # the gate. Needs the whole platform up.
)

fail() { printf 'FAIL: %s\n' "$1" >&2; }
ok()   { printf '  ok   %s\n' "$1"; }
note() { printf '  ..   %s\n' "$1"; }

usage() {
  cat <<'HELP'
rebuild.sh - rebuild k3s + Argo CD + Traefik + the app, in dependency order.

USAGE
  rebuild.sh                          run every step, stop at the first failure
  rebuild.sh --from 50-gitops        start at a step, continue to the end
  rebuild.sh --only 50-gitops,99-acceptance
                                      run just these, in the order given
  rebuild.sh --from-zero             DESTROY first (90-teardown --yes), then
                                      rebuild from nothing
  rebuild.sh --from-zero --yes       same, without the confirmation prompt
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

  --from-zero is the whole drill in one command, and the only mode that
  destroys the cluster. Three rules it obeys, each because the alternative is
  a way to lose a working host:
    - The credential is collected BEFORE the teardown. A missing key must not
      be learned by destroying the cluster that could have asked again.
    - It requires 99-acceptance in the selection. --from-zero --only 10-k3s
      would destroy everything and rebuild a fragment. That is a mistake, not
      a use case, so it is refused rather than performed.
    - It asks for confirmation unless --yes, and refuses outright without a tty.
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
from_zero=0
assume_yes=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from-zero)
      from_zero=1
      shift
      ;;
    --yes|-y)
      # Only meaningful with --from-zero, and checked for that below rather than
      # accepted silently: a bare `--yes` that quietly does nothing is a flag
      # that lies about what it authorised.
      assume_yes=1
      shift
      ;;
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

# --- --from-zero safety gate --------------------------------------------------
# A flag that authorises destroying the cluster is checked here, before any
# secret is read and long before anything is destroyed.
if [ "$assume_yes" -eq 1 ] && [ "$from_zero" -eq 0 ]; then
  fail "--yes only means something together with --from-zero"
  note "--from-zero destroys the cluster. On its own, this run is additive:"
  note "  45-reset-app.sh drops two Applications and two namespaces by name,"
  note "  and 50-gitops.sh recreates them a few steps later. That asymmetry is"
  note "  why a plain rebuild.sh needs no confirmation and --from-zero does."
  exit 2
fi

if [ "$from_zero" -eq 1 ]; then
  has_gate=0
  for s in "${steps[@]}"; do
    if [ "$s" = "99-acceptance" ]; then has_gate=1; break; fi
  done
  # The gate is what turns "the cluster came back" into "the cluster came back
  # correctly". A destructive run that does not end in the gate rebuilds a
  # fragment and calls it success, which is the failure mode this whole project
  # keeps rediscovering one layer up.
  if [ "$has_gate" -eq 0 ]; then
    fail "--from-zero refuses a selection that does not include 99-acceptance"
    note "The teardown removes the whole cluster. Rebuilding only"
    note "  ${steps[*]}"
    note "and skipping the gate would leave a fragment and report success."
    note "Use --from-zero on its own, or with --from, or add 99-acceptance."
    exit 2
  fi
fi

# --- the one prerequisite, COLLECTED before step 1 ---------------------------
# Resolved here, not discovered at step 7. Same reasoning as 00-preflight.sh: a
# precondition must require only what the run actually needs, and it must
# collect it before the expensive part starts.
needs_sealed=0
for s in "${steps[@]}"; do
  if [ "$s" = "50-gitops" ]; then needs_sealed=1; break; fi
done

# The banner comes FIRST, so the operator knows what is about to start, and how
# long it might take, BEFORE being asked for a secret. A prompt with nothing in
# front of it reads as a demand; the identical prompt sitting under "full
# rebuild, 9 steps" reads as the first step of a procedure.
printf '== rebuild ==\n'
case "$mode" in
  full) note "full rebuild, ${#steps[@]} steps" ;;
  from) note "from $want onward, ${#steps[@]} steps" ;;
  only) note "only ${steps[*]}, ${#steps[@]} steps" ;;
esac
if [ "$from_zero" -eq 1 ]; then
  note "FROM ZERO: the cluster is destroyed first, then rebuilt from nothing"
  note "the estate is not touched: cloudflared, Caddy and every other service stay"
fi

if [ "$needs_sealed" -eq 1 ]; then
  SEALED_CREDS_FILE="${SEALED_CREDS_FILE:-$(cd "$(dirname "$0")/.." && pwd)/overlays/prod/sealed-secrets.yaml}"
  if [ -f "$SEALED_CREDS_FILE" ] && grep -q "kind: SealedSecret" "$SEALED_CREDS_FILE"; then
    ok "sealed credential manifests present ($(basename "$SEALED_CREDS_FILE"))"
  else
    fail "sealed-secrets.yaml is missing or has no SealedSecret entries.
AskVault's credentials are sealed in Git and decrypted in-cluster; without
them the rebuild cannot produce askvault-llm or ghcr-pull. The pod references
are non-optional by design, so a missing secret is a loud
CreateContainerConfigError instead of a healthy pod that quietly 502s."
    exit 1
  fi
else
  note "sealed credentials not needed by this selection"
fi
printf '\n'

# --- the teardown, and WHY it sits here and not earlier ------------------------
# Order is load-bearing in this file for a reason that has nothing to do with
# dependencies: the credential gate above must be able to REFUSE, and a refusal
# after the cluster is destroyed is a refusal that cost the operator everything.
# So the teardown runs after the key is in hand and before step 1. Nothing else
# in the script may move across that line.
teardown_ran=0
if [ "$from_zero" -eq 1 ]; then
  td_script="$HACK_DIR/90-teardown.sh"
  if [ ! -f "$td_script" ]; then
    fail "--from-zero needs $td_script, and it is not there"
    exit 1
  fi

  if [ "$assume_yes" -eq 0 ]; then
    if [ ! -t 0 ]; then
      fail "--from-zero destroys the cluster and stdin is not a terminal"
      note "nothing was destroyed. Re-run with --yes to authorise it:"
      note "  bash $HACK_DIR/rebuild.sh --from-zero --yes"
      note "or, to rebuild WITHOUT destroying, drop the flag:"
      note "  bash $HACK_DIR/rebuild.sh"
      exit 1
    fi
    # Ask about the one thing that cannot be undone. The prompt names the
    # consequence and the count, because "are you sure?" on its own is answered
    # reflexively by whoever typed the command that got them here.
    printf 'This DESTROYS the k3s cluster, all its namespaces and the askvault app.\n'
    printf 'cloudflared, Caddy and every other estate service are left alone.\n'
    printf 'It is then rebuilt from nothing and checked by the gate. Type yes to continue: '
    answer=""
    read -r answer || true
    if [ "$answer" != "yes" ]; then
      fail "not confirmed (got '${answer:-nothing}') -- nothing was destroyed"
      note "to rebuild WITHOUT destroying the cluster, drop --from-zero:"
      note "  bash $HACK_DIR/rebuild.sh"
      exit 1
    fi
  fi

  t0=$(date +%s)
  printf -- '---------- 90-teardown ----------\n'
  if bash "$td_script" --yes; then
    td_rc=0
  else
    td_rc=$?
  fi
  t1=$(date +%s)
  teardown_ran=1
  if [ "$td_rc" -eq 0 ]; then
    printf -- '---------- 90-teardown  PASS  (%ss)\n\n' "$((t1 - t0))"
  else
    printf -- '---------- 90-teardown  FAIL  rc=%s  (%ss)\n\n' "$td_rc" "$((t1 - t0))"
    printf '== summary ==\n'
    note "cluster destroyed, teardown then FAILED rc=$td_rc after $((t1 - t0))s"
    note "the host is at 0% right now -- the rebuild was NOT started"
    note "resume:   bash $HACK_DIR/rebuild.sh"
    printf '\nREBUILD FAILED at 90-teardown (rc=%s)\n' "$td_rc"
    exit 1
  fi
fi

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
# --from-zero did one more unit of real work than the step list, so the tally
# mentions it. A summary that reports 9/9 for a run that also destroyed a
# cluster is undercounting by exactly the part an operator would want to see.
printf '== summary ==\n'

if [ -z "$failed" ]; then
  if [ "$teardown_ran" -eq 1 ]; then
    ok "$passed/${#steps[@]} steps passed, plus the teardown, in ${total}s"
  else
    ok "$passed/${#steps[@]} steps passed in ${total}s"
  fi
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
