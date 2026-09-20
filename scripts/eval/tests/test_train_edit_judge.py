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
import probe_edit_judge_compatibility as probe  # noqa: E402
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
    good = {"toolchain": {"transformers": "4.50.0", "coremltools": "9.0", "numpy": "2.3.5"}, "candidates": [{"name": "xenc-xlmr-base", "revision": "abc", "tokenizer_files_sha256": {"tokenizer.json": "x"}, "upstream": {"loaded": True, "compared": 14, "matched": 14}, "conversion": {"ok": True}, "placement": {k: {"ok": True} for k in ("cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine", "all")}}]}
    path = tmp_path / "report.json"
    path.write_text(json.dumps(good))
    assert trainer.load_compat_receipt(path, "xenc-xlmr-base")["revision"] == "abc"
    for mutate, needle in (
        (lambda d: d["candidates"][0]["upstream"].update(matched=13), "parity"),
        (lambda d: d["candidates"][0]["conversion"].update(ok=False), "conversion"),
        (lambda d: d["candidates"][0]["placement"]["all"].update(ok=False), "placements"),
        (lambda d: d["toolchain"].update(coremltools="8.0"), "toolchain"),
        # A chunk 2b receipt never recorded NumPy; it must not clear a
        # candidate now that NumPy is pinned (rerun the probe instead).
        (lambda d: d["toolchain"].pop("numpy"), "numpy None"),
        (lambda d: d["candidates"][0].update(revision=""), "revision"),
    ):
        doc = json.loads(json.dumps(good))
        mutate(doc)
        path.write_text(json.dumps(doc))
        with pytest.raises(RuntimeError, match=needle):
            trainer.load_compat_receipt(path, "xenc-xlmr-base")
    with pytest.raises(RuntimeError, match="no entry"):
        trainer.load_compat_receipt(path, "xenc-mmbert-small")


def test_trainable_candidates_are_the_two_cleared_backbones():
    assert trainer.TRAINABLE_CANDIDATES == {"xenc-xlmr-base", "xenc-mmbert-small"}
    assert "xenc-mdeberta-v3-base" in probe.CANDIDATES and "xenc-mdeberta-v3-base" not in trainer.TRAINABLE_CANDIDATES


def test_generated_dev_rows_are_valid_labelled_and_frozen_disjoint():
    templates = json.loads((ROOT / "scripts/eval/corpus/edit-judge-dev-templates.json").read_text(encoding="utf-8"))
    packs = data.pack_candidates(ROOT / "Sources/EnviousWisprPostProcessing/Resources/Packs")
    rows, counts = builder.generate_dev_rows(templates, packs)
    assert all(counts[k] > 0 for k in ("terms_safe", "terms_unsafe", "names_unsafe", "names_safe", "rewordings", "injections", "pack_reviewed"))
    # Pack pairs enter only through an explicit review; the formatting-only pairs are omitted.
    assert counts["pack_unreviewed_omitted"] == len(templates["pack_reviews"]["omitted"]) == 21
    assert not any(r["id"].startswith("DEV-PACK") and r["original"].lower().replace("'", "") == r["replacement"].lower().replace("'", "") for r in rows)
    assert all(v["reason"].strip() for v in templates["pack_reviews"]["decisions"].values())
    assert templates["version"] == "edit-judge-dev-templates-v11"
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


def test_a_pair_listed_with_two_labels_is_refused_at_build_time():
    import build_edit_judge_corpus as b

    def row(orig, canon, safe):
        return {"original": orig, "replacement": canon, "correction": True, "safe_alias": safe}

    b.refuse_label_conflicts([row("key cloak", "Keycloak", True), row("post hog", "PostHog", True), row("pine cone", "Pinecone", False)])
    with pytest.raises(ValueError, match="key cloak"):
        b.refuse_label_conflicts([row("key cloak", "Keycloak", True), row("Key Cloak", "keycloak", False)])
    # the live training tables and the v4 calibration-only tables are conflict-free
    templates = json.loads((ROOT / "scripts/eval/corpus/edit-judge-dev-templates.json").read_text(encoding="utf-8"))
    for tables in (None, templates["calibration_only"], templates["calibration_only_final"], templates["calibration_only_v6"], templates["calibration_only_v7"], templates["calibration_only_v8"], templates["calibration_only_v9"]):
        b.generate_dev_rows(templates, [], tables=tables, id_prefix="X")


def test_casing_only_and_no_op_rows_are_refused_at_build_time():
    import build_edit_judge_corpus as b

    def row(rid, orig, canon, correction, safe):
        return {"id": rid, "original": orig, "replacement": canon, "correction": correction, "safe_alias": safe}

    b.refuse_casing_only_corrections([row("a", "garage", "Garage", False, False), row("b", "gar aahj", "Garage", True, True)])
    with pytest.raises(ValueError, match="casing-only"):
        b.refuse_casing_only_corrections([row("c", "garage", "Garage", True, False)])
    with pytest.raises(ValueError, match="casing-only"):
        b.refuse_casing_only_corrections([row("d", "FIGMA", "figma", True, True)])
    with pytest.raises(ValueError, match="equals the replacement"):
        b.refuse_casing_only_corrections([row("e", "\u0924\u0928\u0935\u0940\u0930", "\u0924\u0928\u0935\u0940\u0930", False, False)])
    templates = json.loads((ROOT / "scripts/eval/corpus/edit-judge-dev-templates.json").read_text(encoding="utf-8"))
    for name in ("calibration_only", "calibration_only_final", "calibration_only_v6", "calibration_only_v7", "calibration_only_v8", "calibration_only_v9"):
        rows, counts = b.generate_dev_rows(templates, [], tables=templates[name], id_prefix="X")
        assert counts["formatting_only"] > 0 and all(not r["correction"] for r in rows if r["id"].startswith("X-FORMAT"))


def test_kana_to_kanji_name_pairs_are_corrections_without_an_alias():
    """A reading does not identify one spelling (陽翔 and 晴翔 are both はると), so
    a kana -> kanji name edit is learned as a correction and never becomes an
    automatic alias, in the training tables and in every calibration table
    (Codex 3c r2/r3 disposition)."""
    import re

    kana = re.compile(r"^[\u3040-\u309f\u30a0-\u30ff\u30fc ]+$")
    templates = json.loads((ROOT / "scripts/eval/corpus/edit-judge-dev-templates.json").read_text(encoding="utf-8"))
    tables = [templates] + [templates[k] for k in ("calibration_only", "calibration_only_final", "calibration_only_v6", "calibration_only_v7", "calibration_only_v8", "calibration_only_v9")]
    seen_unsafe = 0
    for tab in tables:
        assert not any(kana.match(o) for o, _ in tab["names_safe"].get("ja", [])), "kana original labelled a safe alias"
        seen_unsafe += sum(1 for o, c in tab["names_unsafe"].get("ja", []) if kana.match(o) and any("\u4e00" <= ch <= "\u9fff" for ch in c))
    assert seen_unsafe >= 5 + 2 * 4  # the five training pairs plus two per calibration table
    rows, _ = builder.generate_dev_rows(templates, [])
    ja_kana = [r for r in rows if r["language"] == "ja" and r["stratum"] in ("person", "ambiguous_name") and kana.match(r["original"])]
    assert ja_kana and all(r["correction"] and not r["safe_alias"] for r in ja_kana)


def test_authored_rows_carry_provenance_and_the_sampled_review_status(tmp_path):
    good = dict(_row(1, False, False), label_source="authored by gpt-6-astra 2026-09-19 for a test")
    path = tmp_path / "authored.jsonl"
    data.write_jsonl(path, [good])
    rows, counts = builder.load_authored_rows([path])
    assert counts == {"authored.jsonl": 1}
    assert rows[0]["review_status"] == builder.AUTHORED_REVIEW_STATUS == "authored-sample-reviewed"
    assert rows[0]["authored_file"] == "authored.jsonl"
    assert builder.AUTHORED_REVIEW_STATUS in data.REVIEWED_STATUSES
    # No authoring provenance: refused, never silently promoted to reviewed.
    data.write_jsonl(path, [dict(good, label_source="selftest")])
    with pytest.raises(RuntimeError, match="provenance"):
        builder.load_authored_rows([path])


def test_partition_loader_accepts_both_reviewed_statuses_and_nothing_else(tmp_path):
    for status, ok in (("template-reviewed", True), ("authored-sample-reviewed", True), ("unreviewed", False), ("reviewed", False)):
        rows = [dict(_row(i, True, i % 2 == 0), review_status=status) for i in range(4)]
        path = tmp_path / f"{status}.jsonl"
        data.write_jsonl(path, rows)
        part = {"path": path.name, "file_sha256": data.sha256_file(path), "rows": 4, "hashes": [data.content_hash(r) for r in rows], "families": sorted({data.family_key(r) for r in rows})}
        manifest = {"hash_version": data.HASH_VERSION, "partitions": {"train": part}}
        if ok:
            assert len(trainer.load_partition(tmp_path, "train", manifest)) == 4
        else:
            with pytest.raises(RuntimeError, match="not reviewed"):
                trainer.load_partition(tmp_path, "train", manifest)


def _det_rows(n_pos, n_neg):
    rows = [dict(_row(i, True, False), stratum="person") for i in range(n_pos)]
    rows += [dict(_row(100 + i, False, False), stratum="grammar_punctuation") for i in range(n_neg)]
    return rows


def test_detection_selection_picks_the_eligible_threshold_with_the_highest_recall():
    # 100 positives scored 0.9, 300 negatives scored 0.1 except 3 at 0.7:
    # thresholds up to 0.7 propose 3 false (ub over 5%? 3/300 -> ub 0.026, fine);
    # every threshold in (0.1, 0.9] reaches recall 1.0, so the tie-break
    # (lowest ub, then HIGHEST threshold) must land on 0.9.
    rows = _det_rows(100, 300)
    probs = [[0.1, 0.9]] * 100 + [[0.9, 0.1]] * 297 + [[0.3, 0.7]] * 3
    sel = trainer.select_detection_threshold(rows, probs)
    assert sel["qualifying"] is True
    assert sel["selected"]["detection_threshold"] == 0.9
    assert sel["selected"]["correction_recall"]["value"] == 1.0
    assert sel["selected"]["false_add_rate"]["num"] == 0


def test_detection_selection_is_non_qualifying_when_false_proposals_exceed_the_bar():
    # 100 positives at 0.9, 20 negatives all at 0.9: no threshold separates
    # them; recall 1.0 is reached but false proposals are 20/20 -> diagnostic
    # branch, qualifying False.
    rows = _det_rows(100, 20)
    probs = [[0.1, 0.9]] * 120
    sel = trainer.select_detection_threshold(rows, probs)
    assert sel["qualifying"] is False
    assert sel["branch"].startswith("diagnostic: recall reached")
    assert sel["selected"]["false_add_rate"]["value"] == 1.0


def test_detection_selection_falls_back_to_macro_f1_when_recall_is_never_reached():
    rows = _det_rows(10, 10)
    probs = [[0.99, 0.01]] * 20  # below every grid threshold: nothing is ever proposed
    sel = trainer.select_detection_threshold(rows, probs)
    assert sel["qualifying"] is False
    assert sel["branch"].startswith("diagnostic: no threshold reached recall_min")
    assert sel["selected"]["detection_threshold"] == 0.95


def test_detection_selection_refuses_to_qualify_on_an_undefined_denominator():
    rows = _det_rows(5, 0)
    sel = trainer.select_detection_threshold(rows, [[0.1, 0.9]] * 5)
    assert sel["qualifying"] is False and sel["selected"] is None
    assert sel["branch"].startswith("undefined")


def test_wilson_upper_bound_is_above_the_point_and_widens_with_fewer_trials():
    assert trainer.wilson_upper_bound(0, 0) is None
    small = trainer.wilson_upper_bound(1, 20)
    large = trainer.wilson_upper_bound(10, 200)
    assert small > 0.05 and large > 0.05 and small > large
    assert trainer.wilson_upper_bound(0, 300) < 0.01


def test_family_row_weights_equalise_families_within_a_class_and_classes_overall():
    objective = trainer.Objective("detection")
    # Class 1: family "Alina" x 9 rows and family "Zed" x 1; class 0: two families x 1.
    rows = [dict(_row(i, True, False), replacement="Alina") for i in range(9)]
    rows += [dict(_row(9, True, False), replacement="Zed")]
    rows += [dict(_row(20, False, False), replacement="went"), dict(_row(21, False, False), replacement="its")]
    w, acc = trainer.family_row_weights(rows, objective)
    assert len(w) == 12 and abs(sum(w) / 12 - 1.0) < 1e-9
    # The nine Alina rows together weigh the same as the one Zed row...
    assert abs(sum(w[:9]) - w[9]) < 1e-9
    # ...and the positive class weighs the same as the negative class.
    assert abs(sum(w[:10]) - sum(w[10:])) < 1e-9
    assert acc["classes"] == {"notCorrection": {"rows": 2, "families": 2}, "correction": {"rows": 10, "families": 2}}


def test_objective_from_config_defaults_old_manifests_to_three_class():
    assert trainer.objective_from_config({}).name == "three-class"
    det = trainer.objective_from_config({"objective": "detection"})
    assert det.class_order == ("notCorrection", "correction") and det.threshold_key == "detection_threshold"
    assert det.decide([0.4, 0.6], 0.6) == (True, False)
    assert det.decide([0.4, 0.6], 0.61) == (False, False)
    with pytest.raises(ValueError):
        trainer.Objective("regression")


def test_family_weighted_loss_is_the_global_weighted_mean_not_a_batch_renormalisation():
    # Pure arithmetic (no torch in the test venv): the trainer's loss is
    # mean(loss_i * w_i) with GLOBAL weights of mean 1.0. A per-batch
    # renormalisation sum(l*w)/sum(w) differs whenever a batch's weights are
    # unequal and its losses differ, and with batch size 1 cancels the
    # weights entirely.
    objective = trainer.Objective("detection")
    rows = [dict(_row(i, True, False), replacement="Alina") for i in range(3)] + [dict(_row(9, False, False), replacement="went")]
    w, _ = trainer.family_row_weights(rows, objective)
    assert abs(w[0] * 3 - w[3]) < 1e-9          # one family of three vs one family of one
    losses = [0.1, 0.1, 0.1, 2.0]
    global_mean = sum(l * x for l, x in zip(losses, w)) / len(w)
    renormalised = sum(l * x for l, x in zip(losses, w)) / sum(w)
    assert abs(global_mean - renormalised) < 1e-9  # equal here only because sum(w) == len(w)
    batch = [3]                                   # a minibatch of one row
    assert abs((losses[3] * w[3]) / 1 - losses[3] * w[3]) < 1e-12
    assert abs((losses[3] * w[3]) / w[3] - losses[3]) < 1e-12  # renormalising erases the weight
    src = (ROOT / "scripts/eval/train_edit_judge.py").read_text()
    # The declared objective is the default; the batch form exists only behind
    # the recorded `--loss-normalisation batch` switch (controlled comparison).
    assert 'return weighted.mean() if args.loss_normalisation == "global" else weighted.sum() / w.sum()' in src
    assert 'choices=["global", "batch"], default="global"' in src


def test_dual_selection_requires_the_bar_on_both_populations():
    # Main dev: clean separation at every threshold. Cross-author: 300
    # negatives with 12 scored 0.7 -> thresholds <= 0.7 propose 12/300 (ub
    # about 0.062, over the bar); 0.75+ propose 0 (ub about 0.010, under).
    main_rows = _det_rows(100, 300)
    main_probs = [[0.1, 0.9]] * 100 + [[0.9, 0.1]] * 300
    cross_rows = _det_rows(100, 300)
    cross_probs = [[0.1, 0.9]] * 100 + [[0.9, 0.1]] * 288 + [[0.3, 0.7]] * 12
    sel = trainer.select_detection_threshold_dual(main_rows, main_probs, cross_rows, cross_probs)
    assert sel["qualifying"] is True and sel["populations"] == ["dev", "cross_dev"]
    assert sel["selected"]["detection_threshold"] == 0.9  # highest eligible: ties on recall 1.0 and ub 0 false
    assert sel["selected"]["cross"]["false_add_rate"]["num"] == 0
    # The single-population rule on main alone would also pick 0.9; the dual
    # rule must REFUSE when the cross population never clears the bar.
    bad_cross_probs = [[0.1, 0.9]] * 100 + [[0.9, 0.1]] * 270 + [[0.1, 0.9]] * 30
    sel2 = trainer.select_detection_threshold_dual(main_rows, main_probs, cross_rows, bad_cross_probs)
    assert sel2["qualifying"] is False
    assert sel2["branch"].startswith("development failure")
    assert trainer.select_detection_threshold(main_rows, main_probs)["qualifying"] is True


def test_dual_selection_maximises_the_lower_recall_then_minimises_the_higher_bound():
    # Cross recall drops from 1.0 to 0.9 above 0.6; main is perfect everywhere.
    # Eligible thresholds: all; the lower recall is 1.0 up to 0.6 and 0.9 above,
    # so the rule must stop at 0.6, not run to the highest threshold.
    main_rows = _det_rows(100, 300)
    main_probs = [[0.1, 0.9]] * 100 + [[0.9, 0.1]] * 300
    cross_rows = _det_rows(100, 300)
    cross_probs = [[0.1, 0.9]] * 90 + [[0.4, 0.6]] * 10 + [[0.9, 0.1]] * 300
    sel = trainer.select_detection_threshold_dual(main_rows, main_probs, cross_rows, cross_probs)
    assert sel["qualifying"] is True
    assert sel["selected"]["detection_threshold"] == 0.6
    assert sel["selected"]["min_recall"] == 1.0


def test_dual_selection_is_undefined_when_a_population_lacks_a_class():
    main_rows = _det_rows(100, 300)
    main_probs = [[0.1, 0.9]] * 100 + [[0.9, 0.1]] * 300
    sel = trainer.select_detection_threshold_dual(main_rows, main_probs, _det_rows(5, 0), [[0.1, 0.9]] * 5)
    assert sel["qualifying"] is False and sel["selected"] is None and sel["branch"].startswith("undefined")


def test_cross_dev_loader_requires_reviewed_rows_with_both_classes(tmp_path):
    rows = _det_rows(3, 2)
    for r in rows:
        r["review_status"] = "authored-sample-reviewed"
    path = tmp_path / "cross.jsonl"
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))
    assert len(trainer.load_cross_dev(path)) == 5
    one_class = tmp_path / "one.jsonl"
    one_class.write_text("".join(json.dumps(r) + "\n" for r in rows if r["correction"]))
    with pytest.raises(RuntimeError, match="both classes"):
        trainer.load_cross_dev(one_class)
    unreviewed = tmp_path / "unreviewed.jsonl"
    unreviewed.write_text("".join(json.dumps({k: v for k, v in r.items() if k != "review_status"}) + "\n" for r in rows))
    with pytest.raises(RuntimeError, match="not reviewed"):
        trainer.load_cross_dev(unreviewed)


def test_a_cross_dev_partition_is_declared_and_checked_for_frozen_leakage_like_the_others():
    # Codex 4a-ii round 4 F1: the population that selected the threshold is
    # exported in the training manifest, so a frozen row sharing only the
    # cross-author family is refused by the same leakage check.
    manifest, loaded, problems = gate.load_frozen()
    assert problems == []
    frozen_row = loaded["working"][0]
    same_family = dict(frozen_row, id="XA", pasted="new context " + frozen_row["original"], edited="new context " + frozen_row["replacement"])
    clean = {"train": [_row(1, True, True)], "dev": [_row(2, True, False)], "calibration": [_row(3, False, False)], "cross_dev": [_row(4, False, False)]}
    trainer.refuse_frozen_overlap(clean, manifest)
    with pytest.raises(RuntimeError, match="cross_dev shares .* alias famil"):
        trainer.refuse_frozen_overlap(dict(clean, cross_dev=clean["cross_dev"] + [same_family]), manifest)
    declared = data.TrainingManifest(
        judge="x", kind="trained", checkpoint="-", tokenizer="-", thresholds={},
        partitions={n: data.partition_manifest(rs) for n, rs in dict(clean, cross_dev=[same_family]).items()},
        provenance="test", hash_version=data.HASH_VERSION,
        execution_identity={"checkpoint_sha256": "0" * 64, "tokenizer_sha256": "0" * 64, "config_sha256": "0" * 64})
    leaks = data.leakage_problems(declared, manifest)
    assert any("partition cross_dev" in p for p in leaks)


def test_selection_rule_text_names_the_populations_that_select():
    det = trainer.Objective("detection")
    assert "BOTH the dev partition and the cross_dev partition" in trainer.selection_rule_text(det, True)
    assert trainer.selection_rule_text(det, False).startswith("single population")
    assert "safe_threshold" in trainer.selection_rule_text(trainer.Objective("three-class"), False)


def test_single_labeller_rows_only_ever_train_and_never_split_a_family():
    """Founder 2026-09-19 hybrid review: a `harvest-jev-labelled` row (one model
    labeller) may train but never lands in dev or calibration, and when its family
    is held by dev or calibration it is dropped rather than crossing partitions."""
    rows = [dict(_row(i, True, False), review_status="blind-labelled-unanimous") for i in range(60)]
    # single-labeller rows: 30 with fresh families, 30 sharing families with the rows above
    fresh = [dict(_row(100 + i, True, False), replacement=f"Fresh{i}", review_status="harvest-jev-labelled") for i in range(30)]
    shared = [dict(_row(200 + i, True, False), replacement=rows[i]["replacement"], review_status="harvest-jev-labelled") for i in range(30)]
    parts, train_only, dropped = builder.partition_rows(rows + fresh + shared, "test-seed")
    assert len(train_only) == 60
    for name in ("dev", "calibration"):
        assert all(r["review_status"] != "harvest-jev-labelled" for r in parts[name])
    held = {data.family_key(r) for n in ("dev", "calibration") for r in parts[n]}
    assert set(dropped) == {r["id"] for r in shared if data.family_key(r) in held}
    assert all(r["id"] in {x["id"] for x in parts["train"]} for r in fresh)
    assert not data.cross_partition_families(parts)
    assert "harvest-jev-labelled" in data.TRAIN_ONLY_STATUSES <= data.REVIEWED_STATUSES


def test_calibration_fresh_excludes_single_labeller_rows_and_counts_them(tmp_path, monkeypatch):
    """The calibration-fresh path never holds a `harvest-jev-labelled` row, and its
    manifest counts the exclusion (peer review of feat/996-jev-label-status)."""
    manifest, _, problems = gate.load_frozen()
    assert problems == []
    def cal_row(i: int, status: str) -> dict:
        return dict(_row(i, True, False), replacement=f"Calfresh{i}", edited=f"ctx {i} Calfresh{i}", review_status=status)
    good = [cal_row(i, "template-reviewed") for i in range(3)]
    single = cal_row(9, "harvest-jev-labelled")
    monkeypatch.setattr(builder, "generate_dev_rows", lambda templates, packs, tables=None, id_prefix="CAL": (good + [single], {}))
    templates = tmp_path / "templates.json"
    templates.write_text(json.dumps({"version": "t", "cal_tables": {}}), encoding="utf-8")
    split = tmp_path / "split-manifest.json"
    split.write_text(json.dumps({"partitions": {"train": {"families": [], "hashes": []}}}), encoding="utf-8")
    args = type("A", (), {})()
    args.templates, args.calibration_tables, args.split_manifest, args.calibration_out = templates, "cal_tables", [split], tmp_path / "cal"
    assert builder.build_calibration_fresh(args, manifest) == 0
    written = data.read_jsonl(tmp_path / "cal" / "calibration.jsonl")
    assert [r["id"] for r in written] == [r["id"] for r in good]
    assert all(r["review_status"] not in data.TRAIN_ONLY_STATUSES for r in written)
    m = json.loads((tmp_path / "cal" / "split-manifest.json").read_text(encoding="utf-8"))
    assert m["train_only_rows"] == {"statuses": sorted(data.TRAIN_ONLY_STATUSES), "excluded_from_calibration": 1}


def test_parity_receipt_binding_refuses_every_changed_or_missing_input():
    binding = {"seed": 996, "tokenizer_sha256": "abc", "contract": {"maxLength": 128}, "cross_dev_sha256": None}
    assert trainer.receipt_mismatches(binding, {"binding": dict(binding)}) == []
    assert trainer.receipt_mismatches(binding, {"binding": {**binding, "seed": 7}}) == ["seed"]
    assert trainer.receipt_mismatches(binding, {"binding": {**binding, "contract": {"maxLength": 256}}}) == ["contract"]
    missing = {k: v for k, v in binding.items() if k != "cross_dev_sha256"}
    assert trainer.receipt_mismatches(binding, {"binding": missing}) == ["cross_dev_sha256"]
    assert trainer.receipt_mismatches(binding, {}) == sorted(binding)
    assert trainer.receipt_mismatches(binding, {"binding": {**binding, "extra": 1}}) == []
