"""Harness-contract tests for the edit-judge trainer and dev-data builder (#996 chunk 2c).

Pure parts only: the decision rule, the calibration scorer and threshold
selection with Wilson bounds, the identity digest, and the template-driven
dev-data generator. No model runs here.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts/eval"))

import build_edit_judge_corpus as builder  # noqa: E402
import edit_judge_data as data  # noqa: E402
import edit_judge_gate as gate  # noqa: E402
import train_edit_judge as trainer  # noqa: E402


def _row(i: int, correction: bool, safe: bool, language: str = "en") -> dict:
    return {"id": f"R{i}", "stratum": "domain", "language": language, "pasted": f"ctx {i} orig{i}", "edited": f"ctx {i} repl{i}", "original": f"orig{i}", "replacement": f"repl{i}", "correction": correction, "safe_alias": safe, "label_source": "t"}


def test_decision_rule_maps_probabilities_to_the_two_booleans():
    assert trainer.decide([0.6, 0.2, 0.2], 0.5) == (False, False)
    assert trainer.decide([0.2, 0.5, 0.3], 0.5) == (True, False)
    assert trainer.decide([0.1, 0.2, 0.7], 0.5) == (True, True)
    # Exactly at the threshold counts as safe; below the correction sum does not.
    assert trainer.decide([0.1, 0.4, 0.5], 0.5) == (True, True)
    assert trainer.decide([0.1, 0.41, 0.49], 0.5) == (True, False)
    assert trainer.decide([0.5, 0.25, 0.25], 0.5) == (False, False)
    with pytest.raises(ValueError):
        trainer.decide([0.5, 0.5], 0.5)
    with pytest.raises(ValueError):
        trainer.decide([float("nan"), 0.5, 0.5], 0.5)


def test_wilson_lower_bound_is_conservative_and_none_on_zero_trials():
    assert trainer.wilson_lower_bound(0, 0) is None
    assert abs(trainer.wilson_lower_bound(100, 100) - 0.9737) < 1e-3
    # Hand-computed: p=0.95, n=20, z=1.6449: (1.01764 - 0.10489) / 1.13528 = 0.8040.
    assert abs(trainer.wilson_lower_bound(19, 20) - 0.8040) < 1e-3
    assert trainer.wilson_lower_bound(19, 20) < 0.95
    # With zero errors the bound is n / (n + z^2): 50 flawless answers are not enough, 53 are.
    assert trainer.wilson_lower_bound(50, 50) < 0.95
    assert trainer.wilson_lower_bound(53, 53) > 0.95
    assert trainer.wilson_lower_bound(0, 10) == pytest.approx(0.0, abs=1e-12)


def test_score_decisions_reports_denominators_and_per_language():
    rows = [_row(0, True, True), _row(1, True, False, "de"), _row(2, False, False), _row(3, True, True, "de")]
    probs = [[0.1, 0.1, 0.8], [0.1, 0.8, 0.1], [0.9, 0.05, 0.05], [0.1, 0.1, 0.8]]
    s = trainer.score_decisions(rows, probs, 0.5)
    assert s["correction_recall"] == {"value": 1.0, "num": 3, "den": 3}
    assert s["false_add_rate"] == {"value": 0.0, "num": 0, "den": 1}
    assert s["alias_precision"]["num"] == 2 and s["alias_precision"]["den"] == 2 and s["alias_precision"]["value"] == 1.0
    assert s["alias_recall"] == {"value": 1.0, "num": 2, "den": 2}
    assert set(s["per_language"]) == {"en", "de"}
    assert s["per_language"]["de"]["positives"] == 2
    with pytest.raises(ValueError):
        trainer.score_decisions(rows, probs[:3], 0.5)


def test_threshold_selection_needs_the_wilson_bound_not_the_point_estimate():
    # 19 of 20 predicted-safe correct is a 0.95 point estimate but a 0.78 lower bound: no threshold qualifies.
    rows = [_row(i, True, i != 0) for i in range(20)]
    probs = [[0.0, 0.1, 0.9]] * 20
    sel = trainer.select_safe_threshold(rows, probs)
    assert sel["qualifying"] is False and sel["selected"] is None
    # 60 safe rows all predicted safe with high confidence, one unsafe row predicted with p2=0.6:
    # thresholds above 0.6 exclude it and qualify; the smallest qualifying threshold with the best recall wins.
    rows = [_row(i, True, True) for i in range(60)] + [_row(99, True, False)]
    probs = [[0.0, 0.05, 0.95]] * 60 + [[0.0, 0.4, 0.6]]
    sel = trainer.select_safe_threshold(rows, probs)
    assert sel["qualifying"] is True
    assert sel["selected"]["safe_threshold"] == 0.61
    assert sel["selected"]["wilson_lb_95"] > 0.95
    # Zero predicted-safe rows at every threshold: never qualifies.
    sel = trainer.select_safe_threshold(rows, [[0.9, 0.05, 0.05]] * 61)
    assert sel["qualifying"] is False


def test_config_digest_changes_with_any_bound_component():
    base = {"class_order": list(trainer.CLASS_ORDER), "safe_threshold": 0.7, "precision_variant": "fp32", "package_sha256": None}
    d = trainer.config_digest(base)
    assert len(d) == 64
    assert trainer.config_digest(dict(base, safe_threshold=0.71)) != d
    assert trainer.config_digest(dict(base, precision_variant="int8")) != d
    assert trainer.config_digest(dict(base, package_sha256="a" * 64)) != d
    assert trainer.config_digest(dict(base, class_order=list(reversed(trainer.CLASS_ORDER)))) != d
    assert trainer.config_digest(dict(base)) == d


def test_refuse_frozen_overlap_derives_from_consumed_rows():
    manifest, loaded, problems = gate.load_frozen()
    assert problems == []
    frozen_row = loaded["working"][0]
    clean = {"train": [_row(1, True, True)], "dev": [_row(2, True, False)], "calibration": [_row(3, False, False)]}
    trainer.refuse_frozen_overlap(clean, manifest)
    # A renamed, relabelled frozen row in train is caught by content hash.
    leaked = dict(clean, train=clean["train"] + [dict(frozen_row, id="RENAMED", correction=False, safe_alias=False)])
    with pytest.raises(RuntimeError, match="frozen leakage"):
        trainer.refuse_frozen_overlap(leaked, manifest)
    # A same-family row with new context in dev is caught by family.
    same_family = dict(frozen_row, id="SF", pasted="brand new context " + frozen_row["original"], edited="brand new context " + frozen_row["replacement"])
    with pytest.raises(RuntimeError, match="alias famil"):
        trainer.refuse_frozen_overlap(dict(clean, dev=clean["dev"] + [same_family]), manifest)
    # Cross-partition sharing is derived from the rows, not declared.
    crossed = dict(clean, calibration=clean["calibration"] + [dict(_row(1, True, True), id="COPY")])
    with pytest.raises(RuntimeError, match="shares"):
        trainer.refuse_frozen_overlap(crossed, manifest)


def test_load_partition_verifies_families_rows_and_hash_version(tmp_path):
    rows = [dict(_row(i, True, i % 2 == 0), review_status="template-reviewed") for i in range(4)]
    path = tmp_path / "train.jsonl"
    data.write_jsonl(path, rows)
    part = {"path": "train.jsonl", "file_sha256": data.sha256_file(path), "rows": 4, **data.partition_manifest(rows)}
    manifest = {"hash_version": data.HASH_VERSION, "partitions": {"train": part}}
    assert len(trainer.load_partition(tmp_path, "train", manifest)) == 4
    erased = json.loads(json.dumps(manifest))
    erased["partitions"]["train"]["families"] = []
    with pytest.raises(RuntimeError, match="families differ"):
        trainer.load_partition(tmp_path, "train", erased)
    stale = json.loads(json.dumps(manifest))
    stale["partitions"]["train"]["families"] = sorted(part["families"])[:-1] + ["someone-else"]
    with pytest.raises(RuntimeError, match="families differ"):
        trainer.load_partition(tmp_path, "train", stale)
    wrong_count = json.loads(json.dumps(manifest))
    wrong_count["partitions"]["train"]["rows"] = 3
    with pytest.raises(RuntimeError, match="row count"):
        trainer.load_partition(tmp_path, "train", wrong_count)
    with pytest.raises(RuntimeError, match="hash version"):
        trainer.load_partition(tmp_path, "train", dict(manifest, hash_version="v0"))
    unreviewed = [dict(r, review_status="unreviewed") for r in rows]
    data.write_jsonl(path, unreviewed)
    fresh = {"hash_version": data.HASH_VERSION, "partitions": {"train": dict(part, file_sha256=data.sha256_file(path))}}
    with pytest.raises(RuntimeError, match="not reviewed"):
        trainer.load_partition(tmp_path, "train", fresh)


def test_compat_receipt_must_clear_the_candidate(tmp_path):
    good = {"toolchain": {"transformers": "4.50.0", "coremltools": "9.0"}, "candidates": [{"name": "xenc-xlmr-base", "revision": "abc", "tokenizer_files_sha256": {"tokenizer.json": "x"}, "upstream": {"loaded": True, "compared": 14, "matched": 14}, "conversion": {"ok": True}, "placement": {k: {"ok": True} for k in ("cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine", "all")}}]}
    path = tmp_path / "report.json"
    path.write_text(json.dumps(good))
    assert trainer.load_compat_receipt(path, "xenc-xlmr-base")["revision"] == "abc"
    for mutate, needle in (
        (lambda d: d["candidates"][0]["upstream"].update(matched=13), "parity"),
        (lambda d: d["candidates"][0]["conversion"].update(ok=False), "conversion"),
        (lambda d: d["candidates"][0]["placement"]["all"].update(ok=False), "placements"),
        (lambda d: d["toolchain"].update(coremltools="8.0"), "toolchain"),
        (lambda d: d["candidates"][0].update(revision=""), "revision"),
    ):
        doc = json.loads(json.dumps(good))
        mutate(doc)
        path.write_text(json.dumps(doc))
        with pytest.raises(RuntimeError, match=needle):
            trainer.load_compat_receipt(path, "xenc-xlmr-base")
    with pytest.raises(RuntimeError, match="no entry"):
        trainer.load_compat_receipt(path, "xenc-mmbert-small")


def test_generated_dev_rows_are_valid_labelled_and_frozen_disjoint():
    templates = json.loads((ROOT / "scripts/eval/corpus/edit-judge-dev-templates.json").read_text(encoding="utf-8"))
    packs = data.pack_candidates(ROOT / "Sources/EnviousWisprPostProcessing/Resources/Packs")
    rows, counts = builder.generate_dev_rows(templates, packs)
    assert all(counts[k] > 0 for k in ("terms_safe", "terms_unsafe", "names_unsafe", "names_safe", "rewordings", "injections", "pack_reviewed"))
    # Pack pairs enter only through an explicit review; the formatting-only pairs are omitted.
    assert counts["pack_unreviewed_omitted"] == len(templates["pack_reviews"]["omitted"]) == 21
    assert not any(r["id"].startswith("DEV-PACK") and r["original"].lower().replace("'", "") == r["replacement"].lower().replace("'", "") for r in rows)
    assert all(v["reason"].strip() for v in templates["pack_reviews"]["decisions"].values())
    assert templates["version"] == "edit-judge-dev-templates-v3"
    classes = {data.three_class(r["correction"], r["safe_alias"]) for r in rows}
    assert classes == set(data.THREE_CLASSES)
    assert {r["language"] for r in rows} >= {"en", "de", "es", "fr", "it", "pt", "hi", "ar", "zh", "ja", "ru", "ko"}
    assert all(r["review_status"] == builder.REVIEW_STATUS for r in rows)
    assert all("drafted by Claude" in r["label_source"] for r in rows)
    # Every generated row that survives the validator is a valid frozen-shape row.
    valid = [r for r in rows if gate.validate_rows([r], "x") == []]
    assert len(valid) > 3000
    manifest, _, _ = gate.load_frozen()
    survivors, dropped = builder.drop_frozen(valid, manifest)
    assert dropped["frozen_hash"] == 0
    assert {data.family_key(r) for r in survivors}.isdisjoint(data.frozen_families(manifest))
    # Instruction-like rows never carry the safe class; unsafe tables never carry it either.
    assert all(not r["safe_alias"] for r in rows if r["stratum"] in ("instruction_like", "ambiguous_name"))
    assert all(r["correction"] and not r["safe_alias"] for r in rows if r["id"].startswith("DEV-TERMU"))
