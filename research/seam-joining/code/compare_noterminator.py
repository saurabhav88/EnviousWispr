"""Who should judge a recording that ends WITHOUT a full stop?

Founder question, 2026-07-25. Two systems can answer it, so the plan has to say
which one does, and "the simple rule is provably right here" turns out to be
false: across all three sets, 8-14% of no-terminator rows are genuinely
separate thoughts. A missing full stop is evidence, not proof.

This scores both deciders on exactly that subset:

  rule   #1785's deterministic certificate — no terminal punctuation, or a
         final closed-class word that cannot end a sentence, means merge
  model  the seam classifier, which saw no-terminator examples in training
         (assemble_dataset.py leaves the terminator off 10% of the time)

Reported separately because the two disagree in the direction that matters:
a wrong merge welds two of the user's sentences together and is silent.
"""

import json
import os
import sys

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

LABELS = ["KEEP", "MERGE_SPACE", "MERGE_COMMA"]
SEAM = "<seam>"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MODEL = os.path.join(ROOT, "model", "seam-legacy-view")

TERMINATORS = (".", "!", "?")

# The REAL closed-class lists the deterministic arm uses, per language, not a
# re-implementation. A hand-copied mirror measures a second implementation
# against itself (validation-discipline.md
# RULE: measure-with-the-real-tool-never-a-simulation).
from bench_options import CANNOT_END  # noqa: E402


def window(row):
    left = " ".join(row["rec1"].split()[-18:])
    right = " ".join(row["rec2"].split()[:14])
    return f"{left} {SEAM} {right}"


def rule_predict(row):
    """#1785's arm, both certificates, using each row's own language list."""
    stripped = row["rec1"].strip()
    words = [w.strip(".,!?;:\"'()").lower() for w in stripped.split()]
    closed = CANNOT_END.get(row.get("language", "English"), set())
    if not stripped.endswith(TERMINATORS):
        return "MERGE_SPACE"
    if words and words[-1] in closed:
        return "MERGE_SPACE"
    return "KEEP"


def rule_predict_safe_half(row):
    """The same rule with the no-punctuation certificate REMOVED.

    That certificate is the one under test: it claims a missing full stop
    proves the thought was unfinished. If dropping it removes the wrong merges
    without costing much, the fallback should ship without it.
    """
    stripped = row["rec1"].strip()
    words = [w.strip(".,!?;:\"'()").lower() for w in stripped.split()]
    closed = CANNOT_END.get(row.get("language", "English"), set())
    if words and words[-1] in closed:
        return "MERGE_SPACE"
    return "KEEP"


def model_predict(rows, batch=32):
    tok = AutoTokenizer.from_pretrained(MODEL)
    model = AutoModelForSequenceClassification.from_pretrained(MODEL)
    model.eval()
    out = []
    for i in range(0, len(rows), batch):
        chunk = rows[i : i + batch]
        enc = tok([window(r) for r in chunk], truncation=True, max_length=96,
                  padding=True, return_tensors="pt")
        with torch.no_grad():
            out.extend(model(**enc).logits.argmax(-1).tolist())
    return [LABELS[p] for p in out]


def score(preds, rows, label):
    correct = sum(int(p == r["label"]) for p, r in zip(preds, rows))
    keep_rows = [(p, r) for p, r in zip(preds, rows) if r["label"] == "KEEP"]
    wrong_merges = sum(1 for p, _ in keep_rows if p != "KEEP")
    merge_rows = [(p, r) for p, r in zip(preds, rows) if r["label"] != "KEEP"]
    missed = sum(1 for p, _ in merge_rows if p == "KEEP")
    print(f"  {label:26} {100*correct/len(rows):5.1f}% correct   "
          f"{wrong_merges:>3} wrong merges of {len(keep_rows):>3} separate pairs   "
          f"{missed:>3} joins missed of {len(merge_rows):>3}")


def main():
    for name in ("seam_test.jsonl", "seam_zeroshot.jsonl"):
        path = os.path.join(ROOT, "data", name)
        rows = [json.loads(l) for l in open(path, encoding="utf-8")]
        subset = [r for r in rows if not r["rec1"].rstrip().endswith(TERMINATORS)]
        if not subset:
            continue
        print(f"\n{name}: {len(subset)} rows where the left half has NO full stop")
        score([rule_predict(r) for r in subset], subset, "rule, both certificates")
        score([rule_predict_safe_half(r) for r in subset], subset, "rule, safe half only")
        score(model_predict(subset), subset, "seam classifier")

        # And the complement, so the comparison is not cherry-picked.
        rest = [r for r in rows if r["rec1"].rstrip().endswith(TERMINATORS)]
        print(f"  ({len(rest)} rows WITH a full stop, for contrast)")
        score([rule_predict(r) for r in rest], rest, "rule, both certificates")
        score(model_predict(rest), rest, "seam classifier")
    return 0


if __name__ == "__main__":
    sys.exit(main())
