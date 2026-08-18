#!/usr/bin/env bash
# scripts/lib/launch-check-test.sh — two-way test for the dev-app launch check
# (#2157 chunk C).
#
# THE FAILED-LAUNCH CASE IS THE POINT. A readiness check that has never been seen
# to FAIL is a check nobody has tested: the previous `sleep 3` version would have
# "passed" against any app, and a check that always returns success is
# indistinguishable from a deleted one. Every positive case here has a negative
# twin, and the truncation case is the specific defect that would have made the
# first implementation reject a correctly-launched app.
#
# Uses a fake bundle and a real background process — no EnviousWispr build, no
# dev-app slot, no interference with any other session.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/launch-check.sh
. "$HERE/launch-check.sh"

PASS=0; FAIL=0; TMP=""; PIDS=()

cleanup() {
  local p
  for p in "${PIDS[@]+"${PIDS[@]}"}"; do kill "$p" 2>/dev/null || true; done
  # Reap each job so the shell does not print "Terminated: 15" after the summary.
  # bash 3.2 reports killed background jobs on stderr, which reads as a FAILURE
  # immediately below a passing count — a cosmetic line that misrepresents the
  # result is worth removing.
  for p in "${PIDS[@]+"${PIDS[@]}"}"; do wait "$p" 2>/dev/null || true; done
  for p in "${PIDS[@]+"${PIDS[@]}"}"; do kill -9 "$p" 2>/dev/null || true; done
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
}
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "$2"; }

# A fake bundle whose executable is a long-lived symlink named exactly like the
# real one, at a path long enough that `ps -o comm=` would truncate it — which is
# the whole reason this uses `ps -ww -o command=`.
make_bundle() { # <name>
  local dir="$TMP/$1/EnviousWispr Local.app/Contents/MacOS"
  mkdir -p "$dir"
  # A SYMLINK to a real binary. Two wrong fixtures were tried first and both
  # looked like the SUBJECT was broken:
  #   - a shell script: runs under its interpreter, so argv[0] is `/bin/bash` and
  #     the bundle path is argv[1]. Nothing like the real app.
  #   - a COPY of /bin/sleep: macOS kills it on launch. Copying a platform binary
  #     breaks its signature, so the process dies instantly and `pgrep` finds
  #     nothing — indistinguishable from a detector that does not work.
  # A symlink executes the real, signed binary while argv[0] remains the LINK's
  # path, which is exactly the shape of the shipped compiled executable.
  # Verified 2026-08-18: `ps -o command=` shows the bundle path plus its argument.
  ln -s /bin/sleep "$dir/EnviousWispr"
  printf '%s\n' "$TMP/$1/EnviousWispr Local.app"
}

# Sets LAST_PID rather than PRINTING the pid. A `$(launch ...)` substitution runs
# in a SUBSHELL, so `PIDS+=(...)` inside it updates a copy the parent never sees —
# the cleanup trap then finds an empty array and leaks a process that outlives the
# test. Caught 2026-08-18 by checking for strays AFTER a green run; the run was
# already passing, so nothing in the assertions would ever have revealed it.
LAST_PID=""
launch() { # <app_path> -> sets LAST_PID
  local app="$1"
  # stdout/stderr MUST be detached. A background child inheriting this script's
  # stdout keeps the pipe open, so the caller (a harness, a CI step, a shell
  # substitution) blocks until the child dies — which for a `sleep 3600` loop is
  # never. The test then produces no output at all and looks like a hang in the
  # SUBJECT rather than in the harness. Cost one 180 s timeout to learn.
  "$app/Contents/MacOS/EnviousWispr" 3600 >/dev/null 2>&1 &
  LAST_PID=$!
  PIDS+=("$LAST_PID")
}

TMP="$(mktemp -d /tmp/ew-launch-check-XXXXXX)"

# --- 1. POSITIVE: a running bundle is detected -------------------------------
APP_A="$(make_bundle a-very-long-directory-name-to-force-comm-truncation)"
launch "$APP_A"; PID_A="$LAST_PID"
sleep 0.4
if [ -n "$(ew_launched_pids "$APP_A")" ]; then
  ok "running bundle is detected (long path, would truncate under ps -o comm=)"
else
  bad "running bundle is detected" "found no pid for a process that is running"
fi

# --- 2. NEGATIVE: a DIFFERENT bundle is not mistaken for this one -------------
# This is the sibling-worktree defect. Both bundles have identical executable
# NAMES and identical trailing path components; only the parent differs.
APP_B="$(make_bundle sibling-worktree)"
if [ -z "$(ew_launched_pids "$APP_B")" ]; then
  ok "a sibling bundle that is NOT running is not reported"
else
  bad "sibling bundle isolation" "reported a pid for a bundle that never launched"
fi

launch "$APP_B"; PID_B="$LAST_PID"
sleep 0.4
a_pids="$(ew_launched_pids "$APP_A")"
b_pids="$(ew_launched_pids "$APP_B")"
if [ "$a_pids" = "$PID_A" ] && [ "$b_pids" = "$PID_B" ]; then
  ok "two sibling bundles running: each reports only its OWN pid"
else
  bad "sibling discrimination" "A expected $PID_A got '$a_pids'; B expected $PID_B got '$b_pids'"
fi

# --- 3. THE FAILED-LAUNCH CASE (plan §11.3 requires it) -----------------------
APP_DEAD="$(make_bundle never-launched)"
start=$(date +%s)
if ew_wait_for_launch "$APP_DEAD" 5; then
  bad "failed launch is detected" "reported success for a bundle that was never launched"
else
  ok "failed launch RETURNS FAILURE (the check can actually fail)"
fi
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -le 3 ]; then
  ok "failed launch gives up promptly (${elapsed}s for 5 tries)"
else
  bad "failed-launch timing" "took ${elapsed}s, expected a bounded poll"
fi

# --- 4. POSITIVE: wait returns quickly for an already-running app -------------
start=$(date +%s)
if ew_wait_for_launch "$APP_A" 50; then
  elapsed=$(( $(date +%s) - start ))
  if [ "$elapsed" -le 1 ]; then
    ok "already-running app is detected immediately (${elapsed}s, not a fixed 3s wait)"
  else
    bad "fast-path timing" "took ${elapsed}s for an app already running"
  fi
else
  bad "already-running app detected" "wait failed for a running app"
fi

# --- 5. NEGATIVE: a dead process is no longer reported ------------------------
kill "$PID_B" 2>/dev/null || true
sleep 0.5
if [ -z "$(ew_launched_pids "$APP_B")" ]; then
  ok "a terminated app is no longer reported"
else
  bad "termination detection" "still reporting a pid after the process was killed"
fi

# --- 6. NEGATIVE: a prefilter FALSE POSITIVE must be rejected by the filter ----
# `pgrep -f <pattern>` matches the pattern against every command line INCLUDING
# the shell running the pgrep, because the pattern sits in that shell's own argv.
# Observed live 2026-08-18: a peer session's occupancy check returned two PIDs and
# both were shells asking the same question. `ew_launched_pids` uses that same
# prefilter, so the `ps -ww -o command=` filter is the only thing rejecting it.
#
# The first version of this case asserted "no pid for a bundle that never existed"
# and PASSED EVEN WHEN THE PREFILTER MATCHED NOTHING — it proved absence of a
# false positive that was never generated, which is the same class of defect the
# rest of this file exists to catch. Now the prefilter is STUBBED to return a
# guaranteed false positive (this shell's own pid), and a marker proves it ran.
APP_NEVER="$TMP/never-existed/EnviousWispr Local.app"
PREFILTER_CALLED="$TMP/.pgrep-called"
pgrep() {
  : > "$PREFILTER_CALLED"
  printf '%s\n' "$$"
}
actual="$(ew_launched_pids "$APP_NEVER")"
unset -f pgrep
if [ -f "$PREFILTER_CALLED" ] && [ -z "$actual" ]; then
  ok "prefilter false positive is REJECTED by the executable filter"
else
  bad "prefilter false-positive rejection" "marker or rejection missing: '$actual'"
fi

# --- "could not tell" is not "did not launch" ---------------------------------
# `pgrep` exits 0 on a match, 1 on NO match and >1 on an ERROR, and the `|| true`
# in ew_launched_pids flattens all three. The direction is safe — a probe failure
# reports a launch failure rather than a phantom success — but the REASON is
# wrong, and "the dev app did not launch" sends the next reader to inspect an app
# that may be running perfectly. Same defect as the benchmark's contention gate.
pgrep() { return 3; }
ew_wait_for_launch "$TMP/absent.app" 1 >/dev/null 2>&1; rc=$?
launch_warn="$(ew_wait_for_launch "$TMP/absent.app" 1 2>&1 >/dev/null)"
unset -f pgrep
if [ "$rc" -eq 2 ]; then
  ok "a BROKEN process probe reports 'could not tell' (2), not 'did not launch' (1)"
else
  bad "launch probe error" "returned $rc; a probe failure is indistinguishable from a real launch failure"
fi
if printf '%s' "$launch_warn" | grep -q "not evidence the app did not launch"; then
  ok "the could-not-tell case says so on stderr"
else
  bad "launch probe warning" "silent: '$launch_warn'"
fi

# THE TWIN: with a WORKING probe that finds nothing, this really is a launch
# failure and must still report 1. Without it, a fix that returns 2 for
# everything would look correct.
pgrep() { return 1; }
ew_wait_for_launch "$TMP/absent.app" 1 >/dev/null 2>&1; rc=$?
unset -f pgrep
if [ "$rc" -eq 1 ]; then
  ok "a WORKING probe that finds nothing still reports 'did not launch' (the twin)"
else
  bad "launch negative" "returned $rc instead of 1"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$((PASS + FAIL))" -lt 11 ]; then
  printf 'ERROR: expected at least 11 assertions, ran %s\n' "$((PASS + FAIL))"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
