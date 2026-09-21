"""Harness-contract tests for scripts/eval/edit_judge_gate.py (#996 Chunk 1).

When these fail the eval INSTRUMENT is wrong; they say nothing about any judge.
The gate's own `--mode selftest` is the two-way control (passing and failing
scorecards, refusals); this file pins the pieces the selftest reaches through
and the shipped corpus files themselves.
"""
from __future__ import annotations

import json
import pytest
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts/eval"))

import edit_judge_gate as gate  # noqa: E402


def _rows():
    return gate._synthetic_rows(4, 4)


def _verdict(rid, vc, sa, latency=10.0):
    return gate._record(rid, vc, sa, latency=latency)


def test_selftest_passes_and_reports_a_nonzero_check_count(capsys):
    assert gate.mode_selftest() == 0
    out = capsys.readouterr().out
    assert out.startswith("SELFTEST PASS:")
    assert int(out.split(":")[1].split()[0]) > 20


def test_bypass_on_a_positive_counts_against_recall_not_out_of_the_population():
    rows = _rows()
    records = [gate._record(r["id"], None, None, outcome="unavailable") if r["id"] == "P0"
               else _verdict(r["id"], r["correction"], r["safe_alias"]) for r in rows]
    card = gate.score(rows, records)
    assert card.judge == "selftest"
    assert card.positives == 4 and card.true_positives == 3
    assert card.correction_recall == 0.75
    assert card.bypass_counts == {"unavailable": 1}
    assert card.attempted == 8 and card.completed == 7
    # The bypass's latency is in the population too.
    assert len(card.latencies_ms) == 8


def test_scorecard_name_must_match_the_records():
    rows = _rows()
    records = [_verdict(r["id"], r["correction"], r["safe_alias"]) for r in rows]
    card = gate.score(rows, records, "afm-macos27")
    assert any("judge mismatch" in p for p in card.problems)
    assert card.verdict()[0] is False


def test_alias_precision_only_counts_rows_the_judge_would_learn():
    rows = _rows()
    # P0: correction accepted, alias safe, label safe (correct).
    # P1: correction accepted, alias safe, label unsafe (wrong).
    # P2: correction rejected but alias flagged safe -> not learned, not counted.
    records = []
    for r in rows:
        if r["id"] == "P0":
            records.append(_verdict(r["id"], True, True))
        elif r["id"] == "P1":
            records.append(_verdict(r["id"], True, True))
        elif r["id"] == "P2":
            records.append(_verdict(r["id"], False, True))
        else:
            records.append(_verdict(r["id"], r["correction"], False))
    card = gate.score(rows, records)
    assert card.predicted_safe_aliases == 2
    assert card.correct_safe_aliases == 1
    assert card.alias_precision == 0.5


def test_undefined_required_metric_fails_but_undefined_advisory_does_not():
    rows = _rows()
    # Every correction accepted, nothing marked as a safe alias: alias
    # precision is undefined and that is advisory only (plan §3a, pivot).
    records = [_verdict(r["id"], r["correction"], False, latency=5.0) for r in rows]
    card = gate.score(rows, records)
    ok, reasons = card.verdict()
    assert ok, reasons
    assert card.to_dict()["advisory"]["alias_precision"]["value"] is None
    assert card.to_dict()["advisory"]["alias_recall"] == {"value": 0.0, "num": 0, "den": 2}
    # No negative rows at all: the false-proposal rate is undefined and FAILS.
    positives = [r for r in rows if r["correction"]]
    card = gate.score(positives, [_verdict(r["id"], True, False, latency=5.0) for r in positives])
    ok, reasons = card.verdict()
    assert not ok
    assert "false_add_rate undefined (zero denominator)" in reasons


def test_alias_precision_cannot_fail_an_otherwise_qualifying_arm():
    rows = _rows()
    # Every correction accepted and every alias marked safe, labels split.
    records = [_verdict(r["id"], r["correction"], r["correction"], latency=5.0) for r in rows]
    card = gate.score(rows, records)
    ok, reasons = card.verdict()
    assert ok, reasons
    assert card.alias_precision == 0.5
    assert not any("alias" in x for x in reasons)


def test_thresholds_are_the_plan_values():
    assert gate.THRESHOLDS == {
        "correction_recall_min": 0.85,
        "false_add_rate_max": 0.02,
        "latency_p50_ms_max": 2000.0,
        "latency_p95_ms_max": 5000.0,
    }
    assert gate.KIND_GUARDRAILS == {"kind_recall_min": 0.80, "kind_false_add_rate_max": 0.05}
    assert gate.ADVISORY == {"alias_precision_reference": 0.95}
    assert len(gate.STRATA) == 9


def test_shipped_corpus_files_validate_and_meet_the_floor():
    working = gate.load_jsonl(gate.WORKING_CORPUS)
    holdout = gate.load_jsonl(gate.HOLDOUT_CORPUS)
    assert gate.validate_corpus(working, holdout) == []
    assert len(working) >= gate.MIN_WORKING_ROWS
    assert len(holdout) >= gate.MIN_HOLDOUT_ROWS
    # Provenance is recorded on every row: who drafted the label. Review status
    # is a fact about the corpus that changes when review completes, so the
    # test pins the drafter only, never the pending state.
    for r in working + holdout:
        assert "drafted by Claude" in r["label_source"]


def test_scorecard_dict_carries_numerators_and_denominators():
    rows = _rows()
    records = [_verdict(r["id"], r["correction"], r["safe_alias"], latency=5.0) for r in rows]
    d = gate.score(rows, records).to_dict()
    assert d["correction_recall"] == {"value": 1.0, "num": 4, "den": 4}
    assert d["false_add_rate"] == {"value": 0.0, "num": 0, "den": 4}
    assert d["latency_ms"]["n"] == 8
    assert set(d["per_stratum"]) <= set(gate.STRATA)
    assert d["pass"] is True, d["reasons"]
    assert d["advisory"]["alias_precision"] == {"value": 1.0, "num": 2, "den": 2}


def test_bypassed_safe_alias_row_stays_in_the_advisory_recall_denominator():
    # 4 positives: P0 and P2 are labelled safe aliases. P0 is answered
    # correctly (alias found); P2 hits the deadline. Recall must be 1/2, not
    # 1/1: the population is the labelled rows, not the answered rows.
    rows = _rows()
    records = []
    for r in rows:
        if r["id"] == "P2":
            records.append(gate._record(r["id"], None, None, outcome="deadline", latency=5.0))
        else:
            records.append(_verdict(r["id"], r["correction"], r["safe_alias"], latency=5.0))
    card = gate.score(rows, records)
    assert card.bypass_counts == {"deadline": 1}
    assert card.to_dict()["advisory"]["alias_recall"] == {"value": 0.5, "num": 1, "den": 2}
    # The bypass reaches the detection verdict only through correction recall
    # (3/4 answered positives), never through the advisory block.
    assert card.correction_recall == 0.75


def _kind_rows(kind, correction, n, stratum="person"):
    rows = []
    for i in range(n):
        rows.append({"id": f"{kind}-{i}", "stratum": stratum, "language": "en", "pasted": f"call {kind} alpha {i} now", "edited": f"call {kind} beta{kind}{i} now",
                     "original": f"alpha {i}", "replacement": f"beta{kind}{i}", "correction": correction, "safe_alias": False, "label_source": "test", "kind": kind, "frame": f"{kind} frame {i}"})
    return rows


def test_per_kind_guardrails_fail_a_pooled_pass():
    # 200 easy positives carry the pooled numbers; one small negative kind
    # gets 3 of 20 wrong (0.15 > 0.05): the pooled false rate is 3/220 but the
    # kind guardrail fails the verdict and names the kind.
    rows = _kind_rows("easy_pos", True, 200) + _kind_rows("easy_neg", False, 300, "rewording") + _kind_rows("hard_neg", False, 20, "rewording")
    records = [_verdict(r["id"], True, False, latency=5.0) if r["correction"] or r["id"] in {"hard_neg-0", "hard_neg-1", "hard_neg-2"} else _verdict(r["id"], False, False, latency=5.0) for r in rows]
    card = gate.score(rows, records, exam="v2")
    ok, reasons = card.verdict()
    # Pooled passes (3/320 = 0.009 <= 0.02, recall 1.0): ONLY the kind guardrail fails.
    assert card.false_add_rate == 3 / 320 and card.correction_recall == 1.0
    assert not ok and reasons == ["kind hard_neg false_add_rate 0.1500 <= 0.05 failed"]
    d = card.to_dict()
    assert d["exam"] == "v2" and d["per_kind"]["hard_neg"] == {"rows": 20, "positives": 0, "true_positives": 0, "negatives": 20, "false_positives": 3, "bypass": 0}
    assert d["kind_guardrails"] == gate.KIND_GUARDRAILS
    # Recall guardrail on a positive kind.
    rows2 = _kind_rows("easy_neg", False, 200, "rewording") + _kind_rows("easy_pos2", True, 200) + _kind_rows("hard_pos", True, 20)
    records2 = [_verdict(r["id"], r["correction"] and r["id"] not in {"hard_pos-0", "hard_pos-1", "hard_pos-2", "hard_pos-3", "hard_pos-4"}, False, latency=5.0) for r in rows2]
    card2 = gate.score(rows2, records2, exam="v2")
    ok2, reasons2 = card2.verdict()
    # Pooled recall 215/220 = 0.977 passes; only the kind floor fails.
    assert card2.correction_recall == 215 / 220
    assert not ok2 and reasons2 == ["kind hard_pos recall 0.7500 >= 0.8 failed"]
    # Rows without a kind (legacy) produce no per-kind block and no guardrail.
    legacy = gate.score(_rows(), [_verdict(r["id"], r["correction"], r["safe_alias"], latency=5.0) for r in _rows()])
    assert legacy.to_dict()["per_kind"] == {} and legacy.to_dict()["kind_guardrails"] is None and legacy.to_dict()["exam"] == "legacy"


def test_exam_v2_validator_refuses_unknown_kind_label_mismatch_and_short_kinds(tmp_path, monkeypatch):
    taxonomy = {"kinds": [{"kind": "k_pos", "correction": True, "stratum": "person"}, {"kind": "k_neg", "correction": False, "stratum": "rewording"}], "max_rows_per_frame_per_kind": 2, "max_rows_per_frame_overall": 10}
    tpath = tmp_path / "taxonomy.json"
    tpath.write_text(json.dumps(taxonomy))
    monkeypatch.setattr(gate, "EXAM_V2_TAXONOMY", tpath)
    good = _kind_rows("k_pos", True, gate.MIN_ROWS_PER_KIND) + _kind_rows("k_neg", False, gate.MIN_ROWS_PER_KIND, "rewording")
    assert gate.validate_exam_v2(good) == []
    bad_kind = [dict(good[0], kind="k_other", id="x1")] + good[1:]
    assert any("not in the taxonomy" in p for p in gate.validate_exam_v2(bad_kind))
    bad_label = [dict(good[0], correction=False, id="x2")] + good[1:]
    assert any("disagrees with kind" in p for p in gate.validate_exam_v2(bad_label))
    short = good[:gate.MIN_ROWS_PER_KIND] + _kind_rows("k_neg", False, gate.MIN_ROWS_PER_KIND - 1, "rewording")
    assert any(f"needs >= {gate.MIN_ROWS_PER_KIND}" in p for p in gate.validate_exam_v2(short))
    # A taxonomy kind with no rows at all is allowed (recorded as absent at freeze), not a refusal.
    assert gate.validate_exam_v2(good[:gate.MIN_ROWS_PER_KIND] + good[gate.MIN_ROWS_PER_KIND:]) == []
    alias = [dict(good[0], safe_alias=True, id="x3")] + good[1:]
    assert any("safe_alias must be false" in p for p in gate.validate_exam_v2(alias))
    # Diversity: a reused replacement, a reused sentence, a frame over its cap.
    dup_rep = good + [dict(good[0], id="x4", pasted="another sentence alpha 0 here", edited=f"another sentence {good[0]['replacement']} here")]
    assert any("replacement(s) used by more than one row" in p for p in gate.validate_exam_v2(dup_rep))
    dup_sent = good + [dict(good[0], id="x5", replacement="gammaX", edited=good[0]["pasted"].replace("alpha 0", "gammaX"))]
    assert any("pasted sentence is used by more than one row" in p for p in gate.validate_exam_v2(dup_sent))
    frames = [dict(r, frame="one frame") for r in good]
    assert any("frame reuse over the declared caps" in p for p in gate.validate_exam_v2(frames))
    cov = gate.exam_v2_coverage(good) if False else None  # coverage needs the real taxonomy file; covered by the freeze path


def test_frozen_exposure_is_counted_per_exam(tmp_path):
    runs = tmp_path / "runs"
    for name, doc in (("a", {"partition": "frozen-report", "judge": "j"}), ("b", {"partition": "frozen-report", "judge": "j", "exam": "v2"}), ("c", {"partition": "frozen-report", "judge": "j", "exam": "legacy"}), ("d", {"partition": "dev", "judge": "j"})):
        (runs / name).mkdir(parents=True)
        (runs / name / "scorecard.json").write_text(json.dumps(doc))
    assert gate.frozen_exposure("j", runs)["prior_frozen_report_runs"] == 2          # legacy: a (no key) + c
    assert gate.frozen_exposure("j", runs, exam="v2")["prior_frozen_report_runs"] == 1
    assert gate.frozen_exposure("j", runs, exam="v2")["exam"] == "v2"


def test_exam_registry_keeps_legacy_paths_unchanged():
    assert gate.EXAMS["legacy"]["manifest"] == gate.FROZEN_MANIFEST
    assert gate.EXAMS["legacy"]["partitions"] == {"working": gate.WORKING_CORPUS, "holdout": gate.HOLDOUT_CORPUS}
    assert set(gate.EXAMS["v2"]["partitions"]) == {"exam"} and gate.EXAMS["v2"]["manifest"].name == "edit-judge-exam-v2-manifest.json"
    manifest, loaded, problems = gate.load_exam("nope")
    assert problems and "unknown exam" in problems[0]


def test_attempt_ledger_reserves_once_per_exam_and_candidate(tmp_path):
    ledger = tmp_path / "attempts.jsonl"
    ident = {"checkpoint_sha256": "a" * 64, "tokenizer_sha256": "b" * 64, "config_sha256": "c" * 64, "path": "shape+judge"}
    rec = gate.reserve_attempt("v2", "d" * 64, "xenc-mmbert-small", ident, ["cmd"], attempts_log=ledger, os_major=27)
    assert rec["status"] == "started" and len(rec["key_digest"]) == 64 and rec["os_major"] == 27
    # A second reservation for the same exam + identity + macOS major is refused (exit 2).
    with pytest.raises(SystemExit) as exc:
        gate.reserve_attempt("v2", "d" * 64, "xenc-mmbert-small", ident, ["cmd"], attempts_log=ledger, os_major=27)
    assert exc.value.code == 2
    # A different identity, a different exam digest, a different exam or a
    # different macOS major are new keys: a PASS on 27 says nothing about 15.
    gate.reserve_attempt("v2", "d" * 64, "xenc-mmbert-small", dict(ident, config_sha256="e" * 64), ["cmd"], attempts_log=ledger, os_major=27)
    gate.reserve_attempt("v2", "f" * 64, "xenc-mmbert-small", ident, ["cmd"], attempts_log=ledger, os_major=27)
    gate.reserve_attempt("legacy", "d" * 64, "xenc-mmbert-small", ident, ["cmd"], attempts_log=ledger, os_major=27)
    gate.reserve_attempt("v2", "d" * 64, "xenc-mmbert-small", ident, ["cmd"], attempts_log=ledger, os_major=15)
    gate.complete_attempt(rec, "completed", tmp_path / "run", attempts_log=ledger)
    lines = [json.loads(l) for l in ledger.read_text().splitlines()]
    assert [l["status"] for l in lines] == ["started", "started", "started", "started", "started", "completed"]
    # The ledger is append-only: the completed line repeats the key, never rewrites the started one.
    assert lines[-1]["key_digest"] == rec["key_digest"] and lines[0]["status"] == "started"


def test_attempt_ledger_rows_without_an_os_major_count_as_macos_27(tmp_path):
    """Every row written before `os_major` existed ran on macOS 27, so such a
    row still blocks a rerun on 27 and leaves every other major open."""
    ledger = tmp_path / "attempts.jsonl"
    ident = {"checkpoint_sha256": "a" * 64, "tokenizer_sha256": "b" * 64, "config_sha256": "c" * 64, "path": "shape+judge"}
    legacy = {"key_digest": "0" * 64, "exam": "v2", "exam_manifest_sha256": "d" * 64, "judge": "xenc-mmbert-small", "execution_identity": ident, "status": "completed", "started_at": "2026-09-21T13-22-50Z"}
    ledger.write_text(json.dumps(legacy) + "\n")
    assert gate.LEGACY_LEDGER_OS_MAJOR == 27
    with pytest.raises(SystemExit) as exc:
        gate.reserve_attempt("v2", "d" * 64, "xenc-mmbert-small", ident, ["cmd"], attempts_log=ledger, os_major=27)
    assert exc.value.code == 2
    rec = gate.reserve_attempt("v2", "d" * 64, "xenc-mmbert-small", ident, ["cmd"], attempts_log=ledger, os_major=14)
    assert rec["os_major"] == 14 and rec["key_digest"] != legacy["key_digest"]


@pytest.mark.skipif(sys.platform != "darwin", reason="host_identity reads sw_vers and sysctl; on Linux it exits 2 by design")
def test_host_identity_reads_this_machine():
    host = gate.host_identity()
    assert host["os_major"] == int(host["os_version"].split(".")[0]) >= 14
    assert host["chip"] and isinstance(host["virtual"], bool)
