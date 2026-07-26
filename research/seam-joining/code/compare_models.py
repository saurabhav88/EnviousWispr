"""Compare every trained seam model PER LANGUAGE, across seeds.

Founder point 2026-07-25: the English winner and the international winner may not
be the same model. English is 598 of the 879 held-out rows - 68% - so an
aggregate score is dominated by it and can hide a model that is worse in German
or Russian. Aggregates are reported last, and only for context.

Two numbers per language, because they answer different questions:
  wrong merges - two separate sentences welded together. Silent damage. The
                 number that decides whether something is shippable.
  accuracy     - all three labels correct. Quality, not safety.
"""

import json
import os
import sys
from collections import defaultdict

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

LABELS = ["KEEP", "MERGE_SPACE", "MERGE_COMMA"]
SEAM = "<seam>"


def score(model_dir, rows):
    tok = AutoTokenizer.from_pretrained(model_dir)
    model = AutoModelForSequenceClassification.from_pretrained(model_dir)
    model.eval()
    if torch.cuda.is_available():
        model.cuda()

    per = defaultdict(lambda: {"n": 0, "correct": 0, "keep_n": 0, "wrong_merge": 0})
    batch = 64
    for i in range(0, len(rows), batch):
        chunk = rows[i : i + batch]
        texts = [
            f"{' '.join(r['rec1'].split()[-18:])} {SEAM} {' '.join(r['rec2'].split()[:14])}"
            for r in chunk
        ]
        enc = tok(texts, truncation=True, max_length=96, padding=True, return_tensors="pt")
        if torch.cuda.is_available():
            enc = {k: v.cuda() for k, v in enc.items()}
        with torch.no_grad():
            pred = model(**enc).logits.argmax(-1).tolist()
        for r, p in zip(chunk, pred):
            lab = LABELS[p]
            s = per[r["language"]]
            s["n"] += 1
            s["correct"] += int(lab == r["label"])
            if r["label"] == "KEEP":
                s["keep_n"] += 1
                s["wrong_merge"] += int(lab != "KEEP")
    del model
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    return per


def main():
    rows = [json.loads(l) for l in open("seam_test.jsonl", encoding="utf-8")]
    dirs = [d for d in sorted(os.listdir(".")) if d.startswith("seam-") and os.path.isdir(d)]
    if len(sys.argv) > 1:
        dirs = [d for d in dirs if any(a in d for a in sys.argv[1:])]

    langs = sorted({r["language"] for r in rows})
    results = {}
    for d in dirs:
        try:
            results[d] = score(d, rows)
        except Exception as exc:
            print(f"{d}: skipped ({type(exc).__name__})", flush=True)

    print("\nWRONG MERGES BY LANGUAGE  (silent damage - lower is better)")
    head = f"{'model':26}" + "".join(f"{l:>12}" for l in langs) + f"{'TOTAL':>8}"
    print(head)
    print("-" * len(head))
    for d, per in results.items():
        cells = ""
        tot = 0
        for l in langs:
            s = per.get(l)
            if not s or not s["keep_n"]:
                cells += f"{'-':>12}"
                continue
            cells += f"{s['wrong_merge']:>6}/{s['keep_n']:<5}"
            tot += s["wrong_merge"]
        print(f"{d:26}{cells}{tot:>8}")

    print("\nACCURACY BY LANGUAGE")
    print(head)
    print("-" * len(head))
    for d, per in results.items():
        cells = ""
        cor = n = 0
        for l in langs:
            s = per.get(l)
            if not s or not s["n"]:
                cells += f"{'-':>12}"
                continue
            cells += f"{100*s['correct']/s['n']:>11.1f}%"
            cor += s["correct"]
            n += s["n"]
        print(f"{d:26}{cells}{100*cor/max(n,1):>7.1f}%")

    print("\nNOTE: English is 68% of the rows, so the TOTAL column is mostly English.")
    print("Read the per-language columns before picking a winner.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
