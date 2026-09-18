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

`--dev` (#996 chunk 2c) builds LABELLED development data instead, from the
tracked template tables `scripts/eval/corpus/edit-judge-dev-templates.json`
(class decided per table by the reviewer, never per row) plus the pack
aliases placed into English term templates. Rows carry the frozen-corpus
shape, `label_source` naming the table and template, and
`review_status: template-reviewed`. Families that are frozen are dropped and
counted; the result is split by alias family into train / dev / calibration
(`edit_judge_data.split_by_family`) and written with a split manifest whose
hashes the trainer binds to. The polish spans stay UNREVIEWED and are never
part of the dev data.

Run from the MAIN checkout (the polish corpus is gitignored and lives there):
  python3 scripts/eval/build_edit_judge_corpus.py
  python3 scripts/eval/build_edit_judge_corpus.py --dev --seed chunk-2c
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
DEV_TEMPLATES = ROOT / "scripts/eval/corpus/edit-judge-dev-templates.json"
DEFAULT_OUT = ROOT / "artifacts/issue-996-edit-judge/candidates"
DEFAULT_DEV_OUT = ROOT / "artifacts/issue-996-edit-judge/dev"

PACK_STRATUM = {"brands": "brand", "names": "person", "tech": "domain", "legal": "domain", "medical": "domain"}
REVIEW_STATUS = "template-reviewed"


def _row(rid: str, stratum: str, language: str, template: str, original: str, replacement: str, correction: bool, safe_alias: bool, source: str) -> dict:
    """One labelled row in the frozen-corpus shape from a template with one
    `{X}` slot. The sentence must contain the original exactly once."""
    pasted = template.replace("{X}", original)
    edited = template.replace("{X}", replacement)
    return {
        "id": rid,
        "stratum": stratum,
        "language": language,
        "pasted": pasted,
        "edited": edited,
        "original": original,
        "replacement": replacement,
        "correction": correction,
        "safe_alias": safe_alias,
        "label_source": f"{source}; drafted by Claude 2026-09-18 for #996 (class decided at table level)",
        "review_status": REVIEW_STATUS,
    }


def generate_dev_rows(templates: dict, packs: list[dict]) -> tuple[list[dict], dict]:
    """Every template x entity combination the tables allow. Deterministic:
    no sampling, so the same tables always give the same rows. Returns the
    rows and per-source counts."""
    rows: list[dict] = []
    counts: dict[str, int] = {}
    langs = templates["languages"]
    version = templates["version"]

    def add(row: dict, source_key: str) -> None:
        rows.append(row)
        counts[source_key] = counts.get(source_key, 0) + 1

    # correctionAndSafe: hand-written term mishears, two term templates per
    # (language, alias) chosen round robin, so the safe class does not swamp
    # the unsafe and notCorrection classes the judge must get right.
    for lang, t in langs.items():
        n_templates = len(t["term_templates"])
        k = 0
        for term in templates["terms_safe"]:
            for ai, alias in enumerate(term["aliases"]):
                for j in range(2):
                    ti = (k + j) % n_templates
                    template = t["term_templates"][ti]
                    add(_row(f"DEV-TERM-{lang}-{ti}-{term['canonical']}-{ai}", "domain", lang, template, alias, term["canonical"], True, True, f"{version} terms_safe x {lang} term_templates[{ti}]"), "terms_safe")
                k += 1
    # correctionButUnsafe: common-word originals for terms, real-name originals for names.
    for lang, t in langs.items():
        for ti, template in enumerate(t["term_templates"]):
            for pi, (orig, canon) in enumerate(templates["terms_unsafe"]["pairs"]):
                add(_row(f"DEV-TERMU-{lang}-{ti}-{pi}", "domain", lang, template, orig, canon, True, False, f"{version} terms_unsafe[{pi}] x {lang} term_templates[{ti}]"), "terms_unsafe")
        for ti, template in enumerate(t["name_templates"]):
            for pi, (orig, canon) in enumerate(templates["names_unsafe"].get(lang, [])):
                add(_row(f"DEV-NAMEU-{lang}-{ti}-{pi}", "ambiguous_name", lang, template, orig, canon, True, False, f"{version} names_unsafe[{lang}][{pi}] x name_templates[{ti}]"), "names_unsafe")
            for pi, (orig, canon) in enumerate(templates["names_safe"].get(lang, [])):
                add(_row(f"DEV-NAME-{lang}-{ti}-{pi}", "person", lang, template, orig, canon, True, True, f"{version} names_safe[{lang}][{pi}] x name_templates[{ti}]"), "names_safe")
        # notCorrection: rewordings/formatting and instruction-like replacements in context templates.
        for ti, template in enumerate(t["context_templates"]):
            for pi, (orig, repl) in enumerate(templates["rewordings"].get(lang, [])):
                stratum = "grammar_punctuation" if any(ch.isdigit() for ch in repl) else "rewording"
                add(_row(f"DEV-REWORD-{lang}-{ti}-{pi}", stratum, lang, template, orig, repl, False, False, f"{version} rewordings[{lang}][{pi}] x context_templates[{ti}]"), "rewordings")
            for pi, injection in enumerate(templates["injections"].get(lang, [])):
                orig = templates["rewordings"][lang][pi % len(templates["rewordings"][lang])][0]
                add(_row(f"DEV-INJECT-{lang}-{ti}-{pi}", "instruction_like", lang, template, orig, injection, False, False, f"{version} injections[{lang}][{pi}] x context_templates[{ti}]"), "injections")
    # Vocabulary-pack aliases enter ONLY through an explicit per-pair review
    # (`pack_reviews.decisions`); a pair with no review stays an unreviewed
    # candidate. English templates, one per pair (round robin) so the pack
    # does not swamp the multilingual rows; names pack -> name templates.
    en = langs["en"]
    reviews = templates.get("pack_reviews", {}).get("decisions", {})
    for i, c in enumerate(packs):
        key = json.dumps([c["pack"], c["original"], c["replacement"]], ensure_ascii=False, separators=(",", ":"))
        review = reviews.get(key)
        if review is None:
            counts["pack_unreviewed_omitted"] = counts.get("pack_unreviewed_omitted", 0) + 1
            continue
        correction, safe_alias = review["correction"], review["safe_alias"]
        data.three_class(correction, safe_alias)  # refuses (false, true)
        if not isinstance(review.get("reason"), str) or not review["reason"].strip():
            raise ValueError(f"pack review lacks a reason: {key}")
        stratum = PACK_STRATUM.get(c["pack"], "domain") if correction else "rewording"
        pool = en["name_templates"] if stratum == "person" else en["term_templates"]
        template = pool[i % len(pool)]
        add(_row(f"DEV-PACK-{c['pack']}-{i}", stratum, "en", template, c["original"], c["replacement"], correction, safe_alias, f"packs/{c['pack']}.json pair reviewed: {review['reason']}"), "pack_reviewed")
    return rows, counts


def build_dev(args, frozen: dict) -> int:
    import edit_judge_gate as gate_mod

    templates = json.loads(args.templates.read_text(encoding="utf-8"))
    packs = data.pack_candidates(args.packs)
    rows, source_counts = generate_dev_rows(templates, packs)
    # Rows the frozen-corpus validator refuses (an original that appears
    # twice in its template, an unchanged run) are dropped by name.
    kept: list[dict] = []
    dropped_invalid = 0
    for r in rows:
        if gate_mod.validate_rows([r], "dev") == []:
            kept.append(r)
        else:
            dropped_invalid += 1
    rows = kept
    rows, dropped_frozen = drop_frozen(rows, frozen)
    # Duplicate cases across sources collapse to one row.
    seen: set[str] = set()
    unique: list[dict] = []
    for r in rows:
        h = data.content_hash(r)
        if h in seen:
            continue
        seen.add(h)
        unique.append(r)
    rows = unique
    problems = gate_mod.validate_rows(rows, "dev")
    if problems:
        print("INFRA-ERROR: generated dev rows invalid: " + "; ".join(problems[:5]), file=sys.stderr)
        return 2
    gate_mod.require_clean_dev(rows, frozen)
    parts = data.split_by_family(rows, args.seed, fractions=(0.7, 0.15, 0.15))
    crossing = data.cross_partition_families(parts)
    if crossing:
        print("INFRA-ERROR: family crossed partitions: " + "; ".join(crossing[:3]), file=sys.stderr)
        return 2
    out = args.dev_out
    out.mkdir(parents=True, exist_ok=True)
    manifest = {
        "hash_version": data.HASH_VERSION,
        "templates_version": templates["version"],
        "templates_sha256": data.sha256_file(args.templates),
        "seed": args.seed,
        "review_status": REVIEW_STATUS,
        "source_counts": source_counts,
        "dropped_invalid": dropped_invalid,
        "dropped_frozen": dropped_frozen,
        "partitions": {},
    }
    for name, part_rows in parts.items():
        path = out / f"{name}.jsonl"
        data.write_jsonl(path, part_rows)
        classes = {}
        langs = {}
        for r in part_rows:
            c = data.three_class(r["correction"], r["safe_alias"])
            classes[c] = classes.get(c, 0) + 1
            langs[r["language"]] = langs.get(r["language"], 0) + 1
        manifest["partitions"][name] = {
            "path": path.name,
            "file_sha256": data.sha256_file(path),
            "rows": len(part_rows),
            "classes": dict(sorted(classes.items())),
            "languages": dict(sorted(langs.items())),
            **data.partition_manifest(part_rows),
        }
    (out / "split-manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    summary = {k: v for k, v in manifest.items() if k != "partitions"}
    summary["partitions"] = {n: {k: v for k, v in p.items() if k not in ("hashes", "families")} for n, p in manifest["partitions"].items()}
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


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
    p.add_argument("--dev", action="store_true", help="build labelled development data from the template tables")
    p.add_argument("--templates", type=Path, default=DEV_TEMPLATES)
    p.add_argument("--dev-out", type=Path, default=DEFAULT_DEV_OUT)
    p.add_argument("--seed", default="chunk-2c", help="--dev: family split seed")
    args = p.parse_args()

    required = (args.packs, args.frozen_manifest) + ((args.templates,) if args.dev else (args.polish,))
    for path in required:
        if not path.exists():
            print(f"INFRA-ERROR: missing {path}", file=sys.stderr)
            return 2
    # The full frozen check (digests, hash set, families, structure), so a
    # stale or hollow manifest can never let a frozen family through.
    frozen, _, problems = gate.load_frozen(args.frozen_manifest, gate.FROZEN_PARTITIONS)
    if problems:
        print("INFRA-ERROR: frozen partitions are not intact: " + "; ".join(problems), file=sys.stderr)
        return 2
    if args.dev:
        return build_dev(args, frozen)

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
