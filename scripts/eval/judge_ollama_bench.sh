#!/bin/bash
# Grade every model's #1950 benchmark candidates with the existing Type B scorer.
#
# ONE MODEL PER INVOCATION, SERIALLY. Running the models concurrently would put many
# judge sessions in flight at once for no wall-clock benefit worth the rate-limit risk,
# and the whole sweep is ~20 short calls.
#
# WHICHEVER JUDGE `behavior_judge.py` DEFAULTS TO, resolved once below and then passed
# explicitly. The judge is part of the resume stamp, so changing it invalidates every
# stamped receipt and the next sweep re-grades the whole field instead of mixing two
# judges in one scoreboard. Do not read that as "the sweep follows the default
# automatically" — it does now, and only because the stamp was fixed to include the
# judge; before that, 15 stamped Sonnet receipts would have been skipped straight
# through a switch to a different judge. The 12-arm comparison that licensed the move
# to the Azure credits is recorded on issue #1950.
#
# RESUMABLE. A prior receipt is reused only when its summary.json is cacheable AND its
# stamp matches the candidate file, the corpus and the judge; otherwise it is discarded.
# An arm with judgeable output is then re-judged, while an arm whose every candidate
# errored is reported as unmeasurable and never judged at all. So an interrupted sweep
# keeps confirmed work without reusing a doubtful result.
#
# FAIL CLOSED per model: a judge failure that leaves no summary.json is reported at the
# end and exits nonzero. An INCOMPLETE receipt is deliberately kept on disk for diagnosis
# but never stamped, so it is re-judged next run; it is reported and also exits nonzero.
# Neither can be mistaken for a finished score.
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

# Resolve the judge ONCE, from `behavior_judge.py` itself rather than from a second
# default written here. Two defaults are a drift bug waiting to happen, and this one
# would be invisible: the stamp would record the shell's idea of the judge while a
# different judge did the grading. Reading DEFAULT_JUDGE also honours EW_JUDGE for
# free, because that is where the override already lives.
#
# Fails closed. An empty answer would otherwise stamp `judge=` on every arm and make
# all receipts look mutually comparable, which is the failure this whole change exists
# to prevent.
JUDGE="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import behavior_judge; print(behavior_judge.DEFAULT_JUDGE)' "$ROOT/scripts/eval" 2>/dev/null)"
if [ -z "$JUDGE" ]; then
  echo "FATAL: could not resolve the default judge from behavior_judge.py" >&2
  exit 2
fi
echo "=== judge: $JUDGE ===" >&2

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
# ValueError, not JSONDecodeError: invalid UTF-8 raises UnicodeDecodeError,
# which a JSONDecodeError-only tuple misses. Both are ValueError subclasses,
# so catching the base is the enumeration rather than a list that can miss
# the next member — and an escaped exception here exits 1, which the caller
# maps to "predates the cacheable field" for a file it could not decode.
except (OSError, ValueError):
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
# Why the receipt was refused, for the resume MESSAGE only — DELEGATED, not
# reimplemented. This used to be an inline copy of the report's logic, and the
# copy fell behind twice in one PR: first it did not classify verdicts, then it
# did not validate metadata, and both times it announced "predates the cacheable
# field" about a file the report correctly called hand-edited or corrupt. A
# comment asking for parity cannot enforce it, so `receipt_state.py` is the single
# authority and both layers ask it.
#
# Exit code IS the state; stdout carries malformed field names.
#   0 = object carrying `cacheable` (so the field says false)
#   1 = object without it, valid verdict, usable metadata (pre-#2007)
#   2 = unreadable, malformed, or valid JSON that is not an object
#   3 = a verdict this gate cannot emit (not ours / hand-edited)
#   4 = valid verdict but gap metadata whose types prove nothing
receipt_refusal_state() {
  python3 "$ROOT/scripts/eval/receipt_state.py" "$1"
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
  # The JUDGE is part of the inputs. Without it a receipt graded by one judge is
  # silently reused after the default changes, which is exactly what would have
  # happened on 2026-08-11: 15 arms carried stamped, cacheable Sonnet receipts, so a
  # sweep under the new Azure default would have skipped every one and produced a
  # scoreboard mixing two judges with nothing saying so. The receipt records its own
  # judge in `meta.judge`, so the mixing was detectable and simply never checked.
  #
  # Consequence, and it is intended: changing the judge invalidates every stamp and
  # the next sweep re-grades the full field. That is the only way a comparison stays
  # a comparison, and it is affordable precisely because the new judge is cheap.
  inputs_sha="$(
    { printf 'judge=%s\n' "$JUDGE"; sha256 "$cand" "$CORPUS"; } | sha256 | cut -d' ' -f1
  )"
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
      bad_fields="$(receipt_refusal_state "$dest/summary.json")"
      case $? in
        0) reason="receipt is not cacheable" ;;
        1) reason="receipt predates the cacheable field" ;;
        3) reason="receipt carries a verdict this gate cannot produce" ;;
        4) reason="receipt has malformed metadata ($bad_fields), so its gap counts prove nothing" ;;
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
  # `--judge "$JUDGE"` explicitly, never the implicit default: the judge that grades
  # must be the same value that went into the stamp, and letting each side resolve it
  # independently is how they drift.
  python3 "$ROOT/scripts/eval/behavior_judge.py" \
    --system new --judge "$JUDGE" \
    --corpus "$CORPUS" --candidates "$cand" --out "$dest" >&2 || true

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
