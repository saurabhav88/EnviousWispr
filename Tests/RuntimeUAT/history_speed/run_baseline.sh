#!/usr/bin/env bash
# One History speed baseline of one build (#4586 WP-A). About 45 minutes on a quiet M5 Max.
# Usage: Tests/RuntimeUAT/history_speed/run_baseline.sh <EnviousWispr.app> <executable sha256> <new out dir> [--busy]
# Needs: the dev-app lock (claim it first, in its own call), build/history_speed/frame_recorder,
# Screen Recording for this shell. Writes one folder per contained session and summary.md.
#   main/      search (10 series x 6 attempts), Show edits + Play (10), idle CPU/memory, scroll
#              (3 tabs x trackpad + wheel x 3 repeats, xctrace on the first; plus one deep run), then open History missing + existing
#              catalog (15 samples each)
#   indexing/  one trackpad scroll on Dictations started before the catalog finishes (scroll while
#              background indexing runs)
# --busy keeps one busy loop per performance core running during every measured phase.
# --quick: one pilot session, at most 5 minutes wall time INCLUDING fixture copy, catalog wait and cleanup
#   (not an exact science). Search: 3 series x 3 attempts. Open: existing x3, missing x1. Scroll: 3 tabs x
#   trackpad + wheel x 1, no xctrace (hitch NOT MEASURED), no deep run. Idle CPU 10 s. No indexing session,
#   no Show edits / Play. Writes wall-time.txt and puts the total in summary.md (a WARNING line over 300 s; never a failing exit).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -lt 3 ]; then sed -n '2,3p' "$0"; exit 2; fi
APP="$1"; SHA="$2"; OUT="$3"; BUSY=""; QUICK=""
shift 3
for arg in "$@"; do
  case "$arg" in --busy) BUSY="--busy";; --quick) QUICK=1;; *) echo "unknown option: $arg" >&2; exit 2;; esac
done
T0=$(date +%s); FAILED=""
SEED="${HISTORY_SPEED_SEED:-/Users/m4pro_sv/Developer/AgentArtifacts/enviouswispr/runs/2026/11/20261115-020456-4586-history-speed-pr0-fixture-54bb/seed}"
SERIES="dictations-common-typed,dictations-two-letter-typed,dictations-q4-typed,dictations-accented-typed,dictations-devanagari-typed,transcripts-accented-typed,dictations-rare,dictations-absent,transcripts-filename,meetings-title"
if [ -e "$OUT" ]; then echo "output exists: $OUT" >&2; exit 2; fi
# Every session copies ~120,000 fixture files; Spotlight indexes them and loads the Mac for minutes
# (measured on the M1 2026-11-17: load 15 from mds). A folder whose name ends in .noindex is skipped.
REAL_PARENT="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd -P)" || { echo "output parent does not exist: $OUT" >&2; exit 2; }
case "$REAL_PARENT/" in *.noindex/*) ;; *) echo "put the output under a folder named *.noindex (Spotlight): $REAL_PARENT" >&2; exit 2;; esac
OUT="$REAL_PARENT/$(basename "$OUT")"
mkdir -p "$OUT"
python3 -B "$HERE/fixture.py" verify --seed "$SEED" > "$OUT/seed-verify.json"
if [ -n "$QUICK" ]; then
  python3 -B "$HERE/containment_pilot.py" "$APP" "$SHA" "$SEED" "$OUT/main" \
    --run "$HERE/search_cases.json" 3 --only "dictations-common-typed,dictations-accented-typed,dictations-devanagari-typed" $BUSY \
    --open existing:3,missing:1 --warmups 1 \
    --scroll --idle --idle-seconds 10 --repeats 1 --trace-repeats 0 $BUSY > "$OUT/main.log" 2>&1 || { echo "main session exit $?" >> "$OUT/main.log"; FAILED=1; }
else
  python3 -B "$HERE/containment_pilot.py" "$APP" "$SHA" "$SEED" "$OUT/main" \
    --run "$HERE/search_cases.json" 6 --only "$SERIES" $BUSY --card --repeats 10 --open missing,existing 15 \
    --scroll --idle --repeats 3 --trace-repeats 1 --deep $BUSY > "$OUT/main.log" 2>&1 || { echo "main session exit $?" >> "$OUT/main.log"; FAILED=1; }
  python3 -B "$HERE/containment_pilot.py" "$APP" "$SHA" "$SEED" "$OUT/indexing" --scroll-early \
    --scroll --tabs Dictations --inputs trackpad --repeats 1 $BUSY > "$OUT/indexing.log" 2>&1 \
    || { echo "indexing session exit $?" >> "$OUT/indexing.log"; FAILED=1; }
fi
WALL=$(( $(date +%s) - T0 ))
echo "$WALL" > "$OUT/wall-time.txt"
python3 -B "$HERE/summarize_baseline.py" "$OUT" > "$OUT/summary.md"
printf '\nWall time: %s s (%s min %s s)\n' "$WALL" $((WALL / 60)) $((WALL % 60)) >> "$OUT/summary.md"
if [ -n "$QUICK" ] && [ "$WALL" -gt 300 ]; then
  MSG="WARNING: quick mode took $WALL s, over the 5 minute budget"
  echo "$MSG" >&2; printf '%s\n' "$MSG" >> "$OUT/summary.md"
fi
cat "$OUT/summary.md"
if [ -n "$FAILED" ]; then echo "a pilot session exited nonzero (see main.log / indexing.log): the run is incomplete" >&2; exit 1; fi
