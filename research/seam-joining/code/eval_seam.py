"""Interrogate the trained seam classifier. 99.2% is a number to distrust.

Four checks, each designed to expose a different way that figure could be fake:

  1. PER LANGUAGE. English test rows come from a completely independent file the
     model never saw. German and Russian test rows were carved out of the SAME
     generated file the training rows came from, so near-duplicates may survive
     the exact-match leakage filter. If English collapses while German and
     Russian are perfect, the score is leakage.

  2. NEAR-DUPLICATE AUDIT. Exact first-half matches were removed at assembly
     time. This checks how similar each test row's nearest training row is, so
     "different by one word" cannot hide.

  3. SHORTCUT PROBE. If the model can predict the label from the punctuation of
     recording 1 alone - ignoring all the words - then it learned an artifact of
     how the data was built, not grammar. Compares the model against a rule that
     only looks at that punctuation.

  4. THE FOUNDER'S OWN CASES, which never appeared in any training data.
"""

import json
import os
import sys
import time
from collections import Counter, defaultdict

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

LABELS = ["KEEP", "MERGE_SPACE", "MERGE_COMMA"]
SEAM = "<seam>"
HERE = os.path.dirname(os.path.abspath(__file__))


def load():
    tok = AutoTokenizer.from_pretrained(os.path.join(HERE, "seam-model"))
    model = AutoModelForSequenceClassification.from_pretrained(os.path.join(HERE, "seam-model"))
    model.eval()
    return tok, model


def predict(tok, model, pairs, bs=64):
    out = []
    for i in range(0, len(pairs), bs):
        chunk = pairs[i : i + bs]
        texts = [
            f"{' '.join(a.split()[-18:])} {SEAM} {' '.join(b.split()[:14])}" for a, b in chunk
        ]
        enc = tok(texts, truncation=True, max_length=96, padding=True, return_tensors="pt")
        with torch.no_grad():
            logits = model(**enc).logits
            probs = torch.softmax(logits, -1)
        for p in probs:
            idx = int(p.argmax())
            out.append((LABELS[idx], float(p[idx])))
    return out


def main():
    tok, model = load()
    rows = [json.loads(l) for l in open(os.path.join(HERE, "seam_test.jsonl"), encoding="utf-8")]
    pairs = [(r["rec1"], r["rec2"]) for r in rows]

    t0 = time.perf_counter()
    preds = predict(tok, model, pairs)
    ms = (time.perf_counter() - t0) * 1000 / len(rows)

    # ---------- 1. per language
    per_lang = defaultdict(lambda: [0, 0])
    damaging = defaultdict(int)
    for r, (p, _) in zip(rows, preds):
        per_lang[r["language"]][1] += 1
        per_lang[r["language"]][0] += int(p == r["label"])
        if r["label"] == "KEEP" and p != "KEEP":
            damaging[r["language"]] += 1
    print("1. ACCURACY BY LANGUAGE  (English source is fully independent)")
    for lang, (c, n) in sorted(per_lang.items()):
        print(f"   {lang:9} {c}/{n} = {100*c/n:5.1f}%   wrongly merged a real boundary: {damaging[lang]}")

    # ---------- 2. near-duplicate audit
    train = [json.loads(l) for l in open(os.path.join(HERE, "seam_train.jsonl"), encoding="utf-8")]
    train_by_lang = defaultdict(list)
    for t in train:
        train_by_lang[t["language"]].append(set(t["rec1"].lower().split()))
    print("\n2. NEAREST TRAINING ROW (word overlap of recording 1)")
    for lang in sorted(per_lang):
        sims = []
        pool = train_by_lang[lang]
        for r in [x for x in rows if x["language"] == lang][:150]:
            w = set(r["rec1"].lower().split())
            if not w or not pool:
                continue
            best = max((len(w & t) / len(w | t) for t in pool), default=0.0)
            sims.append(best)
        if sims:
            sims.sort()
            near = sum(1 for s in sims if s > 0.8)
            print(f"   {lang:9} median {sims[len(sims)//2]:.2f}  p90 {sims[int(.9*len(sims))]:.2f}"
                  f"  rows >0.8 similar: {near}/{len(sims)}")

    # ---------- 3. shortcut probe
    def punct_only(rec1):
        s = rec1.rstrip()
        if s.endswith("?"):
            return "MERGE_SPACE"
        if s.endswith("."):
            return "MERGE_SPACE"
        return "MERGE_SPACE"

    naive = sum(1 for r in rows if punct_only(r["rec1"]) == r["label"])
    majority = Counter(r["label"] for r in rows).most_common(1)[0]
    model_acc = sum(1 for r, (p, _) in zip(rows, preds) if p == r["label"]) / len(rows)
    print("\n3. COULD A SHORTCUT EXPLAIN THIS?")
    print(f"   always-guess-{majority[0]:12} {100*majority[1]/len(rows):5.1f}%")
    print(f"   punctuation of rec1 only  {100*naive/len(rows):5.1f}%")
    print(f"   the trained model         {100*model_acc:5.1f}%")

    # ---------- 4. founder's own seams, never in training
    print("\n4. THE FOUNDER'S REAL SEAMS (never trained on)")
    founder = [
        ("I mean the ideal outcome.", "would be recognizing when two sentences need to be joined.", "MERGE_SPACE"),
        ("Today I am going to", "The store.", "MERGE_SPACE"),
        ("What I want you to do.", "is run multiple variations of broken sentences.", "MERGE_SPACE"),
        ("The problem is that you", "Assumed how the software works without testing.", "MERGE_SPACE"),
        ("I'm speaking in a longer sentence and I'm stopping.", "Mid thought.", "MERGE_SPACE"),
        ("Let's make sure we", "Clean up the bathroom.", "MERGE_SPACE"),
        ("Hold on a second. So we know that we keep the Bluetooth mic warm for 30 seconds and after that,", "We tear it down.", "MERGE_SPACE"),
        ("I finished the report.", "The store is closed.", "KEEP"),
        ("Thanks for sending that.", "I will review it tonight.", "KEEP"),
        ("The build is green.", "We can merge now.", "KEEP"),
        ("I sent the invoice.", "Did you get it?", "KEEP"),
    ]
    fp = predict(tok, model, [(a, b) for a, b, _ in founder])
    ok = 0
    for (a, b, want), (got, conf) in zip(founder, fp):
        hit = got == want
        ok += hit
        print(f"   [{'OK ' if hit else 'MISS'}] {conf:.2f} {got:12} want {want:12} | {a[:44]} + {b[:34]}")
    print(f"   => {ok}/{len(founder)}")
    print(f"\nlatency on this Mac: {ms:.1f}ms per decision")
    return 0


if __name__ == "__main__":
    sys.exit(main())
