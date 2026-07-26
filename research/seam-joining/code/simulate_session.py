"""What happens over a WHOLE dictation session, not one pair at a time?

Founder question, 2026-07-25, and it exposes a hole in everything measured so
far: every number in this project comes from isolated pairs. Real people dictate
into one field five or six times in a row. The risk is not one bad join, it is
what a sequence of them produces.

Cascading cannot run away on its own. Merging A and B deletes A's terminator but
B keeps its own, so the text ends properly punctuated and the next decision
starts clean. The real danger is compounding: at a 10% per-decision error rate,
a six-recording burst has roughly a one-in-three chance of at least one bad
join, and each bad join hands the next decision a longer, stranger sentence than
anything in training.

This replays REAL bursts from the founder's history, applying each decision to
the text the previous decision produced, exactly as the app would. Then it
prints the final text a user would actually be looking at.

Two deterministic guardrails are measured with it, because they cost nothing:
  --max-words   refuse to extend a sentence past this length
  --max-chain   refuse more than N consecutive joins without a real break
"""

import argparse
import json
import os
import re
import sys
from collections import Counter

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

LABELS = ["KEEP", "MERGE_SPACE", "MERGE_COMMA"]
SEAM = "<seam>"
TERMINATORS = (".", "!", "?")
KEEP_CAPITAL = {"i", "i'm", "i've", "i'll", "i'd"}


def find(name):
    here = os.path.dirname(os.path.abspath(__file__))
    for c in (os.path.join(os.path.dirname(here), "data", name),
              os.path.join(here, name), name):
        if os.path.exists(c):
            return c
    return None


def sessions_from(path, max_gap, min_len):
    """A burst is consecutive recordings each within `max_gap` of the last."""
    rows = [json.loads(l) for l in open(path, encoding="utf-8")]
    bursts, current = [], []
    for row in rows:
        if current and row["gap_seconds"] <= max_gap:
            current.append(row["rec2"])
        else:
            if len(current) >= min_len:
                bursts.append(current)
            current = [row["rec1"], row["rec2"]]
    if len(current) >= min_len:
        bursts.append(current)
    return bursts


def apply_join(left, right, separator):
    """Exactly what the app would write: drop the terminator we are joining
    across, drop the trailing space, lowercase the next word unless it earns
    its capital."""
    left = re.sub(r"[.!?]+$", "", left.strip()).rstrip()
    if separator.strip() == "" or separator.startswith(","):
        left = left.rstrip(",").rstrip()
    words = right.split()
    if words:
        bare = words[0].strip(".,!?;:")
        earns_capital = (
            bare.lower() in KEEP_CAPITAL
            or (len(bare) > 1 and any(c.isupper() for c in bare[1:]))
        )
        if not earns_capital and bare[:1].isupper():
            right = right[0].lower() + right[1:]
    return f"{left}{separator}{right}"


def decide(model, tok, left, right):
    text = (f"{' '.join(left.split()[-18:])} {SEAM} {' '.join(right.split()[:14])}")
    enc = tok(text, truncation=True, max_length=96, return_tensors="pt")
    if torch.cuda.is_available():
        enc = {k: v.cuda() for k, v in enc.items()}
    with torch.no_grad():
        return LABELS[model(**enc).logits.argmax(-1).item()]


def last_sentence(text):
    parts = re.split(r"(?<=[.!?])\s+", text.strip())
    return parts[-1] if parts else text


def replay(model, tok, burst, max_words, max_chain):
    """Run a burst through, applying each decision to the running text."""
    out = burst[0].strip()
    chain = 0
    decisions = []
    refusals = Counter()
    for nxt in burst[1:]:
        verdict = decide(model, tok, out, nxt)
        tail = last_sentence(out)
        if verdict != "KEEP":
            if max_chain and chain >= max_chain:
                verdict, reason = "KEEP", "chain limit"
                refusals[reason] += 1
            elif max_words and len(tail.split()) + len(nxt.split()) > max_words:
                verdict, reason = "KEEP", "length ceiling"
                refusals[reason] += 1
        decisions.append(verdict)
        if verdict == "KEEP":
            chain = 0
            if not out.rstrip().endswith(TERMINATORS):
                out = out.rstrip() + "."
            out = f"{out} {nxt.strip()}"
        else:
            chain += 1
            out = apply_join(out, nxt.strip(), ", " if verdict == "MERGE_COMMA" else " ")
    return out, decisions, refusals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--pairs", default="seam_real_transcripts.jsonl")
    ap.add_argument("--max-gap", type=float, default=30.0)
    ap.add_argument("--min-len", type=int, default=4, help="recordings per burst")
    ap.add_argument("--max-words", type=int, default=0, help="0 = no ceiling")
    ap.add_argument("--max-chain", type=int, default=0, help="0 = no limit")
    ap.add_argument("--show", type=int, default=6)
    args = ap.parse_args()

    path = find(args.pairs)
    if not path:
        print(f"{args.pairs} not found", file=sys.stderr)
        return 1
    bursts = sessions_from(path, args.max_gap, args.min_len)
    print(f"\n{len(bursts)} real bursts of {args.min_len}+ recordings "
          f"(gap <= {args.max_gap:.0f}s)")
    print(f"guardrails: max sentence {args.max_words or 'none'} words, "
          f"max consecutive joins {args.max_chain or 'none'}")

    tok = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForSequenceClassification.from_pretrained(args.model)
    model.eval()
    if torch.cuda.is_available():
        model.cuda()

    longest = 0
    all_decisions = Counter()
    all_refusals = Counter()
    over40 = over60 = 0
    shown = 0
    for burst in bursts:
        out, decisions, refusals = replay(model, tok, burst, args.max_words, args.max_chain)
        all_decisions.update(decisions)
        all_refusals.update(refusals)
        worst = max((len(s.split()) for s in re.split(r"(?<=[.!?])\s+", out)), default=0)
        longest = max(longest, worst)
        over40 += worst > 40
        over60 += worst > 60
        if shown < args.show and any(d != "KEEP" for d in decisions):
            shown += 1
            print(f"\n--- burst of {len(burst)}, decisions: {decisions}")
            print(f"    BEFORE: {' | '.join(b[:60] for b in burst[:4])}")
            print(f"    AFTER : {out[:400]}")

    total = sum(all_decisions.values())
    print(f"\n{total} decisions across {len(bursts)} bursts: {dict(all_decisions)}")
    print(f"joined {100*(total-all_decisions['KEEP'])/max(total,1):.1f}% of the time")
    if all_refusals:
        print(f"guardrail refusals: {dict(all_refusals)}")
    print(f"longest sentence produced: {longest} words")
    print(f"bursts producing a sentence over 40 words: {over40}/{len(bursts)}")
    print(f"bursts producing a sentence over 60 words: {over60}/{len(bursts)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
