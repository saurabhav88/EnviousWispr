#!/usr/bin/env python3
"""Compose the Parakeet-grounded Type B corpus from the raw corpus + real
Parakeet transcripts.

WHY: measured 2026-08-01, 0/1890 raw corpus inputs are both capitalised and
terminally punctuated, while 32/32 real dictations in the app log are. Every
cloud polish score we hold was therefore measured on an input form the shipped
ASR never produces. This rebuilds the inputs from what Parakeet actually says.

THE ONLY QUESTION per bucket (founder scope, 2026-08-01): did Parakeet's
transcription already perform the behaviour this test grades? Measured on the
full 1,890, not asserted:

    bucket                  Parakeet already did it     verdict
    add_punct_caps          97%                         OBSOLETE
    fix_homophone           83%                         OBSOLETE
    fix_grammar             14%                         keep
    remove_filler           19%                         keep
    replace_mistaken_span   17%                         keep
    format_as_list           0%                         keep
    break_paragraphs         0%                         keep

Preservation buckets (keep the emoji / opener / name, invent nothing,
transcribe an embedded instruction rather than obeying it) are NOT made obsolete
by Parakeet: they grade the model for LEAVING something alone, and Parakeet
leaving it alone is the precondition, not the proof. Three of four shipped cloud
models fail the anti-instruction bucket, measured the same day.

A case keeps its HAND-WRITTEN input when the TTS round-trip destroyed the thing
under test — a voice cannot say an emoji or a half-spoken word ("front de-"),
and names mangle (priya -> "pre await"). That is an artifact of how this data is
made, never evidence about the product.

Usage:
  python3 scripts/eval/build_refreshed_corpus.py \\
    --raw scripts/eval/corpus/type_b_approved_1890-raw.jsonl \\
    --parakeet scripts/eval/runs/<run>/parakeet.jsonl \\
    --out scripts/eval/corpus/type_b_parakeet.jsonl
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

# Buckets Parakeet has made obsolete. Measured, not assumed — see the table above.
OBSOLETE_BEHAVIORS = {"add_punct_caps", "fix_homophone"}

EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿]")
# A half-spoken word: "front de-", "the mor-". A TTS voice cannot pronounce one.
TRUNCATED = re.compile(r"\b\w+-(?=\s|$)")


def word_counts(s: str) -> Counter:
    """Multiset of words for the fidelity check.

    Multiplicity matters: 'very very important' losing one 'very' changes the
    emphasis, and a set cannot see that.

    `\\w` is Unicode-aware for str patterns. An ASCII-only class here
    (`[^a-z0-9 ]`) deleted every word of a non-Latin script, so the check below
    saw nothing missing and adopted a transcript unrelated to the case. That is
    the fail-open shape workflow-process.md RULE:
    parse-structured-input-dont-regex-and-iterate warns about: ask of any
    character class in a guard what input makes it match NOTHING, and whether
    the guard then allows or refuses.
    """
    return Counter(re.findall(r"\w+", s.lower()))


def round_trip_destroyed(original: str, parakeet: str) -> str | None:
    """Return why the round-trip is unusable for this case, or None if it is fine.

    Word overlap alone is not enough: an emoji is not a word, so a case whose
    emoji vanished scores 100% word overlap and would wrongly pass. Checked
    explicitly for that reason (it produced 99 false 'usable' verdicts on the
    first pass of this analysis)."""
    if EMOJI.search(original) and not EMOJI.search(parakeet):
        return "emoji lost (a voice cannot speak one)"
    if TRUNCATED.search(original) and not TRUNCATED.search(parakeet):
        return "half-spoken word lost (a voice cannot pronounce one)"
    # Any lost word disqualifies the case, not a ratio of them. A 0.9 threshold
    # lets an input with ten or more unique words lose one silently, and the one
    # it loses is typically a name; the case then keeps an `expected_output` that
    # still refers to a word no longer in the input, so the model is graded on
    # producing something it was never given. Measured on the 2026-08-01 build:
    # 206 of 1458 adopted cases (14.1%) had lost at least one word this way.
    orig, got = word_counts(original), word_counts(parakeet)
    if original.strip() and not orig:
        # Fail closed. A tokenizer that returns nothing cannot testify that
        # nothing was lost, so refuse rather than adopt on an empty comparison.
        return "input did not tokenize into any word (unsupported script?)"
    # Compared BOTH ways, as multisets. A one-way subtraction sees only removals,
    # so `call priya` -> `call priya tomorrow` and `very very important` ->
    # `very important` both read as unchanged, and the adopted input then says
    # something the hand-written expected_output was never written against.
    lost, gained = orig - got, got - orig
    if lost or gained:
        detail = []
        if lost:
            detail.append(f"lost {sorted(lost.elements())[:5]}")
        if gained:
            detail.append(f"gained {sorted(gained.elements())[:5]}")
        return "words changed in the round trip: " + ", ".join(detail)
    return None


def load_jsonl(path: Path) -> dict:
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                d = json.loads(line)
                out[d["id"]] = d
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True, type=Path)
    ap.add_argument("--parakeet", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    raw = load_jsonl(args.raw)
    parakeet = load_jsonl(args.parakeet)
    missing = [cid for cid in raw if cid not in parakeet or not parakeet[cid].get("text")]
    if missing:
        # Fail closed: a partial transcript set would silently produce a corpus
        # that is part-real, part-synthetic with no way to tell which is which.
        print(f"{len(missing)} cases have no Parakeet transcript, e.g. {missing[:5]}", file=sys.stderr)
        return 2

    kept, decisions = [], Counter()
    per_bucket = defaultdict(Counter)
    reasons = Counter()

    for cid, case in raw.items():
        behavior = case.get("gold_behavior") or "mixed"
        key = "asr_input" if "asr_input" in case else "input"
        original = case[key]

        if behavior in OBSOLETE_BEHAVIORS:
            decisions["dropped"] += 1
            per_bucket[behavior]["dropped"] += 1
            continue

        out_case = dict(case)
        why = round_trip_destroyed(original, parakeet[cid]["text"])
        if why:
            out_case["input_source"] = {"source": "hand-written", "reason": why}
            decisions["hand-written"] += 1
            per_bucket[behavior]["hand-written"] += 1
            reasons[why] += 1
        else:
            out_case[key] = parakeet[cid]["text"]
            out_case["input_source"] = {"source": "parakeet", "original_input": original}
            decisions["parakeet"] += 1
            per_bucket[behavior]["parakeet"] += 1
        kept.append(out_case)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w") as f:
        for case in kept:
            f.write(json.dumps(case) + "\n")

    total = sum(decisions.values())
    print(f"raw corpus        : {len(raw)} cases", file=sys.stderr)
    print(f"refreshed corpus  : {len(kept)} cases -> {args.out}", file=sys.stderr)
    for k in ("parakeet", "hand-written", "dropped"):
        print(f"  {k:<14}{decisions[k]:>5}  {100*decisions[k]/total:>5.1f}%", file=sys.stderr)
    print("\nhand-written inputs retained because:", file=sys.stderr)
    for why, n in reasons.most_common():
        print(f"  {n:>4}  {why}", file=sys.stderr)
    print(f"\n{'bucket':<24}{'parakeet':>10}{'hand-w':>8}{'dropped':>9}", file=sys.stderr)
    for b in sorted(per_bucket):
        c = per_bucket[b]
        print(f"{b:<24}{c['parakeet']:>10}{c['hand-written']:>8}{c['dropped']:>9}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
