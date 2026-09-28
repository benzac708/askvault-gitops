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
# SECOND JOB: COLLECT THE CREDENTIAL, before burning eight minutes.
#   50-gitops.sh builds the askvault-llm secret from OPENROUTER_API_KEY. Finding
#   that out at step 7 of 8, after six green steps, is an expensive way to learn
#   about a missing variable -- so this asks for it up front, which is the entire
#   point of a preflight. It used to REFUSE here and print an export line for the
#   operator to run, which made the one command that rebuilds everything into two
#   commands and put a hand-typed credential on the command line where it lands
#   in shell history. Asking is strictly better than refusing, and refusing was
#   only ever a way of not implementing the ask.
#
#   Three-way behaviour, identical to 50-gitops.sh's own, because a script that
#   collects a secret one way in two places is a script that will one day
#   collect it two ways:
#     set        -> use it
#     unset, tty -> prompt, no echo, no history, no file
#     unset, no tty (CI, ssh without -t) -> refuse, and say exactly what to do
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
# ON DESTRUCTION -- this script is no longer purely additive, and used to claim
#   it was. 45-reset-app.sh deletes two Applications and two namespaces, so the
#   old "this does not destroy anything" comment became false the moment that step
#   was added, and a header that lies about blast radius is worse than no header.
#   It still takes no --yes gate, and the reasoning still holds but narrower: what
#   it drops is scoped to the two askvault namespaces by name and is rebuilt six
#   steps later, whereas 90-teardown.sh takes the cluster itself and cannot be
#   rebuilt by this script at all. That asymmetry is where confirmation belongs.

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

# --- the one prerequisite, COLLECTED before step 1 ---------------------------
# Resolved here, not discovered at step 7. Same reasoning as 00-preflight.sh: a
# precondition must require only what the run actually needs, and it must
# collect it before the expensive part starts.
needs_key=0
for s in "${steps[@]}"; do
  if [ "$s" = "50-gitops" ]; then needs_key=1; break; fi
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

if [ "$needs_key" -eq 1 ]; then
  if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    ok "OPENROUTER_API_KEY present (len ${#OPENROUTER_API_KEY})"
  elif [ -t 0 ]; then
    note "50-gitops.sh builds the askvault-llm secret and needs an OpenRouter key"
    # -r raw, -s silent: no echo, no line editing, nothing in history. The
    # `|| true` is load-bearing under `set -e`: a bare `read` returns 1 at EOF
    # (Ctrl-D), which would kill this script with no message at all -- and this
    # project has prior findings that are exactly "the check died without saying
    # why". The empty test below is what reports.
    printf '  ..   key (input hidden -- not echoed, not in history, not on disk): '
    read -rs OPENROUTER_API_KEY || true
    printf '\n'
    # An empty key is REFUSED, not passed on. It is not a no-op: a Secret holding
    # an empty value satisfies a required secretKeyRef, so the pod starts, reports
    # provider=openrouter, and answers every question with an empty completion.
    # Nothing about that looks broken from the outside, which is exactly why the
    # refusal belongs here rather than downstream.
    if [ -z "${OPENROUTER_API_KEY:-}" ]; then
      fail "an empty key was entered (or input ended at EOF).
      An empty key is not a placeholder. The manifests reference askvault-llm as
      a REQUIRED secretKeyRef with no 'optional: true' -- deliberately, so that a
      missing key is a loud CreateContainerConfigError instead of a healthy pod
      that quietly 502s at question time. An empty value defeats that: it passes
      the identical check and then answers nothing."
      exit 1
    fi
    # MUST be exported. 50-gitops.sh is a child `bash`, so an unexported shell
    # variable is invisible to it and it prompts a SECOND time for the same
    # secret -- turning one prompt into two, and making it look like the first was
    # lost. This is the whole reason the value is collected up here at all.
    export OPENROUTER_API_KEY
    ok "OPENROUTER_API_KEY read from stdin (len ${#OPENROUTER_API_KEY})"
  else
    fail "OPENROUTER_API_KEY is not set, stdin is not a terminal, and this run includes 50-gitops"
    note "50-gitops.sh builds the askvault-llm secret from that variable"
    note "non-interactive: export OPENROUTER_API_KEY=... then re-run, or --only to skip it"
    note "interactive:   re-run without redirecting stdin -- it will ask for the key"
    exit 1
  fi
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
