"""Build app-output-labelled synthetic continuation pairs.

Splits stored English dictations at eligible mid-sentence word boundaries. The
label is inferred from casing ALREADY PRESENT IN APP OUTPUT (`polishedText` when
present, else the raw transcript). It is NOT a founder correction and NOT
independent ground truth: a name our own pipeline previously lowercased is
labelled "safe to lowercase", so agreeing with that error scores as correct.

Use for coverage characterisation and for surfacing suspicious words. Never as a
precision certificate. Corrected 2026-07-26 after grounded review r2.

Local only. Transcript text and generated rows are never committed.
"""

import glob
import hashlib
import json
import os
import random
import re

STORE = os.path.expanduser("~/Library/Application Support/EnviousWispr/transcripts")
OUT = (
    "/private/tmp/claude-501/-Users-m4pro-sv-Developer-EnviousLabs-EnviousWispr/"
    "ff88b620-7ce1-43d3-99d0-8dc68323ee9e/scratchpad/pairs.tsv"
)

random.seed(1803)  # deterministic sampling

pairs = []
skipped_short = 0
# sorted(): glob order is filesystem-dependent, so without this the seed
# below does not actually make the sample reproducible (grounded review r2).
for path in sorted(glob.glob(os.path.join(STORE, "*.json"))):
    try:
        j = json.load(open(path))
    except Exception:
        continue
    if (j.get("language") or "") != "en":
        continue
    text = " ".join((j.get("polishedText") or j.get("text") or "").split())
    if len(text) < 40:
        skipped_short += 1
        continue

    # Candidate split points: the start of a word that is NOT sentence-initial,
    # i.e. the preceding non-space character is not . ! ? : ; and not an opener.
    candidates = []
    for m in re.finditer(r"(?<=[a-z,]) ([A-Za-z][A-Za-z'’]{1,})", text):
        start = m.start(1)
        word = m.group(1)
        # Skip the pronoun I and acronyms; the rule refuses those on other grounds.
        if word in ("I",) or word.isupper():
            continue
        if len(word) < 2:
            continue
        candidates.append((start, word))
    if not candidates:
        continue

    start, word = random.choice(candidates)
    left = text[:start]
    payload = text[start:]
    must_keep = word[0].isupper()
    # Simulate what the speech engine does to a fresh chunk: capitalise it.
    payload = payload[0].upper() + payload[1:]
    case_id = hashlib.sha256(
        f"{os.path.basename(path)}:{start}".encode("utf-8")
    ).hexdigest()[:16]
    pairs.append((case_id, left, payload, "keep" if must_keep else "lower"))

with open(OUT, "w") as f:
    for case_id, left, payload, label in pairs:
        f.write(f"{case_id}\t{label}\t{left}\t{payload}\n")

keep = sum(1 for p in pairs if p[2] == "keep")
print(f"real labelled continuation pairs: {len(pairs)}")
print(f"  MUST KEEP (capitalised mid-sentence): {keep}")
print(f"  SHOULD LOWER (lowercase mid-sentence): {len(pairs) - keep}")
print(f"  skipped as too short: {skipped_short}")
