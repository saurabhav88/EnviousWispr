#!/usr/bin/env bash
# One History speed baseline of one build (#4586 WP-A). About 45 minutes on a quiet M5 Max.
# Usage: Tests/RuntimeUAT/history_speed/run_baseline.sh <EnviousWispr.app> <executable sha256> <new out dir> [--busy]
# Needs: the dev-app lock (claim it first, in its own call), build/history_speed/frame_recorder,
# Screen Recording for this shell. Writes one folder per contained session and summary.md.
#   main/      search (10 series x 4 attempts), Show edits + Play (10), idle CPU/memory, scroll
#              (3 tabs x trackpad + wheel, plus one deep run), then open History missing + existing
#              catalog (15 samples each)
#   indexing/  one trackpad scroll on Dictations started before the catalog finishes (scroll while
#              background indexing runs)
# --busy keeps one busy loop per performance core running during every measured phase.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -lt 3 ]; then sed -n '2,3p' "$0"; exit 2; fi
APP="$1"; SHA="$2"; OUT="$3"; BUSY="${4:-}"
SEED="${HISTORY_SPEED_SEED:-/Users/m4pro_sv/Developer/AgentArtifacts/enviouswispr/runs/2026/11/20261115-020456-4586-history-speed-pr0-fixture-54bb/seed}"
SERIES="dictations-common-typed,dictations-two-letter-typed,dictations-q4-typed,dictations-accented-typed,dictations-devanagari-typed,transcripts-accented-typed,dictations-rare,dictations-absent,transcripts-filename,meetings-title"
if [ -e "$OUT" ]; then echo "output exists: $OUT" >&2; exit 2; fi
mkdir -p "$OUT"
python3 -B "$HERE/fixture.py" verify --seed "$SEED" > "$OUT/seed-verify.json"
python3 -B "$HERE/containment_pilot.py" "$APP" "$SHA" "$SEED" "$OUT/main" \
  --run "$HERE/search_cases.json" 4 --only "$SERIES" $BUSY --card --repeats 10 --open missing,existing 15 \
  --scroll --idle --repeats 1 --deep $BUSY > "$OUT/main.log" 2>&1 || echo "main session exit $?" >> "$OUT/main.log"
python3 -B "$HERE/containment_pilot.py" "$APP" "$SHA" "$SEED" "$OUT/indexing" --scroll-early \
  --scroll --tabs Dictations --inputs trackpad --repeats 1 $BUSY > "$OUT/indexing.log" 2>&1 \
  || echo "indexing session exit $?" >> "$OUT/indexing.log"
python3 -B "$HERE/summarize_baseline.py" "$OUT" > "$OUT/summary.md"
cat "$OUT/summary.md"
