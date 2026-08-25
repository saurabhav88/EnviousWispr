#!/usr/bin/env bash
# Two-way suite for scripts/lib/lane-verdict.sh and lane-verdict.py (#2401).
#
# The point of the change is that a CRASHED lane can no longer report a green
# verdict, so this asserts BOTH halves: a healthy lane still passes, AND a
# crashed one is refused. A gate that refuses everything would satisfy a
# refusal-only suite while making the lane unusable, and a gate that refuses
# nothing is the defect being fixed — so every rejected case here is paired with
# an accepted twin that differs only in the field under test.
#
# The two files have different contracts and are tested at their own boundaries:
# the shell owns arguments, the count guard and the verdict lines; the judge owns
# classifying a result payload, and its documented interface already takes a file
# path, so it needs no seam to be driven. Nothing here gives the gate a test-only
# knob (`validation-discipline.md` RULE: a-test-seam-on-a-GUARD-is-a-bypass).
#
# Run: bash scripts/lib/lane-verdict-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/lane-verdict.sh
. "$HERE/lane-verdict.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ew-lane-verdict-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Every failure LEADS with the same name its pass prints, so a mutation control
# reading this output can tell WHICH case fired rather than only that one did
# (validation-discipline.md, the unreadable-control entry).
ok() { PASS=$((PASS + 1)); printf "  ok    %s\n" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf "  FAIL  %s — %s\n" "$1" "$2"; }

# ---------------------------------------------------------------- the judge --
# `nodeType` nesting mirrors a real bundle: Test Plan > Unit test bundle >
# Test Suite > Test Case, with Failure Message as a child of the case.
node() {  # <name> <result> [failure message]
  local name="$1" result="$2" message="${3:-}"
  if [ -n "$message" ]; then
    printf '{"nodeType":"Test Case","nodeIdentifier":"%s","result":"%s","children":[{"nodeType":"Failure Message","name":"%s"}]}' \
      "$name" "$result" "$message"
  else
    printf '{"nodeType":"Test Case","nodeIdentifier":"%s","result":"%s"}' "$name" "$result"
  fi
}

payload() {  # <file> <case json>...
  local out="$1"; shift
  local joined="" sep=""
  local c
  for c in "$@"; do joined="$joined$sep$c"; sep=","; done
  printf '{"testNodes":[{"nodeType":"Test Plan","children":[{"nodeType":"Unit test bundle","children":[{"nodeType":"Test Suite","children":[%s]}]}]}]}' \
    "$joined" > "$out"
}

judge() {  # <file> -> rc, stderr captured to $TMP/err
  EW_LANE_LABEL="probe" python3 "$HERE/lane-verdict.py" "$1" >"$TMP/out" 2>"$TMP/err"
}

echo "== the three results a healthy lane produces are accepted =="
# Measured on a real 6,829-case lane: Passed 6815, Skipped 12, Expected Failure 2.
# Exactly three distinct values, which is why the allowlist is these three and
# why anything else must fail rather than be assumed benign.
payload "$TMP/healthy.json" \
  "$(node 'S/passes()' 'Passed')" \
  "$(node 'S/hardwareGated()' 'Skipped')" \
  "$(node 'S/knownIssue()' 'Expected Failure')"
if judge "$TMP/healthy.json"; then ok "a healthy lane passes"; else bad "a healthy lane passes" "rc=$? stderr=$(cat "$TMP/err")"; fi

echo "== a crashed case is refused, and NAMED =="
payload "$TMP/crashed.json" \
  "$(node 'S/passes()' 'Passed')" \
  "$(node 'S/dies()' 'Failed' 'Test crashed with signal trap.')"
if judge "$TMP/crashed.json"; then
  bad "a crashed case is refused" "the judge accepted it"
elif ! /usr/bin/grep -q "S/dies()" "$TMP/err"; then
  bad "a crashed case is refused" "refused without naming the case: $(cat "$TMP/err")"
elif ! /usr/bin/grep -q "Test crashed with signal trap" "$TMP/err"; then
  bad "a crashed case is refused" "refused without the failure message: $(cat "$TMP/err")"
else
  ok "a crashed case is refused, and NAMED"
fi

echo "== crash text as DATA does not fire the gate =="
# This is the whole reason the oracle is the typed result rather than the
# console. A build log for a suite containing a literal fatalError(...) call
# echoed that source line 24 times as compiler diagnostics, so on an untyped
# stream a crash and a quotation of a crash are the same bytes. Here the crash
# wording sits in a PASSING case's identifier and must change nothing.
payload "$TMP/data.json" \
  "$(node 'S/testCrashedWithSignalTrapIsReportedLoudly()' 'Passed')" \
  "$(node 'S/fatalErrorMessageIsRendered()' 'Passed')"
if judge "$TMP/data.json"; then ok "crash text as data does not fire the gate"; else bad "crash text as data does not fire the gate" "rc=$? stderr=$(cat "$TMP/err")"; fi

echo "== an unknown result value fails CLOSED =="
# A future Xcode may invent a value. Refusing what we do not recognise is the
# only direction that cannot silently green a lane.
payload "$TMP/unknown.json" "$(node 'S/x()' 'Interrupted')"
if judge "$TMP/unknown.json"; then
  bad "an unknown result value fails closed" "the judge accepted 'Interrupted'"
else
  ok "an unknown result value fails closed"
fi

echo "== a payload with no cases, or no shape, is refused =="
payload "$TMP/empty.json"
if judge "$TMP/empty.json"; then bad "zero test cases is refused" "accepted"; else ok "zero test cases is refused"; fi

printf '{"testNodes":"not-an-array"}' > "$TMP/shape.json"
if judge "$TMP/shape.json"; then bad "a malformed testNodes is refused" "accepted"; else ok "a malformed testNodes is refused"; fi

printf 'not json at all' > "$TMP/broken.json"
if judge "$TMP/broken.json"; then bad "unparseable JSON is refused" "accepted"; else ok "unparseable JSON is refused"; fi

if judge "$TMP/does-not-exist.json"; then bad "a missing payload is refused" "accepted"; else ok "a missing payload is refused"; fi

echo "== the judge is found from ANY cwd =="
# The case that was missing: every judge row above drives lane-verdict.py
# directly, so none of them exercises how `ew_lane_verdict` FINDS it. That is a
# fixture too small to express the question — the rows share the harness's own
# `$HERE` and so cannot disagree with it.
#
# Under bash the resolution is correct however the file is sourced, and these
# rows are green before and after the hardening. They exist because the value is
# consumed by a path lookup that nothing else asserts, and because this suite
# runs on Linux CI where a real bundle is unavailable — so the resolution is the
# one part of the shell's bundle path that CAN be checked there.
if [ -f "$EW_LANE_JUDGE" ]; then
  ok "the judge path resolves to an existing file"
else
  bad "the judge path resolves to an existing file" "EW_LANE_JUDGE=$EW_LANE_JUDGE"
fi
case "$EW_LANE_JUDGE" in
  /*) ok "the judge path is absolute, not cwd-relative" ;;
  *) bad "the judge path is absolute, not cwd-relative" "EW_LANE_JUDGE=$EW_LANE_JUDGE" ;;
esac
# Two-way: source it from an unrelated cwd, by a relative path, and require the
# same answer. A resolver that happened to work from the repo root only would
# pass both rows above.
resolved=$(cd "$HERE/../.." && cd scripts && bash -c '. lib/lane-verdict.sh; printf "%s" "$EW_LANE_JUDGE"')
if [ "$resolved" = "$EW_LANE_JUDGE" ]; then
  ok "sourcing from another cwd resolves the same judge"
else
  bad "sourcing from another cwd resolves the same judge" "got '$resolved', want '$EW_LANE_JUDGE'"
fi

echo "== the shell contract =="
LOG="$TMP/lane.log"
printf 'Test run with 6623 tests in 578 suites passed\nTest run with 206 tests in 21 suites passed\n' > "$LOG"

out=$(ew_lane_verdict "$LOG" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "too few arguments is a usage error, not a verdict"; else bad "too few arguments is a usage error, not a verdict" "rc=$rc out=$out"; fi

out=$(ew_lane_verdict "$TMP/no-such.log" "$TMP/bundle" "probe" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | /usr/bin/grep -q "verdict: FAIL"; then
  ok "a missing log is a FAIL verdict"
else
  bad "a missing log is a FAIL verdict" "rc=$rc out=$out"
fi

# The empty-run guard this change PRESERVES rather than replaces.
: > "$TMP/zero.log"
out=$(ew_lane_verdict "$TMP/zero.log" "$TMP/bundle" "probe" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | /usr/bin/grep -q "executed 0 tests"; then
  ok "the empty-run guard still refuses a zero count"
else
  bad "the empty-run guard still refuses a zero count" "rc=$rc out=$out"
fi

# A positive count is no longer sufficient — the truncated-run half of the fix.
out=$(ew_lane_verdict "$LOG" "$TMP/no-such-bundle" "probe" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | /usr/bin/grep -q "no result bundle"; then
  ok "a positive count alone does NOT green a lane"
else
  bad "a positive count alone does NOT green a lane" "rc=$rc out=$out"
fi

# The count is summed across per-target summaries, unchanged.
out=$(ew_lane_verdict "$LOG" "$TMP/no-such-bundle" "probe" 2>&1)
if printf '%s' "$out" | /usr/bin/grep -q "executed 6829 tests"; then
  ok "the count sums every per-target run summary"
else
  bad "the count sums every per-target run summary" "out=$out"
fi

echo "== the expected count FLAGS and never GATES =="
# tools-and-apps.md FACT: ew-watcher-classification — a count is a parameter, a
# parameter can be borrowed from the wrong workflow, and a count-GATED check
# fails toward silence. Both rows below must reach the SAME verdict path; only
# the warning differs.
mismatch=$(ew_lane_verdict "$LOG" "$TMP/no-such-bundle" "probe" 9999 2>&1); mrc=$?
matched=$(ew_lane_verdict "$LOG" "$TMP/no-such-bundle" "probe" 6829 2>&1); yrc=$?
if [ "$mrc" -eq "$yrc" ]; then
  ok "an expected-count mismatch does not change the verdict"
else
  bad "an expected-count mismatch does not change the verdict" "mismatch rc=$mrc, match rc=$yrc"
fi
if printf '%s' "$mismatch" | /usr/bin/grep -q "expected 9999"; then
  ok "an expected-count mismatch is reported LOUDLY"
else
  bad "an expected-count mismatch is reported LOUDLY" "out=$mismatch"
fi
if printf '%s' "$matched" | /usr/bin/grep -q "expected"; then
  bad "a matching expected-count says nothing" "out=$matched"
else
  ok "a matching expected-count says nothing"
fi
# A borrowed or malformed parameter must be loud and inert, never a verdict.
junk=$(ew_lane_verdict "$LOG" "$TMP/no-such-bundle" "probe" "not-a-number" 2>&1); jrc=$?
if [ "$jrc" -eq "$mrc" ] && printf '%s' "$junk" | /usr/bin/grep -q "not a number"; then
  ok "a non-numeric expected-count warns and is ignored"
else
  bad "a non-numeric expected-count warns and is ignored" "rc=$jrc out=$junk"
fi

echo
printf "PASS=%d FAIL=%d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
