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
import os
import sys
import tempfile
import unicodedata

LANGUAGES = [
    "ar", "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hi", "hr", "hu", "it", "ja",
    "ko", "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi", "zh",
]
INTERFACE = {"en", "de"}


def fail(message):
    print(f"build-vocabulary: {message}", file=sys.stderr)
    sys.exit(1)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


CANONICALIZATION = "length-prefixed-v1"


def canonical_text(resource, code):
    """Mirrors SettingsSearchVocabulary.canonicalText(language:) (length-prefixed-v1); the Swift
    tests compare the receipt hashes against Swift's own computation, so a drift here cannot pass."""
    data = next(d for d in resource["languageData"] if d["language"] == code)
    fields = ["language", code]
    fields += ["stop", str(len(data["stop"]))] + data["stop"]
    fields += ["markers", str(len(data["markers"]))] + data["markers"]
    for entry in sorted(resource["entries"], key=lambda e: e["id"]):
        block = next(b for b in entry["blocks"] if b["language"] == code)
        fields += ["entry", entry["id"], "present" if "title" in block else "absent",
                   block.get("title", ""), "words", str(len(block["words"]))] + block["words"]
        fields += ["phrases", str(len(block["phrases"]))] + block["phrases"]
        fields += ["phraseExemption", "present" if "phraseExemption" in block else "absent",
                   block.get("phraseExemption", "")]
    return "".join(f"{len(field.encode('utf-8'))}:{field}" for field in fields)


class BuildError(Exception):
    pass


def build(source_bytes, inventory, edits):
    """Returns the resource. Ids are reconciled in four explicit groups: retained (mapped and
    in the Phase 0 source, optionally with reviewed word or phrase edits), added (mapped, not
    in the source, with complete reviewed blocks and the path of their review output), exempt
    and retired (in the source, no longer mapped, with a reason). A rename is a retirement plus
    an addition. New content never borrows a Phase 0 review."""
    if sha256(source_bytes) != edits["sourceSHA256"]:
        raise BuildError(f"source has SHA-256 {sha256(source_bytes)}, edits pin {edits['sourceSHA256']}")
    source = json.loads(source_bytes)
    mapped = sorted(i["id"] for i in inventory["items"] if i["disposition"] == "mapped")
    exempt = {i["id"] for i in inventory["items"] if i["disposition"] == "exempt"}
    added = edits.get("added", {})
    retired = edits.get("retired", {})
    phase0 = set(source["entries"])

    if set(edits["languageData"]) != set(LANGUAGES):
        raise BuildError("edits must give stop lists and markers for exactly the declared languages")
    for code, lists in edits["languageData"].items():
        for name in ("stop", "markers"):
            # Swift compares strings by canonical equivalence, so two spellings of one word
            # (for example a precomposed Devanagari letter and its nukta form) are a repeat there.
            seen = [unicodedata.normalize("NFC", word) for word in lists[name]]
            if len(set(seen)) != len(seen):
                raise BuildError(f"{code}.{name}: a word appears twice (canonically equal spellings)")
    for entry_id in sorted(set(added) & phase0):
        raise BuildError(f"{entry_id} is in the Phase 0 source; edit its blocks instead of adding it")
    for entry_id in sorted(set(added) - set(mapped)):
        raise BuildError(f"{entry_id} is added but is not a mapped id")
    for entry_id in sorted(set(mapped) - phase0 - set(added)):
        raise BuildError(f"{entry_id} is mapped but has no vocabulary: draft it, review it, add it")
    for entry_id, reason in retired.items():
        if not isinstance(reason, str) or not reason.strip():
            raise BuildError(f"{entry_id}: retirement needs a nonblank reason")
    for entry_id in sorted(set(retired) & set(mapped)):
        raise BuildError(f"{entry_id} is retired but still mapped")
    for entry_id in sorted(set(retired) - phase0):
        raise BuildError(f"{entry_id} is retired but is not in the Phase 0 source")
    for entry_id in sorted(phase0 - set(mapped) - exempt - set(retired)):
        raise BuildError(f"{entry_id} left the map: record it under retired with a reason")
    for entry_id in edits["blocks"]:
        if entry_id not in mapped or entry_id not in phase0:
            raise BuildError(f"edits replace a block of {entry_id}, which is not a retained mapped id")

    entries = []
    for entry_id in mapped:
        blocks = []
        for code in LANGUAGES:
            if entry_id in added:
                record = added[entry_id]
                if not record.get("review") or not record.get("reviewSHA256"):
                    raise BuildError(f"{entry_id}: an added id names its review output and its SHA-256")
                original = added[entry_id]["blocks"].get(code)
                if original is None:
                    raise BuildError(f"{entry_id}/{code}: an added id needs every declared language")
                replacement = {}
            else:
                original = source["entries"][entry_id][code]
                replacement = edits["blocks"].get(entry_id, {}).get(code, {})
            unknown = set(replacement) - {"words", "phrases"}
            if unknown:
                raise BuildError(f"{entry_id}/{code}: edits may replace words or phrases only, not {sorted(unknown)}")
            block = {"language": code}
            if code not in INTERFACE:
                block["title"] = original.get("title", "")
            block["words"] = replacement.get("words", original["words"])
            block["phrases"] = replacement.get("phrases", original["phrases"])
            if not block["phrases"] and "phraseExemption" in original:
                block["phraseExemption"] = original["phraseExemption"]
            blocks.append(block)
        entries.append({"id": entry_id, "blocks": blocks})

    return {
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


def encode(resource):
    """One entry per line keeps review diffs readable at about the compact size."""
    def dump(value):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

    text = "{\n" + ",\n".join(
        [f'"{key}":{dump(resource[key])}' for key in ("schema", "version", "languages")]
        + ['"languageData":[\n' + ",\n".join(dump(d) for d in resource["languageData"]) + "\n]"]
        + ['"entries":[\n' + ",\n".join(dump(e) for e in resource["entries"]) + "\n]"]
    ) + "\n}\n"
    return text.encode("utf-8")


def self_test():
    """Reconciliation cases on a tiny source; no repository file is read or written."""
    def block(code, word):
        return ({} if code in INTERFACE else {"title": f"t {code}"}) | {"words": [word], "phrases": ["p"]}

    def entry(word):
        return {code: block(code, word) for code in LANGUAGES}

    source = json.dumps({"entries": {"keep": entry("k"), "gone": entry("g"), "skip": entry("s")}}).encode()
    lists = {code: {"stop": ["filler"], "markers": ["not"]} for code in LANGUAGES}

    def inventory(mapped, exempt=("skip",)):
        return {"items": [{"id": i, "disposition": "mapped"} for i in mapped]
                + [{"id": i, "disposition": "exempt"} for i in exempt]}

    def edits(**extra):
        return {"sourceSHA256": sha256(source), "languageData": lists, "blocks": {}} | extra

    new = {"blocks": entry("n"), "review": "additions/new.json", "reviewSHA256": "0" * 64}
    cases = [
        ("retained and retired", inventory(["keep"]), edits(retired={"gone": "removed in #1"}), ["keep"]),
        ("added with its review", inventory(["keep", "new"]),
         edits(added={"new": new}, retired={"gone": "renamed to new"}), ["keep", "new"]),
        ("new mapped id without vocabulary", inventory(["keep", "new"]), edits(retired={"gone": "x"}),
         "has no vocabulary"),
        ("id left the map silently", inventory(["keep"]), edits(), "record it under retired"),
        ("added id already in Phase 0", inventory(["keep", "gone"]), edits(added={"gone": new}),
         "edit its blocks instead"),
        ("added id without its review", inventory(["keep", "new"]),
         edits(added={"new": {"blocks": entry("n")}}, retired={"gone": "x"}), "names its review output"),
        ("retired id still mapped", inventory(["keep", "gone"]), edits(retired={"gone": "x"}),
         "still mapped"),
        ("retired without a reason", inventory(["keep"]), edits(retired={"gone": " "}),
         "nonblank reason"),
        ("a reviewed phrase exemption is kept", inventory(["keep", "new"]),
         edits(added={"new": {"blocks": {code: block(code, "n") | {"phrases": [], "phraseExemption": "title suffices"}
                                        for code in LANGUAGES}, "review": "r", "reviewSHA256": "0" * 64}},
               retired={"gone": "x"}), "exemption kept"),
        ("canonically equal list words", inventory(["keep"]),
         edits(retired={"gone": "x"}, languageData=lists | {"hi": {"stop": ["filler"],
               "markers": ["\u095c", "\u0921\u093c"]}}), "canonically equal"),
    ]
    failures = 0
    for name, inv, ed, want in cases:
        try:
            built = build(source, inv, ed)
            got = [e["id"] for e in built["entries"]]
            if want == "exemption kept":
                kept = all(b.get("phraseExemption") == "title suffices" and b["phrases"] == []
                           for e in built["entries"] if e["id"] == "new" for b in e["blocks"])
                got = "exemption kept" if kept else "exemption dropped"
        except BuildError as error:
            got = str(error)
        ok = got == want if isinstance(want, list) else isinstance(got, str) and want in got
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {got}")
    print(f"self-test: {len(cases) - failures} passed, {failures} failed")
    sys.exit(1 if failures else 0)


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
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
    with open(args.inventory, encoding="utf-8") as handle:
        inventory = json.load(handle)
    try:
        resource = build(source_bytes, inventory, edits)
    except BuildError as error:
        fail(str(error))
    data = encode(resource)
    # Write beside the target and rename, so a reader never sees half a resource.
    directory = os.path.dirname(os.path.abspath(args.out))
    descriptor, staging = tempfile.mkstemp(prefix=".settings-search-vocabulary.", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
        os.chmod(staging, 0o644)
        os.replace(staging, args.out)
    except BaseException:
        if os.path.exists(staging):
            os.unlink(staging)
        raise

    print(f"resource {args.out}: {len(data)} bytes, SHA-256 {sha256(data)}")
    print(f"ids: {len(resource['entries'])} written, {len(edits.get('added', {}))} added, "
          f"{len(edits.get('retired', {}))} retired")
    print(f"content hashes ({CANONICALIZATION}):")
    for code in LANGUAGES:
        print(f"{code}\t{sha256(canonical_text(resource, code).encode('utf-8'))}")


if __name__ == "__main__":
    main()
