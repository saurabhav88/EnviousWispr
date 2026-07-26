"""Score every trained model on BOTH test sets and rank by a single honest rule.

Two sets, because they answer different questions:
  seam_test.jsonl      879 rows, English/German/Russian - languages we trained on
  seam_zeroshot.jsonl  330 rows, six languages with ZERO training data

A model that wins the first and loses the second is overfitted to its training
languages, and expanding to new languages would then require a data project per
language rather than working out of the box.

Ranking rule, fixed before results are seen:
  1. fewest wrong merges across BOTH sets (silent damage is disqualifying)
  2. then highest mean accuracy across BOTH sets
Seeds are averaged; the spread is printed so a lucky seed cannot be mistaken for
a better model.
"""

import json
import os
import re
import statistics
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
    correct = wrong_merge = keep_n = 0
    for i in range(0, len(rows), 64):
        chunk = rows[i : i + 64]
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
            correct += int(lab == r["label"])
            if r["label"] == "KEEP":
                keep_n += 1
                wrong_merge += int(lab != "KEEP")
    del model
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    return correct / len(rows), wrong_merge, keep_n


def main():
    trained = [json.loads(l) for l in open("seam_test.jsonl", encoding="utf-8")]
    unseen = [json.loads(l) for l in open("seam_zeroshot.jsonl", encoding="utf-8")]

    dirs = sorted(d for d in os.listdir(".") if d.startswith("seam-") and os.path.isdir(d))
    # Group seeds of the same configuration together.
    groups = defaultdict(list)
    for d in dirs:
        groups[re.sub(r"-s\d+$", "", d)].append(d)

    rows = []
    for name, members in sorted(groups.items()):
        accs_t, accs_z, wm_t, wm_z = [], [], [], []
        for d in members:
            try:
                a, w, _ = score(d, trained)
                accs_t.append(a)
                wm_t.append(w)
                a, w, _ = score(d, unseen)
                accs_z.append(a)
                wm_z.append(w)
            except Exception as exc:
                print(f"  {d}: skipped ({type(exc).__name__}: {str(exc)[:60]})", flush=True)
        if not accs_t:
            continue
        rows.append({
            "name": name,
            "n": len(accs_t),
            "acc_t": statistics.mean(accs_t),
            "acc_z": statistics.mean(accs_z),
            "wm_t": statistics.mean(wm_t),
            "wm_z": statistics.mean(wm_z),
            "spread_z": (min(accs_z), max(accs_z)),
        })

    rows.sort(key=lambda r: (r["wm_t"] + r["wm_z"], -(r["acc_t"] + r["acc_z"]) / 2))

    print(f"\n{'configuration':24}{'seeds':>6}{'trained-lang':>14}{'UNSEEN-lang':>13}"
          f"{'wrong merges':>15}{'unseen spread':>18}")
    print(f"{'':24}{'':>6}{'accuracy':>14}{'accuracy':>13}{'trained+unseen':>15}{'':>18}")
    print("-" * 92)
    for r in rows:
        lo, hi = r["spread_z"]
        print(f"{r['name']:24}{r['n']:>6}{100*r['acc_t']:>13.1f}%{100*r['acc_z']:>12.1f}%"
              f"{r['wm_t']:>8.1f}+{r['wm_z']:<5.1f}{100*lo:>10.1f}-{100*hi:.1f}%")
    print("\nRanked by fewest wrong merges, then accuracy. Both criteria fixed before running.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
