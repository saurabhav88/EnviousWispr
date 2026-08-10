#!/bin/bash
# Grade every model's #1950 benchmark candidates with the existing Type B scorer.
#
# ONE MODEL PER INVOCATION, SERIALLY. `behavior_judge.py`'s default judge is the
# headless Claude CLI on the subscription ($0). Running the models concurrently
# would put many CLI sessions in flight at once for no wall-clock benefit worth
# the rate-limit risk, and the whole sweep is ~20 short calls.
#
# SAME JUDGE AS EVERY OTHER TYPE B NUMBER WE HOLD (claude-sonnet-5, the harness
# default). polish-eval.md: never mix judge models within a comparison — a
# different judge here would make these scores incomparable to #1914's and to
# the 1,890-case research run, which is most of the value of reusing the harness.
#
# RESUMABLE. A model whose summary.json already exists is skipped, so an
# interrupted sweep keeps its work.
#
# FAIL CLOSED per model: a judge failure leaves no summary.json, is reported at
# the end, and exits nonzero. It never leaves a partial score that reads as real.
set -uo pipefail

CORPUS="${1:?usage: judge_ollama_bench.sh <corpus.jsonl> <candidates-dir> <judged-dir>}"
CANDDIR="${2:?usage: judge_ollama_bench.sh <corpus.jsonl> <candidates-dir> <judged-dir>}"
OUTDIR="${3:?usage: judge_ollama_bench.sh <corpus.jsonl> <candidates-dir> <judged-dir>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

mkdir -p "$OUTDIR"
failed=()
skipped=()
unmeasurable=()
for cand in "$CANDDIR"/*.jsonl; do
  base="$(basename "$cand" .jsonl)"
  dest="$OUTDIR/$base"
  # Resume-safe skip, keyed on the INPUTS rather than on the mere existence of a
  # receipt. Judging is the slow, paid step, so skipping already-judged arms is
  # the point of this loop — but a candidate file regenerated under the same arm
  # name (a re-run of the default, unsuffixed arm is the common case) left the
  # old summary in place and skipped it, so the report combined the NEW latency
  # numbers with the OLD quality scores and said nothing. Same shape as the two
  # holes above it: a result whose scope is quietly narrower than it looks.
  stamp="$dest/.inputs-sha256"
  inputs_sha="$(shasum -a 256 "$cand" "$CORPUS" | shasum -a 256 | cut -d' ' -f1)"
  if [ -f "$dest/summary.json" ]; then
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$inputs_sha" ]; then
      skipped+=("$base")
      continue
    fi
    # Inputs moved under an existing receipt. Re-judge rather than trust it, and
    # say so: a silent re-judge would hide that a previous report was mixed.
    echo "=== re-judging $base: candidates or corpus changed since its receipt ===" >&2
    rm -rf "$dest"
  fi
  # A model that errored on EVERY case has no output to grade. Judging 20 empty
  # strings would return 20 critical failures, which reads as "measured and
  # terrible" for a model that was never measured at all — a paywalled hosted
  # model, most often. The report tiers these separately from its own receipt.
  total=$(grep -c . "$cand")
  errs=$(python3 -c "import json,sys; print(sum(1 for l in open(sys.argv[1]) if l.strip() and json.loads(l).get('error')))" "$cand")
  if [ "$errs" -ge "$total" ]; then
    echo "=== skipping $base: $errs/$total cases errored, nothing to judge ===" >&2
    unmeasurable+=("$base")
    continue
  fi
  echo "=== judging $base ===" >&2
  if python3 "$ROOT/scripts/eval/behavior_judge.py" \
       --system new --corpus "$CORPUS" --candidates "$cand" --out "$dest" >&2; then
    printf '%s\n' "$inputs_sha" > "$stamp"
    echo "  ok $base" >&2
  else
    # behavior_judge exits nonzero for BLOCK verdicts too, not only infra
    # failure, so the presence of summary.json is what distinguishes "graded and
    # failed the gate" from "never graded". Only the latter is an error here:
    # this benchmark ranks models, it does not gate them.
    if [ -f "$dest/summary.json" ]; then
      # A graded-but-non-CLEAR run is a complete receipt for these inputs, so it
      # earns a stamp exactly like a CLEAR one. Without this the next run would
      # re-judge every weak model forever, which is the expensive half.
      printf '%s\n' "$inputs_sha" > "$stamp"
      echo "  ok $base (non-CLEAR verdict, expected for weak models)" >&2
    else
      echo "  FAILED $base" >&2
      failed+=("$base")
    fi
  fi
done

[ ${#skipped[@]} -gt 0 ] && echo "skipped (already judged): ${skipped[*]}" >&2
[ ${#unmeasurable[@]} -gt 0 ] && echo "unmeasurable (every case errored): ${unmeasurable[*]}" >&2
if [ ${#failed[@]} -gt 0 ]; then
  echo "FAIL: ${#failed[@]} model(s) produced no summary.json: ${failed[*]}" >&2
  exit 1
fi
echo "judged all models into $OUTDIR" >&2
