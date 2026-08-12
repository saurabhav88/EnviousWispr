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

# Resolve AND VALIDATE the judge ONCE, before the loop, from `behavior_judge.py` itself
# rather than from a second default written here. Two defaults are a drift bug waiting to
# happen and this one would be invisible: the stamp would record the shell's idea of the
# judge while a different judge graded.
#
# VALIDATION BEFORE THE LOOP IS LOAD-BEARING, NOT TIDINESS. The loop below `rm -rf`s any
# receipt whose stamp no longer matches, and the judge is part of that stamp — so a refused
# or mistyped EW_JUDGE mismatches EVERY arm, deletes every cached receipt, and then
# `behavior_judge.py` refuses the judge and exits before writing replacements. The whole
# stored set would be gone, with the log blaming "candidates or corpus changed". Cloud
# review caught this on PR #2026; it is a hazard my own put-the-judge-in-the-stamp fix
# created, so the fix has to carry its own guard. `--print-judge-identity` exits 2 on any
# judge with no funded route, and on an endpoint that cannot be resolved or validated.
#
# It returns two values: the judge id for `--judge` and the log line, and an IDENTITY for
# the stamp. They differ on purpose. Azure deployment names are resource-local, so the same
# `azure/gpt-5-6-luna` label on a different endpoint can be a different model; the identity
# folds in a digest of the endpoint host and the API version so a resource change
# invalidates the stamp instead of silently reusing another grader's receipt. A digest, not
# the host, because this value is printed and stored.
JUDGE_LINES="$(python3 "$ROOT/scripts/eval/behavior_judge.py" --print-judge-identity 2>&1)"
if [ $? -ne 0 ]; then
  echo "FATAL: $JUDGE_LINES" >&2
  echo "       Refusing to start: a bad judge would invalidate every stamp and this script" >&2
  echo "       deletes receipts whose stamp does not match. Nothing has been touched." >&2
  exit 2
fi
JUDGE="$(printf '%s\n' "$JUDGE_LINES" | sed -n 1p)"
JUDGE_IDENTITY="$(printf '%s\n' "$JUDGE_LINES" | sed -n 2p)"
# Third line: the model version the probe observed, empty for non-Azure judges. Exported to
# every arm so each one verifies against THIS sweep's model instead of probing for itself. An
# arm that probes independently pins whatever is current, so a deployment repointed between arms
# stays self-consistent inside that process while the stamp written here still names the first
# model — two model versions under one stamp, which is the mixing this stamp exists to prevent.
JUDGE_PINNED_MODEL="$(printf '%s\n' "$JUDGE_LINES" | sed -n 3p)"
export EW_AZURE_PINNED_MODEL="$JUDGE_PINNED_MODEL"
if [ -z "$JUDGE" ] || [ -z "$JUDGE_IDENTITY" ]; then
  echo "FATAL: could not resolve the judge and its identity from behavior_judge.py" >&2
  exit 2
fi
echo "=== judge: $JUDGE (stamp identity $JUDGE_IDENTITY${JUDGE_PINNED_MODEL:+, serving $JUDGE_PINNED_MODEL}) ===" >&2

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

# Move a superseded receipt OUT of the report-visible path without destroying it.
#
# Called when a re-judge failed to produce a cacheable receipt while a previous one exists.
# Deleting it was the original P1 (a typo wiped the cached set); leaving it at `$dest` was the
# next P1 (`report_ollama_bench.py` validates cacheability but never reads `.inputs-sha256`, so
# it would rank the old judge's scores beside newly judged arms). Quarantine satisfies both:
# the bytes survive for inspection, and nothing that ranks receipts can find them.
#
# ONE slot per arm, and the rule for what may occupy it is the whole point. An earlier version
# replaced the slot unconditionally, reasoning that a previous quarantine "is already
# superseded". False, and cloud review caught it: after one failed re-judge the canonical path
# holds a PARTIAL receipt and the complete one is in the slot, so the next failure displaced the
# complete receipt with a partial and the only good copy was gone. Repeated outages would grind
# the quarantine down from complete to worthless, which is precisely the loss it exists to
# prevent — the third variant of that same loss across four review rounds.
#
# The rule: never trade a cacheable receipt for a non-cacheable one. Everything else may be
# replaced, so the slot cannot grow without bound.
#
# | slot holds     | being displaced | action                                  |
# |----------------|-----------------|-----------------------------------------|
# | nothing        | anything        | move it in                              |
# | cacheable      | NOT cacheable   | KEEP the slot, discard the displaced one|
# | cacheable      | cacheable       | replace (the newer complete one wins)   |
# | NOT cacheable  | anything        | replace                                 |
#
# Uses `$dest`/`$base`/`$had_previous` from the enclosing loop.
quarantine_previous() {
  [ "$had_previous" = 1 ] || return 0
  # `receipt_cacheable` is only asked about files that exist: $dest may be a directory with no
  # summary at all (an interrupted write), which is not cacheable by definition.
  dest_is_cacheable=1
  if [ ! -f "$dest/summary.json" ] || ! receipt_cacheable "$dest/summary.json"; then
    dest_is_cacheable=0
  fi
  if [ -f "$dest.stale/summary.json" ] \
     && receipt_cacheable "$dest.stale/summary.json" \
     && [ "$dest_is_cacheable" = 0 ]; then
    rm -rf "$dest"
    echo "  discarded an incomplete receipt for $base; the COMPLETE quarantine at" >&2
    echo "     $dest.stale is kept (a partial must never displace a complete one)" >&2
    return 0
  fi
  rm -rf "$dest.stale"
  mv "$dest" "$dest.stale"
  echo "  previous receipt for $base quarantined at $dest.stale (not ranked, not stamped)" >&2
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
  # The JUDGE IDENTITY is part of the inputs, which is the judge id plus, for Azure, a digest
  # of the endpoint host and API version. The bare id is not enough: deployment names are
  # resource-local, so the same label on another endpoint can be another model.
  #
  # Without the judge at all, a receipt graded by one judge is
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
    { printf 'judge=%s\n' "$JUDGE_IDENTITY"; sha256 "$cand" "$CORPUS"; } | sha256 | cut -d' ' -f1
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
    # DELIBERATELY NOT deleted here. The judge writes into a staging directory below and the
    # old receipt is replaced only once a new one exists, so a judge that produces nothing
    # cannot destroy the stored set.
    #
    # This is the second and structural fix for the same P1 (cloud review, #2026). The first
    # validated the judge's funded ROUTE before the loop, and the reviewer correctly pointed
    # out that this only closes one member of the class: `claude-sonet-5` and `azure/typo` are
    # both routed, so they passed that check, mismatched every stamp, and reached the delete
    # before the CLI or the endpoint rejected them. Probing harder would have narrowed the
    # window rather than closing it — a mid-run capacity error or an expired key fails after
    # any probe. Not deleting until a replacement exists removes every member at once,
    # including the ones nobody has thought of.
    #
    # Leaving the old receipt is safe ONLY because the block below stamps nothing unless a
    # cacheable staged receipt was promoted. An earlier version of this comment argued the
    # receipt was safe "because its stamp no longer matches this judge" — false, and the
    # reviewer caught it: the post-judge branch re-read $dest and would have written the new
    # stamp onto that old receipt. The safety lives in the stamping rule, not here.
    #
    # Given that rule: if the judge is later set back to whatever produced this receipt, its
    # original stamp matches again and skipping it is correct, because that judge really did
    # produce it.
  fi
  # A model that errored on EVERY case has no output to grade. Judging 20 empty
  # strings would return 20 critical failures, which reads as "measured and
  # terrible" for a model that was never measured at all — a paywalled hosted
  # model, most often. The report tiers these separately from its own receipt.
  total=$(grep -c . "$cand")
  errs=$(python3 -c "import json,sys; print(sum(1 for l in open(sys.argv[1]) if l.strip() and json.loads(l).get('error')))" "$cand")
  if [ "$errs" -ge "$total" ]; then
    echo "=== skipping $base: $errs/$total cases errored, nothing to judge ===" >&2
    # This branch `continue`s, so it never reaches the staged-outcome handling below — and once
    # the resume branch stopped deleting, a stale receipt could sit at the canonical path while
    # this arm is reported unmeasurable. `report_ollama_bench.py` would then read that receipt
    # instead of seeing the missing one it expects, and reject the whole benchmark because the
    # old skip counts do not match this run's errors. Quarantine here too: the arm has no
    # gradeable output, so nothing at the ranked path can be current.
    had_previous=0
    [ -e "$dest" ] && had_previous=1
    quarantine_previous
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
  # Staged, then swapped. `--out` points at a scratch sibling so a failed run leaves `$dest`
  # exactly as it was; only a run that actually produced a summary.json replaces it. The
  # swap is a rename inside $OUTDIR, so it is atomic enough for this purpose and cannot
  # leave a half-copied receipt behind.
  staging="$dest.rejudge"
  rm -rf "$staging"
  python3 "$ROOT/scripts/eval/behavior_judge.py" \
    --system new --judge "$JUDGE" \
    --corpus "$CORPUS" --candidates "$cand" --out "$staging" >&2 || true
  # The outcome is CARRIED from the staged run, never re-derived by looking at $dest.
  #
  # Third round of cloud review on this one area, and both remaining P1s came from reading
  # $dest afterwards: that cannot distinguish a receipt THIS run produced from one it merely
  # failed to replace. It let a failed re-judge write the new judge's stamp onto the previous
  # judge's receipt, so later runs skipped it and reported the old judge's scores as the new
  # judge's — the exact silently-mixed-judges defect this whole change exists to prevent, and
  # one my own staging fix introduced. My comment claimed the surviving receipt was safe
  # "because its stamp no longer matches"; the very next block was writing that stamp.
  staged_state=missing
  if [ -f "$staging/summary.json" ]; then
    if receipt_cacheable "$staging/summary.json"; then
      staged_state=cacheable
    else
      staged_state=partial
    fi
  fi
  # The DIRECTORY, not the summary inside it. An earlier run interrupted after `write_outputs`
  # created $dest or wrote per_case.jsonl but before summary.json leaves a directory with no
  # receipt: a summary-only test called that "no previous", quarantine skipped it, and
  # `mv "$staging" "$dest"` then moved the staged directory INSIDE it. No canonical summary for
  # the report, misplaced diagnostics accumulating, and no error anywhere. Cloud review caught
  # it; `mv` into an existing directory nesting rather than replacing is the trap.
  had_previous=0
  [ -e "$dest" ] && had_previous=1

  case "$staged_state" in
    cacheable)
      # The ONLY path that stamps. A stamp asserts "this judge produced this receipt", so it
      # is written exactly where that is true and nowhere else.
      #
      # Quarantine BEFORE promoting, never `rm -rf` then `mv`. That order had a window: an
      # interruption between the delete and the rename destroyed the old receipt while the new
      # one was still under `.rejudge`, and the next run deletes the staging directory — so both
      # were lost, which contradicted the interruption safety this staging was added for.
      # Two renames instead, so at every instant at least one complete receipt exists at a
      # path we can name.
      #
      # RESIDUAL LIMIT, recorded rather than engineered around: an interruption in the gap
      # between the two renames still loses the NEW result, because the next run clears the
      # staging directory and cannot know the staged receipt matches the current inputs. The old
      # receipt survives in the quarantine slot and the arm is simply re-judged, so the cost is
      # one re-run rather than lost data. Auto-promoting a leftover staged receipt would risk
      # promoting one graded against different inputs, which is worse than a re-run.
      quarantine_previous
      mv "$staging" "$dest"
      printf '%s\n' "$inputs_sha" > "$stamp"
      echo "  ok $base" >&2
      ;;
    partial)
      # A partial receipt must not evict a complete one, and the complete one must not stay
      # where the REPORT can see it. Both halves are cloud-review P1s from consecutive rounds,
      # and they pull in opposite directions until the old receipt is quarantined rather than
      # kept or deleted: `report_ollama_bench.py` reads `$dest/summary.json` and checks
      # cacheability but never the stamp, so a valid receipt from the PREVIOUS judge sitting at
      # the canonical path gets ranked alongside newly judged arms — a corrupted comparison,
      # silently, which is the failure this whole change exists to prevent.
      quarantine_previous
      # Promote the partial: it is what the current judge actually produced, and the report
      # rejects a non-cacheable receipt loudly rather than ranking it. Never stamped, so the
      # resume branch re-judges the arm next time.
      mv "$staging" "$dest"
      echo "  INCOMPLETE $base (receipt is not cacheable; left in place, not stamped)" >&2
      incomplete+=("$base")
      ;;
    missing)
      # The judge refused, crashed, timed out, or lost its network before writing anything.
      rm -rf "$staging"
      quarantine_previous
      echo "  FAILED $base" >&2
      failed+=("$base")
      ;;
  esac
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
