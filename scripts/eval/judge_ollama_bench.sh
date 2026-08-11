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
incomplete=()

# `shasum` is Perl-provided and is NOT guaranteed by the ubuntu-latest runner
# image, which lists coreutils (and therefore `sha256sum`). Our own pr-check.yml
# only uses `shasum` in the macOS jobs. Measured: the two emit byte-identical
# `hash  filename` output, and the nested pipeline below agrees across
# shasum|shasum, sha256sum|sha256sum and mixed — so this shim cannot invalidate a
# stamp written by the other tool.
sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
  else
    sha256sum "$@"
  fi
}

# Is this receipt safe to cache AND to rank? Read the judge's own answer; never
# infer it from the release verdict. `evaluate_new_gate` gives a quality failure
# precedence over incompleteness, so a run that is BOTH quality-failed and
# missing coverage reports BLOCK — and a verdict-based rule would stamp that
# partial receipt as a finished one. Fails closed on a missing field, unreadable
# file, or JSON that is valid but not an object; every receipt written before
# #2007 lacks the field and is therefore re-judged once.
receipt_cacheable() {
  python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        receipt = json.load(f)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(receipt, dict):
    raise SystemExit(1)
raise SystemExit(0 if receipt.get("cacheable") is True else 1)
PY
}

# Why the receipt was refused, for the resume MESSAGE only. Deliberately NOT
# part of the caching decision: every state below fails closed and is re-judged,
# so this changes what the reader is told and nothing else.
#
# Three states, not two. A two-way "does it have the field" test folds an
# unreadable or non-object receipt in with a legacy one and announces "predates
# the cacheable field" about a file it could not even parse — asserting a cause
# it never observed, which is the whole defect this pass exists to remove.
#   0 = object carrying `cacheable` (so the field says false)
#   1 = object without it (written before #2007)
#   2 = unreadable, malformed, or valid JSON that is not an object
receipt_refusal_state() {
  python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        receipt = json.load(f)
except (OSError, json.JSONDecodeError):
    raise SystemExit(2)
if not isinstance(receipt, dict):
    raise SystemExit(2)
raise SystemExit(0 if "cacheable" in receipt else 1)
PY
}
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
  inputs_sha="$(sha256 "$cand" "$CORPUS" | sha256 | cut -d' ' -f1)"
  if [ -f "$dest/summary.json" ]; then
    # Cacheability is checked HERE too, not only after judging. A matching stamp
    # used to `continue` outright, so every arm already stamped with a partial
    # receipt stayed skipped forever — including the ones this bug has already
    # produced. Nonzero from the helper inside the final `&&` operand just makes
    # the condition false; the script sets `set -uo pipefail` with no `errexit`.
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$inputs_sha" ] \
       && receipt_cacheable "$dest/summary.json"; then
      skipped+=("$base")
      continue
    fi
    # Re-judge rather than trust it, and say WHICH condition failed: reporting a
    # non-cacheable receipt as a stamp mismatch sends the reader after the wrong
    # thing entirely.
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$inputs_sha" ]; then
      # A refusal must name its own reason, and these are two different
      # situations: a receipt written before #2007 simply has no acceptance field
      # and needs one re-judge, while a receipt carrying `cacheable: false`
      # recorded real gaps. Calling the first one "not cacheable" reads as a
      # broken receipt. Every arm of the shipped #1950 sweep hits the first case,
      # so this is the path a reader actually meets. The post-judge branch below
      # keeps the plain wording deliberately: the judge that just wrote that
      # receipt always sets the field, so there `false` is the only way to get in.
      receipt_refusal_state "$dest/summary.json"
      case $? in
        0) reason="receipt is not cacheable" ;;
        1) reason="receipt predates the cacheable field" ;;
        *) reason="receipt is unreadable or is not a JSON object" ;;
      esac
    else
      reason="candidates or corpus changed since its receipt"
    fi
    echo "=== re-judging $base: $reason ===" >&2
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
  # The exit status is deliberately NOT the cacheability answer. behavior_judge
  # exits nonzero for a BLOCK verdict as well as for a partial run, so the
  # receipt itself is inspected either way — a graded-but-failed run IS a
  # complete answer and must earn its stamp, or every weak model is re-judged
  # forever, which is the expensive half.
  python3 "$ROOT/scripts/eval/behavior_judge.py" \
    --system new --corpus "$CORPUS" --candidates "$cand" --out "$dest" >&2 || true

  if [ -f "$dest/summary.json" ] && receipt_cacheable "$dest/summary.json"; then
    printf '%s\n' "$inputs_sha" > "$stamp"
    echo "  ok $base" >&2
  elif [ -f "$dest/summary.json" ]; then
    # A receipt exists but is partial or internally inconsistent. Do NOT stamp:
    # withholding the stamp is the whole recovery mechanism, because the resume
    # branch above deletes and re-judges an unstamped receipt. Leaving the file
    # in place keeps it readable for whoever investigates.
    echo "  INCOMPLETE $base (receipt is not cacheable; left in place, not stamped)" >&2
    incomplete+=("$base")
  else
    echo "  FAILED $base" >&2
    failed+=("$base")
  fi
done

[ ${#skipped[@]} -gt 0 ] && echo "skipped (already judged): ${skipped[*]}" >&2
[ ${#unmeasurable[@]} -gt 0 ] && echo "unmeasurable (every case errored): ${unmeasurable[*]}" >&2
[ ${#incomplete[@]} -gt 0 ] && echo "incomplete (partial receipt, will be re-judged): ${incomplete[*]}" >&2
if [ ${#failed[@]} -gt 0 ] || [ ${#incomplete[@]} -gt 0 ]; then
  [ ${#failed[@]} -gt 0 ] && \
    echo "FAIL: ${#failed[@]} model(s) produced no summary.json: ${failed[*]}" >&2
  [ ${#incomplete[@]} -gt 0 ] && \
    echo "FAIL: ${#incomplete[@]} model(s) produced a receipt that is not cacheable: ${incomplete[*]}" >&2
  exit 1
fi
echo "judged all models into $OUTDIR" >&2
