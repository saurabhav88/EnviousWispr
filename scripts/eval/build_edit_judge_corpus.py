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
import unicodedata
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
AUTHORED_REVIEW_STATUS = "authored-sample-reviewed"


def load_authored_rows(paths: list[Path]) -> tuple[list[dict], dict]:
    """Rows written by a model for #996 (gpt-6-astra on Azure, 2026-09-19),
    already screened by the caller through the gate's validator and the
    frozen family set, added as a labelled source next to the template
    tables. Each row keeps its own `label_source`; the review status is set
    here so a file that forgot it cannot pass as reviewed. A row whose
    label_source does not name the author is refused: provenance is part of
    the label."""
    rows: list[dict] = []
    counts: dict = {}
    for path in paths:
        loaded = data.read_jsonl(path)
        for r in loaded:
            src = r.get("label_source")
            if not isinstance(src, str) or "authored by" not in src:
                raise RuntimeError(f"{path}: row {r.get('id')} has no authoring provenance in label_source")
            # A row that carries its own review status keeps it (a receipt
            # may have set a stronger or weaker one); a row without one gets
            # the sampled-review status this source was actually given.
            status = r.get("review_status") if isinstance(r.get("review_status"), str) and r.get("review_status") in data.REVIEWED_STATUSES else AUTHORED_REVIEW_STATUS
            rows.append(dict(r, review_status=status, authored_file=path.name))
        counts[path.name] = len(loaded)
    return rows, counts


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


def generate_dev_rows(templates: dict, packs: list[dict], tables: dict | None = None, id_prefix: str = "DEV") -> tuple[list[dict], dict]:
    """Every template x entity combination the tables allow. Deterministic:
    no sampling, so the same tables always give the same rows. `tables`
    defaults to the templates file's own training tables; the
    calibration-only tables are passed instead for the fresh calibration
    set (then `packs` is empty). Returns the rows and per-source counts."""
    rows: list[dict] = []
    counts: dict[str, int] = {}
    langs = templates["languages"]
    version = templates["version"]
    tables = tables if tables is not None else templates

    def add(row: dict, source_key: str) -> None:
        rows.append(row)
        counts[source_key] = counts.get(source_key, 0) + 1

    # correctionAndSafe: hand-written term mishears, two term templates per
    # (language, alias) chosen round robin, so the safe class does not swamp
    # the unsafe and notCorrection classes the judge must get right.
    for lang, t in langs.items():
        n_templates = len(t["term_templates"])
        k = 0
        for term in tables["terms_safe"]:
            for ai, alias in enumerate(term["aliases"]):
                for j in range(2):
                    ti = (k + j) % n_templates
                    template = t["term_templates"][ti]
                    add(_row(f"{id_prefix}-TERM-{lang}-{ti}-{term['canonical']}-{ai}", "domain", lang, template, alias, term["canonical"], True, True, f"{version} terms_safe x {lang} term_templates[{ti}]"), "terms_safe")
                k += 1
    # correctionButUnsafe: common-word originals for terms, real-name originals for names.
    for lang, t in langs.items():
        for ti, template in enumerate(t["term_templates"]):
            for pi, (orig, canon) in enumerate(tables["terms_unsafe"]["pairs"]):
                add(_row(f"{id_prefix}-TERMU-{lang}-{ti}-{pi}", "domain", lang, template, orig, canon, True, False, f"{version} terms_unsafe[{pi}] x {lang} term_templates[{ti}]"), "terms_unsafe")
            # notCorrection: casing-only edits (`garage -> Garage`). The frozen
            # convention labels them notCorrection (EC-BRAND-006 `figma -> Figma`)
            # and the runtime alignment drops them before the judge, so they are
            # formatting negatives here, never unsafe corrections (Codex 3c).
            for pi, (orig, canon) in enumerate(tables.get("formatting_only", {}).get("pairs", [])):
                add(_row(f"{id_prefix}-FORMAT-{lang}-{ti}-{pi}", "grammar_punctuation", lang, template, orig, canon, False, False, f"{version} formatting_only[{pi}] x {lang} term_templates[{ti}]"), "formatting_only")
        for ti, template in enumerate(t["name_templates"]):
            for pi, (orig, canon) in enumerate(tables["names_unsafe"].get(lang, [])):
                add(_row(f"{id_prefix}-NAMEU-{lang}-{ti}-{pi}", "ambiguous_name", lang, template, orig, canon, True, False, f"{version} names_unsafe[{lang}][{pi}] x name_templates[{ti}]"), "names_unsafe")
            for pi, (orig, canon) in enumerate(tables["names_safe"].get(lang, [])):
                add(_row(f"{id_prefix}-NAME-{lang}-{ti}-{pi}", "person", lang, template, orig, canon, True, True, f"{version} names_safe[{lang}][{pi}] x name_templates[{ti}]"), "names_safe")
        # notCorrection: rewordings/formatting and instruction-like replacements in context templates.
        for ti, template in enumerate(t["context_templates"]):
            for pi, (orig, repl) in enumerate(tables["rewordings"].get(lang, [])):
                stratum = "grammar_punctuation" if any(ch.isdigit() for ch in repl) else "rewording"
                add(_row(f"{id_prefix}-REWORD-{lang}-{ti}-{pi}", stratum, lang, template, orig, repl, False, False, f"{version} rewordings[{lang}][{pi}] x context_templates[{ti}]"), "rewordings")
            for pi, injection in enumerate(tables["injections"].get(lang, [])):
                orig = tables["rewordings"][lang][pi % len(tables["rewordings"][lang])][0]
                add(_row(f"{id_prefix}-INJECT-{lang}-{ti}-{pi}", "instruction_like", lang, template, orig, injection, False, False, f"{version} injections[{lang}][{pi}] x context_templates[{ti}]"), "injections")
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
        add(_row(f"{id_prefix}-PACK-{c['pack']}-{i}", stratum, "en", template, c["original"], c["replacement"], correction, safe_alias, f"packs/{c['pack']}.json pair reviewed: {review['reason']}"), "pack_reviewed")
    refuse_label_conflicts(rows)
    refuse_casing_only_corrections(rows)
    return rows, counts


def refuse_casing_only_corrections(rows: list[dict]) -> None:
    """A casing-only edit is formatting, never a correction and never a safe
    alias (frozen convention; the runtime alignment drops it before the
    judge). Five such pairs sat in the v6 `terms_unsafe` table as
    corrections and inflated correction recall while hiding 365 false
    additions (Codex 3c); a table that labels one as a correction is refused."""
    noop = [r["id"] for r in rows if unicodedata.normalize("NFC", r["original"]) == unicodedata.normalize("NFC", r["replacement"])]
    if noop:
        raise ValueError(f"{len(noop)} row(s) whose original equals the replacement (two such name pairs sat in the v5 table): {noop[:5]}")
    bad = [r["id"] for r in rows if unicodedata.normalize("NFC", r["original"]).casefold() == unicodedata.normalize("NFC", r["replacement"]).casefold() and (r["correction"] or r["safe_alias"])]
    if bad:
        raise ValueError(f"{len(bad)} casing-only edit(s) labelled as corrections (must be notCorrection): {bad[:5]}")


def refuse_label_conflicts(rows: list[dict]) -> None:
    """One (original, replacement) pair carries ONE label. The tables are
    hand-written and the same pair can be listed as a safe alias and as an
    unsafe probe by mistake (`key cloak -> Keycloak` in the v5 final
    calibration table: 49 unsafe rows against 24 safe rows of the same
    pair, which made the set unmeasurable); a set with such a pair is
    refused at build time rather than discovered in the score."""
    labels: dict[tuple[str, str], set[tuple[bool, bool]]] = {}
    for r in rows:
        labels.setdefault((r["original"].casefold(), r["replacement"].casefold()), set()).add((r["correction"], r["safe_alias"]))
    conflicts = sorted(k for k, v in labels.items() if len(v) > 1)
    if conflicts:
        raise ValueError(f"{len(conflicts)} pair(s) carry more than one label: {conflicts[:5]}")


def build_calibration_fresh(args, frozen: dict) -> int:
    """A calibration set from the CALIBRATION-ONLY tables: fresh families
    that never entered training or threshold selection. Refuses any family
    shared with the given split manifest or the frozen rows."""
    import edit_judge_gate as gate_mod

    templates = json.loads(args.templates.read_text(encoding="utf-8"))
    rows, source_counts = generate_dev_rows(templates, [], tables=templates[args.calibration_tables], id_prefix="CAL")
    for r in rows:
        r["label_source"] = r["label_source"].replace("(class decided at table level)", "(calibration-only table, class decided at table level)")
    rows = [r for r in rows if gate_mod.validate_rows([r], "cal") == []]
    rows, dropped_frozen = drop_frozen(rows, frozen)
    seen: set[str] = set()
    rows = [r for r in rows if not (data.content_hash(r) in seen or seen.add(data.content_hash(r)))]
    problems = gate_mod.validate_rows(rows, "cal")
    if problems:
        print("INFRA-ERROR: generated calibration rows invalid: " + "; ".join(problems[:5]), file=sys.stderr)
        return 2
    gate_mod.require_clean_dev(rows, frozen)
    # Disjoint from EVERY manifest given: the training split and each
    # earlier calibration set (exposed policy-development material).
    used_families: set[str] = set()
    used_hashes: set[str] = set()
    for m in args.split_manifest:
        split = json.loads(m.read_text(encoding="utf-8"))
        used_families |= {f for p in split["partitions"].values() for f in p["families"]}
        used_hashes |= {h for p in split["partitions"].values() for h in p["hashes"]}
    shared_f = sorted({data.family_key(r) for r in rows} & used_families)
    shared_h = [r["id"] for r in rows if data.content_hash(r) in used_hashes]
    if shared_f or shared_h:
        print(f"INFRA-ERROR: calibration set shares {len(shared_f)} families / {len(shared_h)} rows with the given manifests: {shared_f[:5]}", file=sys.stderr)
        return 2
    out = args.calibration_out
    out.mkdir(parents=True, exist_ok=False)
    path = out / "calibration.jsonl"
    data.write_jsonl(path, rows)
    classes: dict[str, int] = {}
    langs: dict[str, int] = {}
    for r in rows:
        c = data.three_class(r["correction"], r["safe_alias"])
        classes[c] = classes.get(c, 0) + 1
        langs[r["language"]] = langs.get(r["language"], 0) + 1
    manifest = {
        "hash_version": data.HASH_VERSION,
        "templates_version": templates["version"],
        "templates_sha256": data.sha256_file(args.templates),
        "tables": args.calibration_tables,
        "disjoint_from_split_manifest_sha256": data.sha256_file(args.split_manifest[0]),
        "disjoint_from_manifests_sha256": [data.sha256_file(m) for m in args.split_manifest],
        "review_status": REVIEW_STATUS,
        "source_counts": source_counts,
        "dropped_frozen": dropped_frozen,
        "partitions": {"calibration": {"path": path.name, "file_sha256": data.sha256_file(path), "rows": len(rows), "classes": dict(sorted(classes.items())), "languages": dict(sorted(langs.items())), **data.partition_manifest(rows)}},
    }
    (out / "split-manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in manifest.items() if k != "partitions"} | {"calibration": {k: v for k, v in manifest["partitions"]["calibration"].items() if k not in ("hashes", "families")}}, indent=2, ensure_ascii=False))
    return 0


def build_dev(args, frozen: dict) -> int:
    import edit_judge_gate as gate_mod

    templates = json.loads(args.templates.read_text(encoding="utf-8"))
    packs = data.pack_candidates(args.packs)
    rows, source_counts = generate_dev_rows(templates, packs)
    if args.authored:
        authored, authored_counts = load_authored_rows(args.authored)
        rows += authored
        source_counts["authored"] = authored_counts
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
    # Every other frozen exam on disk (exam v2, #996) excludes its families
    # and hashes from training the same way; counted separately.
    for other in gate_mod.frozen_manifests_present():
        if other.get("frozen_at") == frozen.get("frozen_at"):
            continue
        rows, dropped_other = drop_frozen(rows, other)
        for k, v in dropped_other.items():
            dropped_frozen[f"{other.get('exam', 'other')}_{k}"] = dropped_frozen.get(f"{other.get('exam', 'other')}_{k}", 0) + v
    # Duplicate cases across sources collapse to one row.
    seen: set[str] = set()
    first_by_case: dict[tuple, dict] = {}
    unique: list[dict] = []
    dropped_case_dups = 0
    conflicts: list[dict] = []
    for r in rows:
        h = data.content_hash(r)
        case = (r["pasted"], r["edited"])
        if h in seen:
            dropped_case_dups += 1
            continue
        earlier = first_by_case.get(case)
        if earlier is not None:
            if earlier["correction"] == r["correction"]:
                dropped_case_dups += 1          # same case, same label: the twin goes
                continue
            # Same case, different label: neither source is trusted; both go
            # to quarantine for adjudication and neither trains.
            conflicts.append({"case": {"pasted": r["pasted"], "edited": r["edited"]}, "a": {"id": earlier["id"], "correction": earlier["correction"], "label_source": earlier["label_source"]}, "b": {"id": r["id"], "correction": r["correction"], "label_source": r["label_source"]}})
            continue
        seen.add(h)
        first_by_case[case] = r
        unique.append(r)
    conflict_ids = {c["a"]["id"] for c in conflicts}
    rows = [r for r in unique if r["id"] not in conflict_ids]
    source_counts["dropped_case_duplicates"] = dropped_case_dups
    source_counts["label_conflicts_quarantined"] = len(conflicts)
    if conflicts:
        args.dev_out.mkdir(parents=True, exist_ok=True)
        (args.dev_out / "label-conflicts.json").write_text(json.dumps(conflicts, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
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
        detection = {"correction": 0, "notCorrection": 0}
        strata: dict = {}
        for r in part_rows:
            c = data.three_class(r["correction"], r["safe_alias"])
            classes[c] = classes.get(c, 0) + 1
            langs[r["language"]] = langs.get(r["language"], 0) + 1
            detection["correction" if r["correction"] else "notCorrection"] += 1
            st = strata.setdefault(r["stratum"], {"correction": 0, "notCorrection": 0})
            st["correction" if r["correction"] else "notCorrection"] += 1
        if 0 in detection.values():
            print(f"INFRA-ERROR: partition {name} lacks one detection class: {detection}", file=sys.stderr)
            return 2
        manifest["partitions"][name] = {
            "path": path.name,
            "file_sha256": data.sha256_file(path),
            "rows": len(part_rows),
            "classes": dict(sorted(classes.items())),
            "detection": detection,
            "strata": dict(sorted(strata.items())),
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
    p.add_argument("--authored", type=Path, action="append", help="--dev: a JSONL of model-authored, gate-validated, frozen-screened rows to add as a labelled source (repeatable)")
    p.add_argument("--calibration-fresh", action="store_true", help="build the calibration-only set from the templates' calibration_only tables")
    p.add_argument("--split-manifest", type=Path, action="append", help="--calibration-fresh: the training split, then every earlier calibration manifest, the set must be disjoint from (repeatable; the first is the training split)")
    p.add_argument("--calibration-out", type=Path, help="--calibration-fresh: output directory (created, must not exist)")
    p.add_argument("--calibration-tables", default="calibration_only", choices=["calibration_only", "calibration_only_final", "calibration_only_v6", "calibration_only_v7", "calibration_only_v8", "calibration_only_v9"], help="--calibration-fresh: which calibration-only tables")
    args = p.parse_args()

    required = (args.packs, args.frozen_manifest) + ((args.templates,) if (args.dev or args.calibration_fresh) else (args.polish,))
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
    if args.calibration_fresh:
        if not args.split_manifest or not args.calibration_out:
            print("INFRA-ERROR: --calibration-fresh needs --split-manifest and --calibration-out", file=sys.stderr)
            return 2
        return build_calibration_fresh(args, frozen)
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
