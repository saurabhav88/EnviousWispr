"""Score models against REAL consecutive recordings. This is the ship gate.

The synthetic held-out set is at its ceiling and cannot separate candidates; the
positional stress set has only ten sentence boundaries and cannot measure safety
at all. This set can: real pauses, real transcription artifacts, real polish
output, and sentence boundaries in quantity.

Two numbers, never merged into one:

  wrong merges   the model joined two of the user's genuinely separate
                 sentences. Silent damage. Zero is the bar.
  missed joins   the model left today's behaviour in place. Costs nothing.

Denominators are printed with the rates, because "zero wrong merges" over 40
boundaries is a far weaker claim than over 400, and the honest form names it.

The labels come from a grader that under-merges about 19% of the time
(`calibrate_grader.py`), so a flagged wrong merge may be the grader's error
rather than the model's. Every flag is therefore WRITTEN OUT for a human to
read, and the printed count is labelled as a ceiling, not a verdict.
"""

import argparse
import json
import os
import sys
from collections import defaultdict

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

LABELS = ["KEEP", "MERGE_SPACE", "MERGE_COMMA"]
SEAM = "<seam>"


def find(name):
    here = os.path.dirname(os.path.abspath(__file__))
    for candidate in (os.path.join(os.path.dirname(here), "data", name),
                      os.path.join(here, name), name):
        if os.path.exists(candidate):
            return candidate
    return None


def predict(model_dir, rows, batch=64):
    tok = AutoTokenizer.from_pretrained(model_dir)
    model = AutoModelForSequenceClassification.from_pretrained(model_dir)
    model.eval()
    if torch.cuda.is_available():
        model.cuda()
    out = []
    for i in range(0, len(rows), batch):
        chunk = rows[i : i + batch]
        texts = [f"{' '.join(r['rec1'].split()[-18:])} {SEAM} "
                 f"{' '.join(r['rec2'].split()[:14])}" for r in chunk]
        enc = tok(texts, truncation=True, max_length=96, padding=True, return_tensors="pt")
        if torch.cuda.is_available():
            enc = {k: v.cuda() for k, v in enc.items()}
        with torch.no_grad():
            out.extend(model(**enc).logits.argmax(-1).tolist())
    del model
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    return [LABELS[p] for p in out]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("models", nargs="+")
    ap.add_argument("--labels", default="seam_real_labelled.jsonl")
    ap.add_argument("--flags-out", default="real_seam_flags.jsonl")
    args = ap.parse_args()

    path = find(args.labels)
    if not path:
        print(f"{args.labels} not found — run grade_real_seams.py first", file=sys.stderr)
        return 1
    rows = [json.loads(l) for l in open(path, encoding="utf-8")]

    # Refuse a TARGETED label file as a general corpus. `grade_real_seams.py
    # --predictions` deliberately grades only the pairs ONE source model chose
    # to merge, which is the right way to measure the dangerous direction and
    # the wrong population to score any other model against: those rows are
    # selected by that model's own decisions, so every other model's numbers
    # come out of a biased sample while reading like a ship gate. Found by
    # cloud review on PR #1793.
    sources = {r.get("label_source", "unknown") for r in rows}
    if any("targeted" in str(s) or "merge_only" in str(s) for s in sources):
        print(f"REFUSING: {path} was graded on one model's MERGE decisions "
              f"only (label_source={sorted(sources)}). Those rows are a biased "
              f"sample, not a population, and scoring other models against them "
              f"produces numbers that look like a gate and are not one. Grade a "
              f"random sample instead (omit --predictions).", file=sys.stderr)
        return 1

    boundaries = [r for r in rows if r["label"] == "KEEP"]
    joins = [r for r in rows if r["label"] != "KEEP"]
    print(f"\n{len(rows)} real consecutive recordings from the founder's logs")
    print(f"  graded as genuinely separate : {len(boundaries)}")
    print(f"  graded as one thought split  : {len(joins)}")
    if len(boundaries) < 30:
        print("  WARNING: too few boundaries to make a safety claim", file=sys.stderr)

    head = f"\n{'model':22}{'wrong merges':>18}{'missed joins':>18}{'agreement':>12}"
    print(head)
    print("-" * len(head.strip()))

    flagged = []
    for model_dir in args.models:
        preds = predict(model_dir, rows)
        wrong = [(r, p) for r, p in zip(rows, preds)
                 if r["label"] == "KEEP" and p != "KEEP"]
        missed = [(r, p) for r, p in zip(rows, preds)
                  if r["label"] != "KEEP" and p == "KEEP"]
        agree = sum(1 for r, p in zip(rows, preds) if p == r["label"]) / max(len(rows), 1)
        name = os.path.basename(model_dir)
        print(f"{name:22}{len(wrong):>8}/{len(boundaries):<9}"
              f"{len(missed):>8}/{len(joins):<9}{100*agree:>11.1f}%")
        for row, pred in wrong:
            flagged.append({**row, "model": name, "model_said": pred,
                            "grader_said": row["label"]})

    out = os.path.join(os.path.dirname(path), args.flags_out)
    with open(out, "w", encoding="utf-8") as handle:
        for row in flagged:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    print(f"\nwrong-merge counts are a CEILING, not a verdict: the grader misses "
          f"about 19% of real\njoins, so some flags are its error. All {len(flagged)} "
          f"are written to {out}\nfor a human to read before any of them counts.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
