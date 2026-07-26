"""Measure the grader before trusting it to label anything.

A grader that labels real seams becomes the ground truth for the ship decision,
so an unmeasured one is worse than none: it would quietly define success as
"agrees with a model nobody checked". The first ten real pairs came back with
"Yeah, I pushed to GitHub." + "Yes, push to GitHub." marked as one sentence,
which is plainly wrong, so the prompt needed work and the work needed a scale.

The held-out synthetic set has known labels. Running the grader on it measures
exactly the thing that matters: does it over-merge? Over-merging is fatal here,
because a grader biased toward JOIN would mark real wrong merges as correct and
hide the only failure that disqualifies the feature.

Compares prompt variants on the same rows so a change is an improvement rather
than a different set of mistakes.
"""

import argparse
import json
import os
import random
import re
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

BASE = """A person is dictating with speech-to-text. They spoke once, paused, then spoke again. Each recording was transcribed separately, so the software added a capital letter and a full stop to each one whether or not the thought was actually finished.

Recording 1: {rec1}
Recording 2: {rec2}

Did they finish a thought and start a new one, or was this one thought interrupted by a pause?

Answer with exactly one word:
SEPARATE - two distinct thoughts, they should stay as two sentences
JOIN - one thought split by the pause, the second continues the first
COMMA - one thought split by the pause, and the join reads best with a comma

Answer:"""

STRICT = """A person dictated, paused, then dictated again. Each recording was transcribed on its own, so the software may have added a capital letter and a full stop to the first one even if the thought was not finished.

Recording 1: {rec1}
Recording 2: {rec2}

Decide whether these are one sentence or two.

The test is grammatical, not topical. Two fragments about the same subject are still two sentences. Ask: would a careful writer have written this as ONE sentence?

Answer SEPARATE when both halves stand on their own as complete sentences, even if they are closely related, sequential, part of the same story, or the second one restates, corrects or contradicts the first.

Answer JOIN only when the first half is grammatically incomplete without the second, so reading them as one sentence is clearly more natural than reading them as two. Typically the first half ends mid-clause, on a preposition, conjunction, article, or an unfinished verb phrase.

Answer COMMA in the same situation as JOIN, but where the joined sentence reads best with a comma at the seam.

When in doubt, answer SEPARATE.

Answer with exactly one word.

Answer:"""

# Hand-checked correction. Reading the flagged cases showed one class the strict
# rule got wrong every time: a second recording opening with a linking word
# ("or", "and", "so", "but"). In speech that almost always CONTINUES the thought
# after a pause — "Did you fix the GitHub problem?" + "Or is that still
# pending?" is one question, not two. The strict rule called all 74 such cases
# separate; a careful pass flipped 35 of them. Without this clause the grader
# blames the model for joins it got right.
LINKED = STRICT.replace(
    "When in doubt, answer SEPARATE.",
    """SPECIAL CASE, and it is common. If the second recording opens with a linking word (or, and, so, but, also, because, which, that), it usually CONTINUES the first thought rather than starting a new one, and the answer is usually COMMA. Read the two halves aloud as one sentence: if that reads naturally, it is one sentence.
  "Did you just implement a fix for the GitHub problem?" + "Or is that still pending?" -> COMMA
  "Is this a rebuild over CI tests?" + "Or was this a simplification?" -> COMMA
Answer SEPARATE for such a pair only when the second half is a genuinely new point that merely happens to start with a linking word, so joining them would read as a rambling run-on.

When in doubt on anything else, answer SEPARATE.""")

PROMPTS = {"strict": STRICT, "linked": LINKED}
LABEL_FROM_WORD = {"SEPARATE": "KEEP", "JOIN": "MERGE_SPACE", "COMMA": "MERGE_COMMA"}


def grade(client, model, template, pair):
    """Return (label, failure). A silent None here would be a fabricated result:
    the first run of this file dropped 80 of 150 answers and still printed
    confident percentages."""
    for attempt in range(4):
        try:
            response = client.messages.create(
                model=model, max_tokens=8, temperature=0,
                messages=[{"role": "user", "content": template.format(
                    rec1=pair["rec1"].strip(), rec2=pair["rec2"].strip())}])
        except Exception as exc:
            name = type(exc).__name__
            if "Throttl" in name or "TooManyRequests" in name or "429" in str(exc):
                time.sleep(1.5 * (attempt + 1))
                continue
            return None, f"api:{name}"
        text = response.content[0].text
        word = re.sub(r"[^A-Z]", "", text.upper())
        for key, label in LABEL_FROM_WORD.items():
            if word.startswith(key[:4]):
                return label, None
        return None, f"parse:{text.strip()[:24]!r}"
    return None, "api:throttled-out"


def report(name, results, rows):
    preds = [r[0] for r in results]
    failures = [r[1] for r in results if r[1]]
    if failures:
        print(f"  {name:8} {len(failures)}/{len(rows)} FAILED: "
              f"{dict(Counter(failures).most_common(3))}")
    pairs = [(p, r["label"]) for p, r in zip(preds, rows) if p]
    if not pairs:
        print(f"  {name}: no usable answers")
        return
    if len(pairs) < 0.9 * len(rows):
        print(f"  {name:8} REFUSING to score: only {len(pairs)}/{len(rows)} answered")
        return
    correct = sum(1 for p, t in pairs if p == t)
    # The fatal direction: truth is KEEP, grader says merge.
    keeps = [(p, t) for p, t in pairs if t == "KEEP"]
    over = sum(1 for p, _ in keeps if p != "KEEP")
    merges = [(p, t) for p, t in pairs if t != "KEEP"]
    under = sum(1 for p, _ in merges if p == "KEEP")
    # Treating the two merge kinds as one, since the seam decision is what matters.
    binary = sum(1 for p, t in pairs if (p == "KEEP") == (t == "KEEP"))
    print(f"  {name:8} exact {100*correct/len(pairs):5.1f}%   "
          f"join-or-not {100*binary/len(pairs):5.1f}%   "
          f"OVER-merges {over:>3}/{len(keeps):<3}   under-merges {under:>3}/{len(merges)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=150)
    ap.add_argument("--model", default="us.anthropic.claude-haiku-4-5-20251001-v1:0")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--lang", default="English")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    rows = [json.loads(l) for l in
            open(os.path.join(root, "data", "seam_test_shared.jsonl"), encoding="utf-8")]
    rows = [r for r in rows if r.get("language") == args.lang]
    # Stratify. The natural mix is ~11% KEEP, so 150 unstratified rows carry
    # about 11 of the ONE class that measures the fatal direction. Balance it
    # so the over-merge denominator is big enough to mean anything.
    rng = random.Random(1790)
    keeps = [r for r in rows if r["label"] == "KEEP"]
    merges = [r for r in rows if r["label"] != "KEEP"]
    rng.shuffle(keeps); rng.shuffle(merges)
    half = args.limit // 2
    rows = keeps[:half] + merges[: args.limit - min(half, len(keeps))]
    rng.shuffle(rows)
    print(f"calibrating on {len(rows)} {args.lang} rows with KNOWN labels: "
          f"{dict(Counter(r['label'] for r in rows))}", file=sys.stderr)

    from anthropic import AnthropicBedrock
    client = AnthropicBedrock(
        aws_access_key=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        aws_region="us-east-1")

    print("\n  (over-merges is the fatal direction: grader calls a real boundary a join)")
    for name, template in PROMPTS.items():
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            results = list(pool.map(lambda p: grade(client, args.model, template, p), rows))
        report(name, results, rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
