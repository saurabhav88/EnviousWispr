#!/usr/bin/env python3
"""Find Ollama library models that could be added to the feed (#2778). Deterministic.

  scan.py [--feed website/public/ollama-library.json] [--out candidates.json] [--limit 25]

Reads https://ollama.com/library, drops everything we already have a position on (shipped,
measured, first party, already in the feed), drops embedding-only and cloud-only models, and
for each remaining model resolves a real download size from the registry manifest. Prints a
JSON document: `{"cardCount": N, "candidates": [...]}`. Each candidate is a ready feed row
(`name`, `sizeBytes`) plus the facts a person or the routine needs to judge it
(`description`, `capabilities`, `pulls`), and `parameterCount` suggested from the size tag
(null when the library gives none: the picker must then supply it).

Fails closed. Exit 1 with a message when the page parses to fewer than 100 cards (the layout
changed) or the Swift sources cannot be read. A single model whose manifest cannot be read is
reported in `skipped`, never silently dropped, and never guessed.

The page is untrusted input: this script reads names, tags and numbers out of it and passes
nothing through as an instruction. Descriptions are carried as inert strings for a reader.
"""

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import library  # noqa: E402

SIZE_TAG_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,30}$")


def parameter_count(size_tag: str):
    """'7b' -> '7B', 'e4b' -> 'E4B', '270m' -> '270M'. None when it is not a size."""
    upper = size_tag.upper()
    if re.fullmatch(r"E?\d+(\.\d+)?[BM]", upper):
        return upper
    return None


def candidate_rows(card: dict) -> list:
    """One candidate per size tag (or one for the default tag when the card lists none)."""
    repo = card["name"]
    if not library.NAME_RE.fullmatch(repo) or ":" in repo:
        return []
    sizes = [s for s in card["sizes"] if SIZE_TAG_RE.fullmatch(s)]
    if not sizes:
        return [{"name": repo, "parameterCount": None}]
    return [{"name": f"{repo}:{s}", "parameterCount": parameter_count(s)} for s in sizes]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("--feed", default=str(library.REPO_ROOT / library.FEED_PATH))
    parser.add_argument("--out", help="write the JSON here instead of stdout")
    parser.add_argument("--limit", type=int, default=25, help="most library cards to resolve")
    args = parser.parse_args()

    try:
        known = library.known_names()
        feed = json.loads(Path(args.feed).read_text(encoding="utf-8"))
        feed_names = {library.canonical(row["name"]) for row in feed["models"]}
        feed_repos = {row["name"].split(":", 1)[0] for row in feed["models"]}
        cards = library.fetch_library_cards()
    except Exception as error:
        library.die(str(error))

    known_repos = {name.split(":", 1)[0] for name in known}
    candidates, skipped = [], []
    considered = 0
    for card in cards:
        repo = card["name"]
        if repo in known_repos or repo in feed_repos:
            continue
        if "embedding" in card["capabilities"]:
            continue
        if not card["sizes"] and card["cloud"]:
            continue  # hosted-only: nothing to download
        considered += 1
        if considered > args.limit:
            break
        for row in candidate_rows(card):
            name = row["name"]
            if library.canonical(name) in known or library.canonical(name) in feed_names:
                continue
            try:
                size = library.manifest_layer_bytes(name)
            except Exception as error:
                skipped.append({"name": name, "why": str(error)})
                continue
            if not (library.MIN_SIZE_BYTES <= size <= library.ROUTINE_MAX_SIZE_BYTES):
                skipped.append({"name": name, "why": f"size {size} outside the allowed range"})
                continue
            candidates.append(
                {
                    "name": name,
                    "parameterCount": row["parameterCount"],
                    "sizeBytes": size,
                    "capabilities": card["capabilities"],
                    "description": card["description"][:300],
                }
            )

    document = {"cardCount": len(cards), "candidates": candidates, "skipped": skipped}
    text = json.dumps(document, indent=2, ensure_ascii=False) + "\n"
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
        print(f"wrote {args.out}: {len(candidates)} candidates, {len(skipped)} skipped, {len(cards)} cards")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
