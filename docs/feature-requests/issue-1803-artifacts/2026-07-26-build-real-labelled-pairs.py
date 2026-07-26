"""Build REAL labelled continuation pairs from the local dictation store.

The label is the founder's own mid-sentence casing, not anything I chose:
a word capitalised mid-sentence is a proper noun (MUST KEEP), a lowercase one
is ordinary (SHOULD LOWER). Splitting a real sentence reproduces exactly what
happens when a second recording continues an unfinished first one.

Local only. Emits pairs to the scratchpad; nothing here is ever committed.
"""

import glob
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
for path in glob.glob(os.path.join(STORE, "*.json")):
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
    pairs.append((left, payload, "keep" if must_keep else "lower"))

with open(OUT, "w") as f:
    for left, payload, label in pairs:
        f.write(f"{label}\t{left}\t{payload}\n")

keep = sum(1 for p in pairs if p[2] == "keep")
print(f"real labelled continuation pairs: {len(pairs)}")
print(f"  MUST KEEP (capitalised mid-sentence): {keep}")
print(f"  SHOULD LOWER (lowercase mid-sentence): {len(pairs) - keep}")
print(f"  skipped as too short: {skipped_short}")
