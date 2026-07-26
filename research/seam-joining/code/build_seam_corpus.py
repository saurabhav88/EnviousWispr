"""Build a broad seam-testing corpus from the founder's real dictations.

Founder's idea, 2026-07-25: take real dictations, split them at natural pause
points, and re-join them. The original dictation IS the gold answer, so ground
truth comes free and no hand-labelling is needed.

Two properties make this corpus self-balancing:

  * Split MID-CLAUSE ("...going to | the store") and the gold answer has no
    period and no capital at the seam, so the joiner MUST merge.
  * Split at a REAL sentence boundary ("...it works. | We should ship") and the
    gold answer keeps both, so the joiner MUST NOT merge. Negatives are
    generated automatically rather than invented.
  * Where the second half legitimately begins with a proper noun, gold keeps the
    capital, so "do not lowercase this" cases appear for free too.

The corruption applied at each seam mimics what the transcriber actually does.
That distribution is MEASURED from the real multi-take seams in today's app log,
not guessed - see `observed_seam_stats`.

PRIVACY: the source is the gitignored private corpus of real dictations. Output
stays in the scratchpad and must never be committed.
"""

import json
import os
import random
import re
import sys

CORPUS = (
    os.path.expanduser(
        "~/Developer/EnviousLabs/EnviousWispr/scripts/eval/corpus/corpus.jsonl")
)
LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")

# Words that, appearing at a split point, mark a natural mid-thought pause. A
# speaker resuming after a breath very often resumes right here.
RESUME_AFTER = {
    "to", "and", "but", "so", "or", "for", "with", "that", "the", "a", "an",
    "because", "if", "when", "while", "of", "in", "on", "at", "from", "about",
    "we", "you", "it", "is", "was", "then", "than", "into", "over", "after",
}

TEST_ARTIFACT = re.compile(r"quick brown fox|testing one|test one two|lazy dog", re.I)
TERMINATORS = (".", "!", "?")


def observed_seam_stats():
    """Measure, from the real log, how often the transcriber adds a terminal
    full stop to a take and capitalises the next one."""
    import datetime

    recs = []
    for ln in open(LOG, errors="replace"):
        m = re.match(r"\[(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})[^\]]*\].*\[RAW ASR\] (.*)$", ln)
        if not m:
            continue
        d, t, txt = m.groups()
        if d != "2026-07-25":
            continue
        recs.append((datetime.datetime.fromisoformat(f"{d}T{t}"), txt.strip()))
    recs.sort(key=lambda r: r[0])

    period = capital = seams = 0
    for (t1, a), (t2, b) in zip(recs, recs[1:]):
        gap = (t2 - t1).total_seconds()
        if not (0 < gap <= 8):  # a genuine mid-thought resume, not a new topic
            continue
        if TEST_ARTIFACT.search(a) or TEST_ARTIFACT.search(b):
            continue
        if not a or not b:
            continue
        seams += 1
        period += a.rstrip().endswith(TERMINATORS)
        capital += b[0].isupper()
    return {
        "seams": seams,
        "period_rate": period / seams if seams else 0,
        "capital_rate": capital / seams if seams else 0,
    }


def split_points(text):
    """Yield (index, kind) split positions in a word list."""
    words = text.split()
    for i in range(2, len(words) - 2):
        prev = words[i - 1]
        bare = prev.rstrip(".,!?;:").lower()
        if prev.rstrip().endswith(TERMINATORS):
            yield i, "sentence_boundary"  # must NOT be merged
        elif bare in RESUME_AFTER:
            yield i, "mid_clause"  # must be merged


def corrupt(left, right, add_period, capitalise):
    """Apply what the transcriber does when a recording is split in two.

    A trailing comma is LEFT ALONE rather than replaced by a full stop. That is
    what the real transcriber does - the log shows "...and after that," keeping
    its comma - and replacing it would also destroy information the joiner has no
    way to restore, making the case unwinnable by construction rather than by
    any defect in the joiner.
    """
    stripped = left.rstrip()
    if add_period and not stripped.endswith(TERMINATORS) and not stripped.endswith((",", ";", ":")):
        left = stripped + "."
    if capitalise and right and right[0].islower():
        right = right[0].upper() + right[1:]
    return left, right


def main():
    stats = observed_seam_stats()
    print(f"measured from real seams: {stats}", file=sys.stderr)

    rows = [json.loads(l) for l in open(CORPUS)]
    rng = random.Random(1785)  # fixed seed: the corpus must be reproducible

    cases = []
    for row in rows:
        text = (row.get("asr_input") or "").strip()
        if len(text.split()) < 12 or TEST_ARTIFACT.search(text):
            continue
        points = list(split_points(text))
        if not points:
            continue
        # Two split points per dictation keeps the corpus varied without
        # letting one long dictation dominate.
        for idx, kind in rng.sample(points, min(2, len(points))):
            words = text.split()
            left, right = " ".join(words[:idx]), " ".join(words[idx:])
            if not left or not right:
                continue
            # All four corruption combinations, so accuracy can be reported per
            # combination instead of hidden inside one sampled average.
            for add_period in (False, True):
                for capitalise in (False, True):
                    cl, cr = corrupt(left, right, add_period, capitalise)
                    cases.append(
                        {
                            "id": f"{row['id'][:8]}-{idx}-{int(add_period)}{int(capitalise)}",
                            "kind": kind,
                            "should_merge": kind == "mid_clause",
                            "add_period": add_period,
                            "capitalise": capitalise,
                            "left": cl,
                            "right": cr,
                            "today": f"{cl} {cr}",
                            "gold": text,
                        }
                    )

    out = "seam_corpus.jsonl"
    with open(out, "w") as fh:
        for c in cases:
            fh.write(json.dumps(c) + "\n")

    merge = sum(c["should_merge"] for c in cases)
    print(f"wrote {out}: {len(cases)} cases from {len(rows)} dictations")
    print(f"  should merge (mid-clause):     {merge}")
    print(f"  must NOT merge (real boundary): {len(cases) - merge}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
