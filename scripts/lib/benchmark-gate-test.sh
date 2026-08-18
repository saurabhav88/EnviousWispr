#!/usr/bin/env bash
# scripts/lib/benchmark-gate-test.sh — two-way test for the benchmark's
# contention gate (#2157).
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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$((PASS + FAIL))" -lt 6 ]; then
  printf 'ERROR: expected 6 rows, ran %s\n' "$((PASS + FAIL))"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
