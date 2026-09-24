#!/usr/bin/env python3
"""Generate the American -> British spelling table the English (UK) dictation choice uses (#3124).

Source: VarCon 2020.12.07 (Kevin Atkinson and Benjamin Titze), the spelling-variant data behind the
Aspell and Hunspell en_GB dictionaries. The tarball is pinned by SHA-256 below; a changed download
fails loudly instead of silently changing what British users receive.

Every rule reads VarCon's own tags. None is a hand-picked word, so the table says what the
dictionary says and nothing we tuned on our own dictation:

  R1  Per line, the American form is the entry tagged exactly `A` and the British form the entry
      tagged exactly `B` (British "-ise" spelling). A line without exactly one of each poisons that
      American form: it gets no conversion.
  R2  Lines marked `(-)` (rare or archaic sense) are ignored.
  R3  Every British output an American form has, across ALL lines and clusters, is collected. More
      than one distinct output (itself included) means the spelling depends on the sense
      (program/programme, check/cheque, tire/tyre), so the form is dropped.
  R4  If the American entry also carries a British tag (`B`, `B.`, `Bv`), the American spelling is
      already accepted British and is never converted (among/amongst, learned/learnt).
  R5  Only headwords at SCOWL level 70 or below ("can be found in the dictionary"). VarCon's README
      says clusters above 80 were never checked.
  R6  Headwords that start with a capital letter are dropped: they are names, and respelling a name
      ("Acer" -> "Acre") changes a fact.

Usage:
  scripts/generate-british-spelling.py              # rewrite the committed table
  scripts/generate-british-spelling.py --self-test  # regenerate to a temp file, byte-compare
"""

import collections
import hashlib
import io
import json
import re
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

VARCON_URL = (
    "https://sourceforge.net/projects/wordlist/files/VarCon/2020.12.07/"
    "varcon-2020.12.07.tar.gz/download"
)
VARCON_SHA256 = "3b0720c5718008f37c02658a83d51d5598dd86531f0a2206d410c854006cb184"
VARCON_MEMBER = "varcon-2020.12.07/varcon.txt"
MAX_LEVEL = 70

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Sources/EnviousWisprPostProcessing/Resources/british-spelling.json"


def fetch_varcon() -> str:
    with urllib.request.urlopen(VARCON_URL, timeout=60) as response:
        blob = response.read()
    digest = hashlib.sha256(blob).hexdigest()
    if digest != VARCON_SHA256:
        sys.exit(f"VarCon download hash {digest} != pinned {VARCON_SHA256}; refusing to generate")
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as archive:
        member = archive.extractfile(VARCON_MEMBER)
        if member is None:
            sys.exit(f"{VARCON_MEMBER} missing from the pinned tarball")
        return member.read().decode("latin-1")


POISON = object()


def build_table(varcon: str) -> dict:
    outputs = collections.defaultdict(set)
    levels = {}
    level = 99
    for raw in varcon.splitlines():
        if raw.startswith("##") or not raw.strip():
            continue
        if raw.startswith("# "):
            match = re.search(r"\(level (\d+)\)", raw)
            level = int(match.group(1)) if match else 99
            continue
        body = raw.split(" #")[0]
        parts = body.split(" | ")
        if any(p.strip().startswith("(-)") for p in parts[1:]):
            continue  # R2
        american, british, american_is_british = [], [], False
        for entry in parts[0].split(" / "):
            if ": " not in entry:
                continue
            tags, word = entry.split(": ", 1)
            categories = [t for t in tags.split() if not t.isdigit()]
            if "A" in categories:
                american.append(word.strip())
                if any(t in ("B", "B.", "Bv") for t in categories):
                    american_is_british = True
            if "B" in categories:
                british.append(word.strip())
        if len(american) != 1:
            continue
        form = american[0]
        levels[form] = min(levels.get(form, 99), level)
        if american_is_british:
            outputs[form].add(form)  # R4
        elif len(british) != 1:
            outputs[form].add(POISON)  # R1
        else:
            outputs[form].add(british[0])

    table = {}
    for form, candidates in outputs.items():
        if len(candidates) != 1:
            continue  # R3
        (target,) = candidates
        if target is POISON or target == form:
            continue
        if levels.get(form, 99) > MAX_LEVEL:
            continue  # R5
        if form[0].isupper():
            continue  # R6
        table[form] = target
    return dict(sorted(table.items()))


def render(table: dict) -> str:
    return json.dumps(table, ensure_ascii=True, indent=0, sort_keys=True) + "\n"


def main() -> int:
    table = build_table(fetch_varcon())
    if not table or not all(k.isascii() and v.isascii() for k, v in table.items()):
        sys.exit("generated table is empty or contains non-ASCII entries")
    text = render(table)
    if "--self-test" in sys.argv[1:]:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            handle.write(text)
        committed = OUTPUT.read_text(encoding="utf-8")
        if committed != text:
            print(f"SELF-TEST FAIL: {OUTPUT} differs from a fresh generation ({handle.name})")
            return 1
        print(f"SELF-TEST PASS: {len(table)} entries, committed table matches the pinned source")
        return 0
    OUTPUT.write_text(text, encoding="utf-8")
    print(f"wrote {len(table)} entries to {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
