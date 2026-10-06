#!/usr/bin/env python3
"""Proves the Phase 0 reviews cover the shipped vocabulary's unchanged blocks (#3482).

Ids under "added" in reviewed-edits.json are compared with their own reviewed blocks instead,
and fail if a Phase 0 review also names them.

For each language it rebuilds that language's blocks from the preserved Phase 0 review
output in scripts/settings-map/receipts/phase0/, applies the only deterministic Phase 0
transform (merge_multilingual.py drops a word that folds equal to its block's title) and
the reviewed edits, and compares the result with the shipped resource for every mapped id.
A block that differs fails; nothing is rewritten. Exit 0 only when all 32 languages match.

Usage:
  scripts/settings-map/verify-phase0.py \
      --resource Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json \
      --inventory Tests/Fixtures/settings-map/inventory.json \
      --edits scripts/settings-map/receipts/reviewed-edits.json \
      --phase0 scripts/settings-map/receipts/phase0
"""

import argparse
import json
import pathlib
import sys
import unicodedata

INTERFACE = ("en", "de")


def fold(text):
    """merge_multilingual.py's fold, copied unchanged so the transform is the one that ran."""
    text = text.replace("ß", "ss").replace("ẞ", "ss")
    text = "".join(c for c in unicodedata.normalize("NFKD", text) if unicodedata.category(c) != "Mn")
    return text.casefold()


def answer(path):
    text = path.read_text(encoding="utf-8")
    return json.loads(text[text.index("{"):text.rindex("}") + 1])


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for name in ("resource", "inventory", "edits", "phase0"):
        parser.add_argument(f"--{name}", required=True, type=pathlib.Path)
    args = parser.parse_args()

    resource = json.loads(args.resource.read_text(encoding="utf-8"))
    edit_file = json.loads(args.edits.read_text(encoding="utf-8"))
    edits = edit_file["blocks"]
    # Added ids carry their own review (reviewed-edits.json "added"); Phase 0 never covers them.
    added = edit_file.get("added", {})
    inventory = json.loads(args.inventory.read_text(encoding="utf-8"))
    mapped = {i["id"] for i in inventory["items"] if i["disposition"] == "mapped"}

    reviewed = {code: {} for code in INTERFACE}
    for part in sorted((args.phase0 / "ende").glob("review-a?.txt")):
        for entry_id, by_language in answer(part).items():
            for code in INTERFACE:
                if entry_id in reviewed[code]:
                    sys.exit(f"{part}: {entry_id} reviewed twice")
                reviewed[code][entry_id] = by_language[code]
    for path in sorted((args.phase0 / "intl").glob("review-*.txt")):
        code = path.stem.removeprefix("review-")
        reviewed[code] = {}
        for entry_id, block in answer(path).items():
            words = [w for w in block["words"] if fold(w) != fold(block["title"])]
            reviewed[code][entry_id] = {"title": block["title"], "words": words,
                                        "phrases": block["phrases"]}

    failures = 0
    for code in resource["languages"]:
        if code not in reviewed:
            print(f"{code}: FAIL no Phase 0 review output")
            failures += 1
            continue
        shipped = {e["id"]: next(b for b in e["blocks"] if b["language"] == code)
                   for e in resource["entries"]}
        overlap = set(added) & set(reviewed[code])
        missing = mapped - set(reviewed[code]) - set(added)
        edited = 0
        differing = sorted(overlap)
        for entry_id in sorted(mapped - missing):
            if entry_id in overlap:
                continue
            if entry_id in added:
                expected = dict(added[entry_id]["blocks"][code])
            else:
                expected = dict(reviewed[code][entry_id])
            replacement = edits.get(entry_id, {}).get(code, {})
            edited += bool(replacement)
            expected.update(replacement)
            got = {k: v for k, v in shipped[entry_id].items() if k != "language"}
            if code in INTERFACE:
                expected.pop("title", None)
            if got != expected:
                differing.append(entry_id)
        ok = not missing and not differing and set(shipped) == mapped
        failures += not ok
        print(f"{code}: {'OK' if ok else 'FAIL'} {len(mapped) - len(missing) - len(added)} Phase 0 blocks, "
              f"{len(added)} added with their own review, "
              f"{edited} replaced by reviewed edits, missing {sorted(missing)[:5]}, "
              f"differing {differing[:5]}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
