"""Does the model hold up wherever the cut lands?

The shared held-out set does not answer this. Both arms sit near its ceiling, so
it cannot separate them, and it carries whatever cut-position distribution its
own generator happened to produce. That is the wrong instrument for a change
whose entire claim is about cut POSITION.

This builds the right one. Take source texts the model has never seen, cut each
at EVERY valid position, and report accuracy by what kind of word the cut
followed. If training on one arbitrary cut per sentence leaves blind spots, they
show up here as a class of preceding word the model gets wrong, and a model
trained across the spectrum should be flat instead.

Flat is the result to want. A high average with a bad bucket is exactly the
failure the founder's directive predicts, and an average would hide it.
"""

import argparse
import json
import os
import random
import sys
from collections import defaultdict

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

LABELS = ["KEEP", "MERGE_SPACE", "MERGE_COMMA"]
SEAM = "<seam>"
TERMINATORS = (".", "!", "?")

# Closed-class buckets, so "what kind of word preceded the cut" is a real
# category rather than a bag of individual words.
FUNCTION_WORDS = {
    "articles": {"a", "an", "the"},
    "prepositions": {"of", "in", "on", "at", "for", "with", "from", "by", "to",
                     "into", "about", "over", "under", "through", "between"},
    "conjunctions": {"and", "but", "or", "so", "because", "although", "while",
                     "if", "when", "since", "that", "which", "as"},
    "auxiliaries": {"is", "are", "was", "were", "am", "be", "been", "being",
                    "has", "have", "had", "do", "does", "did", "will", "would",
                    "can", "could", "should", "may", "might", "must"},
    "pronouns": {"i", "you", "he", "she", "it", "we", "they", "my", "your",
                 "his", "her", "its", "our", "their", "this", "these", "those"},
}


def bucket_for(word):
    bare = word.strip(".,!?;:\"'()").lower()
    if word.endswith(TERMINATORS):
        return "after a full stop"
    if word.endswith(","):
        return "after a comma"
    for name, members in FUNCTION_WORDS.items():
        if bare in members:
            return f"after {name}"
    if bare.isdigit():
        return "after a number"
    if word[:1].isupper():
        return "after a capitalised word"
    return "after an ordinary word"


def build(texts, rng, per_text=None):
    rows = []
    for text in texts:
        words = text.split()
        if len(words) < 10:
            continue
        spots = list(range(3, len(words) - 3))
        if per_text and len(spots) > per_text:
            spots = rng.sample(spots, per_text)
        for idx in spots:
            left = " ".join(words[:idx])
            right = " ".join(words[idx:])
            previous = words[idx - 1]
            if previous.endswith(TERMINATORS):
                label = "KEEP"
            elif previous.endswith(","):
                label = "MERGE_COMMA"
                left = left.rstrip(",")
            elif previous[-1:] in ";:":
                continue
            else:
                label = "MERGE_SPACE"
            # Corrupt exactly as the transcriber does, measured 2026-07-24.
            roll = rng.random()
            if label != "KEEP":
                left = left.rstrip(",;:") + ("." if roll < 0.80 else "" if roll < 0.90 else "?")
            if rng.random() < 0.90 and right[:1].islower():
                right = right[0].upper() + right[1:]
            rows.append({"rec1": left, "rec2": right, "label": label,
                         "bucket": bucket_for(previous)})
    return rows


def score(model_dir, rows, batch=64):
    tok = AutoTokenizer.from_pretrained(model_dir)
    model = AutoModelForSequenceClassification.from_pretrained(model_dir)
    model.eval()
    if torch.cuda.is_available():
        model.cuda()
    per = defaultdict(lambda: {"n": 0, "ok": 0, "keep": 0, "wrong_merge": 0})
    for i in range(0, len(rows), batch):
        chunk = rows[i : i + batch]
        texts = [f"{' '.join(r['rec1'].split()[-18:])} {SEAM} "
                 f"{' '.join(r['rec2'].split()[:14])}" for r in chunk]
        enc = tok(texts, truncation=True, max_length=96, padding=True, return_tensors="pt")
        if torch.cuda.is_available():
            enc = {k: v.cuda() for k, v in enc.items()}
        with torch.no_grad():
            preds = model(**enc).logits.argmax(-1).tolist()
        for r, p in zip(chunk, preds):
            got = LABELS[p]
            s = per[r["bucket"]]
            s["n"] += 1
            s["ok"] += int(got == r["label"])
            if r["label"] == "KEEP":
                s["keep"] += 1
                s["wrong_merge"] += int(got != "KEEP")
    del model
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    return per


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("models", nargs="+")
    ap.add_argument("--per-text", type=int, default=12)
    args = ap.parse_args()

    # The rig keeps everything flat in the home directory; the Mac keeps data
    # one level up from the code. Look in both rather than assuming a layout.
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [os.path.join(os.path.dirname(here), "data", "seam_test_shared.jsonl"),
                  os.path.join(here, "seam_test_shared.jsonl"),
                  "seam_test_shared.jsonl"]
    path = next((c for c in candidates if os.path.exists(c)), None)
    if not path:
        print(f"seam_test_shared.jsonl not found in {candidates}", file=sys.stderr)
        return 1
    seen = set()
    texts = []
    for line in open(path, encoding="utf-8"):
        row = json.loads(line)
        if row.get("language") != "English":
            continue
        expected = (row.get("expected") or "").strip()
        if expected and expected not in seen:
            seen.add(expected)
            texts.append(expected)

    rng = random.Random(1790)
    rows = build(texts, rng, per_text=args.per_text)
    print(f"positional stress set: {len(rows)} cuts from {len(texts)} unseen texts",
          file=sys.stderr)

    results = {m: score(m, rows) for m in args.models}
    buckets = sorted({b for r in results.values() for b in r})

    head = f"{'cut position':28}" + "".join(f"{os.path.basename(m):>22}" for m in args.models)
    print("\nACCURACY BY WHERE THE CUT LANDED")
    print(head)
    print("-" * len(head))
    for b in buckets:
        line = f"{b:28}"
        for m in args.models:
            s = results[m].get(b)
            line += f"{100*s['ok']/s['n']:>15.1f}% ({s['n']:>3})" if s and s["n"] else f"{'-':>22}"
        print(line)

    print("\nWRONG MERGES BY WHERE THE CUT LANDED  (only 'after a full stop' has any)")
    for b in buckets:
        cells = ""
        any_keep = False
        for m in args.models:
            s = results[m].get(b)
            if s and s["keep"]:
                any_keep = True
                cells += f"{s['wrong_merge']:>15}/{s['keep']:<6}"
            else:
                cells += f"{'-':>22}"
        if any_keep:
            print(f"{b:28}{cells}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
