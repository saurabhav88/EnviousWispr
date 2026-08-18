#!/usr/bin/env bash
# scripts/lib/benchmark-gate-test.sh — tests for the two benchmark decisions
# that are pure logic: the contention gate, and the seed-outcome classifier
# (#2157).
#
# WHY THIS FILE EXISTS FOR TEN LINES OF SHELL
# The gate decides whether a timing is worth recording. It got that wrong in the
# direction that publishes a number: `pgrep -x a || pgrep -x b` treats "no match"
# (exit 1) and "the probe FAILED" (exit >1) identically, so a broken probe read
# as a quiet machine and the benchmark went ahead having established nothing.
# `xcode-build-tooling.md` RULE: purge-orphaned-derived-data already says exit >1
# is an error rather than a no-match, so the defect was a rule the repo had
# written down and this script did not follow. A gate that silently stops
# gating is exactly what a test is for.
#
# IT READS THE GATE OUT OF THE REAL SCRIPT rather than restating it. A retyped
# copy proves the copy correct and says nothing about what ships.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$HERE/../build-benchmark.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "$2"; }

GATE="$(sed -n '/^pgrep -x xcodebuild/,/^fi$/p' "$TARGET")"
# Fail closed on an extraction miss: an empty GATE would `eval` to nothing, every
# row would report PROCEEDED, and a green-looking run would have tested no code
# at all. This is the silent-empty trap the gate itself fell into.
if [ -z "$GATE" ]; then
  echo "ERROR: could not extract the contention gate from $TARGET — refusing to report a verdict." >&2
  exit 1
fi
case "$GATE" in
  *pgrep*) : ;;
  *) echo "ERROR: extracted block contains no pgrep; the anchor has drifted." >&2; exit 1 ;;
esac

# `pgrep` is shadowed per-row so the gate sees the exit statuses under test. The
# subshell keeps the shadow and any `exit` from leaking into the next row.
run() { # <xcodebuild-exit> <tuist-exit> -> "PROCEEDED" or ""
  (
    # shellcheck disable=SC2329  # invoked indirectly, by the gate inside `eval "$GATE"`
    pgrep() { case "$2" in xcodebuild) return "$XB" ;; tuist) return "$TU" ;; *) return 1 ;; esac; }
    XB="$1"; TU="$2"
    eval "$GATE"
    echo "PROCEEDED"
  ) 2>/dev/null
}

# Every row is a PAIR: the one input that must proceed, and five that must not.
# Rows 4 and 5 are the ones the previous form got wrong, and rows 2, 3 and 6 are
# what stops a "fix" that simply refuses everything from looking correct.
while read -r xb tu want label; do
  [ -n "$xb" ] || continue
  out="$(run "$xb" "$tu")"
  got="REFUSE"; [ "$out" = "PROCEEDED" ] && got="PROCEEDED"
  if [ "$got" = "$want" ]; then
    ok "$label (xcodebuild=$xb tuist=$tu) -> $got"
  else
    bad "$label" "xcodebuild=$xb tuist=$tu gave $got, expected $want"
  fi
done <<'ROWS'
1 1 PROCEEDED both probes said NO MATCH
0 1 REFUSE an xcodebuild is running
1 0 REFUSE a tuist is running
2 1 REFUSE the xcodebuild probe ERRORED
1 3 REFUSE the tuist probe ERRORED
0 0 REFUSE both are running
ROWS

# --- the seed-outcome classifier ---------------------------------------------
# Every wrong line this benchmark has printed was a wrong CLASSIFICATION, never a
# wrong measurement: a hardcoded "chunk A not yet landed", then a MISS reported
# for a warm tree the seed was never asked about. Both were unreachable from a
# test while the decision sat inline beside `xcodebuild`, which is why it is now
# a pure function — the shape of the fix, not just the fix.
# The table is exhaustive over the inputs that can differ, and every row names
# the outcome it must NOT be confused with.
# shellcheck source=scripts/build-benchmark.sh
eval "$(sed -n '/^ew_benchmark_seed_outcome() {/,/^}/p' "$TARGET")"
if ! declare -f ew_benchmark_seed_outcome >/dev/null; then
  echo "ERROR: could not extract ew_benchmark_seed_outcome from $TARGET." >&2
  exit 1
fi

while IFS='|' read -r seed pre clone still want label; do
  [ -n "${seed:-}" ] || continue
  got="$(ew_benchmark_seed_outcome "$seed" "$pre" "$clone" "$still")"
  case "$got" in
    "$want"*) ok "$label -> ${want}" ;;
    *) bad "$label" "got '$got', expected something starting '$want'" ;;
  esac
done <<'ROWS'
0|0|0|0|SKIPPED|--no-seed outranks everything, even a warm tree
0|1|1|1|SKIPPED|--no-seed still wins when the tree is warm and a clone exists
1|1|0|0|WARM|a warm tree is NOT a miss: the seed was never consulted
1|1|1|1|WARM|a warm tree is NOT a hit either, whatever the flag says
1|0|1|1|HIT|a clone taken and kept
1|0|1|0|HIT then DISCARDED|a clone taken and thrown away is NOT a plain hit
1|0|0|0|MISS|no snapshot for this key
ROWS

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$((PASS + FAIL))" -lt 13 ]; then
  printf 'ERROR: expected 13 rows, ran %s\n' "$((PASS + FAIL))"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
