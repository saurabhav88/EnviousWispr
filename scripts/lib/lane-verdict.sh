#!/usr/bin/env bash
# scripts/lib/lane-verdict.sh — one verdict owner for every Xcode test lane (#2401).
#
# THE EMPTY RUN, AND THIS REASONING IS PRESERVED RATHER THAN REPLACED
# `xcodebuild` prints suite-level "passed" text even for an empty bundle, so a
# presence-grep would green a run where nothing executed. A positive executed
# count is therefore required. That guard is not a mistake and this file keeps
# it verbatim — it is correct and complete about the EMPTY case, and it is the
# only record of why a presence-grep was rejected.
#
# THE TRUNCATED RUN, WHICH THAT GUARD CANNOT SEE
# A positive count does not prove the lane finished. A test bundle that CRASHES
# mid-run was measured reporting `** TEST SUCCEEDED **` with a lane total of
# 2,557 against a baseline of 6,664 — roughly 4,100 tests never run, exit 0.
# Every signal a reader checks agreed and every one was wrong: a crash prints
# ZERO `✘` marks so the failure count is honestly zero, `xcodebuild` concluded
# SUCCEEDED, and `n < 1` is comfortably satisfied by 2,557. The guard catches an
# EMPTY run and passes a TRUNCATED one.
#
# WHY THE CONSOLE IS NOT THE ORACLE, MEASURED RATHER THAN ARGUED
# The obvious fix is to grep the log for `Fatal error:`. Three measurements say
# no, all taken 2026-08-25 against this repo:
#   1. THE LOG CARRIES TEST SOURCE. A build log for a suite containing a literal
#      `fatalError(...)` call echoed that source line 24 times as compiler
#      diagnostics. Console text is an untyped stream in which a crash and a
#      quotation of a crash are the same bytes, and a gate that fires on data is
#      the shape `validation-discipline.md` RULE: false-positives-not-gates-
#      trains-evasion measures the cost of.
#   2. THE STRING IS NOT OURS. Its wording belongs to the Swift runtime and to
#      Xcode, so a set of console signatures is a DESCRIPTION with a next
#      counterexample forever, not an enumeration.
#   3. THE CONSOLE SEES LESS THAN THE BUNDLE. On the crashed run the console's
#      final `Test run with N tests` read 3, because `xcodebuild` restarts after
#      a crash and that line reports only the last launch. The result bundle
#      held all SIX cases, including the two that ran before the crash and the
#      one that died.
#
# WHAT IS ASKED INSTEAD, AND WHY IT IS A CLOSED QUESTION
#   "Does the named result bundle hold at least one test case, and is every case
#    result one this repo accepts?"
# The bundle is structured, so the answer comes from a typed field rather than
# from matching text, and no amount of test output can forge one. The accepted
# set is MEASURED, not guessed — a healthy full lane of 6,829 cases produced
# exactly three distinct values:
#       Passed 6815 · Skipped 12 · Expected Failure 2
# `Skipped` is what a hardware-gated `@Test(.enabled(if:))` reports; `Expected
# Failure` is what a `withKnownIssue` case reports. Anything else — including a
# value a future Xcode invents — is refused, so this fails CLOSED.
#
# Deliberately NOT matched: the crash's own failure text. The crashed run's
# `Failure Message` child read `Test crashed with signal trap.`, which is not the
# `Crash: xctest at ...` a reader of the older note would expect. Keying on that
# prefix would have shipped a check that misses the case it was written for. The
# typed `Failed` result catches it with no string involved.
#
# THE EXPECTED COUNT IS A FLAG, NEVER A GATE
# `tools-and-apps.md` FACT: ew-watcher-classification is explicit: a count is a
# PARAMETER, a parameter can be borrowed from the wrong workflow, and a
# count-GATED check fails toward silence — it prints progress forever and says
# nothing. So a mismatch is reported loudly beside a verdict and never licenses
# or withholds one.
#
# CONTRACT
#   ew_lane_verdict <log> <result_bundle> <label> [expected_count]
# Echoes the executed count and a PASS/FAIL verdict. Returns 0 only when the
# count is positive AND every case in the bundle carries an accepted result.

# The three results a healthy lane is allowed to produce. Anything else fails.
EW_LANE_ACCEPTED_RESULTS="Passed Skipped Expected Failure"

# Resolved ONCE, at source time, to an ABSOLUTE path, with a loud branch below
# when the judge is not where this says it is.
#
# NOT because the old form was broken for any shipped consumer — it was not.
# Every consumer runs bash (`xcode-test.sh` and all three workflow steps), and
# under bash `${BASH_SOURCE[0]}` resolves correctly however the file is sourced.
#
# The reason is what happens OUTSIDE bash. `BASH_SOURCE` does not exist in zsh,
# so it expands to empty, `dirname ""` is `.`, and the judge is looked for beside
# the caller's cwd. Measured two-way, same command, same cwd:
#     zsh  -> <root>/lane-verdict.py             (wrong, and the file is absent)
#     bash -> <root>/scripts/lib/lane-verdict.py (right)
# This machine's interactive shell is zsh, so anyone driving the function by hand
# to diagnose a lane hits it — while every automated path is fine. That is a bad
# failure to own: it fires only for the person already debugging something else.
#
# Fail-closed either way, so this was never a false green. What the explicit
# branch buys is a NAMED failure: "cannot find its result judge" instead of a
# python traceback, so a missing judge and a crashed lane cannot be confused.
EW_LANE_VERDICT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EW_LANE_JUDGE="$EW_LANE_VERDICT_DIR/lane-verdict.py"

ew_lane_verdict() {
  if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "ew_lane_verdict: expected <log> <result_bundle> <label> [expected_count]" >&2
    return 2
  fi

  local log="$1" bundle="$2" label="$3" expected="${4:-}"
  local n payload rc


  if [ ! -f "$log" ]; then
    echo "ERROR: $label has no test log at $log" >&2
    echo "==> $label verdict: FAIL"
    return 1
  fi


  # Sum the Swift Testing per-target run summaries — the same quantity the guard
  # this replaces computed, kept as the empty-run detector rather than the verdict.
  #
  # ONE awk PASS, not the original `grep | grep | awk`. Under `errexit` — which
  # all three workflow steps set — a no-match `grep` exits 1, the pipeline fails,
  # and the assignment ABORTS THE SHELL. On an empty lane, which is precisely the
  # case the count exists to catch, so the guard would die instead of reporting.
  # Found by this file's own new errexit row, not by review; awk exits 0 whether
  # or not it matches, so the failure has nowhere to come from.
  n=$(LC_ALL=C awk '
    {
      rest = $0
      while (match(rest, /Test run with [0-9]+ test/)) {
        hit = substr(rest, RSTART, RLENGTH)
        sub(/^Test run with /, "", hit)
        sub(/ test$/, "", hit)
        total += hit + 0
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    END { print total + 0 }
  ' "$log")

  # Reported before any refusal, because a reader diagnosing a FAIL wants the
  # number as much as a reader confirming a PASS does.
  echo "==> $label executed $n tests"

  if [ -n "$expected" ]; then
    case "$expected" in
      "" | *[!0-9]*)
        # A malformed parameter is loud and harmless: it must not be able to
        # decide a lane either way.
        echo "WARNING: $label expected-count is not a number: '$expected' (ignored)" >&2
        ;;
      *)
        if [ "$n" -ne "$expected" ]; then
          echo "WARNING: $label executed $n tests, expected $expected — NOT a verdict, see the verdict line" >&2
        fi
        ;;
    esac
  fi

  if [ "$n" -lt 1 ]; then
    echo "ERROR: $label executed 0 tests (empty/misconfigured bundle)" >&2
    echo "==> $label verdict: FAIL"
    return 1
  fi

  if [ ! -d "$bundle" ]; then
    echo "ERROR: $label has no result bundle at $bundle" >&2
    echo "==> $label verdict: FAIL"
    return 1
  fi

  payload="$(mktemp "${TMPDIR:-/tmp}/ew-lane-verdict.XXXXXX")" || {
    echo "ERROR: $label could not create a temporary file for the result payload" >&2
    echo "==> $label verdict: FAIL"
    return 1
  }

  # `get test-results tests` is the MODERN subcommand. The one most sessions
  # reach for first, `get test-report tests`, is deprecated and refuses outright.
  #
  # NOT `if ! cmd; then rc=$?`: inside that branch `$?` is the status of the `!`
  # EXPRESSION, which is 0 exactly when the command failed. The message would
  # have read "exited 0" for every real failure — a diagnostic that is wrong
  # precisely when it is read (#2407 review r2).
  if xcrun xcresulttool get test-results tests --path "$bundle" >"$payload" 2>/dev/null; then
    # #2455 C5: every EXPECTED test bundle must appear in the RESULT payload.
    #
    # The count guard sums per-target totals, so a bundle dropped from a scheme
    # leaves a large positive number — 7,110 instead of 7,158 reads as a pass.
    # `EnviousWisprDesktopEffectsTests` is the one that matters: it holds the
    # three suites that drive real windows, it is the newest and so easiest to
    # drop by accident, and it is the smallest, so its absence moves the total
    # least.
    #
    # Read from the PAYLOAD, not the log. A first attempt paired a name-grep over
    # the log with a count of anonymous `Test run started.` markers; Codex review
    # (2026-08-27) rejected it correctly — the log carries the bundle name on
    # BUILD lines, the markers carry no name, and two uncorrelated signals do not
    # prove that the NAMED bundles ran. `xcresulttool` emits one
    # `Unit test bundle` node per bundle that actually executed, which is the
    # direct answer.
    #
    # Caller-controlled: `xcode-test.sh --filter` runs one suite on purpose and
    # passes an empty list. A gate that fails honest usage teaches people to
    # bypass it.
    local required_bundles="${EW_LANE_REQUIRED_BUNDLES-EnviousWisprTests EnviousWisprDesktopEffectsTests EnviousWisprASRTests}"
    if [ -n "$required_bundles" ]; then
      local ran_bundles required_bundle
      ran_bundles="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for plan in d.get("testNodes", []):
    for node in plan.get("children", []) or []:
        if node.get("nodeType") == "Unit test bundle":
            print(node.get("name", ""))
' "$payload" 2>/dev/null)"
      for required_bundle in $required_bundles; do
        if ! printf '%s\n' "$ran_bundles" | grep -qx "$required_bundle"; then
          echo "ERROR: $label never ran $required_bundle — absent from the result bundle" >&2
          echo "  ran: $(printf '%s ' $ran_bundles)" >&2
          echo "==> $label verdict: FAIL"
          rm -f "$payload"
          return 1
        fi
      done
    fi
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$payload"
    echo "ERROR: $label could not read the result bundle at $bundle (xcresulttool exited $rc)" >&2
    echo "==> $label verdict: FAIL"
    return 1
  fi

  if [ ! -f "$EW_LANE_JUDGE" ]; then
    # Loud and specific: "the judge is missing" and "the lane crashed" are
    # different situations and must not print the same thing.
    rm -f "$payload"
    echo "ERROR: $label cannot find its result judge at $EW_LANE_JUDGE" >&2
    echo "==> $label verdict: FAIL"
    return 1
  fi

  # RUN IT AS AN `if` CONDITION, which suppresses `errexit` for this command.
  #
  # All three workflow steps run under `set -e` and call this as a simple
  # command, so a bare invocation would abort the shell THE INSTANT the judge
  # rejected — before the temp file is removed and before the `verdict: FAIL`
  # line is printed. CI would still go red, which is why this is easy to miss,
  # but red with no verdict, no reason and a leaked payload: the failure mode is
  # a MISSING EXPLANATION exactly when someone needs one (#2407 review r2).
  #
  # Invisible to this file's own suite by construction — that harness runs
  # `set -uo pipefail` with no `errexit`, so no row it contains could express the
  # question. The suite now sets it explicitly for one row.
  if EW_LANE_LABEL="$label" EW_LANE_ACCEPTED="$EW_LANE_ACCEPTED_RESULTS" \
    python3 "$EW_LANE_JUDGE" "$payload"
  then
    rc=0
  else
    rc=$?
  fi
  rm -f "$payload"

  if [ "$rc" -ne 0 ]; then
    echo "==> $label verdict: FAIL"
    return 1
  fi

  echo "==> $label verdict: PASS"
  return 0
}
