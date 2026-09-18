#!/usr/bin/env python3
"""Build UNLABELLED candidate examples for the edit judge — issue #996.

Reads what the repo already has (the vocabulary packs and the raw-ASR versus
polished corpus) and writes candidate rows for human review into the
gitignored artifact tree. Nothing written here is a label: a pack alias is a
recogniser mishear the pack author recorded, a polish span is a change a
polish model made. A reviewer turns a candidate into a labelled row by
adding `pasted` where it is missing, `correction`, `safe_alias`, `stratum`
and `label_source`, and setting `review_status` to `reviewed`.

The frozen report rows are never read here, and every candidate is checked
against the frozen manifest so a candidate that duplicates a frozen row by
content hash or alias family is dropped and counted, never written.

Outputs (under --out, default main checkout `artifacts/issue-996-edit-judge/candidates/`):
  pack-candidates.jsonl       one row per (alias -> term) pair, `pasted: null`
  polish-candidates.jsonl     one row per 1..4 word replaced run
  summary.json                counts, skips, language coverage, frozen overlap

Run from the MAIN checkout (the polish corpus is gitignored and lives there):
  python3 scripts/eval/build_edit_judge_corpus.py
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import edit_judge_data as data  # noqa: E402
import edit_judge_gate as gate  # noqa: E402

ROOT = Path(__file__).parent.parent.parent.resolve()
PACKS_DIR = ROOT / "Sources/EnviousWisprPostProcessing/Resources/Packs"
POLISH_CORPUS = ROOT / "scripts/eval/corpus/speechpath_1861.jsonl"
FROZEN_MANIFEST = ROOT / "scripts/eval/corpus/edit-judge-frozen-manifest.json"
DEFAULT_OUT = ROOT / "artifacts/issue-996-edit-judge/candidates"


def drop_frozen(cands: list[dict], frozen: dict) -> tuple[list[dict], dict]:
    """Remove candidates that duplicate a frozen row by content hash (when
    the candidate has a sentence) or by alias family (always). Returns the
    survivors and the counts of what was dropped and why."""
    fh = data.frozen_hashes(frozen)
    ff = data.frozen_families(frozen)
    kept: list[dict] = []
    dropped = {"frozen_hash": 0, "frozen_family": 0}
    for c in cands:
        if data.family_key(c) in ff:
            dropped["frozen_family"] += 1
            continue
        if isinstance(c.get("pasted"), str) and data.content_hash(c) in fh:
            dropped["frozen_hash"] += 1
            continue
        kept.append(c)
    return kept, dropped


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--packs", type=Path, default=PACKS_DIR)
    p.add_argument("--polish", type=Path, default=POLISH_CORPUS)
    p.add_argument("--frozen-manifest", type=Path, default=FROZEN_MANIFEST)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = p.parse_args()

    for path in (args.packs, args.polish, args.frozen_manifest):
        if not path.exists():
            print(f"INFRA-ERROR: missing {path}", file=sys.stderr)
            return 2
    # The full frozen check (digests, hash set, families, structure), so a
    # stale or hollow manifest can never let a frozen family through.
    frozen, _, problems = gate.load_frozen(args.frozen_manifest, gate.FROZEN_PARTITIONS)
    if problems:
        print("INFRA-ERROR: frozen partitions are not intact: " + "; ".join(problems), file=sys.stderr)
        return 2

    packs = data.pack_candidates(args.packs)
    packs_kept, packs_dropped = drop_frozen(packs, frozen)
    polish_rows = data.read_jsonl(args.polish)
    polish, polish_skipped = data.mine_polish_spans(polish_rows)
    polish_kept, polish_dropped = drop_frozen(polish, frozen)

    n_packs = data.write_jsonl(args.out / "pack-candidates.jsonl", packs_kept)
    n_polish = data.write_jsonl(args.out / "polish-candidates.jsonl", polish_kept)
    summary = {
        "hash_version": data.HASH_VERSION,
        "review_status": "unreviewed: every row has label null; none is training, dev or calibration data until reviewed",
        "packs": {
            "source": str(args.packs),
            "files": sorted(p.name for p in args.packs.glob("*.json")),
            "candidates": len(packs),
            "written": n_packs,
            "dropped": packs_dropped,
            "with_sentence": 0,
            "languages": data.language_coverage(packs_kept),
        },
        "polish": {
            "source": str(args.polish),
            "source_rows": len(polish_rows),
            "candidates": len(polish),
            "written": n_polish,
            "dropped": polish_dropped,
            "skipped": polish_skipped,
            "languages": data.language_coverage(polish_kept),
        },
        "coverage_gap": (
            "packs and the polish corpus carry no language tag (und) and are English-dominant; "
            "no non-Latin script is represented; multilingual rows need reviewed templates or TTS-to-ASR round trips"
        ),
    }
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
