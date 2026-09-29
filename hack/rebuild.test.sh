#!/usr/bin/env bash
# Unit tests for rebuild.sh --from-zero and the 90-teardown credential rules.
#
# Each test builds a throwaway directory containing a COPY of the real
# rebuild.sh and 90-teardown.sh, plus STUB steps that only record that they ran.
# Nothing here touches a cluster. What is under test is the orchestrator: the
# confirmation gate, the ordering of the teardown against the credential gate,
# the refusal rules, the reporting, and the teardown's handling of the
# per-user kubeconfig.
#
# Runs against whatever directory this file sits in, so it works both from the
# repo and from a scratch copy:
#     bash hack/rebuild.test.sh
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${TMPDIR:-/tmp}/askvault-rebuild-tests"
rm -rf "$WORK"; mkdir -p "$WORK"
PASS=0
FAIL=0
t() { if [ "$1" = "0" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi; }

mk() {                      # mk <dir> <teardown-exit>
  rm -rf "$1"; mkdir -p "$1"
  cp "$SRC/rebuild.sh" "$1/rebuild.sh"
  cp "$SRC/90-teardown.sh" "$1/90-teardown.sh.real"
  cat > "$1/90-teardown.sh" <<'STUB'
#!/usr/bin/env bash
echo "TEARDOWN-RAN args=[$*]" >> "$ORDER_LOG"
exit "${STUB_TEARDOWN_RC:-0}"
STUB
  for s in 00-preflight 10-k3s 20-argocd 30-traefik 40-cloudflare 45-reset-app 50-gitops 31-monitoring 99-acceptance; do
    cat > "$1/$s.sh" <<STUB
#!/usr/bin/env bash
echo "$s" >> "\$ORDER_LOG"
exit "\${STUB_STEP_RC:-0}"
STUB
  done
}

run() {                    # run <dir> <args...>  (stdin from /dev/null = non-tty)
  local d="$1"; shift
  export ORDER_LOG="$d/order.log"; : > "$ORDER_LOG"
  ( cd "$d" && bash ./rebuild.sh "$@" ) > "$d/out.txt" 2>&1
  echo $?
}
# `run` is a shell function, so `env VAR=x run` cannot work. Set it exported.
withkey()  { export SEALED_CREDS_FILE="$SRC/../overlays/prod/sealed-secrets.yaml"; }
nokey()    { export SEALED_CREDS_FILE="$WORK/missing-sealed.yaml"; }

# --- 1. --yes without --from-zero is rejected, not silently ignored -----------
D=$WORK/t1; mk "$D"
rc=$(run "$D" --yes)
[ "$rc" = 2 ] && t 0 "1  --yes alone -> exit 2" || t 1 "1  --yes alone -> exit $rc (want 2)"
grep -q "only means something together with --from-zero" "$D/out.txt" && t 0 "1  ...and says why" || t 1 "1  ...missing the why"
[ ! -s "$D/order.log" ] && t 0 "1  ...and nothing ran" || t 1 "1  ...but order.log has: $(cat "$D/order.log")"

# --- 2. --from-zero without --yes and without a tty: refuse, destroy nothing --
D=$WORK/t2; mk "$D"
withkey; rc=$(run "$D" --from-zero)
[ "$rc" = 1 ] && t 0 "2  --from-zero, no tty, no --yes -> exit 1" || t 1 "2  -> exit $rc (want 1)"
grep -q "nothing was destroyed" "$D/out.txt" && t 0 "2  ...and states nothing was destroyed" || t 1 "2  ...missing that line"
[ ! -s "$D/order.log" ] && t 0 "2  ...teardown did NOT run" || t 1 "2  ...BUT it ran: $(cat "$D/order.log")"

# --- 3. the gate is enforced: --only without 99-acceptance is refused ---------
D=$WORK/t3; mk "$D"
rc=$(run "$D" --from-zero --yes --only 10-k3s)
[ "$rc" = 2 ] && t 0 "3  --from-zero --only 10-k3s -> exit 2" || t 1 "3  -> exit $rc (want 2)"
grep -q "does not include 99-acceptance" "$D/out.txt" && t 0 "3  ...and names the missing gate" || t 1 "3  ...missing the why"
[ ! -s "$D/order.log" ] && t 0 "3  ...teardown did NOT run" || t 1 "3  ...BUT it ran: $(cat "$D/order.log")"

# --- 4. --from-zero --only WITH the gate is allowed ---------------------------
D=$WORK/t4; mk "$D"
withkey; rc=$(run "$D" --from-zero --yes --only 50-gitops,99-acceptance)
[ "$rc" = 0 ] && t 0 "4  --from-zero --only 50-gitops,99-acceptance -> exit 0" || t 1 "4  -> exit $rc (want 0)"
[ "$(head -1 "$D/order.log")" = "TEARDOWN-RAN args=[--yes]" ] && t 0 "4  ...teardown ran first" || t 1 "4  ...first line is: $(head -1 "$D/order.log")"

# --- 5. THE ORDERING SAFETY PROPERTY -----------------------------------------
# A missing key must refuse BEFORE the cluster is destroyed. This is the whole
# reason the teardown sits after the credential gate.
D=$WORK/t5; mk "$D"
nokey; rc=$(run "$D" --from-zero --yes)
[ "$rc" = 1 ] && t 0 "5  --from-zero --yes, no sealed file -> exit 1" || t 1 "5  -> exit $rc (want 1)"
grep -q "sealed-secrets.yaml is missing" "$D/out.txt" && t 0 "5  ...refused on the CREDENTIAL, not the confirmation" || t 1 "5  ...wrong refusal: $(grep -m1 FAIL "$D/out.txt")"
[ ! -s "$D/order.log" ] && t 0 "5  ...and the cluster was NOT destroyed" || t 1 "5  ...BUT teardown ran: $(cat "$D/order.log")"

# --- 6. full happy path: teardown, then all nine steps, in order --------------
D=$WORK/t6; mk "$D"
withkey; rc=$(run "$D" --from-zero --yes)
[ "$rc" = 0 ] && t 0 "6  full --from-zero --yes -> exit 0" || t 1 "6  -> exit $rc (want 0)"
expected="TEARDOWN-RAN args=[--yes]
00-preflight
10-k3s
20-argocd
30-traefik
40-cloudflare
45-reset-app
50-gitops
31-monitoring
99-acceptance"
[ "$(cat "$D/order.log")" = "$expected" ] && t 0 "6  ...exact order: teardown, then the 9 steps" || t 1 "6  ...order was:
$(cat "$D/order.log")"
grep -q "9/9 steps passed, plus the teardown" "$D/out.txt" && t 0 "6  ...summary counts the teardown" || t 1 "6  ...summary did not count it"
grep -q "REBUILD COMPLETE" "$D/out.txt" && t 0 "6  ...prints REBUILD COMPLETE" || t 1 "6  ...no REBUILD COMPLETE"
grep -q "FROM ZERO: the cluster is destroyed first" "$D/out.txt" && t 0 "6  ...banner announces the destruction" || t 1 "6  ...banner silent about destruction"

# --- 7. teardown fails: do NOT start a rebuild on a dead host ----------------
D=$WORK/t7; mk "$D"
export STUB_TEARDOWN_RC=1; withkey; rc=$(run "$D" --from-zero --yes); unset STUB_TEARDOWN_RC
[ "$rc" = 1 ] && t 0 "7  teardown fails -> exit 1" || t 1 "7  -> exit $rc (want 1)"
grep -q "REBUILD FAILED at 90-teardown" "$D/out.txt" && t 0 "7  ...names 90-teardown as the failure" || t 1 "7  ...wrong failure line"
grep -q "rebuild was NOT started" "$D/out.txt" && t 0 "7  ...says the rebuild was not started" || t 1 "7  ...missing that"
[ "$(wc -l < "$D/order.log")" = 1 ] && t 0 "7  ...and zero steps ran after it" || t 1 "7  ...steps ran anyway: $(cat "$D/order.log")"
grep -q "rebuild.sh$" "$D/out.txt" && t 0 "7  ...resume hint is a plain rebuild" || t 1 "7  ...bad resume hint"

# --- 8. a step fails after a successful teardown: normal resume hint ---------
D=$WORK/t8; mk "$D"
export STUB_STEP_RC=1; withkey; rc=$(run "$D" --from-zero --yes); unset STUB_STEP_RC
[ "$rc" = 1 ] && t 0 "8  a step fails after teardown -> exit 1" || t 1 "8  -> exit $rc (want 1)"
grep -q "resume:   bash .*rebuild.sh --from 00-preflight" "$D/out.txt" \
  && t 0 "8  ...resume points at the failed step" || t 1 "8  ...resume: $(grep resume: "$D/out.txt")"

# --- 9. tty: typed confirmation, declined ------------------------------------
D=$WORK/t9; mk "$D"
export ORDER_LOG="$D/order.log"; : > "$ORDER_LOG"
printf 'no\n' | script -qec "cd $D && bash ./rebuild.sh --from-zero" "$D/typescript" > "$D/out.txt" 2>&1
[ ! -s "$D/order.log" ] && t 0 "9  tty, answered 'no' -> nothing destroyed" || t 1 "9  ...it ran anyway: $(cat "$D/order.log")"
grep -q "not confirmed" "$D/out.txt" && t 0 "9  ...reports not confirmed" || t 1 "9  ...missing the refusal"
grep -q "rebuild WITHOUT destroying" "$D/out.txt" && t 0 "9  ...offers the non-destructive alternative" || t 1 "9  ...no alternative offered"

# --- 10. tty: typed confirmation, accepted -----------------------------------
D=$WORK/t10; mk "$D"
export ORDER_LOG="$D/order.log"; : > "$ORDER_LOG"
printf 'yes\n' | script -qec "cd $D && OPENROUTER_API_KEY=fixture-not-a-real-key bash ./rebuild.sh --from-zero" "$D/typescript" > "$D/out.txt" 2>&1
[ "$(head -1 "$D/order.log")" = "TEARDOWN-RAN args=[--yes]" ] && t 0 "10 tty, answered 'yes' -> teardown ran" || t 1 "10 ...first line: $(head -1 "$D/order.log")"
grep -q "REBUILD COMPLETE" "$D/out.txt" && t 0 "10 ...run completed" || t 1 "10 ...did not complete"

# --- 11. regression: --list is unchanged and still has no teardown in it -----
D=$WORK/t11; mk "$D"
out=$(cd "$D" && bash ./rebuild.sh --list 2>&1)
[ "$out" = "00-preflight
10-k3s
20-argocd
30-traefik
40-cloudflare
45-reset-app
50-gitops
31-monitoring
99-acceptance" ] && t 0 "11 --list still exactly the 9 numbered steps" || t 1 "11 --list changed:
$out"
printf '%s' "$out" | grep -q teardown && t 1 "11 teardown leaked into the step list" || t 0 "11 teardown is NOT in the step list"

# --- 12. regression: --help and plain run still work -------------------------
D=$WORK/t12; mk "$D"
rc=$(run "$D" --help); [ "$rc" = 0 ] && t 0 "12 --help -> exit 0" || t 1 "12 --help -> exit $rc"
D=$WORK/t12b; mk "$D"
withkey; rc=$(run "$D")
[ "$rc" = 0 ] && t 0 "12 plain rebuild -> exit 0" || t 1 "12 plain rebuild -> exit $rc"
if grep -q teardown "$D/order.log"; then t 1 "12 plain rebuild ran a teardown!"; else t 0 "12 plain rebuild runs NO teardown"; fi
[ "$(wc -l < "$D/order.log")" = 9 ] && t 0 "12 ...and ran all 9 steps" || t 1 "12 ...ran $(wc -l < "$D/order.log") lines"
grep -q "9/9 steps passed in" "$D/out.txt" && t 0 "12 ...summary unchanged (no '+ the teardown')" || t 1 "12 ...summary changed"

# ============================================================================
# 90-teardown.sh: the per-user credential
# ============================================================================
# The teardown removes ~/.kube/config, which the k3s-uninstall path never did,
# and the removal must reach the host where k3s is ALREADY uninstalled -- that
# is the state a previous teardown leaves, and it is when a stale
# cluster-admin credential is most likely still sitting there.
TD=$WORK/tk
rm -rf "$TD"; mkdir -p "$TD/home/.kube"
cp "$SRC/90-teardown.sh" "$TD/"
# rebuild.sh must be alongside it: the footer names it, and the test below
# asserts the printed path is actually runnable. A fixture without it would
# make the assertion fail for a reason that has nothing to do with the code.
cp "$SRC/rebuild.sh" "$TD/rebuild.sh"

# --- 13. dry run announces the removal when the file exists -----------------
printf 'stale\n' > "$TD/home/.kube/config"
out=$(HOME="$TD/home" bash "$TD/90-teardown.sh" 2>&1)
grep -q "WOULD RUN: rm -f .*kube/config" <<<"$out" && t 0 "13 dry run announces the kubeconfig removal" || t 1 "13 dry run did not announce it"
grep -q "8b\. the per-user cluster-admin credential" <<<"$out" && t 0 "13 ...under its own step heading" || t 1 "13 ...no step heading"
[ -f "$TD/home/.kube/config" ] && t 0 "13 ...and the dry run destroyed nothing" || t 1 "13 ...THE DRY RUN DELETED IT"

# --- 14. reached even when k3s is already uninstalled -----------------------
# The bug this guards: the removal sat inside the `else` of
# "k3s-uninstall.sh not present", so the one host that most needs the cleanup
# was the one host that skipped it. On a host with k3s installed that branch
# is unreachable, so the test redirects the hardcoded path in a THROWAWAY COPY
# to force the branch. The control flow under test is the real control flow;
# only the path constant differs, and only in a file the test owns.
TDK="$WORK/tk-nosdk"
rm -rf "$TDK"; mkdir -p "$TDK/home/.kube" "$TDK/no-such-dir"
sed 's|/usr/local/bin/k3s-uninstall.sh|PLACEHOLDER_NO_SUCH_DIR/k3s-uninstall.sh|g' \
  "$SRC/90-teardown.sh" > "$TDK/90-teardown.sh"
printf 'stale\n' > "$TDK/home/.kube/config"
out=$(HOME="$TDK/home" bash "$TDK/90-teardown.sh" 2>&1)
grep -q "k3s-uninstall.sh not present" <<<"$out" \
  && t 0 "14 branch forced: k3s reported as not installed" \
  || t 1 "14 could not force the k3s-absent branch"
grep -q "WOULD RUN: rm -f .*kube/config" <<<"$out" \
  && t 0 "14 ...and the credential is STILL cleaned there" \
  || t 1 "14 SKIPPED on a k3s-less host -- the original bug"
# and the copy really is only the path that changed
[ "$(diff <(sed 's|PLACEHOLDER_NO_SUCH_DIR|/usr/local/bin|g' "$TDK/90-teardown.sh") "$SRC/90-teardown.sh" | wc -l)" = 0 ] \
  && t 0 "14 the forced copy differs from the real script in nothing else" \
  || t 1 "14 the forced copy was modified beyond the path"

# --- 15. absent file is a note, not a failure -------------------------------
rm -f "$TD/home/.kube/config"
out=$(HOME="$TD/home" bash "$TD/90-teardown.sh" 2>&1)
grep -q "no per-user kubeconfig present" <<<"$out" && t 0 "15 absent kubeconfig -> note" || t 1 "15 absent kubeconfig -> $(grep -c kubeconfig <<<"$out") mentions"
grep -q "WOULD RUN: rm -f" <<<"$out" && t 1 "15 ...but still tried to remove it" || t 0 "15 ...and does not try to remove it"

# --- 16. --keep-k3s leaves the credential alone -----------------------------
# The cluster survives, so its credential must too. Taking it would break a
# working host, which is a worse outcome than the one this change fixes.
printf 'live\n' > "$TD/home/.kube/config"
HOME="$TD/home" bash "$TD/90-teardown.sh" --keep-k3s >/dev/null 2>&1
[ -f "$TD/home/.kube/config" ] && t 0 "16 --keep-k3s preserves the kubeconfig" || t 1 "16 --keep-k3s DELETED a live cluster's credential"
out=$(HOME="$TD/home" bash "$TD/90-teardown.sh" --keep-k3s 2>&1)
grep -q "8b\." <<<"$out" && t 1 "16 ...and does not even mention the step" || t 0 "16 ...and does not mention the step"

# --- 17. the footer's command is runnable, from every argv[0] shape ----------
# It was `${0%/*}`, which returns the WHOLE string when argv[0] has no slash,
# so the footer printed "90-teardown.sh/rebuild.sh" - an unrunnable command,
# from the script whose last job is to say what to type.
CMD=$(cd "$TD" && bash ./90-teardown.sh 2>&1 | grep "TO REBUILD" | sed 's/.*bash //')
[ -f "$CMD" ] && t 0 "17 footer command exists: $CMD" || t 1 "17 footer printed a non-existent path: $CMD"
CMD2=$(HOME="$TD/home" PATH="$TD:$PATH" bash -c '90-teardown.sh' 2>&1 | grep "FULL DRILL" | sed 's/.*bash //')
case "$CMD2" in *90-teardown.sh/rebuild.sh*) t 1 "17 bare-name invocation prints the broken path" ;; *) t 0 "17 bare-name invocation prints a clean path" ;; esac
n=$(cd "$TD" && bash ./90-teardown.sh 2>&1 | grep -cE "TO REBUILD|FULL DRILL")
[ "$n" = 2 ] && t 0 "17 footer prints exactly two commands, no list" || t 1 "17 footer printed $n lines (a list crept back in?)"
grep -qE "TO REBUILD:.*(preflight|k3s\.sh|argocd)" <<<"$(cd "$TD" && bash ./90-teardown.sh 2>&1)" && t 1 "17 the stale step LIST is back" || t 0 "17 no hand-typed step list anywhere in the footer"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
