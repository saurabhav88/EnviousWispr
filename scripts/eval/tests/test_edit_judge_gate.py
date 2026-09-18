"""Harness-contract tests for scripts/eval/edit_judge_gate.py (#996 Chunk 1).

When these fail the eval INSTRUMENT is wrong; they say nothing about any judge.
The gate's own `--mode selftest` is the two-way control (passing and failing
scorecards, refusals); this file pins the pieces the selftest reaches through
and the shipped corpus files themselves.
"""
from __future__ import annotations

import json
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


def test_undefined_metric_fails_the_verdict():
    rows = _rows()
    records = [_verdict(r["id"], False, False) for r in rows]
    card = gate.score(rows, records)
    ok, reasons = card.verdict()
    assert not ok
    assert "alias_precision undefined (zero denominator)" in reasons


def test_thresholds_are_the_plan_values():
    assert gate.THRESHOLDS == {
        "correction_recall_min": 0.85,
        "false_add_rate_max": 0.05,
        "alias_precision_min": 0.95,
        "latency_p50_ms_max": 2000.0,
        "latency_p95_ms_max": 5000.0,
    }
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
    assert d["pass"] is True or "alias_precision undefined (zero denominator)" in d["reasons"]
