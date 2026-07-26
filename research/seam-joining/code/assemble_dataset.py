"""Assemble the seam training/test sets for English, German and Russian.

Founder scope decision 2026-07-25: validate on these three, expand later.

SOURCES
  English train : the founder's own polished dictations, split at natural pause
                  points and corrupted the way the transcriber really corrupts
                  them (measured: 80% full stop, 10% none, 10% question mark;
                  90% of second halves capitalised).
  German train  : ChatGPT-generated, 800 of 1000 rows.
  Russian train : ChatGPT-generated, 800 of 1000 rows.

  English test  : the founder's independent 1,000-case file (600 English rows).
                  A completely separate source from anything trained on.
  German test   : the held-out 200 rows.
  Russian test  : the held-out 200 rows.

LABELS are derived from the expected output, never hand-assigned:
  KEEP         the join keeps a sentence boundary
  MERGE_COMMA  the halves join with a comma
  MERGE_SPACE  the halves join with a plain space

Leakage is checked explicitly at the end - any first half appearing in both
train and test is a bug, not a rounding error.
"""

import argparse
import csv
import json
import os
import random
import re
import sys
from collections import Counter

HOME = os.path.expanduser("~")
DOWNLOADS = os.path.join(HOME, "Downloads")
REPO = os.path.join(HOME, "Developer/EnviousLabs/EnviousWispr")
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")

GENERATED = {
    "German": "german_voice_join_dataset_1000.csv",
    "Russian": "russian_dictation_join_dataset_1000.csv",
}
TEST_FILE = "enviouswispr_smart_casing_spacing_1000.csv"
EG1 = os.path.join(REPO, "scripts/eval/runs/bakeoff-1265/train_sft_v2.jsonl")

TERMINATORS = (".", "!", "?")
RESUME_AFTER_ANY = True  # split anywhere sensible, not only after function words


def label_for(rec1, rec2, expected):
    """Derive the seam label by comparing the expected output to the halves."""
    exp = re.sub(r"\s+", " ", expected).strip()
    left_words = len(re.sub(r"\s+", " ", rec1).strip().split())
    words = exp.split()
    if left_words == 0 or left_words >= len(words):
        return None
    boundary_token = words[left_words - 1]
    if boundary_token.endswith(TERMINATORS):
        return "KEEP"
    if boundary_token.endswith(","):
        return "MERGE_COMMA"
    return "MERGE_SPACE"


def rows_from_generated(path, language):
    out = []
    for r in csv.DictReader(open(path, encoding="utf-8-sig")):
        lab = label_for(r["recording_1"], r["recording_2"], r["expected_output"])
        if not lab:
            continue
        out.append({
            "rec1": r["recording_1"].strip(),
            "rec2": r["recording_2"].strip(),
            "expected": r["expected_output"].strip(),
            "label": lab,
            "language": language,
            "source": "generated",
        })
    return out


def split_english(rng, cuts_per_text=8):
    """Turn the founder's polished dictations into BALANCED seam pairs.

    Splitting at random positions produces almost only MERGE_SPACE, because a
    random point in a sentence is nearly always mid-clause. That imbalance would
    teach a model to always merge. So each label is manufactured deliberately:

      KEEP         split exactly at a real sentence boundary inside the text
      MERGE_COMMA  split immediately after a comma, so rejoining needs one back
      MERGE_SPACE  split mid-clause, away from any punctuation

    BROAD-SPECTRUM SPLITTING (founder directive 2026-07-25). Earlier this took
    exactly ONE cut per label per text, which used 6.9% of the 33,121 cut
    positions the corpus offers. That was wrong, and the reason is the whole
    point of the feature: you cannot predict where a person stops to think. The
    pause lands wherever their mind needed a moment, so at inference the cut is
    effectively arbitrary. Training on one "realistic" position per sentence
    fits a distribution that does not exist; the model's actual job is to judge
    two fragments however they were severed.

    So cut in many places. What must stay realistic is the FRAGMENTS and the
    damage the transcriber does to them, never the location of the break.

    `cuts_per_text` caps how many positions each source text contributes, so a
    long text cannot flood the set with near-copies of itself.
    """
    texts = []
    if os.path.exists(EG1):
        for line in open(EG1):
            o = (json.loads(line).get("output") or "").strip()
            if len(o.split()) >= 10:
                texts.append(o)
    corpus = os.path.join(REPO, "scripts/eval/corpus/corpus.jsonl")
    if os.path.exists(corpus):
        for line in open(corpus):
            t = (json.loads(line).get("asr_input") or "").strip()
            if len(t.split()) >= 10:
                texts.append(t)
    texts = list(dict.fromkeys(texts))

    def corrupt(left, right, genuine):
        roll = rng.random()
        if genuine:
            c_left = left  # already ends with its own terminator
        elif roll < 0.80:
            c_left = left.rstrip(",;:") + "."
        elif roll < 0.90:
            c_left = left
        else:
            c_left = left.rstrip(",;:") + "?"
        c_right = right
        if rng.random() < 0.90 and c_right[:1].islower():
            c_right = c_right[0].upper() + c_right[1:]
        return c_left, c_right

    buckets = {"KEEP": [], "MERGE_COMMA": [], "MERGE_SPACE": []}
    for text in texts:
        words = text.split()
        if len(words) < 8:
            continue
        boundary = [i for i in range(3, len(words) - 3) if words[i - 1].endswith(TERMINATORS)]
        comma = [i for i in range(3, len(words) - 3) if words[i - 1].endswith(",")]
        plain = [i for i in range(3, len(words) - 3)
                 if not words[i - 1][-1:] in ".,!?;:"]

        for label, spots in (("KEEP", boundary), ("MERGE_COMMA", comma), ("MERGE_SPACE", plain)):
            if not spots:
                continue
            for idx in rng.sample(spots, min(cuts_per_text, len(spots))):
                left = " ".join(words[:idx])
                right = " ".join(words[idx:])
                if label == "MERGE_COMMA":
                    left = left.rstrip(",")  # the comma is what must come back
                c_left, c_right = corrupt(left, right, label == "KEEP")
                buckets[label].append({
                    "rec1": c_left, "rec2": c_right, "expected": text,
                    "label": label, "language": "English",
                    "source": "founder_dictation",
                })

    # Rebalance toward the mix the generated sets use, so no label dominates.
    target = {"MERGE_SPACE": 0.50, "KEEP": 0.35, "MERGE_COMMA": 0.15}
    smallest = min(len(buckets[k]) / target[k] for k in target if buckets[k])
    out = []
    for label, frac in target.items():
        take = int(smallest * frac)
        rng.shuffle(buckets[label])
        out += buckets[label][:take]
    rng.shuffle(out)

    # Which label ran out first decides where more data would actually help.
    # Real sentence boundaries are the scarce resource: a text yields dozens of
    # mid-clause cuts but only as many KEEP cuts as it has sentences. Print it
    # rather than leaving a future session to rediscover the ceiling.
    binding = min(target, key=lambda k: len(buckets[k]) / target[k] if buckets[k] else 1e9)
    print(f"  english cuts harvested: "
          f"{ {k: len(v) for k, v in buckets.items()} }", file=sys.stderr)
    print(f"  binding label: {binding} — total capped at {len(out)} by its supply",
          file=sys.stderr)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cuts", type=int, default=8,
                    help="max split positions harvested per source text per label")
    ap.add_argument("--suffix", default="",
                    help="suffix for the output filenames, so two arms can coexist")
    args = ap.parse_args()

    rng = random.Random(1785)
    train, test = [], []

    # English: train from the founder's dictations, test from the independent file.
    eng = split_english(rng, cuts_per_text=args.cuts)
    rng.shuffle(eng)
    train += eng
    for r in csv.DictReader(open(os.path.join(DOWNLOADS, TEST_FILE), encoding="utf-8-sig")):
        if r["language"] != "English":
            continue
        lab = label_for(r["recording_1"], r["recording_2"], r["expected_output"])
        if lab:
            test.append({"rec1": r["recording_1"].strip(), "rec2": r["recording_2"].strip(),
                         "expected": r["expected_output"].strip(), "label": lab,
                         "language": "English", "source": "holdout_file"})

    # German and Russian: 800 train / 200 test out of each generated file.
    #
    # Each language gets its OWN generator, seeded by name. Sharing `rng` with
    # the English splitter coupled them invisibly: broad-spectrum splitting drew
    # far more random numbers, so the shared stream was in a different state by
    # the time it shuffled these rows, and the holdout silently became a
    # DIFFERENT 200 rows. That moved 231 of 879 previously-held-out rows into
    # training and made the old and new models non-comparable on these
    # languages. A holdout must not depend on how much randomness an unrelated
    # step happened to consume.
    for language, fn in GENERATED.items():
        rows = rows_from_generated(os.path.join(DOWNLOADS, fn), language)
        random.Random(f"holdout-{language}").shuffle(rows)
        test += rows[:200]
        train += rows[200:]

    # Leakage check: no first half may appear on both sides.
    train_left = {r["rec1"] for r in train}
    overlap = [r for r in test if r["rec1"] in train_left]
    if overlap:
        print(f"LEAKAGE: {len(overlap)} test rows share a first half with train", file=sys.stderr)
        test = [r for r in test if r["rec1"] not in train_left]

    for name, rows in ((f"seam_train{args.suffix}.jsonl", train),
                       (f"seam_test{args.suffix}.jsonl", test)):
        with open(os.path.join(OUT, name), "w") as fh:
            for r in rows:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")

    print(f"train {len(train)}   test {len(test)}   (leakage removed: {len(overlap)})")
    for name, rows in (("TRAIN", train), ("TEST", test)):
        print(f"\n{name}")
        print(f"  language: {dict(Counter(r['language'] for r in rows))}")
        print(f"  label   : {dict(Counter(r['label'] for r in rows))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
