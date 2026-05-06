"""Unit tests for the alias-suggestion scorer (#637).

Run from repo root:
  python3 -m pytest scripts/eval/tests/test_alias_scorer.py
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent.parent.parent.resolve()
sys.path.insert(0, str(ROOT / "scripts/eval"))

from alias_suggestion_gate import (  # noqa: E402
    aggregate_corpus,
    assign_matches,
    cluster_count,
    is_plausible,
    match_score,
    normalize,
    normalized_edit_similarity,
    score_case,
)


# --- match_score ---


def test_match_exact_identical():
    assert match_score("Sourabh", "Sourabh") == 1.0


def test_match_close_phonetic():
    # Sourabh vs Saurabh: one-char swap, should be > 0.8
    assert match_score("Sourabh", "Saurabh") > 0.80


def test_match_no_space_variant():
    # "kuber netties" vs "kubernetties": space shouldn't tank the score
    assert match_score("kuber netties", "kubernetties") > 0.90


def test_match_unrelated():
    # Totally different words should score low
    assert match_score("Saurabh", "Tornado") < 0.40


# --- normalize ---


def test_normalize_lowercase_trim():
    assert normalize("  Saurabh  ") == "saurabh"


def test_normalize_collapses_whitespace():
    assert normalize("kuber  netties") == "kuber netties"


def test_normalize_strips_outer_punct():
    assert normalize('"Sourabh."') == "sourabh"


# --- assign_matches greedy ---


def test_assign_one_to_one():
    suggestions = ["Sourabh", "Sorab"]
    groups = [
        {"id": "g1", "variants": ["Sourabh", "Sorab"]},
        {"id": "g2", "variants": ["Saurav"]},
    ]
    matched = assign_matches(suggestions, groups)
    # Both suggestions should match g1, but greedy assigns one per group.
    assert matched.count("g1") == 1
    assert sum(1 for m in matched if m is not None) == 1


def test_assign_no_double_count():
    suggestions = ["Sourabh", "Sourabh", "Sourabh"]
    groups = [{"id": "g1", "variants": ["Sourabh"]}]
    matched = assign_matches(suggestions, groups)
    # Only one of the three identical suggestions should consume the group.
    assert matched.count("g1") == 1


# --- cluster_count ---


def test_cluster_three_distinct():
    assert cluster_count(["Sourabh", "Sorab", "Saurav"]) == 3


def test_cluster_dupes_collapse():
    # Filter dedupes "Sourabh" exactly, but if we feed cluster two near-dupes
    # it should still merge.
    assert cluster_count(["Sourabh", "sourabh"]) == 1


def test_cluster_no_space_match():
    assert cluster_count(["kuber netties", "kubernetties"]) == 1


# --- score_case (aliasable) ---


def _aliasable_case():
    return {
        "id": "T1",
        "canonical": "Saurabh",
        "category": "person",
        "acceptable_categories": ["person"],
        "no_alias_expected": False,
        "expected_alias_groups": [
            {"id": "sourabh", "variants": ["Sourabh", "Sorab", "Sourab"]},
            {"id": "saurav", "variants": ["Saurav", "Sorov"]},
        ],
    }


def _record(raw, filtered, predicted="person", error=None, timed_out=False, latency=1200):
    return {
        "predicted_category": predicted,
        "raw_aliases": raw,
        "filtered_aliases": filtered,
        "latency_ms": latency,
        "cold_start": False,
        "timed_out": timed_out,
        "error": error,
    }


def test_aliasable_all_axes_pass():
    case = _aliasable_case()
    rec = _record(["Sourabh", "Saurav", "Sorab"], ["Sourabh", "Saurav", "Sorab"])
    r = score_case(case, rec)
    assert r.case_pass is True
    assert r.recall >= 2 and r.precision >= 2 and r.diversity >= 2 and r.category >= 2


def test_aliasable_one_hit_fails():
    case = _aliasable_case()
    # One real hit (Sourabh) plus two unrelated noise words.
    # Rubric: 1 hit of 2 groups = 50% → recall=2; precision tanks because
    # 2 of 3 suggestions are noise; case fails on precision.
    rec = _record(["Sourabh", "Tornado", "Tornado"], ["Sourabh", "Tornado", "Tornado"])
    r = score_case(case, rec)
    assert r.recall == 2
    assert r.precision <= 1  # precision low → case fails MIN_ABSOLUTE
    assert r.case_pass is False


def test_aliasable_near_canonical_no_matches_fails_recall():
    # All 5 "near canonical" but none match expected groups
    case = _aliasable_case()
    near = ["Saurabhh", "Saurabbh", "Saurabh1"]  # all >= 0.40 and < 0.95 against Saurabh
    rec = _record(near, near)
    r = score_case(case, rec)
    assert r.recall == 0
    assert r.case_pass is False


def test_refusal_fails_regardless_of_axes():
    case = _aliasable_case()
    rec = _record([], [], error="timeout", timed_out=True)
    r = score_case(case, rec)
    assert r.refusal == 1
    assert r.case_pass is False


def test_degeneration_fail():
    case = _aliasable_case()
    # Raw non-empty, filter ate everything (in real life because it's all canonical echoes)
    rec = _record(["Saurabh", "Saurabh", "saurabh"], [])
    r = score_case(case, rec)
    assert r.degeneration == 1
    assert r.case_pass is False


def test_wrong_category_fails():
    case = _aliasable_case()
    rec = _record(["Sourabh", "Saurav", "Sorab"], ["Sourabh", "Saurav", "Sorab"], predicted="brand")
    r = score_case(case, rec)
    assert r.category == 0
    assert r.case_pass is False


# --- score_case (no-alias-expected) ---


def _no_alias_case():
    return {
        "id": "T-NOALIAS-1",
        "canonical": "John",
        "category": "person",
        "acceptable_categories": ["person"],
        "no_alias_expected": True,
        "expected_alias_groups": [],
    }


def test_no_alias_clean_pass():
    case = _no_alias_case()
    rec = _record([], [])
    r = score_case(case, rec)
    assert r.case_pass is True
    assert r.recall == 3 and r.precision == 3 and r.diversity == 3


def test_no_alias_with_filtered_output_fails():
    case = _no_alias_case()
    rec = _record(["Jon", "Joan"], ["Jon", "Joan"])
    r = score_case(case, rec)
    assert r.case_pass is False


def test_no_alias_filter_saved_us_still_passes_user_visible():
    # Per founder direction 2026-05-05 question 3: defer pass/fail rule until baseline.
    # Current behavior: filter ate everything → user-visible empty → passes the user-visible
    # expectation. Degeneration counter ticks (recorded for review).
    case = _no_alias_case()
    rec = _record(["John", "john", "JOHN"], [])
    r = score_case(case, rec)
    assert r.case_pass is True
    assert r.degeneration == 1


# --- aggregate_corpus ---


def test_aggregate_per_category_threshold():
    cases = [_aliasable_case() for _ in range(10)]
    # Force half to fail
    results = []
    for i, c in enumerate(cases):
        if i < 9:
            rec = _record(["Sourabh", "Saurav", "Sorab"], ["Sourabh", "Saurav", "Sorab"])
        else:
            rec = _record([], [], error="timeout", timed_out=True)
        results.append(score_case(c, rec))
    summary = aggregate_corpus("test", cases, results)
    # 9/10 = 90% — exactly at threshold
    assert summary.per_category_pass["person"] >= 0.89


def test_aggregate_side_gate_degeneration():
    cases = [_aliasable_case() for _ in range(20)]
    results = []
    for i, c in enumerate(cases):
        if i < 18:
            rec = _record(["Sourabh", "Saurav", "Sorab"], ["Sourabh", "Saurav", "Sorab"])
        else:
            # 2 of 20 = 10% degeneration > 5% ceiling
            rec = _record(["Saurabh"], [])
        results.append(score_case(c, rec))
    summary = aggregate_corpus("test", cases, results)
    assert summary.side_gates_pass is False
    assert any("degeneration" in f for f in summary.failures)
