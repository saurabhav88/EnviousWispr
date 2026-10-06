#!/usr/bin/env python3
"""Builds Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json (#3482).

Inputs, all named on the command line:
  --source    the Phase 0 vocabulary (multilingual-v2.json); its SHA-256 must equal
              the one pinned in --edits, so a changed source cannot slip in.
  --inventory Tests/Fixtures/settings-map/inventory.json: which ids are mapped and
              which are exempt. Every source id must be one or the other.
  --edits     scripts/settings-map/receipts/reviewed-edits.json: the reviewed stop
              lists and markers for every language, and reviewed replacements of
              single blocks' words or phrases.

It writes the resource and prints each language's content hash. It never writes a
review receipt and never decides validity: the Swift validator
(SettingsSearchVocabulary.validate) is the one schema authority, and the receipt
hashes are recorded by hand after a review, so new content cannot approve itself.

Usage:
  scripts/settings-map/build-vocabulary.py --source <multilingual-v2.json> \
      --inventory Tests/Fixtures/settings-map/inventory.json \
      --edits scripts/settings-map/receipts/reviewed-edits.json \
      --out Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json
"""

import argparse
import hashlib
import json
import sys

LANGUAGES = [
    "ar", "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hi", "hr", "hu", "it", "ja",
    "ko", "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi", "zh",
]
INTERFACE = {"en", "de"}
SEPARATOR = "\x1f"


def fail(message):
    print(f"build-vocabulary: {message}", file=sys.stderr)
    sys.exit(1)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def canonical_text(resource, code):
    """Mirrors SettingsSearchVocabulary.canonicalText(language:); the Swift tests compare
    the receipt hashes against Swift's own computation, so a drift here cannot pass."""
    data = next(d for d in resource["languageData"] if d["language"] == code)
    lines = [f"language\t{code}", "stop\t" + SEPARATOR.join(data["stop"]),
             "markers\t" + SEPARATOR.join(data["markers"])]
    for entry in sorted(resource["entries"], key=lambda e: e["id"]):
        block = next(b for b in entry["blocks"] if b["language"] == code)
        lines.append("\t".join([
            "entry", entry["id"], block.get("title", ""), SEPARATOR.join(block["words"]),
            SEPARATOR.join(block["phrases"]), block.get("phraseExemption", ""),
        ]))
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", required=True)
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--edits", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    with open(args.source, "rb") as handle:
        source_bytes = handle.read()
    with open(args.edits, encoding="utf-8") as handle:
        edits = json.load(handle)
    if sha256(source_bytes) != edits["sourceSHA256"]:
        fail(f"{args.source} has SHA-256 {sha256(source_bytes)}, edits pin {edits['sourceSHA256']}")
    source = json.loads(source_bytes)
    with open(args.inventory, encoding="utf-8") as handle:
        inventory = json.load(handle)

    mapped = sorted(i["id"] for i in inventory["items"] if i["disposition"] == "mapped")
    exempt = sorted(i["id"] for i in inventory["items"] if i["disposition"] == "exempt")
    if set(source["entries"]) != set(mapped) | set(exempt):
        fail("source ids are not exactly the inventory's mapped plus exempt ids")
    if set(edits["languageData"]) != set(LANGUAGES):
        fail("edits must give stop lists and markers for exactly the declared languages")
    for block_id in edits["blocks"]:
        if block_id not in mapped:
            fail(f"edits replace a block of {block_id}, which is not a mapped id")

    entries = []
    for entry_id in mapped:
        blocks = []
        for code in LANGUAGES:
            original = source["entries"][entry_id][code]
            replacement = edits["blocks"].get(entry_id, {}).get(code, {})
            unknown = set(replacement) - {"words", "phrases"}
            if unknown:
                fail(f"{entry_id}/{code}: edits may replace words or phrases only, not {sorted(unknown)}")
            block = {"language": code}
            if code not in INTERFACE:
                block["title"] = original["title"]
            block["words"] = replacement.get("words", original["words"])
            block["phrases"] = replacement.get("phrases", original["phrases"])
            blocks.append(block)
        entries.append({"id": entry_id, "blocks": blocks})

    resource = {
        "schema": "settings-search-vocabulary",
        "version": 1,
        "languages": LANGUAGES,
        "languageData": [
            {"language": code, "stop": edits["languageData"][code]["stop"],
             "markers": edits["languageData"][code]["markers"]}
            for code in LANGUAGES
        ],
        "entries": entries,
    }

    # One entry per line keeps review diffs readable at about the compact size.
    def dump(value):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

    text = "{\n" + ",\n".join(
        [f'"{key}":{dump(resource[key])}' for key in ("schema", "version", "languages")]
        + ['"languageData":[\n' + ",\n".join(dump(d) for d in resource["languageData"]) + "\n]"]
        + ['"entries":[\n' + ",\n".join(dump(e) for e in entries) + "\n]"]
    ) + "\n}\n"
    data = text.encode("utf-8")
    with open(args.out, "wb") as handle:
        handle.write(data)

    print(f"resource {args.out}: {len(data)} bytes, SHA-256 {sha256(data)}")
    print(f"ids: {len(mapped)} mapped written, {len(exempt)} exempt removed")
    for code in LANGUAGES:
        print(f"{code}\t{sha256(canonical_text(resource, code).encode('utf-8'))}")


if __name__ == "__main__":
    main()
