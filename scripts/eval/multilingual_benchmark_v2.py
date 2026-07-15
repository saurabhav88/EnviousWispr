#!/usr/bin/env python3
"""Fail-closed corpus validator and manifest builder for EG-1 multilingual V2.

This tool validates benchmark inputs only. It does not run or inspect models.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import types
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any, Iterable, Sequence


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
DEVELOPMENT_AUTHORING_VERIFIER_PATH = (
    SCRIPT_PATH.parent / "build_eg1_multilingual_development_authoring.py"
)
DEVELOPMENT_LEAKAGE_SCANNER_PATH = (
    SCRIPT_PATH.parent / "scan_eg1_multilingual_development_leakage.py"
)
RATING_SCHEMA_PATH = (
    SCRIPT_PATH.parent / "multilingual_benchmark_v2_rating.schema.json"
)
DEVELOPMENT_AUTHORING_IMPORT_CLOSURE = (
    SCRIPT_PATH,
    DEVELOPMENT_AUTHORING_VERIFIER_PATH,
    DEVELOPMENT_LEAKAGE_SCANNER_PATH,
    SCRIPT_PATH.parent / "screen_eg1_replay_semantic_neighbors.py",
    SCRIPT_PATH.parent / "build_eg1_replay_inventory.py",
    SCRIPT_PATH.parent / "eg1_replay_normalizer_v1.py",
    SCRIPT_PATH.parent / "multilingual_benchmark_v2.schema.json",
    RATING_SCHEMA_PATH,
    SCRIPT_PATH.parent
    / "contracts/eg1_multilingual_development_authoring_v1.json",
    SCRIPT_PATH.parent
    / "contracts/eg1_multilingual_development_leakage_scanner_v1.json",
)
DEVELOPMENT_AUTHORING_MODULE_NAMES = (
    "multilingual_benchmark_v2",
    "eg1_pinned_multilingual_benchmark_v2",
    "scan_eg1_multilingual_development_leakage",
    "eg1_replay_normalizer_v1",
    "build_eg1_replay_inventory",
    "eg1_pinned_replay_semantic_neighbors",
    "_eg1_multilingual_development_authoring_for_ratings",
)
SCHEMA_VERSION = "eg1-multilingual-benchmark-v2"
RATING_SCHEMA_VERSION = "eg1-multilingual-benchmark-v2-rating"
VALIDATOR_VERSION = "1.6.0"
LANGUAGES = ("en", "de", "fr", "es", "ru")
SPLITS = ("development", "frozen")
DOMAINS = (
    "work_admin",
    "personal_home",
    "technical_product",
    "medical",
    "legal_financial",
)
BEHAVIORS = (
    "filler_removal",
    "self_correction",
    "native_morphology",
    "punctuation_capitalization",
    "entities_numbers_dates",
    "names_code_switching",
    "topic_shift_long_dictation",
    "mixed_two_to_three_edits",
    "explicit_two_item_list",
    "scoped_two_item_list",
    "natural_three_to_five_item_bullet_list",
    "spoken_ordinals_numbered_list",
    "two_item_prose_restraint",
    "three_plus_item_prose_restraint",
    "quoted_high_risk_instruction_restraint",
    "clean_minimal_edit_restraint",
)
DIFFICULTIES = ("routine", "challenging", "adversarial")
SAFETY_RISKS = ("standard", "medical", "legal", "financial")
LIST_CONTRACTS = (
    "no_list_requirement",
    "activate_bullets",
    "activate_numbered",
    "restrain_prose",
)
SOURCE_TYPES = ("native_original", "shared_concept_local_rewrite")
LEAKAGE_ROLES = (
    "training",
    "prior_eval",
    "blocked_family_registry",
    "blocked_text_hash_registry",
)
REQUIRED_FROZEN_LEAKAGE_ROLES = frozenset(LEAKAGE_ROLES)
REQUIRED_SCREEN_METHODS = (
    "exact_normalized",
    "token_ngram_jaccard",
    "character_ngram_jaccard",
    "embedding_cosine",
)
RATING_AXES = (
    "same_language",
    "meaning_preserved",
    "requested_cleanup_completed",
    "native_grammar_morphology",
    "entities_preserved",
    "numbers_preserved",
    "timing_preserved",
    "attribution_preserved",
    "list_contract_satisfied",
    "no_damaging_extra_edits",
)
DAMAGE_SEVERITIES = ("S0", "S1", "S2", "S3", "S4")

POSITIVE_LIST_BEHAVIORS = frozenset(BEHAVIORS[8:12])
RESTRAINT_BEHAVIORS = frozenset(BEHAVIORS[12:16])

EXPECTED_LIST_CONTRACT = {
    **{behavior: "no_list_requirement" for behavior in BEHAVIORS[:8]},
    "explicit_two_item_list": "activate_bullets",
    "scoped_two_item_list": "activate_bullets",
    "natural_three_to_five_item_bullet_list": "activate_bullets",
    "spoken_ordinals_numbered_list": "activate_numbered",
    **{behavior: "restrain_prose" for behavior in BEHAVIORS[12:]},
}

DEVELOPMENT_CASES_PER_CELL = 2
MIN_FROZEN_CASES_PER_CELL = 4
DEFAULT_FROZEN_CASES_PER_CELL = 4
RELEASE_NET_IMPROVEMENT = 0.05
RELEASE_TARGET_POWER = 0.80
RELEASE_FAMILYWISE_ALPHA = 0.05
RELEASE_PRIMARY_LANGUAGE_COMPARISONS = 5
COMPARISON_BINDING_FIELDS = (
    "development_corpus_sha256",
    "development_benchmark_manifest_sha256",
    "development_comparison_manifest_sha256",
    "baseline_artifact_sha256",
    "baseline_evaluation_config_sha256",
    "finalist_artifact_sha256",
    "finalist_evaluation_config_sha256",
)


def release_counts(frozen_cases_per_cell: int) -> dict[str, dict[str, int]]:
    return {
        "development": {
            "per_language": len(BEHAVIORS) * len(DOMAINS) * DEVELOPMENT_CASES_PER_CELL,
            "per_behavior": len(DOMAINS) * DEVELOPMENT_CASES_PER_CELL,
            "per_domain": len(BEHAVIORS) * DEVELOPMENT_CASES_PER_CELL,
        },
        "frozen": {
            "per_language": len(BEHAVIORS) * len(DOMAINS) * frozen_cases_per_cell,
            "per_behavior": len(DOMAINS) * frozen_cases_per_cell,
            "per_domain": len(BEHAVIORS) * frozen_cases_per_cell,
        },
    }


RELEASE_COUNTS = release_counts(DEFAULT_FROZEN_CASES_PER_CELL)

IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
BLOCKED_FAMILY_CLEARANCE_FIELDS = {
    "registry_sha256",
    "candidate_semantic_family_id",
    "reviewer_id",
    "independent_of_author",
    "status",
    "reviewed_on",
}
BLOCKED_REGISTRY_RECEIPT_FIELDS = {
    "schema_version",
    "status",
    "registry_id",
    "normalization_policy_id",
    "execution_git_head",
    "contract",
    "builder",
    "allocator",
    "counts",
    "sources",
    "artifacts",
    "decision_summary",
    "candidate_clearance_contract",
    "privacy",
    "authorship_gate",
    "publication",
}
BLOCKED_REGISTRY_ARTIFACTS = {
    "blocked_family_registry.jsonl": {
        "role": "blocked_family_registry",
        "row_count": 7198,
    },
    "blocked_text_hashes.jsonl": {
        "role": "blocked_text_hash_registry",
        "row_count": 13733,
    },
    "source_coverage.jsonl": {
        "role": None,
        "row_count": 11236,
    },
    "provisional_decisions.jsonl": {
        "role": None,
        "row_count": 23,
    },
}
BLOCKED_REGISTRY_COUNTS = {
    "sources": 4,
    "source_rows": 11236,
    "blocked_families": 7198,
    "normalized_input_hashes": 6872,
    "normalized_output_hashes": 6861,
    "normalized_empty_input_rows": 1,
    "normalized_empty_output_rows": 1,
    "provisional_decisions": 23,
    "replace": 23,
    "retain": 0,
}
BLOCKED_REGISTRY_CONTRACT_FIELDS = {
    "schema_version",
    "registry_id",
    "status",
    "normalization_policy_id",
    "allocator",
    "counts",
    "sources",
    "expected_validator_artifacts",
    "candidate_clearance_contract",
    "decision_policy",
    "publication",
}
BLOCKED_REGISTRY_SOURCE_RECEIPT_FIELDS = {
    "role",
    "name",
    "path",
    "sha256",
    "expected_sha256",
    "row_count",
    "unique_row_ids",
    "blocked_family_count",
    "unique_normalized_input_hashes",
    "unique_normalized_output_hashes",
    "normalized_empty_input_rows",
    "normalized_empty_output_rows",
}
BLOCKED_REGISTRY_CANDIDATE_CLEARANCE_CONTRACT = {
    "provenance_field": "blocked_family_clearances",
    "registry_artifact": "blocked_family_registry.jsonl",
    "registry_binding_field": "registry_sha256",
    "candidate_binding_field": "candidate_semantic_family_id",
    "required_status": "cleared",
    "independent_review_required": True,
}


def _binomial_pmf(successes: int, trials: int, probability: float) -> float:
    if probability == 0:
        return 1.0 if successes == 0 else 0.0
    if probability == 1:
        return 1.0 if successes == trials else 0.0
    return math.exp(
        math.lgamma(trials + 1)
        - math.lgamma(successes + 1)
        - math.lgamma(trials - successes + 1)
        + successes * math.log(probability)
        + (trials - successes) * math.log1p(-probability)
    )


def _exact_two_sided_binomial_p(successes: int, trials: int) -> float:
    lower = min(successes, trials - successes)
    tail = sum(math.comb(trials, index) for index in range(lower + 1)) / (2**trials)
    return min(1.0, 2.0 * tail)


def exact_mcnemar_power(
    cases_per_language: int,
    discordance_rate: float,
    net_improvement: float,
    alpha: float,
) -> float:
    """Unconditional power for the two-sided exact conditional McNemar test.

    `net_improvement` is candidate-only pass probability minus baseline-only
    pass probability. Discordance and the target difference are estimated on
    model-blind development cases before frozen size is sealed.
    """

    if cases_per_language < 1:
        raise ValueError("cases_per_language must be positive")
    if not 0 < alpha < 1:
        raise ValueError("alpha must be between zero and one")
    if not 0 < discordance_rate <= 1:
        raise ValueError("discordance_rate must be in (0, 1]")
    if not 0 < net_improvement <= discordance_rate:
        raise ValueError("net_improvement must be in (0, discordance_rate]")

    candidate_only = (discordance_rate + net_improvement) / 2
    conditional_candidate_win = candidate_only / discordance_rate
    power = 0.0
    for discordant in range(cases_per_language + 1):
        discordant_probability = _binomial_pmf(
            discordant, cases_per_language, discordance_rate
        )
        if discordant_probability < 1e-16:
            continue
        conditional_rejection = sum(
            _binomial_pmf(candidate_wins, discordant, conditional_candidate_win)
            for candidate_wins in range(discordant + 1)
            if _exact_two_sided_binomial_p(candidate_wins, discordant) <= alpha
        )
        power += discordant_probability * conditional_rejection
    return power


def frozen_power_plan(
    *,
    discordance_rate: float,
    net_improvement: float,
    target_power: float,
    familywise_alpha: float,
    primary_language_comparisons: int,
    maximum_cases_per_cell: int,
) -> dict[str, Any]:
    if not 0 < target_power < 1:
        raise ValueError("target_power must be between zero and one")
    if not 0 < familywise_alpha < 1:
        raise ValueError("familywise_alpha must be between zero and one")
    if primary_language_comparisons < 1:
        raise ValueError("primary_language_comparisons must be positive")
    if maximum_cases_per_cell < MIN_FROZEN_CASES_PER_CELL:
        raise ValueError(
            f"maximum_cases_per_cell must be at least {MIN_FROZEN_CASES_PER_CELL}"
        )
    corrected_alpha = familywise_alpha / primary_language_comparisons
    evaluated: list[dict[str, Any]] = []
    for cases_per_cell in range(MIN_FROZEN_CASES_PER_CELL, maximum_cases_per_cell + 1):
        cases_per_language = len(BEHAVIORS) * len(DOMAINS) * cases_per_cell
        power = exact_mcnemar_power(
            cases_per_language,
            discordance_rate,
            net_improvement,
            corrected_alpha,
        )
        evaluated.append(
            {
                "frozen_cases_per_cell": cases_per_cell,
                "frozen_cases_per_language": cases_per_language,
                "exact_power": round(power, 6),
            }
        )
        if power >= target_power:
            return {
                "status": "sized",
                "method": "unconditional_power_two_sided_exact_conditional_mcnemar",
                "planning_discordance_rate": discordance_rate,
                "minimum_detectable_net_improvement": net_improvement,
                "target_power": target_power,
                "familywise_alpha": familywise_alpha,
                "primary_language_comparisons": primary_language_comparisons,
                "per_comparison_alpha_worst_case": corrected_alpha,
                "selected": evaluated[-1],
                "evaluated": evaluated,
            }
    raise ValueError(
        "target power was not reached; increase maximum_cases_per_cell before frozen sealing"
    )


def _wilson_upper(successes: int, total: int) -> float:
    # One-sided 99% endpoint: Bonferroni 0.05 / 5 gives simultaneous 95%
    # coverage across the five language-specific discordance nuisance rates.
    z = 2.3263478740408408
    rate = successes / total
    denominator = 1 + z * z / total
    center = (rate + z * z / (2 * total)) / denominator
    margin = z * math.sqrt(
        (rate * (1 - rate) + z * z / (4 * total)) / total
    ) / denominator
    return center + margin


def _read_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BenchmarkValidationError([f"invalid {label} {path}: {exc}"]) from exc
    if not isinstance(value, dict):
        raise BenchmarkValidationError([f"{label} must be a JSON object"])
    return value


def _parse_json_object_bytes(value: bytes, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BenchmarkValidationError([f"invalid {label}: {exc}"]) from exc
    if not isinstance(parsed, dict):
        raise BenchmarkValidationError([f"{label} must be a JSON object"])
    return parsed


def _validate_development_corpus_and_manifest(
    corpus_path: Path, manifest_path: Path
) -> None:
    rows = read_benchmark(corpus_path)
    validate_rows(rows)
    errors: list[str] = []
    if any(row.get("split") != "development" for row in rows):
        errors.append("development power corpus may contain only development rows")
    target = RELEASE_COUNTS["development"]
    counts = Counter(row.get("language") for row in rows)
    behavior_domain_counts = Counter(
        (row.get("language"), row.get("behavior"), row.get("domain")) for row in rows
    )
    source_counts = Counter(
        (
            row.get("language"),
            row.get("provenance", {}).get("source_type")
            if isinstance(row.get("provenance"), dict)
            else None,
        )
        for row in rows
    )
    for language in LANGUAGES:
        if counts[language] != target["per_language"]:
            errors.append(
                f"development power corpus {language} has {counts[language]} rows, "
                f"expected {target['per_language']}"
            )
        for behavior in BEHAVIORS:
            for domain in DOMAINS:
                actual = behavior_domain_counts[(language, behavior, domain)]
                if actual != DEVELOPMENT_CASES_PER_CELL:
                    errors.append(
                        f"development power corpus {language}/{behavior}/{domain} has "
                        f"{actual}, expected {DEVELOPMENT_CASES_PER_CELL}"
                    )
        native_original = source_counts[(language, "native_original")]
        if native_original < math.ceil(target["per_language"] * 0.8):
            errors.append(
                f"development power corpus {language} has {native_original} native-original rows"
            )
    expected_total = target["per_language"] * len(LANGUAGES)
    if len(rows) != expected_total:
        errors.append(
            f"development power corpus has {len(rows)} rows, expected {expected_total}"
        )

    manifest = _read_json_object(manifest_path, "development benchmark manifest")
    expected_manifest = build_manifest(
        rows=rows,
        corpus_path=corpus_path,
        sources=[],
        receipt_path=None,
        release_profile=False,
    )
    if set(manifest) != set(expected_manifest):
        errors.append("development benchmark manifest field set is invalid")
    corpus_derived_fields = (
        "schema_version",
        "validator_version",
        "benchmark_schema_sha256",
        "rating_schema_sha256",
        "corpus_source_sha256",
        "benchmark_content_sha256",
        "release_profile_enforced",
        "release_profile_parameters",
        "power_plan_sha256",
        "development_discordance_receipt_sha256",
        "development_corpus_sha256",
        "development_benchmark_manifest_sha256",
        "development_comparison_manifest_sha256",
        "comparison_binding",
        "row_count",
        "family_count",
        "family_assignment_sha256",
        "row_hashes",
        "counts",
    )
    for field in corpus_derived_fields:
        if manifest.get(field) != expected_manifest[field]:
            errors.append(f"development benchmark manifest {field} is invalid")
    if errors:
        raise BenchmarkValidationError(errors)


def _development_discordance_summary(
    *,
    discordance_receipt_path: Path,
    development_corpus_path: Path,
    development_benchmark_manifest_path: Path,
    development_comparison_manifest_path: Path,
) -> tuple[dict[str, Any], dict[str, str]]:
    _validate_development_corpus_and_manifest(
        development_corpus_path, development_benchmark_manifest_path
    )
    comparison = _read_json_object(
        development_comparison_manifest_path, "development comparison manifest"
    )
    expected_comparison_fields = {
        "schema_version",
        "baseline_artifact_sha256",
        "baseline_evaluation_config_sha256",
        "finalist_artifact_sha256",
        "finalist_evaluation_config_sha256",
    }
    errors: list[str] = []
    if set(comparison) != expected_comparison_fields:
        errors.append(
            "development comparison manifest must contain exactly "
            f"{sorted(expected_comparison_fields)}"
        )
    if comparison.get("schema_version") != "eg1-multilingual-development-comparison-v1":
        errors.append("development comparison manifest schema_version is invalid")
    for field in expected_comparison_fields - {"schema_version"}:
        value = comparison.get(field)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            errors.append(f"development comparison manifest {field} is invalid")
    if (
        comparison.get("baseline_artifact_sha256"),
        comparison.get("baseline_evaluation_config_sha256"),
    ) == (
        comparison.get("finalist_artifact_sha256"),
        comparison.get("finalist_evaluation_config_sha256"),
    ):
        errors.append("development comparison must bind distinct artifact/config pairs")

    receipt = _read_json_object(discordance_receipt_path, "development discordance receipt")
    expected_receipt_fields = {
        "schema_version",
        "custodian_id",
        "arm_blinded",
        "case_level_outcomes_withheld",
        "development_benchmark_manifest_sha256",
        "development_comparison_manifest_sha256",
        "per_language",
    }
    if set(receipt) != expected_receipt_fields:
        errors.append(
            f"development discordance receipt must contain exactly {sorted(expected_receipt_fields)}"
        )
    if receipt.get("schema_version") != "eg1-multilingual-development-discordance-v1":
        errors.append("development discordance receipt schema_version is invalid")
    if not isinstance(receipt.get("custodian_id"), str) or not receipt["custodian_id"].strip():
        errors.append("development discordance receipt custodian_id is invalid")
    if receipt.get("arm_blinded") is not True:
        errors.append("development discordance receipt must be arm_blinded")
    if receipt.get("case_level_outcomes_withheld") is not True:
        errors.append("development discordance receipt must withhold case-level outcomes")
    benchmark_manifest_sha = sha256_file(development_benchmark_manifest_path)
    comparison_manifest_sha = sha256_file(development_comparison_manifest_path)
    if receipt.get("development_benchmark_manifest_sha256") != benchmark_manifest_sha:
        errors.append("development discordance receipt benchmark-manifest hash mismatch")
    if receipt.get("development_comparison_manifest_sha256") != comparison_manifest_sha:
        errors.append("development discordance receipt comparison-manifest hash mismatch")

    per_language = receipt.get("per_language")
    if not isinstance(per_language, dict) or set(per_language) != set(LANGUAGES):
        errors.append(
            f"development discordance receipt per_language must contain exactly {list(LANGUAGES)}"
        )
        per_language = {}
    expected_pairs = RELEASE_COUNTS["development"]["per_language"]
    totals: dict[str, int] = {}
    discordant: dict[str, int] = {}
    for language in LANGUAGES:
        values = per_language.get(language)
        if not isinstance(values, dict) or set(values) != {"pair_count", "discordant_count"}:
            errors.append(f"development discordance receipt {language} counts are malformed")
            continue
        pair_count = values.get("pair_count")
        discordant_count = values.get("discordant_count")
        if type(pair_count) is not int or pair_count != expected_pairs:
            errors.append(
                f"development discordance receipt {language} pair_count must equal {expected_pairs}"
            )
            continue
        if (
            type(discordant_count) is not int
            or discordant_count < 0
            or discordant_count > pair_count
        ):
            errors.append(
                f"development discordance receipt {language} discordant_count is invalid"
            )
            continue
        totals[language] = pair_count
        discordant[language] = discordant_count
    if errors:
        raise BenchmarkValidationError(errors)

    rates = {language: discordant[language] / totals[language] for language in LANGUAGES}
    upper_bounds = {
        language: _wilson_upper(discordant[language], totals[language])
        for language in LANGUAGES
    }
    summary = {
        "development_discordance_receipt_sha256": sha256_file(discordance_receipt_path),
        "development_case_count_by_language": dict(sorted(totals.items())),
        "observed_discordance_count_by_language": dict(sorted(discordant.items())),
        "observed_discordance_rate_by_language": dict(sorted(rates.items())),
        "discordance_simultaneous_95_upper_by_language": dict(
            sorted(upper_bounds.items())
        ),
        "sizing_discordance_rate": max(
            RELEASE_NET_IMPROVEMENT, max(upper_bounds.values())
        ),
        "custodian_id": receipt["custodian_id"],
    }
    binding = {
        "development_corpus_sha256": sha256_file(development_corpus_path),
        "development_benchmark_manifest_sha256": benchmark_manifest_sha,
        "development_comparison_manifest_sha256": comparison_manifest_sha,
        "baseline_artifact_sha256": comparison["baseline_artifact_sha256"],
        "baseline_evaluation_config_sha256": comparison[
            "baseline_evaluation_config_sha256"
        ],
        "finalist_artifact_sha256": comparison["finalist_artifact_sha256"],
        "finalist_evaluation_config_sha256": comparison[
            "finalist_evaluation_config_sha256"
        ],
    }
    return summary, binding


def release_power_plan(
    *,
    discordance_receipt_path: Path,
    development_corpus_path: Path,
    development_benchmark_manifest_path: Path,
    development_comparison_manifest_path: Path,
    maximum_cases_per_cell: int,
) -> dict[str, Any]:
    discordance_summary, comparison_binding = _development_discordance_summary(
        discordance_receipt_path=discordance_receipt_path,
        development_corpus_path=development_corpus_path,
        development_benchmark_manifest_path=development_benchmark_manifest_path,
        development_comparison_manifest_path=development_comparison_manifest_path,
    )
    plan = frozen_power_plan(
        discordance_rate=discordance_summary["sizing_discordance_rate"],
        net_improvement=RELEASE_NET_IMPROVEMENT,
        target_power=RELEASE_TARGET_POWER,
        familywise_alpha=RELEASE_FAMILYWISE_ALPHA,
        primary_language_comparisons=RELEASE_PRIMARY_LANGUAGE_COMPARISONS,
        maximum_cases_per_cell=maximum_cases_per_cell,
    )
    return {
        **plan,
        "discordance_sizing_method": (
            "maximum_per_language_bonferroni_wilson_simultaneous_95_upper"
        ),
        **discordance_summary,
        "comparison_binding": dict(sorted(comparison_binding.items())),
    }


def validate_power_plan(
    path: Path,
    *,
    frozen_cases_per_cell: int,
    discordance_receipt_path: Path,
    development_corpus_path: Path,
    development_benchmark_manifest_path: Path,
    development_comparison_manifest_path: Path,
) -> dict[str, Any]:
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BenchmarkValidationError([f"invalid power plan {path}: {exc}"]) from exc
    if not isinstance(plan, dict):
        raise BenchmarkValidationError(["power plan must be a JSON object"])
    selected = plan.get("selected")
    if not isinstance(selected, dict):
        raise BenchmarkValidationError(["power plan selected result is missing"])
    selected_cases_per_cell = selected.get("frozen_cases_per_cell")
    if selected_cases_per_cell != frozen_cases_per_cell:
        raise BenchmarkValidationError(
            [
                "power plan frozen_cases_per_cell mismatch: "
                f"selected {selected_cases_per_cell}, requested {frozen_cases_per_cell}"
            ]
        )
    policy = {
        "minimum_detectable_net_improvement": RELEASE_NET_IMPROVEMENT,
        "target_power": RELEASE_TARGET_POWER,
        "familywise_alpha": RELEASE_FAMILYWISE_ALPHA,
        "primary_language_comparisons": RELEASE_PRIMARY_LANGUAGE_COMPARISONS,
    }
    for field, expected in policy.items():
        if plan.get(field) != expected:
            raise BenchmarkValidationError(
                [f"power plan {field} must equal release policy {expected}"]
            )
    try:
        recomputed = release_power_plan(
            discordance_receipt_path=discordance_receipt_path,
            development_corpus_path=development_corpus_path,
            development_benchmark_manifest_path=development_benchmark_manifest_path,
            development_comparison_manifest_path=development_comparison_manifest_path,
            maximum_cases_per_cell=selected_cases_per_cell,
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise BenchmarkValidationError([f"power plan cannot be recomputed: {exc}"]) from exc
    if plan != recomputed:
        raise BenchmarkValidationError(
            ["power plan does not exactly match the deterministic recomputation"]
        )
    return plan


class BenchmarkValidationError(ValueError):
    """Raised only after all discoverable validation errors are collected."""

    def __init__(self, errors: Sequence[str]):
        self.errors = list(errors)
        super().__init__("\n".join(self.errors))


@dataclass(frozen=True)
class LeakageSource:
    role: str
    name: str
    path: Path
    sha256: str


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_text(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    normalized = "".join(
        character
        if unicodedata.category(character)[0] in {"L", "M", "N"}
        else " "
        for character in normalized
    )
    return " ".join(normalized.split())


def _read_json_or_jsonl(path: Path) -> list[Any]:
    if not path.is_file():
        raise BenchmarkValidationError([f"missing input file: {path}"])
    text = path.read_text(encoding="utf-8")
    stripped = text.lstrip()
    if not stripped:
        raise BenchmarkValidationError([f"empty input file: {path}"])
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        value = None
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return [value]
    rows: list[Any] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise BenchmarkValidationError(
                [f"{path}:{line_number}: invalid JSON: {exc.msg}"]
            ) from exc
    if not rows:
        raise BenchmarkValidationError([f"no JSONL rows: {path}"])
    return rows


def read_benchmark(path: Path) -> list[dict[str, Any]]:
    values = _read_json_or_jsonl(path)
    errors = [
        f"{path}: row {index} must be a JSON object"
        for index, value in enumerate(values, start=1)
        if not isinstance(value, dict)
    ]
    if errors:
        raise BenchmarkValidationError(errors)
    return values  # type: ignore[return-value]


def _nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _validate_string_list(
    value: Any, *, case_id: str, field: str, errors: list[str]
) -> None:
    if not isinstance(value, list):
        errors.append(f"{case_id}: {field} must be an array")
        return
    all_strings = all(_nonempty_string(item) for item in value)
    if not all_strings:
        errors.append(f"{case_id}: {field} must contain only non-empty strings")
    if all_strings and len(value) != len(set(value)):
        errors.append(f"{case_id}: {field} contains duplicates")


def _validate_review_record(
    record: Any,
    *,
    case_id: str,
    language: str,
    kind: str,
    errors: list[str],
) -> None:
    required = {"reviewer_id", "locale", "native_attested", "status", "reviewed_on"}
    if kind == "validator":
        required.add("independent_of_author")
    if not isinstance(record, dict):
        errors.append(f"{case_id}: provenance.{kind} must be an object")
        return
    missing = sorted(required - set(record))
    unknown = sorted(set(record) - required)
    if missing:
        errors.append(f"{case_id}: provenance.{kind} missing {missing}")
    if unknown:
        errors.append(f"{case_id}: provenance.{kind} has unknown fields {unknown}")
    reviewer_id = record.get("reviewer_id")
    if not _nonempty_string(reviewer_id) or not IDENTIFIER_RE.fullmatch(reviewer_id):
        errors.append(f"{case_id}: provenance.{kind}.reviewer_id must be a stable identifier")
    locale = record.get("locale")
    if not _nonempty_string(locale) or locale.split("-", 1)[0].lower() != language:
        errors.append(f"{case_id}: provenance.{kind}.locale must match {language}")
    if record.get("native_attested") is not True:
        errors.append(f"{case_id}: provenance.{kind}.native_attested must be true")
    if record.get("status") not in ({"complete"} if kind == "native_author" else {"approved"}):
        errors.append(f"{case_id}: provenance.{kind}.status is not release-valid")
    reviewed_on = record.get("reviewed_on")
    if not isinstance(reviewed_on, str) or not DATE_RE.fullmatch(reviewed_on):
        errors.append(f"{case_id}: provenance.{kind}.reviewed_on must be YYYY-MM-DD")
    else:
        try:
            date.fromisoformat(reviewed_on)
        except ValueError:
            errors.append(f"{case_id}: provenance.{kind}.reviewed_on is not a real date")
    if kind == "validator" and record.get("independent_of_author") is not True:
        errors.append(
            f"{case_id}: provenance.validator.independent_of_author must be true"
        )


def _valid_review_date(value: Any) -> bool:
    if not isinstance(value, str) or not DATE_RE.fullmatch(value):
        return False
    try:
        date.fromisoformat(value)
    except ValueError:
        return False
    return True


def _validate_blocked_family_clearances(
    value: Any,
    *,
    case_id: str,
    family_id: Any,
    author_id: Any,
    errors: list[str],
) -> None:
    field = "provenance.blocked_family_clearances"
    if not isinstance(value, list):
        errors.append(f"{case_id}: {field} must be an array")
        return
    if not value:
        errors.append(f"{case_id}: {field} must not be empty when present")
        return
    seen_registries: set[str] = set()
    for index, clearance in enumerate(value, 1):
        label = f"{field}[{index}]"
        if not isinstance(clearance, dict):
            errors.append(f"{case_id}: {label} must be an object")
            continue
        missing = sorted(BLOCKED_FAMILY_CLEARANCE_FIELDS - set(clearance))
        unknown = sorted(set(clearance) - BLOCKED_FAMILY_CLEARANCE_FIELDS)
        if missing:
            errors.append(f"{case_id}: {label} missing {missing}")
        if unknown:
            errors.append(f"{case_id}: {label} has unknown fields {unknown}")
        registry_sha = clearance.get("registry_sha256")
        if not isinstance(registry_sha, str) or not SHA256_RE.fullmatch(registry_sha):
            errors.append(
                f"{case_id}: {label}.registry_sha256 must be lowercase SHA-256"
            )
        elif registry_sha in seen_registries:
            errors.append(f"{case_id}: {field} contains duplicate registry SHA-256")
        else:
            seen_registries.add(registry_sha)
        if clearance.get("candidate_semantic_family_id") != family_id:
            errors.append(f"{case_id}: {label} must bind to semantic_family_id")
        reviewer_id = clearance.get("reviewer_id")
        if not _nonempty_string(reviewer_id) or not IDENTIFIER_RE.fullmatch(reviewer_id):
            errors.append(
                f"{case_id}: {label}.reviewer_id must be a stable identifier"
            )
        elif reviewer_id == author_id:
            errors.append(f"{case_id}: {label}.reviewer_id must differ from native author")
        if clearance.get("independent_of_author") is not True:
            errors.append(f"{case_id}: {label}.independent_of_author must be true")
        if clearance.get("status") != "cleared":
            errors.append(f"{case_id}: {label}.status must be cleared")
        if not _valid_review_date(clearance.get("reviewed_on")):
            errors.append(
                f"{case_id}: {label}.reviewed_on must be a real YYYY-MM-DD date"
            )


def validate_rows(
    rows: Sequence[dict[str, Any]],
    *,
    release_profile: bool = False,
    frozen_cases_per_cell: int = DEFAULT_FROZEN_CASES_PER_CELL,
) -> None:
    errors: list[str] = []
    seen_case_ids: set[str] = set()
    family_splits: dict[str, set[str]] = defaultdict(set)
    family_signatures: dict[str, tuple[Any, ...]] = {}
    contrast_sets: dict[str, list[dict[str, Any]]] = defaultdict(list)
    normalized_inputs: dict[str, str] = {}
    normalized_outputs: dict[str, str] = {}

    top_fields = {
        "schema_version",
        "case_id",
        "semantic_family_id",
        "shared_concept_brief_id",
        "split",
        "language",
        "domain",
        "behavior",
        "contrast_set_id",
        "difficulty",
        "safety_risk",
        "asr_input",
        "gold_output",
        "requirements",
        "provenance",
    }
    requirement_fields = {
        "meaning",
        "entities",
        "numbers",
        "timing",
        "attribution",
        "formatting",
    }
    formatting_fields = {"list_contract", "expected_item_count", "shared_scope"}
    required_provenance_fields = {
        "source_type",
        "source_ref",
        "native_author",
        "independent_native_validator",
    }
    allowed_provenance_fields = required_provenance_fields | {
        "blocked_family_clearances",
        "shared_concept_binding",
    }

    for row_number, row in enumerate(rows, start=1):
        case_id = row.get("case_id") if _nonempty_string(row.get("case_id")) else f"row-{row_number}"
        missing = sorted(top_fields - set(row))
        unknown = sorted(set(row) - top_fields)
        if missing:
            errors.append(f"{case_id}: missing fields {missing}")
        if unknown:
            errors.append(f"{case_id}: unknown fields {unknown}")
        if row.get("schema_version") != SCHEMA_VERSION:
            errors.append(f"{case_id}: schema_version must be {SCHEMA_VERSION}")

        for field in ("case_id", "semantic_family_id"):
            value = row.get(field)
            if not _nonempty_string(value) or not IDENTIFIER_RE.fullmatch(value):
                errors.append(f"{case_id}: {field} must be a stable identifier")
        shared_brief_id = row.get("shared_concept_brief_id")
        if shared_brief_id is not None and (
            not _nonempty_string(shared_brief_id)
            or not IDENTIFIER_RE.fullmatch(shared_brief_id)
        ):
            errors.append(
                f"{case_id}: shared_concept_brief_id must be a stable identifier or null"
            )
        if case_id in seen_case_ids:
            errors.append(f"{case_id}: duplicate case_id")
        seen_case_ids.add(case_id)

        split = row.get("split")
        language = row.get("language")
        domain = row.get("domain")
        behavior = row.get("behavior")
        contrast_set_id = row.get("contrast_set_id")
        difficulty = row.get("difficulty")
        safety = row.get("safety_risk")
        for field, value, allowed in (
            ("split", split, SPLITS),
            ("language", language, LANGUAGES),
            ("domain", domain, DOMAINS),
            ("behavior", behavior, BEHAVIORS),
            ("difficulty", difficulty, DIFFICULTIES),
            ("safety_risk", safety, SAFETY_RISKS),
        ):
            if value not in allowed:
                errors.append(f"{case_id}: {field} must be one of {list(allowed)}")

        for field in ("asr_input", "gold_output"):
            if not _nonempty_string(row.get(field)):
                errors.append(f"{case_id}: {field} must be non-empty")

        if domain == "medical" and safety != "medical":
            errors.append(f"{case_id}: medical domain requires medical safety_risk")
        if domain == "legal_financial" and safety not in {"legal", "financial"}:
            errors.append(
                f"{case_id}: legal_financial domain requires legal or financial safety_risk"
            )
        if domain in {"work_admin", "personal_home", "technical_product"} and safety != "standard":
            errors.append(f"{case_id}: {domain} domain requires standard safety_risk")

        requirements = row.get("requirements")
        if not isinstance(requirements, dict):
            errors.append(f"{case_id}: requirements must be an object")
            requirements = {}
        else:
            missing = sorted(requirement_fields - set(requirements))
            unknown = sorted(set(requirements) - requirement_fields)
            if missing:
                errors.append(f"{case_id}: requirements missing {missing}")
            if unknown:
                errors.append(f"{case_id}: requirements has unknown fields {unknown}")
        if not _nonempty_string(requirements.get("meaning")):
            errors.append(f"{case_id}: requirements.meaning must be non-empty")
        for field in ("entities", "numbers", "timing", "attribution"):
            _validate_string_list(
                requirements.get(field), case_id=case_id, field=f"requirements.{field}", errors=errors
            )

        formatting = requirements.get("formatting")
        if not isinstance(formatting, dict):
            errors.append(f"{case_id}: requirements.formatting must be an object")
            formatting = {}
        else:
            missing = sorted(formatting_fields - set(formatting))
            unknown = sorted(set(formatting) - formatting_fields)
            if missing:
                errors.append(f"{case_id}: requirements.formatting missing {missing}")
            if unknown:
                errors.append(f"{case_id}: requirements.formatting has unknown fields {unknown}")
        list_contract = formatting.get("list_contract")
        if list_contract not in LIST_CONTRACTS:
            errors.append(
                f"{case_id}: requirements.formatting.list_contract must be one of {list(LIST_CONTRACTS)}"
            )
        expected_contract = EXPECTED_LIST_CONTRACT.get(behavior)
        if expected_contract and list_contract != expected_contract:
            errors.append(
                f"{case_id}: behavior {behavior} requires list_contract {expected_contract}"
            )
        item_count = formatting.get("expected_item_count")
        if list_contract in {"activate_bullets", "activate_numbered"}:
            if not isinstance(item_count, int) or isinstance(item_count, bool) or item_count < 2:
                errors.append(f"{case_id}: active list requires expected_item_count >= 2")
        elif item_count is not None:
            errors.append(f"{case_id}: non-list contract requires expected_item_count null")
        if behavior in {"explicit_two_item_list", "scoped_two_item_list"} and item_count != 2:
            errors.append(f"{case_id}: two-item behavior requires expected_item_count 2")
        if behavior == "natural_three_to_five_item_bullet_list" and item_count not in {3, 4, 5}:
            errors.append(f"{case_id}: natural list item count must be 3, 4, or 5")
        if not isinstance(formatting.get("shared_scope"), str):
            errors.append(f"{case_id}: requirements.formatting.shared_scope must be a string")

        if behavior in POSITIVE_LIST_BEHAVIORS | RESTRAINT_BEHAVIORS:
            if not _nonempty_string(contrast_set_id) or not IDENTIFIER_RE.fullmatch(
                contrast_set_id
            ):
                errors.append(f"{case_id}: list behavior requires a stable contrast_set_id")
            else:
                contrast_sets[contrast_set_id].append(row)
        elif contrast_set_id is not None:
            errors.append(f"{case_id}: core behavior requires contrast_set_id null")

        provenance = row.get("provenance")
        if not isinstance(provenance, dict):
            errors.append(f"{case_id}: provenance must be an object")
            provenance = {}
        else:
            missing = sorted(required_provenance_fields - set(provenance))
            unknown = sorted(set(provenance) - allowed_provenance_fields)
            if missing:
                errors.append(f"{case_id}: provenance missing {missing}")
            if unknown:
                errors.append(f"{case_id}: provenance has unknown fields {unknown}")
        if provenance.get("source_type") not in SOURCE_TYPES:
            errors.append(f"{case_id}: provenance.source_type must be one of {list(SOURCE_TYPES)}")
        if not _nonempty_string(provenance.get("source_ref")):
            errors.append(f"{case_id}: provenance.source_ref must be non-empty")
        shared_binding = provenance.get("shared_concept_binding")
        if provenance.get("source_type") == "shared_concept_local_rewrite":
            if not isinstance(shared_binding, dict) or set(shared_binding) != {
                "brief_id",
                "brief_sha256",
                "independent_local_rewrite",
                "candidate_model_output_seen",
            }:
                errors.append(f"{case_id}: shared row lacks exact shared concept binding")
            elif (
                shared_binding.get("brief_id") != shared_brief_id
                or not isinstance(shared_binding.get("brief_sha256"), str)
                or not SHA256_RE.fullmatch(shared_binding["brief_sha256"])
                or shared_binding.get("independent_local_rewrite") is not True
                or shared_binding.get("candidate_model_output_seen") is not False
            ):
                errors.append(f"{case_id}: shared concept binding is invalid")
        elif shared_brief_id is not None or shared_binding is not None:
            errors.append(f"{case_id}: native-original row must not carry a shared brief")

        author = provenance.get("native_author")
        _validate_review_record(
            author,
            case_id=case_id,
            language=language if language in LANGUAGES else "",
            kind="native_author",
            errors=errors,
        )
        validator = provenance.get("independent_native_validator")
        if validator is None:
            if split == "frozen":
                errors.append(
                    f"{case_id}: frozen row missing independent native validation"
                )
        else:
            _validate_review_record(
                validator,
                case_id=case_id,
                language=language if language in LANGUAGES else "",
                kind="validator",
                errors=errors,
            )
            if isinstance(author, dict) and isinstance(validator, dict):
                if author.get("reviewer_id") == validator.get("reviewer_id"):
                    errors.append(
                        f"{case_id}: native author and validator must be different people"
                    )

        if "blocked_family_clearances" in provenance:
            _validate_blocked_family_clearances(
                provenance["blocked_family_clearances"],
                case_id=case_id,
                family_id=row.get("semantic_family_id"),
                author_id=(
                    author.get("reviewer_id") if isinstance(author, dict) else None
                ),
                errors=errors,
            )

        family_id = row.get("semantic_family_id")
        if _nonempty_string(family_id) and split in SPLITS:
            family_splits[family_id].add(split)
            signature = (domain, behavior, difficulty, safety, list_contract)
            old_signature = family_signatures.setdefault(family_id, signature)
            if old_signature != signature:
                errors.append(
                    f"{case_id}: semantic family {family_id} changes its stratum signature"
                )

        for field, value, seen in (
            ("asr_input", row.get("asr_input"), normalized_inputs),
            ("gold_output", row.get("gold_output"), normalized_outputs),
        ):
            if _nonempty_string(value):
                normalized = normalize_text(value)
                prior = seen.get(normalized)
                if prior is not None and prior != case_id:
                    errors.append(f"{case_id}: normalized {field} duplicates {prior}")
                else:
                    seen[normalized] = case_id

    for family_id, splits in sorted(family_splits.items()):
        if len(splits) > 1:
            errors.append(
                f"semantic family {family_id} crosses splits {sorted(splits)}; allocate whole families"
            )

    for contrast_set_id, members in sorted(contrast_sets.items()):
        if len(members) != 2:
            errors.append(
                f"contrast set {contrast_set_id} has {len(members)} rows, expected one activation and one restraint"
            )
            continue
        positive = [row for row in members if row.get("behavior") in POSITIVE_LIST_BEHAVIORS]
        restraint = [row for row in members if row.get("behavior") in RESTRAINT_BEHAVIORS]
        if len(positive) != 1 or len(restraint) != 1:
            errors.append(
                f"contrast set {contrast_set_id} must contain one activation and one restraint row"
            )
            continue
        if positive[0].get("semantic_family_id") == restraint[0].get("semantic_family_id"):
            errors.append(
                f"contrast set {contrast_set_id} must use separately authored semantic families"
            )
        match_fields = ("split", "language", "domain", "difficulty", "safety_risk")
        mismatches = [
            field for field in match_fields if positive[0].get(field) != restraint[0].get(field)
        ]
        if mismatches:
            errors.append(
                f"contrast set {contrast_set_id} is not matched on {mismatches}"
            )

    if release_profile:
        errors.extend(_release_profile_errors(rows, frozen_cases_per_cell))
    if errors:
        raise BenchmarkValidationError(errors)


def _release_profile_errors(
    rows: Sequence[dict[str, Any]], frozen_cases_per_cell: int
) -> list[str]:
    errors: list[str] = []
    if (
        not isinstance(frozen_cases_per_cell, int)
        or isinstance(frozen_cases_per_cell, bool)
        or frozen_cases_per_cell < MIN_FROZEN_CASES_PER_CELL
    ):
        return [
            "release profile: frozen_cases_per_cell must be an integer "
            f"at least {MIN_FROZEN_CASES_PER_CELL}"
        ]
    release_profile_counts = release_counts(frozen_cases_per_cell)
    counts = Counter((row.get("split"), row.get("language")) for row in rows)
    behavior_counts = Counter(
        (row.get("split"), row.get("language"), row.get("behavior")) for row in rows
    )
    domain_counts = Counter(
        (row.get("split"), row.get("language"), row.get("domain")) for row in rows
    )
    behavior_domain_counts = Counter(
        (
            row.get("split"),
            row.get("language"),
            row.get("behavior"),
            row.get("domain"),
        )
        for row in rows
    )
    source_counts: Counter[tuple[Any, Any, Any]] = Counter()
    for row in rows:
        provenance = row.get("provenance")
        source_type = provenance.get("source_type") if isinstance(provenance, dict) else None
        source_counts[(row.get("split"), row.get("language"), source_type)] += 1
    difficulty_seen: dict[tuple[str, str], set[str]] = defaultdict(set)
    safety_seen: dict[tuple[str, str], set[str]] = defaultdict(set)
    for row in rows:
        key = (row.get("split"), row.get("language"))
        difficulty_seen[key].add(row.get("difficulty"))
        safety_seen[key].add(row.get("safety_risk"))

    for split in SPLITS:
        target = release_profile_counts[split]
        for language in LANGUAGES:
            key = (split, language)
            if counts[key] != target["per_language"]:
                errors.append(
                    f"release profile: {split}/{language} has {counts[key]} rows, expected {target['per_language']}"
                )
            for behavior in BEHAVIORS:
                actual = behavior_counts[(split, language, behavior)]
                if actual != target["per_behavior"]:
                    errors.append(
                        f"release profile: {split}/{language}/{behavior} has {actual}, expected {target['per_behavior']}"
                    )
            for domain in DOMAINS:
                actual = domain_counts[(split, language, domain)]
                if actual != target["per_domain"]:
                    errors.append(
                        f"release profile: {split}/{language}/{domain} has {actual}, expected {target['per_domain']}"
                    )
            expected_behavior_domain = target["per_behavior"] // len(DOMAINS)
            for behavior in BEHAVIORS:
                for domain in DOMAINS:
                    actual = behavior_domain_counts[
                        (split, language, behavior, domain)
                    ]
                    if actual != expected_behavior_domain:
                        errors.append(
                            f"release profile: {split}/{language}/{behavior}/{domain} has {actual}, expected {expected_behavior_domain}"
                        )
            native_original = source_counts[(split, language, "native_original")]
            native_minimum = math.ceil(target["per_language"] * 0.8)
            if native_original < native_minimum:
                errors.append(
                    f"release profile: {split}/{language} has {native_original} native-original rows, minimum {native_minimum}"
                )
            missing_difficulties = sorted(set(DIFFICULTIES) - difficulty_seen[key])
            missing_safety = sorted(set(SAFETY_RISKS) - safety_seen[key])
            if missing_difficulties:
                errors.append(
                    f"release profile: {split}/{language} missing difficulty strata {missing_difficulties}"
                )
            if missing_safety:
                errors.append(
                    f"release profile: {split}/{language} missing safety strata {missing_safety}"
                )
    expected_total = sum(
        release_profile_counts[split]["per_language"] * len(LANGUAGES)
        for split in SPLITS
    )
    if len(rows) != expected_total:
        errors.append(f"release profile: corpus has {len(rows)} rows, expected {expected_total}")
    return errors


def benchmark_content_sha256(rows: Sequence[dict[str, Any]]) -> str:
    ordered = sorted(rows, key=lambda row: row["case_id"])
    payload = "\n".join(canonical_json(row) for row in ordered) + "\n"
    return sha256_bytes(payload.encode("utf-8"))


def rating_content_sha256(rows: Sequence[dict[str, Any]]) -> str:
    ordered = sorted(rows, key=lambda row: row["rating_id"])
    payload = "\n".join(canonical_json(row) for row in ordered) + "\n"
    return sha256_bytes(payload.encode("utf-8"))


def read_ratings(path: Path) -> list[dict[str, Any]]:
    values = _read_json_or_jsonl(path)
    errors = [
        f"{path}: rating row {index} must be a JSON object"
        for index, value in enumerate(values, start=1)
        if not isinstance(value, dict)
    ]
    if errors:
        raise BenchmarkValidationError(errors)
    return values  # type: ignore[return-value]


def _rating_signature(row: dict[str, Any]) -> tuple[Any, ...] | None:
    axes = row.get("axes")
    severity = row.get("damage_severity")
    if not isinstance(axes, dict) or set(axes) != set(RATING_AXES):
        return None
    if any(not isinstance(axes.get(axis), bool) for axis in RATING_AXES):
        return None
    if severity not in DAMAGE_SEVERITIES:
        return None
    return tuple(axes[axis] for axis in RATING_AXES) + (severity,)


def validate_rating_rows(
    ratings: Sequence[dict[str, Any]],
    *,
    corpus_rows: Sequence[dict[str, Any]],
    expected_model_labels: Sequence[str],
) -> dict[str, Any]:
    """Validate the complete blinded native-review workflow without candidate text."""

    validate_rows(corpus_rows)
    errors: list[str] = []
    frozen_cases = {
        row["case_id"]: row for row in corpus_rows if row.get("split") == "frozen"
    }
    if not frozen_cases:
        errors.append("rating workflow requires at least one frozen case")

    labels = list(expected_model_labels)
    if not labels:
        errors.append("at least one predeclared opaque model label is required")
    if len(labels) != len(set(labels)):
        errors.append("expected opaque model labels contain duplicates")
    for label in labels:
        if not _nonempty_string(label) or not IDENTIFIER_RE.fullmatch(label):
            errors.append(f"invalid expected opaque model label {label!r}")
    label_set = set(labels)

    top_fields = {
        "schema_version",
        "rating_id",
        "case_id",
        "opaque_model_label",
        "blind_assignment_id",
        "blinded",
        "reviewer_id",
        "reviewer_locale",
        "reviewer_native_attested",
        "review_round",
        "repeat_of_rating_id",
        "axes",
        "damage_severity",
        "reason",
    }
    seen_rating_ids: set[str] = set()
    seen_assignments: set[str] = set()
    initial_by_pair: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    adjudication_by_pair: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    repeats: list[dict[str, Any]] = []

    for row_number, rating in enumerate(ratings, start=1):
        rating_id = (
            rating.get("rating_id")
            if _nonempty_string(rating.get("rating_id"))
            else f"rating-row-{row_number}"
        )
        missing = sorted(top_fields - set(rating))
        unknown = sorted(set(rating) - top_fields)
        if missing:
            errors.append(f"{rating_id}: missing fields {missing}")
        if unknown:
            errors.append(f"{rating_id}: unknown fields {unknown}")
        if rating.get("schema_version") != RATING_SCHEMA_VERSION:
            errors.append(f"{rating_id}: schema_version must be {RATING_SCHEMA_VERSION}")

        for field in (
            "rating_id",
            "case_id",
            "opaque_model_label",
            "blind_assignment_id",
            "reviewer_id",
        ):
            value = rating.get(field)
            if not _nonempty_string(value) or not IDENTIFIER_RE.fullmatch(value):
                errors.append(f"{rating_id}: {field} must be a stable identifier")
        if rating_id in seen_rating_ids:
            errors.append(f"{rating_id}: duplicate rating_id")
        seen_rating_ids.add(rating_id)

        assignment_id = rating.get("blind_assignment_id")
        if assignment_id in seen_assignments:
            errors.append(f"{rating_id}: duplicate blind_assignment_id {assignment_id}")
        if _nonempty_string(assignment_id):
            seen_assignments.add(assignment_id)
        if rating.get("blinded") is not True:
            errors.append(f"{rating_id}: blinded must be true")
        if rating.get("reviewer_native_attested") is not True:
            errors.append(f"{rating_id}: reviewer_native_attested must be true")

        case_id = rating.get("case_id")
        case = frozen_cases.get(case_id)
        if case is None:
            errors.append(f"{rating_id}: case_id {case_id!r} is not a frozen benchmark case")
        else:
            locale = rating.get("reviewer_locale")
            if (
                not _nonempty_string(locale)
                or locale.split("-", 1)[0].lower() != case["language"]
            ):
                errors.append(
                    f"{rating_id}: reviewer_locale must match case language {case['language']}"
                )

        model_label = rating.get("opaque_model_label")
        if model_label not in label_set:
            errors.append(
                f"{rating_id}: opaque_model_label {model_label!r} was not predeclared"
            )
        review_round = rating.get("review_round")
        if review_round not in {"initial", "adjudication", "repeat"}:
            errors.append(f"{rating_id}: review_round is invalid")
        repeat_of = rating.get("repeat_of_rating_id")
        if review_round == "repeat":
            if not _nonempty_string(repeat_of) or not IDENTIFIER_RE.fullmatch(repeat_of):
                errors.append(f"{rating_id}: repeat rating requires repeat_of_rating_id")
            repeats.append(rating)
        elif repeat_of is not None:
            errors.append(f"{rating_id}: only repeat ratings may set repeat_of_rating_id")

        axes = rating.get("axes")
        if not isinstance(axes, dict):
            errors.append(f"{rating_id}: axes must be an object")
        else:
            missing_axes = sorted(set(RATING_AXES) - set(axes))
            unknown_axes = sorted(set(axes) - set(RATING_AXES))
            if missing_axes:
                errors.append(f"{rating_id}: axes missing {missing_axes}")
            if unknown_axes:
                errors.append(f"{rating_id}: axes has unknown fields {unknown_axes}")
            for axis in RATING_AXES:
                if axis in axes and not isinstance(axes[axis], bool):
                    errors.append(f"{rating_id}: axes.{axis} must be boolean")
        if rating.get("damage_severity") not in DAMAGE_SEVERITIES:
            errors.append(
                f"{rating_id}: damage_severity must be one of {list(DAMAGE_SEVERITIES)}"
            )
        if not _nonempty_string(rating.get("reason")):
            errors.append(f"{rating_id}: reason must be non-empty")

        if case_id in frozen_cases and model_label in label_set:
            pair = (case_id, model_label)
            if review_round == "initial":
                initial_by_pair[pair].append(rating)
            elif review_round == "adjudication":
                adjudication_by_pair[pair].append(rating)

    expected_pairs = {
        (case_id, label) for case_id in frozen_cases for label in label_set
    }
    all_initials: list[dict[str, Any]] = []
    for pair in sorted(expected_pairs):
        initials = initial_by_pair.get(pair, [])
        adjudications = adjudication_by_pair.get(pair, [])
        if len(initials) != 2:
            errors.append(
                f"rating pair {pair} has {len(initials)} initial ratings, expected exactly 2"
            )
            continue
        all_initials.extend(initials)
        initial_reviewers = {rating.get("reviewer_id") for rating in initials}
        if len(initial_reviewers) != 2:
            errors.append(f"rating pair {pair} requires two distinct native initial reviewers")

        signatures = [_rating_signature(rating) for rating in initials]
        disagreement = None not in signatures and signatures[0] != signatures[1]
        if disagreement and len(adjudications) != 1:
            errors.append(
                f"rating pair {pair} disagrees and requires exactly one third-reviewer adjudication"
            )
        if not disagreement and adjudications:
            errors.append(f"rating pair {pair} has adjudication without an initial disagreement")
        if len(adjudications) == 1:
            adjudicator = adjudications[0].get("reviewer_id")
            if adjudicator in initial_reviewers:
                errors.append(
                    f"rating pair {pair} adjudicator must be distinct from both initial reviewers"
                )

    unexpected_initial_pairs = sorted(set(initial_by_pair) - expected_pairs)
    unexpected_adjudication_pairs = sorted(set(adjudication_by_pair) - expected_pairs)
    if unexpected_initial_pairs:
        errors.append(f"unexpected initial rating pairs {unexpected_initial_pairs}")
    if unexpected_adjudication_pairs:
        errors.append(f"unexpected adjudication rating pairs {unexpected_adjudication_pairs}")

    initial_by_id = {
        rating["rating_id"]: rating
        for rating in all_initials
        if _nonempty_string(rating.get("rating_id"))
    }
    repeated_targets: Counter[str] = Counter()
    for repeat in repeats:
        repeat_id = repeat.get("rating_id")
        target_id = repeat.get("repeat_of_rating_id")
        target = initial_by_id.get(target_id)
        if target is None:
            errors.append(
                f"{repeat_id}: repeat_of_rating_id {target_id!r} is not a valid initial rating"
            )
            continue
        repeated_targets[target_id] += 1
        for field in ("case_id", "opaque_model_label", "reviewer_id"):
            if repeat.get(field) != target.get(field):
                errors.append(f"{repeat_id}: repeat must preserve initial {field}")
        if repeat.get("blind_assignment_id") == target.get("blind_assignment_id"):
            errors.append(f"{repeat_id}: repeat requires a new blind_assignment_id")
    duplicate_repeat_targets = sorted(
        target_id for target_id, count in repeated_targets.items() if count > 1
    )
    if duplicate_repeat_targets:
        errors.append(f"initial ratings repeated more than once {duplicate_repeat_targets}")

    required_repeat_count = math.ceil(len(all_initials) * 0.10)
    actual_repeat_count = len(repeated_targets)
    if actual_repeat_count < required_repeat_count:
        errors.append(
            f"repeat coverage is {actual_repeat_count}/{len(all_initials)}, minimum {required_repeat_count}/{len(all_initials)}"
        )

    initials_by_reviewer: Counter[str] = Counter()
    repeats_by_reviewer: Counter[str] = Counter()
    initials_by_language_model: Counter[tuple[str, str]] = Counter()
    repeats_by_language_model: Counter[tuple[str, str]] = Counter()
    for initial in all_initials:
        reviewer_id = initial.get("reviewer_id")
        case = frozen_cases.get(initial.get("case_id"))
        model_label = initial.get("opaque_model_label")
        if _nonempty_string(reviewer_id):
            initials_by_reviewer[reviewer_id] += 1
        if case is not None and model_label in label_set:
            initials_by_language_model[(case["language"], model_label)] += 1
    for target_id in repeated_targets:
        target = initial_by_id.get(target_id)
        if target is None:
            continue
        reviewer_id = target.get("reviewer_id")
        case = frozen_cases.get(target.get("case_id"))
        model_label = target.get("opaque_model_label")
        if _nonempty_string(reviewer_id):
            repeats_by_reviewer[reviewer_id] += 1
        if case is not None and model_label in label_set:
            repeats_by_language_model[(case["language"], model_label)] += 1

    reviewer_coverage: dict[str, dict[str, int]] = {}
    for reviewer_id, initial_count in sorted(initials_by_reviewer.items()):
        minimum = math.ceil(initial_count * 0.10)
        repeated = repeats_by_reviewer[reviewer_id]
        reviewer_coverage[reviewer_id] = {
            "initial": initial_count,
            "repeated": repeated,
            "minimum": minimum,
        }
        if repeated < minimum:
            errors.append(
                f"repeat coverage for reviewer {reviewer_id} is {repeated}/{initial_count}, minimum {minimum}/{initial_count}"
            )

    language_model_coverage: dict[str, dict[str, int]] = {}
    for key, initial_count in sorted(initials_by_language_model.items()):
        minimum = math.ceil(initial_count * 0.10)
        repeated = repeats_by_language_model[key]
        display_key = f"{key[0]}:{key[1]}"
        language_model_coverage[display_key] = {
            "initial": initial_count,
            "repeated": repeated,
            "minimum": minimum,
        }
        if repeated < minimum:
            errors.append(
                f"repeat coverage for language/model {display_key} is {repeated}/{initial_count}, minimum {minimum}/{initial_count}"
            )
    if errors:
        raise BenchmarkValidationError(errors)
    return {
        "initial_rating_count": len(all_initials),
        "adjudication_rating_count": sum(len(rows) for rows in adjudication_by_pair.values()),
        "repeat_rating_count": len(repeats),
        "distinct_repeated_initial_count": actual_repeat_count,
        "required_repeat_count": required_repeat_count,
        "repeat_coverage_by_reviewer": reviewer_coverage,
        "repeat_coverage_by_language_model": language_model_coverage,
    }


def _parse_source_spec(spec: str) -> tuple[str, str, Path]:
    try:
        left, raw_path = spec.split("=", 1)
        role, name = left.split(":", 1)
    except ValueError as exc:
        raise BenchmarkValidationError(
            [f"invalid leakage source {spec!r}; expected ROLE:NAME=PATH"]
        ) from exc
    if role not in LEAKAGE_ROLES:
        raise BenchmarkValidationError(
            [f"invalid leakage role {role!r}; expected one of {list(LEAKAGE_ROLES)}"]
        )
    if not IDENTIFIER_RE.fullmatch(name):
        raise BenchmarkValidationError([f"invalid leakage source name {name!r}"])
    path = Path(raw_path).expanduser().resolve()
    if not path.is_file():
        raise BenchmarkValidationError([f"missing leakage source: {path}"])
    return role, name, path


def parse_leakage_sources(specs: Sequence[str]) -> list[LeakageSource]:
    sources: list[LeakageSource] = []
    seen: set[tuple[str, str]] = set()
    for spec in specs:
        role, name, path = _parse_source_spec(spec)
        key = (role, name)
        if key in seen:
            raise BenchmarkValidationError([f"duplicate leakage source identity: {role}:{name}"])
        seen.add(key)
        sources.append(LeakageSource(role, name, path, sha256_file(path)))
    return sorted(sources, key=lambda source: (source.role, source.name))


def _walk_source_values(
    value: Any, *, allow_string_family: bool = False
) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for key in ("rows", "records", "families", "items"):
            nested = value.get(key)
            if isinstance(nested, (dict, list)):
                yield from _walk_source_values(
                    nested, allow_string_family=allow_string_family
                )
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, (dict, list)):
                yield from _walk_source_values(
                    item, allow_string_family=allow_string_family
                )
            elif isinstance(item, str) and allow_string_family:
                yield {"semantic_family_id": item}
    elif isinstance(value, str) and allow_string_family:
        yield {"semantic_family_id": value}


def _has_valid_blocked_family_clearance(
    row: dict[str, Any], source: LeakageSource
) -> bool:
    provenance = row.get("provenance")
    clearances = (
        provenance.get("blocked_family_clearances")
        if isinstance(provenance, dict)
        else None
    )
    if not isinstance(clearances, list):
        return False
    matching = [
        clearance
        for clearance in clearances
        if isinstance(clearance, dict)
        and clearance.get("registry_sha256") == source.sha256
    ]
    if len(matching) != 1:
        return False
    clearance = matching[0]
    author = provenance.get("native_author")
    author_id = author.get("reviewer_id") if isinstance(author, dict) else None
    reviewer_id = clearance.get("reviewer_id")
    return (
        set(clearance) == BLOCKED_FAMILY_CLEARANCE_FIELDS
        and clearance.get("candidate_semantic_family_id")
        == row.get("semantic_family_id")
        and _nonempty_string(reviewer_id)
        and bool(IDENTIFIER_RE.fullmatch(reviewer_id))
        and reviewer_id != author_id
        and clearance.get("independent_of_author") is True
        and clearance.get("status") == "cleared"
        and _valid_review_date(clearance.get("reviewed_on"))
    )


def exact_leakage_errors(
    rows: Sequence[dict[str, Any]], sources: Sequence[LeakageSource]
) -> list[str]:
    candidate_inputs = {
        normalize_text(row["asr_input"]): row["case_id"] for row in rows
    }
    candidate_outputs = {
        normalize_text(row["gold_output"]): row["case_id"] for row in rows
    }
    candidate_input_hashes = {
        sha256_bytes(value.encode("utf-8")): case_id
        for value, case_id in candidate_inputs.items()
    }
    candidate_output_hashes = {
        sha256_bytes(value.encode("utf-8")): case_id
        for value, case_id in candidate_outputs.items()
    }
    candidate_families = {row["semantic_family_id"]: row["case_id"] for row in rows}
    text_fields = ("asr_input", "input", "gold_output", "output", "expected_output")
    family_fields = ("semantic_family_id", "family_id", "origin_family_id")
    errors: list[str] = []
    for source in sources:
        values = _read_json_or_jsonl(source.path)
        extractable_values = 0
        extractable_families = 0
        extractable_hashes = 0
        for value in values:
            for record in _walk_source_values(
                value, allow_string_family=source.role == "blocked_family_registry"
            ):
                for field in text_fields:
                    text = record.get(field)
                    if not _nonempty_string(text):
                        continue
                    extractable_values += 1
                    normalized = normalize_text(text)
                    if normalized in candidate_inputs:
                        errors.append(
                            f"{candidate_inputs[normalized]}: input exact-leaks from {source.role}:{source.name} field {field}"
                        )
                    if normalized in candidate_outputs:
                        errors.append(
                            f"{candidate_outputs[normalized]}: gold exact-leaks from {source.role}:{source.name} field {field}"
                        )
                has_normalized_hash = (
                    "normalized_text_sha256" in record or "field_kind" in record
                )
                if source.role == "blocked_text_hash_registry" and has_normalized_hash:
                    digest = record.get("normalized_text_sha256")
                    field_kind = record.get("field_kind")
                    if (
                        not isinstance(digest, str)
                        or not SHA256_RE.fullmatch(digest)
                        or field_kind not in {"input", "output"}
                    ):
                        errors.append(
                            f"leakage source {source.role}:{source.name} has malformed normalized text hash"
                        )
                    else:
                        extractable_values += 1
                        extractable_hashes += 1
                        if digest in candidate_input_hashes:
                            errors.append(
                                f"{candidate_input_hashes[digest]}: input exact-hash-leaks from {source.role}:{source.name} field {field_kind}"
                            )
                        if digest in candidate_output_hashes:
                            errors.append(
                                f"{candidate_output_hashes[digest]}: gold exact-hash-leaks from {source.role}:{source.name} field {field_kind}"
                            )
                for field in family_fields:
                    family_id = record.get(field)
                    if _nonempty_string(family_id):
                        extractable_values += 1
                        extractable_families += 1
                    if family_id in candidate_families:
                        errors.append(
                            f"{candidate_families[family_id]}: family {family_id} blocked by {source.role}:{source.name}"
                        )
        if source.role == "blocked_family_registry":
            if not extractable_families:
                errors.append(
                    f"leakage source {source.role}:{source.name} has no family records"
                )
            else:
                for row in rows:
                    if not _has_valid_blocked_family_clearance(row, source):
                        errors.append(
                            f"{row['case_id']}: missing valid blocked-family clearance for {source.role}:{source.name} SHA-256 {source.sha256}"
                        )
        if source.role == "blocked_text_hash_registry" and not extractable_hashes:
            errors.append(
                f"leakage source {source.role}:{source.name} has no normalized hash records"
            )
        if extractable_values == 0:
            errors.append(
                f"leakage source {source.role}:{source.name} has no recognized text, hash, or family fields"
            )
    return sorted(set(errors))


def validate_leakage_receipt(
    receipt_path: Path,
    *,
    rows: Sequence[dict[str, Any]],
    sources: Sequence[LeakageSource],
) -> dict[str, Any]:
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    errors: list[str] = []
    if not isinstance(receipt, dict):
        raise BenchmarkValidationError([f"leakage receipt must be an object: {receipt_path}"])
    if receipt.get("schema_version") != "eg1-multilingual-leakage-receipt-v1":
        errors.append("leakage receipt schema_version is invalid")
    if receipt.get("benchmark_content_sha256") != benchmark_content_sha256(rows):
        errors.append("leakage receipt is not bound to this benchmark content hash")
    if not _nonempty_string(receipt.get("screening_policy_id")):
        errors.append("leakage receipt screening_policy_id is required")

    expected_sources = {
        (source.role, source.name): source.sha256 for source in sources
    }
    entries = receipt.get("sources")
    if not isinstance(entries, list):
        errors.append("leakage receipt sources must be an array")
        entries = []
    observed: dict[tuple[str, str], str] = {}
    for index, entry in enumerate(entries, start=1):
        if not isinstance(entry, dict):
            errors.append(f"leakage receipt source {index} must be an object")
            continue
        key = (entry.get("role"), entry.get("name"))
        if key in observed:
            errors.append(f"leakage receipt duplicates source {key}")
        observed[key] = entry.get("sha256")
        methods = entry.get("methods")
        if not isinstance(methods, dict):
            errors.append(f"leakage receipt source {key} missing methods")
            continue
        missing_methods = sorted(set(REQUIRED_SCREEN_METHODS) - set(methods))
        if missing_methods:
            errors.append(f"leakage receipt source {key} missing methods {missing_methods}")
        for method_name in REQUIRED_SCREEN_METHODS:
            result = methods.get(method_name)
            if not isinstance(result, dict):
                continue
            if result.get("status") != "pass" or result.get("violations") != 0:
                errors.append(f"leakage receipt source {key} method {method_name} did not pass")
            if method_name != "exact_normalized":
                threshold = result.get("threshold")
                maximum = result.get("max_observed")
                if (
                    not isinstance(threshold, (int, float))
                    or isinstance(threshold, bool)
                    or not 0 <= threshold <= 1
                ):
                    errors.append(
                        f"leakage receipt source {key} method {method_name} has invalid threshold"
                    )
                if (
                    not isinstance(maximum, (int, float))
                    or isinstance(maximum, bool)
                    or not 0 <= maximum <= 1
                ):
                    errors.append(
                        f"leakage receipt source {key} method {method_name} has invalid max_observed"
                    )
                elif isinstance(threshold, (int, float)) and maximum > threshold:
                    errors.append(
                        f"leakage receipt source {key} method {method_name} exceeds threshold"
                    )
    if observed != expected_sources:
        errors.append(
            f"leakage receipt source inventory/hash mismatch: expected {expected_sources}, observed {observed}"
        )
    if errors:
        raise BenchmarkValidationError(errors)
    return receipt


def _git_committed_file_bytes(
    execution_head: str, relative_path: str
) -> bytes | None:
    try:
        result = subprocess.run(
            ["git", "show", f"{execution_head}:{relative_path}"],
            cwd=REPO_ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout


def _repo_path(relative_path: Any) -> Path | None:
    if not isinstance(relative_path, str) or not relative_path:
        return None
    candidate = (REPO_ROOT / relative_path).resolve()
    try:
        candidate.relative_to(REPO_ROOT.resolve())
    except ValueError:
        return None
    return candidate


def validate_blocked_registry_receipt(
    receipt_path: Path,
    *,
    sources: Sequence[LeakageSource],
) -> dict[str, Any]:
    """Authenticate the sealed Type B registry and its two distinct source roles."""
    receipt = _read_json_object(receipt_path, "blocked-registry receipt")
    errors: list[str] = []
    if set(receipt) != BLOCKED_REGISTRY_RECEIPT_FIELDS:
        errors.append("blocked-registry receipt top-level schema is invalid")
    if receipt.get("schema_version") != "eg1-type-b-v2-blocked-registry-receipt-v1":
        errors.append("blocked-registry receipt schema_version is invalid")
    if receipt.get("status") != (
        "sources_sealed_all_provisional_replaced_authorship_blocked"
    ):
        errors.append("blocked-registry receipt status is invalid")
    if receipt.get("registry_id") != "eg1-type-b-v2-blocked-registry-2026-07-15":
        errors.append("blocked-registry receipt registry_id is invalid")
    if receipt.get("normalization_policy_id") != (
        "nfkc-casefold-alnum-whitespace-v1"
    ):
        errors.append("blocked-registry receipt normalization policy is invalid")
    if receipt.get("publication") != "exclusive_bundle_receipt_last":
        errors.append("blocked-registry receipt publication status is invalid")
    if receipt.get("counts") != BLOCKED_REGISTRY_COUNTS:
        errors.append("blocked-registry receipt aggregate counts are invalid")
    if (
        receipt.get("candidate_clearance_contract")
        != BLOCKED_REGISTRY_CANDIDATE_CLEARANCE_CONTRACT
    ):
        errors.append("blocked-registry candidate clearance contract is invalid")
    if receipt.get("decision_summary") != {
        "reason_code": "semantic_family_clearance_not_proven",
        "replace": 23,
        "retain": 0,
        "same_cell_reserves_bound": 23,
    }:
        errors.append("blocked-registry receipt decision summary is invalid")
    if receipt.get("privacy") != {
        "private_source_text_published": False,
        "private_source_row_ids_published_raw": False,
        "safe_provisional_case_ids_published": True,
        "other_source_row_ids_published_raw": False,
        "metadata_only": True,
    }:
        errors.append("blocked-registry receipt privacy contract is invalid")
    if receipt.get("authorship_gate") != {
        "candidate_model_output_seen": False,
        "fresh_benchmark_prose_authored": False,
        "fresh_authorship_authorized": False,
        "fresh_slots_required": 1890,
    }:
        errors.append("blocked-registry receipt authorship gate is invalid")

    execution_head = receipt.get("execution_git_head")
    if not isinstance(execution_head, str) or not re.fullmatch(
        r"[0-9a-f]{40}", execution_head
    ):
        errors.append("blocked-registry receipt execution_git_head is invalid")
        execution_head = ""

    contract_relative = "scripts/eval/contracts/eg1_type_b_v2_blocked_registry_v1.json"
    builder_relative = "scripts/eval/build_eg1_type_b_v2_blocked_registry.py"
    allocation_relative = "scripts/eval/contracts/eg1_type_b_v2_allocation_v1.json"
    allocator_relative = "scripts/eval/build_eg1_type_b_v2_manifest.py"
    committed_controls: dict[str, bytes | None] = {}
    for relative_path in (
        contract_relative,
        builder_relative,
        allocation_relative,
        allocator_relative,
    ):
        value = (
            _git_committed_file_bytes(execution_head, relative_path)
            if execution_head
            else None
        )
        committed_controls[relative_path] = value
        if value is None:
            errors.append(
                f"blocked-registry execution commit does not contain {relative_path}"
            )

    contract_bytes = committed_controls[contract_relative]
    contract_sha = sha256_bytes(contract_bytes) if contract_bytes is not None else None
    try:
        contract = (
            _parse_json_object_bytes(
                contract_bytes, "blocked-registry producing contract"
            )
            if contract_bytes is not None
            else {}
        )
    except BenchmarkValidationError as exc:
        errors.extend(exc.errors)
        contract = {}
    expected_contract_receipt = {
        "path": contract_relative,
        "sha256": contract_sha,
        "schema_version": "eg1-type-b-v2-blocked-registry-contract-v1",
    }
    if receipt.get("contract") != expected_contract_receipt:
        errors.append("blocked-registry receipt contract binding is invalid")
    if set(contract) != BLOCKED_REGISTRY_CONTRACT_FIELDS:
        errors.append("blocked-registry tracked contract schema is invalid")
    if contract.get("schema_version") != expected_contract_receipt["schema_version"]:
        errors.append("blocked-registry tracked contract schema_version is invalid")
    for field in ("registry_id", "normalization_policy_id", "counts"):
        if contract.get(field) != receipt.get(field):
            errors.append(f"blocked-registry tracked contract {field} mismatch")
    if contract.get("status") != "sealed":
        errors.append("blocked-registry tracked contract status is invalid")
    if (
        contract.get("candidate_clearance_contract")
        != BLOCKED_REGISTRY_CANDIDATE_CLEARANCE_CONTRACT
    ):
        errors.append("blocked-registry tracked clearance contract is invalid")

    builder_bytes = committed_controls[builder_relative]
    builder_sha = sha256_bytes(builder_bytes) if builder_bytes is not None else None
    if receipt.get("builder") != {
        "path": builder_relative,
        "sha256": builder_sha,
    }:
        errors.append("blocked-registry receipt builder binding is invalid")

    allocation_bytes = committed_controls[allocation_relative]
    allocation_sha = (
        sha256_bytes(allocation_bytes) if allocation_bytes is not None else None
    )
    try:
        allocation_contract = (
            _parse_json_object_bytes(
                allocation_bytes, "Type B producing allocation contract"
            )
            if allocation_bytes is not None
            else {}
        )
    except BenchmarkValidationError as exc:
        errors.extend(exc.errors)
        allocation_contract = {}
    if allocation_contract.get("schema_version") != "eg1-type-b-v2-allocation-v1":
        errors.append("blocked-registry producing allocation contract is invalid")
    allocator_bytes = committed_controls[allocator_relative]
    allocator_sha = (
        sha256_bytes(allocator_bytes) if allocator_bytes is not None else None
    )
    expected_allocator = {
        "allocation_contract_path": allocation_relative,
        "allocation_contract_sha256": allocation_sha,
        "builder_path": allocator_relative,
        "builder_sha256": allocator_sha,
    }
    if receipt.get("allocator") != expected_allocator:
        errors.append("blocked-registry receipt allocator binding is invalid")
    if contract.get("allocator") != expected_allocator:
        errors.append("blocked-registry tracked allocator binding is invalid")

    contract_artifacts = contract.get("expected_validator_artifacts")
    if not isinstance(contract_artifacts, dict) or set(contract_artifacts) != set(
        BLOCKED_REGISTRY_ARTIFACTS
    ):
        errors.append("blocked-registry tracked artifact contract is invalid")
        contract_artifacts = {}

    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != set(
        BLOCKED_REGISTRY_ARTIFACTS
    ):
        errors.append("blocked-registry receipt artifact inventory is invalid")
        artifacts = {}
    live_artifacts: dict[str, list[Any]] = {}
    for artifact_name, expected in BLOCKED_REGISTRY_ARTIFACTS.items():
        artifact = artifacts.get(artifact_name)
        if not isinstance(artifact, dict) or set(artifact) != {
            "sha256",
            "row_count",
            "validator_source_role",
        }:
            errors.append(
                f"blocked-registry receipt artifact {artifact_name} schema is invalid"
            )
            continue
        if artifact.get("row_count") != expected["row_count"]:
            errors.append(
                f"blocked-registry receipt artifact {artifact_name} row count is invalid"
            )
        if artifact.get("validator_source_role") != expected["role"]:
            errors.append(
                f"blocked-registry receipt artifact {artifact_name} role is invalid"
            )
        digest = artifact.get("sha256")
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            errors.append(
                f"blocked-registry receipt artifact {artifact_name} SHA-256 is invalid"
            )
        if artifact_name in contract_artifacts and artifact != contract_artifacts.get(
            artifact_name
        ):
            errors.append(
                f"blocked-registry receipt artifact {artifact_name} differs from tracked contract"
            )
        artifact_path = receipt_path.parent / artifact_name
        if not artifact_path.is_file():
            errors.append(f"missing blocked-registry artifact: {artifact_path}")
            continue
        if sha256_file(artifact_path) != digest:
            errors.append(
                f"blocked-registry artifact {artifact_name} differs from receipt"
            )
        try:
            live_artifact_rows = _read_json_or_jsonl(artifact_path)
        except BenchmarkValidationError as exc:
            errors.extend(exc.errors)
            continue
        if len(live_artifact_rows) != expected["row_count"]:
            errors.append(
                f"blocked-registry artifact {artifact_name} has invalid live row count"
            )
        live_artifacts[artifact_name] = live_artifact_rows

    coverage_by_source: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in live_artifacts.get("source_coverage.jsonl", []):
        if not isinstance(row, dict) or not _nonempty_string(row.get("source_name")):
            errors.append("blocked-registry source coverage row is invalid")
            continue
        coverage_by_source[row["source_name"]].append(row)

    contract_sources = contract.get("sources")
    receipt_sources = receipt.get("sources")
    if not isinstance(contract_sources, list) or len(contract_sources) != 4:
        errors.append("blocked-registry tracked source inventory is invalid")
        contract_sources = []
    if not isinstance(receipt_sources, list) or len(receipt_sources) != 4:
        errors.append("blocked-registry receipt source inventory is invalid")
        receipt_sources = []
    contract_sources_by_name = {
        value.get("name"): value
        for value in contract_sources
        if isinstance(value, dict) and _nonempty_string(value.get("name"))
    }
    producing_source_hashes = {
        value.get("path"): value.get("sha256")
        for value in contract_sources
        if isinstance(value, dict)
        and _nonempty_string(value.get("path"))
        and isinstance(value.get("sha256"), str)
    }
    if allocation_contract.get("source_sha256") != producing_source_hashes:
        errors.append(
            "blocked-registry producing allocation source inventory differs from contract"
        )
    receipt_source_names: list[str] = []
    for source_receipt in receipt_sources:
        if not isinstance(source_receipt, dict) or set(source_receipt) != (
            BLOCKED_REGISTRY_SOURCE_RECEIPT_FIELDS
        ):
            errors.append("blocked-registry receipt source schema is invalid")
            continue
        name = source_receipt.get("name")
        if not _nonempty_string(name):
            errors.append("blocked-registry receipt source name is invalid")
            continue
        receipt_source_names.append(name)
        expected_source = contract_sources_by_name.get(name)
        if expected_source is None:
            errors.append(f"blocked-registry receipt contains unknown source {name}")
            continue
        expected_core = {
            "role": expected_source.get("role"),
            "name": expected_source.get("name"),
            "path": expected_source.get("path"),
            "sha256": expected_source.get("sha256"),
            "expected_sha256": expected_source.get("sha256"),
            "row_count": expected_source.get("row_count"),
        }
        if {field: source_receipt.get(field) for field in expected_core} != expected_core:
            errors.append(f"blocked-registry receipt source {name} provenance mismatch")
        coverage_rows = coverage_by_source.get(name, [])
        empty_digest = sha256_bytes(b"")
        expected_coverage = {
            "unique_row_ids": len(
                {
                    row.get("source_row_id_sha256")
                    for row in coverage_rows
                    if _nonempty_string(row.get("source_row_id_sha256"))
                }
            ),
            "blocked_family_count": len(
                {
                    row.get("blocked_family_id")
                    for row in coverage_rows
                    if _nonempty_string(row.get("blocked_family_id"))
                }
            ),
            "unique_normalized_input_hashes": len(
                {
                    row.get("normalized_input_sha256")
                    for row in coverage_rows
                    if _nonempty_string(row.get("normalized_input_sha256"))
                }
            ),
            "unique_normalized_output_hashes": len(
                {
                    row.get("normalized_output_sha256")
                    for row in coverage_rows
                    if _nonempty_string(row.get("normalized_output_sha256"))
                }
            ),
            "normalized_empty_input_rows": sum(
                row.get("normalized_input_sha256") == empty_digest
                for row in coverage_rows
            ),
            "normalized_empty_output_rows": sum(
                row.get("normalized_output_sha256") == empty_digest
                for row in coverage_rows
            ),
        }
        if len(coverage_rows) != expected_source.get("row_count"):
            errors.append(f"blocked-registry receipt source {name} row coverage mismatch")
        for count_field, expected_value in expected_coverage.items():
            observed_value = source_receipt.get(count_field)
            if type(observed_value) is not int or observed_value != expected_value:
                errors.append(
                    f"blocked-registry receipt source {name} {count_field} differs from source coverage"
                )
        source_path = _repo_path(expected_source.get("path"))
        if source_path is None or not source_path.is_file():
            errors.append(f"blocked-registry source {name} path is invalid")
        else:
            if sha256_file(source_path) != expected_source.get("sha256"):
                errors.append(f"blocked-registry source {name} differs from contract")
            try:
                source_rows = _read_json_or_jsonl(source_path)
            except BenchmarkValidationError as exc:
                errors.extend(exc.errors)
            else:
                if len(source_rows) != expected_source.get("row_count"):
                    errors.append(f"blocked-registry source {name} row count drifted")
    if set(receipt_source_names) != set(contract_sources_by_name) or len(
        receipt_source_names
    ) != len(set(receipt_source_names)):
        errors.append("blocked-registry receipt source inventory differs from contract")
    if receipt_sources:
        for field, aggregate_field in (
            ("normalized_empty_input_rows", "normalized_empty_input_rows"),
            ("normalized_empty_output_rows", "normalized_empty_output_rows"),
        ):
            values = [
                value.get(field)
                for value in receipt_sources
                if isinstance(value, dict) and isinstance(value.get(field), int)
            ]
            if len(values) != 4 or sum(values) != BLOCKED_REGISTRY_COUNTS[aggregate_field]:
                errors.append(
                    f"blocked-registry receipt source {field} totals are invalid"
                )

    role_sources: dict[str, list[LeakageSource]] = {
        role: [source for source in sources if source.role == role]
        for role in ("blocked_family_registry", "blocked_text_hash_registry")
    }
    for role, matching in role_sources.items():
        if len(matching) != 1:
            errors.append(
                f"blocked-registry validation requires exactly one {role} source"
            )

    live_records: dict[str, list[Any]] = {}
    for artifact_name, expected in BLOCKED_REGISTRY_ARTIFACTS.items():
        role = expected["role"]
        if role is None or len(role_sources[role]) != 1:
            continue
        source = role_sources[role][0]
        artifact = artifacts.get(artifact_name)
        expected_path = (receipt_path.parent / artifact_name).resolve()
        if source.path.resolve() != expected_path:
            errors.append(f"live {role} source is not the sealed bundle artifact")
        if isinstance(artifact, dict) and artifact.get("sha256") != source.sha256:
            errors.append(f"live {role} source does not match blocked-registry receipt")
        try:
            records = _read_json_or_jsonl(source.path)
        except BenchmarkValidationError as exc:
            errors.extend(exc.errors)
            records = []
        live_records[role] = records
        if len(records) != expected["row_count"]:
            errors.append(
                f"live {role} source row count is {len(records)}, expected {expected['row_count']}"
            )

    family_records = live_records.get("blocked_family_registry", [])
    family_ids = [
        record.get("semantic_family_id") if isinstance(record, dict) else None
        for record in family_records
    ]
    if family_records and (
        not all(_nonempty_string(value) for value in family_ids)
        or len(set(family_ids)) != len(family_ids)
    ):
        errors.append(
            "live blocked_family_registry must contain unique extractable family records"
        )
    if not family_records:
        errors.append("live blocked_family_registry contains zero family records")

    hash_records = live_records.get("blocked_text_hash_registry", [])
    hash_keys: list[tuple[Any, Any]] = []
    for record in hash_records:
        if not isinstance(record, dict):
            errors.append("live blocked_text_hash_registry contains a non-object record")
            continue
        digest = record.get("normalized_text_sha256")
        field_kind = record.get("field_kind")
        if (
            not isinstance(digest, str)
            or not SHA256_RE.fullmatch(digest)
            or field_kind not in {"input", "output"}
        ):
            errors.append("live blocked_text_hash_registry contains a malformed hash record")
            continue
        hash_keys.append((field_kind, digest))
    if hash_records and len(set(hash_keys)) != len(hash_records):
        errors.append("live blocked_text_hash_registry contains duplicate hash records")
    if not hash_records:
        errors.append("live blocked_text_hash_registry contains zero hash records")

    if errors:
        raise BenchmarkValidationError(errors)
    return receipt


def _nested_counts(rows: Sequence[dict[str, Any]], fields: Sequence[str]) -> dict[str, Any]:
    root: dict[str, Any] = {}
    counter = Counter(tuple(row[field] for field in fields) for row in rows)
    for keys, count in sorted(counter.items()):
        cursor = root
        for key in keys[:-1]:
            cursor = cursor.setdefault(key, {})
        cursor[keys[-1]] = count
    return root


def build_manifest(
    *,
    rows: Sequence[dict[str, Any]],
    corpus_path: Path,
    sources: Sequence[LeakageSource],
    receipt_path: Path | None,
    release_profile: bool,
    blocked_registry_receipt_path: Path | None = None,
    frozen_cases_per_cell: int = DEFAULT_FROZEN_CASES_PER_CELL,
    power_plan_path: Path | None = None,
    discordance_receipt_path: Path | None = None,
    development_corpus_path: Path | None = None,
    development_benchmark_manifest_path: Path | None = None,
    development_comparison_manifest_path: Path | None = None,
) -> dict[str, Any]:
    script_dir = Path(__file__).resolve().parent
    schema_path = script_dir / "multilingual_benchmark_v2.schema.json"
    rating_schema_path = script_dir / "multilingual_benchmark_v2_rating.schema.json"
    family_assignments = sorted(
        {row["semantic_family_id"]: row["split"] for row in rows}.items()
    )
    row_hashes = [
        {"case_id": row["case_id"], "sha256": sha256_bytes(canonical_json(row).encode("utf-8"))}
        for row in sorted(rows, key=lambda item: item["case_id"])
    ]
    list_counts = Counter(
        (
            row["split"],
            row["language"],
            row["requirements"]["formatting"]["list_contract"],
        )
        for row in rows
    )
    power_plan = (
        _read_json_object(power_plan_path, "power plan") if power_plan_path else {}
    )
    return {
        "schema_version": "eg1-multilingual-benchmark-manifest-v2",
        "validator_version": VALIDATOR_VERSION,
        "benchmark_schema_sha256": sha256_file(schema_path),
        "rating_schema_sha256": sha256_file(rating_schema_path),
        "corpus_source_sha256": sha256_file(corpus_path),
        "benchmark_content_sha256": benchmark_content_sha256(rows),
        "release_profile_enforced": release_profile,
        "release_profile_parameters": (
            {
                "development_cases_per_cell": DEVELOPMENT_CASES_PER_CELL,
                "frozen_cases_per_cell": frozen_cases_per_cell,
                "development_cases_per_language": release_counts(frozen_cases_per_cell)[
                    "development"
                ]["per_language"],
                "frozen_cases_per_language": release_counts(frozen_cases_per_cell)["frozen"][
                    "per_language"
                ],
            }
            if release_profile
            else None
        ),
        "power_plan_sha256": sha256_file(power_plan_path) if power_plan_path else None,
        "development_discordance_receipt_sha256": (
            sha256_file(discordance_receipt_path) if discordance_receipt_path else None
        ),
        "development_corpus_sha256": (
            sha256_file(development_corpus_path) if development_corpus_path else None
        ),
        "development_benchmark_manifest_sha256": (
            sha256_file(development_benchmark_manifest_path)
            if development_benchmark_manifest_path
            else None
        ),
        "development_comparison_manifest_sha256": (
            sha256_file(development_comparison_manifest_path)
            if development_comparison_manifest_path
            else None
        ),
        "comparison_binding": power_plan.get("comparison_binding"),
        "row_count": len(rows),
        "family_count": len(family_assignments),
        "family_assignment_sha256": sha256_bytes(
            canonical_json(family_assignments).encode("utf-8")
        ),
        "row_hashes": row_hashes,
        "counts": {
            "split_language": _nested_counts(rows, ("split", "language")),
            "split_language_domain": _nested_counts(rows, ("split", "language", "domain")),
            "split_language_behavior": _nested_counts(rows, ("split", "language", "behavior")),
            "split_language_behavior_domain": _nested_counts(
                rows, ("split", "language", "behavior", "domain")
            ),
            "split_language_difficulty": _nested_counts(rows, ("split", "language", "difficulty")),
            "split_language_safety": _nested_counts(rows, ("split", "language", "safety_risk")),
            "split_language_list_contract": _counter_to_nested(list_counts),
        },
        "leakage_sources": [
            {"role": source.role, "name": source.name, "sha256": source.sha256}
            for source in sources
        ],
        "leakage_receipt_sha256": sha256_file(receipt_path) if receipt_path else None,
        "blocked_registry_receipt_sha256": (
            sha256_file(blocked_registry_receipt_path)
            if blocked_registry_receipt_path
            else None
        ),
    }


def validate_benchmark_manifest_for_ratings(
    manifest_path: Path,
    *,
    rows: Sequence[dict[str, Any]],
    corpus_path: Path,
) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise BenchmarkValidationError(["benchmark manifest must be an object"])
    errors: list[str] = []
    release_parameters = manifest.get("release_profile_parameters")
    frozen_cases_per_cell = (
        release_parameters.get("frozen_cases_per_cell")
        if isinstance(release_parameters, dict)
        else None
    )
    if (
        not isinstance(frozen_cases_per_cell, int)
        or isinstance(frozen_cases_per_cell, bool)
        or frozen_cases_per_cell < MIN_FROZEN_CASES_PER_CELL
    ):
        errors.append("benchmark manifest release_profile_parameters are invalid")
        frozen_cases_per_cell = DEFAULT_FROZEN_CASES_PER_CELL
    try:
        validate_rows(
            rows,
            release_profile=True,
            frozen_cases_per_cell=frozen_cases_per_cell,
        )
    except BenchmarkValidationError as exc:
        errors.extend(exc.errors)
    expected_manifest_fields = {
        "schema_version",
        "validator_version",
        "benchmark_schema_sha256",
        "rating_schema_sha256",
        "corpus_source_sha256",
        "benchmark_content_sha256",
        "release_profile_enforced",
        "release_profile_parameters",
        "power_plan_sha256",
        "development_discordance_receipt_sha256",
        "development_corpus_sha256",
        "development_benchmark_manifest_sha256",
        "development_comparison_manifest_sha256",
        "comparison_binding",
        "row_count",
        "family_count",
        "family_assignment_sha256",
        "row_hashes",
        "counts",
        "leakage_sources",
        "leakage_receipt_sha256",
        "blocked_registry_receipt_sha256",
    }
    missing_fields = sorted(expected_manifest_fields - set(manifest))
    unknown_fields = sorted(set(manifest) - expected_manifest_fields)
    if missing_fields:
        errors.append(f"benchmark manifest missing fields {missing_fields}")
    if unknown_fields:
        errors.append(f"benchmark manifest has unknown fields {unknown_fields}")
    if manifest.get("schema_version") != "eg1-multilingual-benchmark-manifest-v2":
        errors.append("benchmark manifest schema_version is invalid")
    expected = build_manifest(
        rows=rows,
        corpus_path=corpus_path,
        sources=[],
        receipt_path=None,
        release_profile=True,
        frozen_cases_per_cell=frozen_cases_per_cell,
    )
    corpus_derived_fields = (
        "validator_version",
        "benchmark_schema_sha256",
        "rating_schema_sha256",
        "corpus_source_sha256",
        "benchmark_content_sha256",
        "release_profile_enforced",
        "release_profile_parameters",
        "row_count",
        "family_count",
        "family_assignment_sha256",
        "row_hashes",
        "counts",
    )
    for field in corpus_derived_fields:
        if manifest.get(field) != expected[field]:
            errors.append(f"benchmark manifest corpus-derived field {field} is invalid")
    receipt_sha = manifest.get("leakage_receipt_sha256")
    if not isinstance(receipt_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", receipt_sha):
        errors.append("rating workflow requires a benchmark with a leakage receipt")
    blocked_receipt_sha = manifest.get("blocked_registry_receipt_sha256")
    if not isinstance(blocked_receipt_sha, str) or not re.fullmatch(
        r"[0-9a-f]{64}", blocked_receipt_sha
    ):
        errors.append(
            "rating workflow requires a benchmark with a blocked-registry receipt"
        )
    power_plan_sha = manifest.get("power_plan_sha256")
    if not isinstance(power_plan_sha, str) or not re.fullmatch(
        r"[0-9a-f]{64}", power_plan_sha
    ):
        errors.append("rating workflow requires a benchmark with a sealed power plan")
    for field in (
        "development_discordance_receipt_sha256",
        "development_corpus_sha256",
        "development_benchmark_manifest_sha256",
        "development_comparison_manifest_sha256",
    ):
        value = manifest.get(field)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            errors.append(f"rating workflow requires valid {field}")
    comparison_binding = manifest.get("comparison_binding")
    if not isinstance(comparison_binding, dict) or set(comparison_binding) != set(
        COMPARISON_BINDING_FIELDS
    ):
        errors.append("benchmark manifest comparison_binding is invalid")
        comparison_binding = {}
    for field in COMPARISON_BINDING_FIELDS:
        value = comparison_binding.get(field)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            errors.append(f"benchmark manifest comparison_binding {field} is invalid")
    for field in (
        "development_benchmark_manifest_sha256",
        "development_comparison_manifest_sha256",
    ):
        if comparison_binding.get(field) != manifest.get(field):
            errors.append(f"benchmark manifest comparison_binding {field} mismatch")
    sources = manifest.get("leakage_sources")
    role_counts: Counter[str] = Counter()
    if not isinstance(sources, list):
        errors.append("benchmark manifest leakage_sources must be an array")
        sources = []
    for index, source in enumerate(sources, start=1):
        if not isinstance(source, dict) or set(source) != {"role", "name", "sha256"}:
            errors.append(f"benchmark manifest leakage source {index} is malformed")
            continue
        role = source.get("role")
        name = source.get("name")
        sha = source.get("sha256")
        if role not in LEAKAGE_ROLES:
            errors.append(f"benchmark manifest leakage source {index} has invalid role")
        else:
            role_counts[role] += 1
        if not _nonempty_string(name) or not IDENTIFIER_RE.fullmatch(name):
            errors.append(f"benchmark manifest leakage source {index} has invalid name")
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
            errors.append(f"benchmark manifest leakage source {index} has invalid sha256")
    missing_roles = sorted(REQUIRED_FROZEN_LEAKAGE_ROLES - set(role_counts))
    if missing_roles:
        errors.append(f"benchmark manifest missing leakage source roles {missing_roles}")
    for role in ("blocked_family_registry", "blocked_text_hash_registry"):
        if role_counts[role] != 1:
            errors.append(
                f"benchmark manifest requires exactly one leakage source role {role}"
            )
    if errors:
        raise BenchmarkValidationError(errors)
    return manifest


def validate_live_leakage_evidence_for_ratings(
    manifest: dict[str, Any],
    *,
    rows: Sequence[dict[str, Any]],
    source_specs: Sequence[str],
    receipt_path: Path,
    blocked_registry_receipt_path: Path,
) -> None:
    """Re-run and bind leakage checks at the final rating gate."""
    sources = parse_leakage_sources(source_specs)
    if not blocked_registry_receipt_path.is_file():
        raise BenchmarkValidationError(
            [f"missing blocked-registry receipt: {blocked_registry_receipt_path}"]
        )
    validate_blocked_registry_receipt(
        blocked_registry_receipt_path,
        sources=sources,
    )
    errors = exact_leakage_errors(rows, sources)
    if errors:
        raise BenchmarkValidationError(errors)
    if not receipt_path.is_file():
        raise BenchmarkValidationError([f"missing leakage receipt: {receipt_path}"])
    validate_leakage_receipt(receipt_path, rows=rows, sources=sources)

    current_inventory = sorted(
        [
            {"role": source.role, "name": source.name, "sha256": source.sha256}
            for source in sources
        ],
        key=lambda source: (source["role"], source["name"]),
    )
    sealed_inventory = manifest.get("leakage_sources")
    if isinstance(sealed_inventory, list):
        sealed_inventory = sorted(
            sealed_inventory,
            key=lambda source: (str(source.get("role")), str(source.get("name"))),
        )
    evidence_errors: list[str] = []
    if current_inventory != sealed_inventory:
        evidence_errors.append(
            "live leakage source inventory/hashes do not match sealed benchmark manifest"
        )
    if sha256_file(receipt_path) != manifest.get("leakage_receipt_sha256"):
        evidence_errors.append(
            "live leakage receipt does not match sealed benchmark manifest"
        )
    if sha256_file(blocked_registry_receipt_path) != manifest.get(
        "blocked_registry_receipt_sha256"
    ):
        evidence_errors.append(
            "live blocked-registry receipt does not match sealed benchmark manifest"
        )
    if evidence_errors:
        raise BenchmarkValidationError(evidence_errors)


def _rating_gate_git_output(*arguments: str) -> bytes:
    try:
        return subprocess.run(
            ["git", *arguments],
            cwd=REPO_ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except subprocess.CalledProcessError as error:
        raise BenchmarkValidationError(
            [f"cannot authenticate rating-gate Git state: {' '.join(arguments)}"]
        ) from error


def capture_development_authoring_import_closure(
    expected_head: str,
) -> dict[Path, bytes]:
    """Authenticate every local import before any authoring verifier code runs."""
    if not re.fullmatch(r"[0-9a-f]{40}", expected_head):
        raise BenchmarkValidationError(
            ["expected Git HEAD must be a lowercase 40-character SHA-1"]
        )
    actual_head = _rating_gate_git_output("rev-parse", "HEAD").decode().strip()
    if actual_head != expected_head:
        raise BenchmarkValidationError(
            ["Git HEAD differs from the predeclared rating-gate commit"]
        )
    if _rating_gate_git_output("status", "--porcelain", "--untracked-files=no"):
        raise BenchmarkValidationError(
            ["tracked worktree must be clean before loading the rating verifier"]
        )

    tracked_eval_python = {
        line
        for line in _rating_gate_git_output(
            "ls-tree", "-r", "--name-only", expected_head, "--", "scripts/eval"
        )
        .decode("utf-8")
        .splitlines()
        if line.endswith(".py")
    }
    live_eval_python = {
        str(path.relative_to(REPO_ROOT))
        for path in (REPO_ROOT / "scripts/eval").rglob("*.py")
    }
    untracked_python = sorted(live_eval_python - tracked_eval_python)
    if untracked_python:
        raise BenchmarkValidationError(
            [
                "untracked scripts/eval Python shadow(s) must be removed before "
                f"loading the rating verifier: {', '.join(untracked_python)}"
            ]
        )

    captured: dict[Path, bytes] = {}
    for path in DEVELOPMENT_AUTHORING_IMPORT_CLOSURE:
        try:
            relative = str(path.relative_to(REPO_ROOT))
        except ValueError as error:
            raise BenchmarkValidationError(
                [f"rating-gate import control is outside the repository: {path}"]
            ) from error
        if not path.is_file() or path.is_symlink():
            raise BenchmarkValidationError(
                [f"rating-gate import control is not a regular file: {relative}"]
            )
        try:
            committed = _rating_gate_git_output(
                "show", f"{expected_head}:{relative}"
            )
            live = path.read_bytes()
        except OSError as error:
            raise BenchmarkValidationError(
                [f"cannot read rating-gate import control: {relative}"]
            ) from error
        if live != committed:
            raise BenchmarkValidationError(
                [f"committed bytes differ from live rating-gate control: {relative}"]
            )
        captured[path] = committed
    return captured


def _load_committed_module(name: str, path: Path, source: bytes) -> Any:
    module = types.ModuleType(name)
    module.__file__ = str(path)
    module.__package__ = ""
    module.__spec__ = importlib.util.spec_from_loader(
        name, loader=None, origin=str(path)
    )
    sys.modules[name] = module
    exec(compile(source, str(path), "exec"), module.__dict__)
    return module


def load_development_authoring_verifier(expected_head: str) -> Any:
    """Load only the committed authoring verifier and its authenticated imports."""
    captured = capture_development_authoring_import_closure(expected_head)
    current_module = sys.modules[__name__]
    previous_modules = {
        name: sys.modules.get(name) for name in DEVELOPMENT_AUTHORING_MODULE_NAMES
    }
    module_name = "_eg1_multilingual_development_authoring_for_ratings"
    try:
        for dependency_name in DEVELOPMENT_AUTHORING_MODULE_NAMES:
            sys.modules.pop(dependency_name, None)
        current_module._EG1_AUTHENTICATED_SOURCE_SHA256 = sha256_bytes(
            captured[SCRIPT_PATH]
        )
        sys.modules["multilingual_benchmark_v2"] = current_module
        sys.modules["eg1_pinned_multilingual_benchmark_v2"] = current_module
        scanner = _load_committed_module(
            "scan_eg1_multilingual_development_leakage",
            DEVELOPMENT_LEAKAGE_SCANNER_PATH,
            captured[DEVELOPMENT_LEAKAGE_SCANNER_PATH],
        )
        if (
            Path(scanner.SCRIPT_PATH).resolve()
            != DEVELOPMENT_LEAKAGE_SCANNER_PATH.resolve()
        ):
            raise RuntimeError("development leakage scanner path changed")
        module = _load_committed_module(
            module_name,
            DEVELOPMENT_AUTHORING_VERIFIER_PATH,
            captured[DEVELOPMENT_AUTHORING_VERIFIER_PATH],
        )
        if (
            Path(module.SCRIPT_PATH).resolve()
            != DEVELOPMENT_AUTHORING_VERIFIER_PATH.resolve()
        ):
            raise RuntimeError("development authoring verifier path changed")
        if capture_development_authoring_import_closure(expected_head) != captured:
            raise RuntimeError("rating-gate import closure changed while loading")
    except Exception as error:
        for dependency_name, previous in previous_modules.items():
            if previous is None:
                sys.modules.pop(dependency_name, None)
            else:
                sys.modules[dependency_name] = previous
        if isinstance(error, BenchmarkValidationError):
            raise
        raise BenchmarkValidationError(
            [f"cannot load the development authoring verifier: {error}"]
        ) from error
    return module


def authenticate_development_authoring_for_ratings(
    args: argparse.Namespace,
) -> dict[str, Any]:
    """Reopen the complete 800-row authoring chain before accepting ratings."""
    authenticated_fingerprint = capture_rating_authentication_fingerprint(args)
    authoring = load_development_authoring_verifier(args.expected_git_head)
    bundle = args.development_authoring_bundle.expanduser().resolve()
    try:
        expected_head = authoring.validate_git_state(args.expected_git_head)
        receipt = authoring.authenticate_evaluation_bundle(
            bundle,
            expected_head,
            authoring.validate_private_file(
                args.development_allocation_receipt,
                "development allocation receipt",
            ),
            authoring.validate_private_file(
                args.development_shared_brief_receipt,
                "development shared-brief receipt",
            ),
            authoring.validate_private_file(
                args.development_launch_receipt,
                "development launch receipt",
            ),
            authoring.validate_private_file(
                args.development_roster,
                "development private roster",
            ),
            authoring.validate_private_file(
                args.development_native_review_seal,
                "development native-review seal",
            ),
            authoring.validate_private_file(
                args.development_contrast_comparability_seal,
                "development contrast-comparability seal",
            ),
            authoring.validate_private_file(
                args.development_leakage_receipt,
                "development leakage receipt",
            ),
            authoring.validate_private_file(
                args.development_blocked_registry_receipt,
                "development blocked-registry receipt",
            ),
            authoring.validate_private_file(
                args.development_leakage_inventory,
                "development leakage inventory",
            ),
            authoring.validate_private_specs(
                args.development_leakage_source,
                "development leakage source",
            ),
            authoring.validate_private_specs(
                args.development_source_receipt,
                "development source receipt",
            ),
            args.development_scanner_model_dir.expanduser().resolve(),
        )
    except authoring.ValidationFailure as error:
        raise BenchmarkValidationError(
            [f"development authoring evidence is not authentic: {error}"]
        ) from error
    bindings = {
        "development corpus": (
            bundle / "development-corpus.jsonl",
            args.development_corpus.expanduser().resolve(),
        ),
        "development benchmark manifest": (
            bundle / "development-corpus.manifest.json",
            args.development_benchmark_manifest.expanduser().resolve(),
        ),
    }
    errors = [
        f"{label} is not the authenticated development authoring artifact"
        for label, (authenticated, supplied) in bindings.items()
        if not authenticated.is_file()
        or not supplied.is_file()
        or sha256_file(authenticated) != sha256_file(supplied)
    ]
    if errors:
        raise BenchmarkValidationError(errors)
    if capture_rating_authentication_fingerprint(args) != authenticated_fingerprint:
        raise BenchmarkValidationError(
            ["development authoring evidence changed during authentication"]
        )
    authenticated = dict(receipt)
    authenticated["_rating_gate_authenticated_fingerprint"] = authenticated_fingerprint
    return authenticated


def validate_generation_receipts(
    paths: Sequence[Path],
    *,
    expected_model_labels: Sequence[str],
    benchmark_manifest_sha256: str,
    benchmark_manifest: dict[str, Any],
    corpus_rows: Sequence[dict[str, Any]],
) -> list[dict[str, Any]]:
    label_set = set(expected_model_labels)
    errors: list[str] = []
    if len(label_set) != 2 or len(expected_model_labels) != 2:
        errors.append("frozen release rating requires exactly two distinct model labels")
    if len(paths) != len(label_set):
        errors.append(
            f"expected {len(label_set)} frozen generation receipts, observed {len(paths)}"
        )
    expected_fields = {
        "schema_version",
        "opaque_model_label",
        "artifact_sha256",
        "evaluation_config_sha256",
        "benchmark_manifest_sha256",
        "generation_output_sha256",
        "case_count",
        "generation_error_count",
    }
    expected_case_count = sum(row.get("split") == "frozen" for row in corpus_rows)
    observed_labels: set[str] = set()
    observed_pairs: set[tuple[str, str]] = set()
    validated: list[dict[str, Any]] = []
    for path in paths:
        receipt = _read_json_object(path, "frozen generation receipt")
        if set(receipt) != expected_fields:
            errors.append(
                f"frozen generation receipt {path.name} must contain exactly {sorted(expected_fields)}"
            )
            continue
        if receipt.get("schema_version") != "eg1-multilingual-frozen-generation-v1":
            errors.append(f"frozen generation receipt {path.name} schema_version is invalid")
        label = receipt.get("opaque_model_label")
        if label not in label_set or label in observed_labels:
            errors.append(f"frozen generation receipt {path.name} model label is invalid")
        else:
            observed_labels.add(label)
        for field in (
            "artifact_sha256",
            "evaluation_config_sha256",
            "benchmark_manifest_sha256",
            "generation_output_sha256",
        ):
            value = receipt.get(field)
            if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
                errors.append(f"frozen generation receipt {path.name} {field} is invalid")
        if receipt.get("benchmark_manifest_sha256") != benchmark_manifest_sha256:
            errors.append(
                f"frozen generation receipt {path.name} benchmark-manifest hash mismatch"
            )
        if receipt.get("case_count") != expected_case_count:
            errors.append(
                f"frozen generation receipt {path.name} case_count must equal {expected_case_count}"
            )
        if receipt.get("generation_error_count") != 0:
            errors.append(
                f"frozen generation receipt {path.name} must have zero generation errors"
            )
        artifact = receipt.get("artifact_sha256")
        config = receipt.get("evaluation_config_sha256")
        if isinstance(artifact, str) and isinstance(config, str):
            observed_pairs.add((artifact, config))
        validated.append(
            {
                "opaque_model_label": label,
                "receipt_sha256": sha256_file(path),
                "artifact_sha256": artifact,
                "evaluation_config_sha256": config,
                "generation_output_sha256": receipt.get("generation_output_sha256"),
                "case_count": receipt.get("case_count"),
            }
        )
    if observed_labels != label_set:
        errors.append(
            f"frozen generation receipt labels mismatch: expected {sorted(label_set)}, "
            f"observed {sorted(observed_labels)}"
        )
    binding = benchmark_manifest.get("comparison_binding")
    if isinstance(binding, dict):
        expected_pairs = {
            (
                binding.get("baseline_artifact_sha256"),
                binding.get("baseline_evaluation_config_sha256"),
            ),
            (
                binding.get("finalist_artifact_sha256"),
                binding.get("finalist_evaluation_config_sha256"),
            ),
        }
        if observed_pairs != expected_pairs:
            errors.append("frozen generation artifact/config pairs do not match locked comparison")
    else:
        errors.append("benchmark manifest lacks a locked comparison_binding")
    if errors:
        raise BenchmarkValidationError(errors)
    return sorted(validated, key=lambda item: item["opaque_model_label"])


def validate_locked_comparison_binding(
    benchmark_manifest: dict[str, Any], validated_power_plan: dict[str, Any]
) -> None:
    if benchmark_manifest.get("comparison_binding") != validated_power_plan.get(
        "comparison_binding"
    ):
        raise BenchmarkValidationError(
            [
                "benchmark manifest comparison_binding does not match the "
                "recomputed power plan"
            ]
        )


def build_rating_manifest(
    *,
    ratings: Sequence[dict[str, Any]],
    ratings_path: Path,
    benchmark_manifest: dict[str, Any],
    benchmark_manifest_sha256: str,
    expected_model_labels: Sequence[str],
    workflow_stats: dict[str, Any],
    rating_schema_path: Path,
    generation_receipts: Sequence[dict[str, Any]] = (),
) -> dict[str, Any]:
    row_hashes = [
        {
            "rating_id": row["rating_id"],
            "sha256": sha256_bytes(canonical_json(row).encode("utf-8")),
        }
        for row in sorted(ratings, key=lambda item: item["rating_id"])
    ]
    counts = Counter(
        (row["opaque_model_label"], row["review_round"]) for row in ratings
    )
    return {
        "schema_version": "eg1-multilingual-rating-manifest-v2",
        "validator_version": VALIDATOR_VERSION,
        "rating_schema_sha256": sha256_file(rating_schema_path),
        "benchmark_content_sha256": benchmark_manifest["benchmark_content_sha256"],
        "benchmark_manifest_sha256": benchmark_manifest_sha256,
        "rating_source_sha256": sha256_file(ratings_path),
        "rating_content_sha256": rating_content_sha256(ratings),
        "expected_model_labels": sorted(expected_model_labels),
        "generation_receipts": list(generation_receipts),
        "rating_count": len(ratings),
        "workflow_stats": workflow_stats,
        "counts_by_model_and_round": _counter_to_nested(counts),
        "row_hashes": row_hashes,
    }


def _counter_to_nested(counter: Counter[tuple[str, ...]]) -> dict[str, Any]:
    root: dict[str, Any] = {}
    for keys, count in sorted(counter.items()):
        cursor = root
        for key in keys[:-1]:
            cursor = cursor.setdefault(key, {})
        cursor[keys[-1]] = count
    return root


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def validate_command(args: argparse.Namespace) -> int:
    corpus_path = args.corpus.expanduser().resolve()
    rows = read_benchmark(corpus_path)
    validate_rows(
        rows,
        release_profile=args.release_profile,
        frozen_cases_per_cell=args.frozen_cases_per_cell,
    )
    power_plan_path = args.power_plan.expanduser().resolve() if args.power_plan else None
    discordance_receipt_path = (
        args.development_discordance_receipt.expanduser().resolve()
        if args.development_discordance_receipt
        else None
    )
    development_benchmark_manifest_path = (
        args.development_benchmark_manifest.expanduser().resolve()
        if args.development_benchmark_manifest
        else None
    )
    development_corpus_path = (
        args.development_corpus.expanduser().resolve()
        if args.development_corpus
        else None
    )
    development_comparison_manifest_path = (
        args.development_comparison_manifest.expanduser().resolve()
        if args.development_comparison_manifest
        else None
    )
    if args.release_profile and power_plan_path is None:
        raise BenchmarkValidationError(["release profile requires a sealed power plan"])
    if args.release_profile and any(
        path is None
        for path in (
            discordance_receipt_path,
            development_corpus_path,
            development_benchmark_manifest_path,
            development_comparison_manifest_path,
        )
    ):
        raise BenchmarkValidationError(
            [
                "release profile requires the bound development discordance receipt, "
                "benchmark manifest, and comparison manifest"
            ]
        )
    if power_plan_path is not None:
        if any(
            path is None
            for path in (
                discordance_receipt_path,
                development_corpus_path,
                development_benchmark_manifest_path,
                development_comparison_manifest_path,
            )
        ):
            raise BenchmarkValidationError(
                ["power plan validation requires all bound development receipts"]
            )
        validate_power_plan(
            power_plan_path,
            frozen_cases_per_cell=args.frozen_cases_per_cell,
            discordance_receipt_path=discordance_receipt_path,
            development_corpus_path=development_corpus_path,
            development_benchmark_manifest_path=development_benchmark_manifest_path,
            development_comparison_manifest_path=development_comparison_manifest_path,
        )
    sources = parse_leakage_sources(args.leakage_source)
    has_frozen = any(row["split"] == "frozen" for row in rows)
    receipt_path = args.leakage_receipt.expanduser().resolve() if args.leakage_receipt else None
    blocked_registry_receipt_path = (
        args.blocked_registry_receipt.expanduser().resolve()
        if args.blocked_registry_receipt
        else None
    )
    requires_release_evidence = has_frozen or args.release_profile
    if requires_release_evidence:
        roles = {source.role for source in sources}
        missing_roles = sorted(REQUIRED_FROZEN_LEAKAGE_ROLES - roles)
        errors: list[str] = []
        if missing_roles:
            errors.append(f"frozen corpus missing leakage source roles {missing_roles}")
        if receipt_path is None:
            errors.append("frozen corpus requires a leakage screening receipt")
        if blocked_registry_receipt_path is None:
            errors.append("frozen corpus requires a blocked-registry receipt")
        if errors:
            raise BenchmarkValidationError(errors)
    if blocked_registry_receipt_path is not None:
        if not blocked_registry_receipt_path.is_file():
            raise BenchmarkValidationError(
                [f"missing blocked-registry receipt: {blocked_registry_receipt_path}"]
            )
        validate_blocked_registry_receipt(
            blocked_registry_receipt_path,
            sources=sources,
        )
    exact_errors = exact_leakage_errors(rows, sources)
    if exact_errors:
        raise BenchmarkValidationError(exact_errors)
    if receipt_path is not None:
        if not receipt_path.is_file():
            raise BenchmarkValidationError([f"missing leakage receipt: {receipt_path}"])
        validate_leakage_receipt(receipt_path, rows=rows, sources=sources)

    manifest = build_manifest(
        rows=rows,
        corpus_path=corpus_path,
        sources=sources,
        receipt_path=receipt_path,
        release_profile=args.release_profile,
        blocked_registry_receipt_path=blocked_registry_receipt_path,
        frozen_cases_per_cell=args.frozen_cases_per_cell,
        power_plan_path=power_plan_path,
        discordance_receipt_path=discordance_receipt_path,
        development_corpus_path=development_corpus_path,
        development_benchmark_manifest_path=development_benchmark_manifest_path,
        development_comparison_manifest_path=development_comparison_manifest_path,
    )
    if args.manifest_out:
        write_manifest(args.manifest_out.expanduser().resolve(), manifest)
    print(
        canonical_json(
            {
                "status": "valid",
                "row_count": len(rows),
                "family_count": manifest["family_count"],
                "benchmark_content_sha256": manifest["benchmark_content_sha256"],
            }
        )
    )
    return 0


def hash_command(args: argparse.Namespace) -> int:
    rows = read_benchmark(args.corpus.expanduser().resolve())
    validate_rows(
        rows,
        release_profile=args.release_profile,
        frozen_cases_per_cell=args.frozen_cases_per_cell,
    )
    print(benchmark_content_sha256(rows))
    return 0


def power_plan_command(args: argparse.Namespace) -> int:
    plan = release_power_plan(
        discordance_receipt_path=args.development_discordance_receipt.expanduser().resolve(),
        development_corpus_path=args.development_corpus.expanduser().resolve(),
        development_benchmark_manifest_path=args.development_benchmark_manifest.expanduser().resolve(),
        development_comparison_manifest_path=args.development_comparison_manifest.expanduser().resolve(),
        maximum_cases_per_cell=args.maximum_cases_per_cell,
    )
    rendered = canonical_json(plan)
    if args.out:
        output_path = args.out.expanduser().resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    return 0


def _rating_spec_identity_path(spec: str, label: str) -> tuple[str, Path]:
    try:
        identity, raw_path = spec.split("=", 1)
    except ValueError as error:
        raise BenchmarkValidationError(
            [f"invalid {label} {spec!r}; expected IDENTITY=PATH"]
        ) from error
    if not identity or not raw_path:
        raise BenchmarkValidationError(
            [f"invalid {label} {spec!r}; expected IDENTITY=PATH"]
        )
    return identity, Path(raw_path).expanduser().resolve()


def _regular_tree_fingerprint(root: Path, label: str) -> dict[str, str]:
    if not root.is_dir() or root.is_symlink():
        raise BenchmarkValidationError([f"{label} is not a regular directory: {root}"])
    fingerprint: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            raise BenchmarkValidationError([f"{label} contains a symlink: {relative}"])
        if path.is_dir():
            continue
        if not path.is_file():
            raise BenchmarkValidationError(
                [f"{label} contains a non-regular entry: {relative}"]
            )
        fingerprint[relative] = sha256_file(path)
    if not fingerprint:
        raise BenchmarkValidationError([f"{label} contains no regular files: {root}"])
    return fingerprint


def _authoring_rating_paths(args: argparse.Namespace) -> tuple[list[Path], list[Path]]:
    files = [
        args.development_corpus,
        args.development_benchmark_manifest,
        args.development_roster,
        args.development_native_review_seal,
        args.development_contrast_comparability_seal,
        args.development_leakage_receipt,
        args.development_blocked_registry_receipt,
        args.development_leakage_inventory,
    ]
    for spec in (
        *args.development_leakage_source,
        *args.development_source_receipt,
    ):
        files.append(_rating_spec_identity_path(spec, "development evidence")[1])
    directories = [
        args.development_authoring_bundle,
        args.development_allocation_receipt.parent,
        args.development_shared_brief_receipt.parent,
        args.development_launch_receipt.parent,
    ]
    return (
        list(dict.fromkeys(path.expanduser().resolve() for path in files)),
        list(dict.fromkeys(path.expanduser().resolve() for path in directories)),
    )


def capture_rating_authentication_fingerprint(
    args: argparse.Namespace,
) -> dict[str, Any]:
    authoring_files, authoring_directories = _authoring_rating_paths(args)
    file_digests: dict[Path, str] = {}
    for path in authoring_files:
        if path.is_symlink() or not path.is_file():
            raise BenchmarkValidationError(
                [f"authenticated authoring evidence is not a regular file: {path}"]
            )
        file_digests[path] = sha256_file(path)
    directory_fingerprints = {
        directory: _regular_tree_fingerprint(
            directory, "authenticated authoring evidence bundle"
        )
        for directory in authoring_directories
    }
    for directory, fingerprint in directory_fingerprints.items():
        for relative, digest in fingerprint.items():
            path = directory / relative
            prior = file_digests.setdefault(path, digest)
            if prior != digest:
                raise BenchmarkValidationError(
                    ["authenticated authoring evidence changed while fingerprinting"]
                )
    model_dir = args.development_scanner_model_dir.expanduser().resolve()
    return {
        "controls": capture_development_authoring_import_closure(
            args.expected_git_head
        ),
        "files": file_digests,
        "directories": directory_fingerprints,
        "model_dir": model_dir,
        "model": _regular_tree_fingerprint(
            model_dir, "development scanner model"
        ),
    }


@contextlib.contextmanager
def immutable_rating_inputs(
    args: argparse.Namespace,
    authenticated_fingerprint: dict[str, Any],
) -> Iterable[tuple[argparse.Namespace, Any]]:
    """Freeze every post-authentication input and expose a final mutation check."""
    if (
        capture_rating_authentication_fingerprint(args)
        != authenticated_fingerprint
    ):
        raise BenchmarkValidationError(
            ["development authoring evidence changed before rating inputs were frozen"]
        )
    controls = authenticated_fingerprint["controls"]
    original_digests: dict[Path, str] = dict(authenticated_fingerprint["files"])
    authoring_files, authoring_directories = _authoring_rating_paths(args)
    authoring_tree_fingerprints: dict[Path, dict[str, str]] = dict(
        authenticated_fingerprint["directories"]
    )
    model_dir = authenticated_fingerprint["model_dir"]
    model_fingerprint = authenticated_fingerprint["model"]

    def capture(path: Path, label: str) -> tuple[Path, bytes]:
        resolved = path.expanduser().resolve()
        if resolved.is_symlink() or not resolved.is_file():
            raise BenchmarkValidationError([f"{label} is not a regular file: {resolved}"])
        try:
            data = resolved.read_bytes()
        except OSError as error:
            raise BenchmarkValidationError([f"cannot read {label}: {resolved}"]) from error
        digest = sha256_bytes(data)
        prior = original_digests.setdefault(resolved, digest)
        if prior != digest:
            raise BenchmarkValidationError([f"{label} changed while inputs were frozen"])
        return resolved, data

    with tempfile.TemporaryDirectory(prefix="eg1-rating-inputs-") as raw_tmp:
        snapshot_root = Path(raw_tmp)
        os.chmod(snapshot_root, 0o700)
        frozen = argparse.Namespace(**vars(args))
        copied: dict[Path, Path] = {}

        def snapshot(path: Path, label: str) -> Path:
            resolved = path.expanduser().resolve()
            existing = copied.get(resolved)
            if existing is not None:
                return existing
            resolved, data = capture(resolved, label)
            suffix = resolved.suffix if resolved.suffix else ".input"
            target = snapshot_root / f"{len(copied):04d}{suffix}"
            target.write_bytes(data)
            os.chmod(target, 0o400)
            copied[resolved] = target
            return target

        for attribute in (
            "corpus",
            "benchmark_manifest",
            "ratings",
            "power_plan",
            "development_discordance_receipt",
            "development_corpus",
            "development_benchmark_manifest",
            "development_comparison_manifest",
            "leakage_receipt",
            "blocked_registry_receipt",
        ):
            setattr(
                frozen,
                attribute,
                snapshot(getattr(args, attribute), f"rating input {attribute}"),
            )
        frozen.rating_schema_path = snapshot(RATING_SCHEMA_PATH, "rating schema")
        frozen.generation_receipt = [
            snapshot(path, "generation receipt") for path in args.generation_receipt
        ]
        frozen.leakage_source = []
        for spec in args.leakage_source:
            identity, path = _rating_spec_identity_path(spec, "leakage source")
            frozen.leakage_source.append(
                f"{identity}={snapshot(path, 'leakage source')}"
            )

        for path in authoring_files:
            capture(path, "authenticated authoring evidence")
        for directory in authoring_directories:
            fingerprint = _regular_tree_fingerprint(
                directory, "authenticated authoring evidence bundle"
            )
            if fingerprint != authoring_tree_fingerprints.get(directory):
                raise BenchmarkValidationError(
                    ["authenticated authoring evidence changed before snapshotting"]
                )
            for relative, digest in fingerprint.items():
                path = directory / relative
                prior = original_digests.setdefault(path, digest)
                if prior != digest:
                    raise BenchmarkValidationError(
                        ["authenticated authoring evidence changed while inputs were frozen"]
                    )

        def recheck() -> None:
            errors: list[str] = []
            for path, expected_digest in original_digests.items():
                if (
                    path.is_symlink()
                    or not path.is_file()
                    or sha256_file(path) != expected_digest
                ):
                    errors.append(f"rating input changed before publication: {path}")
            for directory, expected in authoring_tree_fingerprints.items():
                try:
                    observed = _regular_tree_fingerprint(
                        directory, "authenticated authoring evidence bundle"
                    )
                except BenchmarkValidationError as error:
                    errors.extend(error.errors)
                    continue
                if observed != expected:
                    errors.append(
                        "authenticated authoring evidence bundle changed before publication: "
                        f"{directory}"
                    )
            try:
                if (
                    _regular_tree_fingerprint(model_dir, "development scanner model")
                    != model_fingerprint
                ):
                    errors.append("development scanner model changed before publication")
                if (
                    capture_development_authoring_import_closure(
                        args.expected_git_head
                    )
                    != controls
                ):
                    errors.append("rating-gate controls changed before publication")
            except BenchmarkValidationError as error:
                errors.extend(error.errors)
            if errors:
                raise BenchmarkValidationError(errors)

        yield frozen, recheck


def write_manifest_atomic(
    path: Path,
    manifest: dict[str, Any],
    *,
    before_publish: Any,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = (
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    descriptor, raw_temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(raw_temporary)
    try:
        os.chmod(temporary, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        before_publish()
        os.replace(temporary, path)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary.unlink(missing_ok=True)
        raise


def validate_ratings_command(args: argparse.Namespace) -> int:
    authentication = authenticate_development_authoring_for_ratings(args)
    with immutable_rating_inputs(
        args, authentication["_rating_gate_authenticated_fingerprint"]
    ) as (frozen_args, recheck):
        return _validate_frozen_ratings_command(frozen_args, args, recheck)


def _validate_frozen_ratings_command(
    args: argparse.Namespace,
    original_args: argparse.Namespace,
    recheck: Any,
) -> int:
    corpus_path = args.corpus.expanduser().resolve()
    benchmark_manifest_path = args.benchmark_manifest.expanduser().resolve()
    ratings_path = args.ratings.expanduser().resolve()
    rows = read_benchmark(corpus_path)
    benchmark_manifest = validate_benchmark_manifest_for_ratings(
        benchmark_manifest_path, rows=rows, corpus_path=corpus_path
    )
    validate_live_leakage_evidence_for_ratings(
        benchmark_manifest,
        rows=rows,
        source_specs=args.leakage_source,
        receipt_path=args.leakage_receipt.expanduser().resolve(),
        blocked_registry_receipt_path=(
            args.blocked_registry_receipt.expanduser().resolve()
        ),
    )
    power_plan_path = args.power_plan.expanduser().resolve()
    discordance_receipt_path = args.development_discordance_receipt.expanduser().resolve()
    development_corpus_path = args.development_corpus.expanduser().resolve()
    development_benchmark_manifest_path = (
        args.development_benchmark_manifest.expanduser().resolve()
    )
    development_comparison_manifest_path = (
        args.development_comparison_manifest.expanduser().resolve()
    )
    source_hashes = {
        "power_plan_sha256": sha256_file(power_plan_path),
        "development_discordance_receipt_sha256": sha256_file(
            discordance_receipt_path
        ),
        "development_corpus_sha256": sha256_file(development_corpus_path),
        "development_benchmark_manifest_sha256": sha256_file(
            development_benchmark_manifest_path
        ),
        "development_comparison_manifest_sha256": sha256_file(
            development_comparison_manifest_path
        ),
    }
    source_errors = [
        f"rating source {field} does not match sealed benchmark manifest"
        for field, actual in source_hashes.items()
        if benchmark_manifest.get(field) != actual
    ]
    if source_errors:
        raise BenchmarkValidationError(source_errors)
    frozen_cases_per_cell = benchmark_manifest["release_profile_parameters"][
        "frozen_cases_per_cell"
    ]
    validated_power_plan = validate_power_plan(
        power_plan_path,
        frozen_cases_per_cell=frozen_cases_per_cell,
        discordance_receipt_path=discordance_receipt_path,
        development_corpus_path=development_corpus_path,
        development_benchmark_manifest_path=development_benchmark_manifest_path,
        development_comparison_manifest_path=development_comparison_manifest_path,
    )
    validate_locked_comparison_binding(benchmark_manifest, validated_power_plan)
    benchmark_manifest_sha = sha256_file(benchmark_manifest_path)
    generation_receipts = validate_generation_receipts(
        [path.expanduser().resolve() for path in args.generation_receipt],
        expected_model_labels=args.expected_model_label,
        benchmark_manifest_sha256=benchmark_manifest_sha,
        benchmark_manifest=benchmark_manifest,
        corpus_rows=rows,
    )
    ratings = read_ratings(ratings_path)
    workflow_stats = validate_rating_rows(
        ratings,
        corpus_rows=rows,
        expected_model_labels=args.expected_model_label,
    )
    manifest = build_rating_manifest(
        ratings=ratings,
        ratings_path=ratings_path,
        benchmark_manifest=benchmark_manifest,
        benchmark_manifest_sha256=benchmark_manifest_sha,
        expected_model_labels=args.expected_model_label,
        workflow_stats=workflow_stats,
        rating_schema_path=args.rating_schema_path,
        generation_receipts=generation_receipts,
    )
    if args.manifest_out:
        write_manifest_atomic(
            original_args.manifest_out.expanduser().resolve(),
            manifest,
            before_publish=recheck,
        )
    else:
        recheck()
    print(
        canonical_json(
            {
                "status": "valid",
                "rating_count": len(ratings),
                "rating_content_sha256": manifest["rating_content_sha256"],
                "workflow_stats": workflow_stats,
            }
        )
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser(
        "validate", help="validate a corpus and optionally write its deterministic manifest"
    )
    validate_parser.add_argument("--corpus", type=Path, required=True)
    validate_parser.add_argument(
        "--release-profile",
        action="store_true",
        help="enforce the balanced development/frozen per-language matrix",
    )
    validate_parser.add_argument(
        "--frozen-cases-per-cell",
        type=int,
        default=DEFAULT_FROZEN_CASES_PER_CELL,
        help=(
            "predeclared frozen rows per behavior-domain cell; minimum/default 4 "
            "(320 per language)"
        ),
    )
    validate_parser.add_argument(
        "--power-plan",
        type=Path,
        help="sealed deterministic JSON emitted by the power-plan command",
    )
    validate_parser.add_argument("--development-discordance-receipt", type=Path)
    validate_parser.add_argument("--development-corpus", type=Path)
    validate_parser.add_argument("--development-benchmark-manifest", type=Path)
    validate_parser.add_argument("--development-comparison-manifest", type=Path)
    validate_parser.add_argument(
        "--leakage-source",
        action="append",
        default=[],
        metavar="ROLE:NAME=PATH",
        help="screen against a pinned training, prior-eval, family, or text-hash input",
    )
    validate_parser.add_argument("--leakage-receipt", type=Path)
    validate_parser.add_argument("--blocked-registry-receipt", type=Path)
    validate_parser.add_argument("--manifest-out", type=Path)
    validate_parser.set_defaults(func=validate_command)

    hash_parser = subparsers.add_parser(
        "content-hash", help="validate structure and print the order-independent content hash"
    )
    hash_parser.add_argument("--corpus", type=Path, required=True)
    hash_parser.add_argument("--release-profile", action="store_true")
    hash_parser.add_argument(
        "--frozen-cases-per-cell",
        type=int,
        default=DEFAULT_FROZEN_CASES_PER_CELL,
    )
    hash_parser.set_defaults(func=hash_command)

    power_parser = subparsers.add_parser(
        "power-plan",
        help="size frozen behavior-domain cells using exact paired McNemar power",
    )
    power_parser.add_argument(
        "--development-discordance-receipt", type=Path, required=True
    )
    power_parser.add_argument("--development-corpus", type=Path, required=True)
    power_parser.add_argument(
        "--development-benchmark-manifest", type=Path, required=True
    )
    power_parser.add_argument(
        "--development-comparison-manifest", type=Path, required=True
    )
    power_parser.add_argument("--maximum-cases-per-cell", type=int, default=30)
    power_parser.add_argument("--out", type=Path)
    power_parser.set_defaults(func=power_plan_command)

    ratings_parser = subparsers.add_parser(
        "validate-ratings",
        help="validate complete blinded native ratings for a sealed release-profile corpus",
    )
    ratings_parser.add_argument("--corpus", type=Path, required=True)
    ratings_parser.add_argument("--benchmark-manifest", type=Path, required=True)
    ratings_parser.add_argument("--ratings", type=Path, required=True)
    ratings_parser.add_argument("--power-plan", type=Path, required=True)
    ratings_parser.add_argument(
        "--development-discordance-receipt", type=Path, required=True
    )
    ratings_parser.add_argument("--development-corpus", type=Path, required=True)
    ratings_parser.add_argument(
        "--development-benchmark-manifest", type=Path, required=True
    )
    ratings_parser.add_argument(
        "--development-comparison-manifest", type=Path, required=True
    )
    ratings_parser.add_argument(
        "--development-authoring-bundle", type=Path, required=True
    )
    ratings_parser.add_argument(
        "--development-allocation-receipt", type=Path, required=True
    )
    ratings_parser.add_argument(
        "--development-shared-brief-receipt", type=Path, required=True
    )
    ratings_parser.add_argument(
        "--development-launch-receipt", type=Path, required=True
    )
    ratings_parser.add_argument("--development-roster", type=Path, required=True)
    ratings_parser.add_argument(
        "--development-native-review-seal", type=Path, required=True
    )
    ratings_parser.add_argument(
        "--development-contrast-comparability-seal", type=Path, required=True
    )
    ratings_parser.add_argument(
        "--development-leakage-receipt", type=Path, required=True
    )
    ratings_parser.add_argument(
        "--development-blocked-registry-receipt", type=Path, required=True
    )
    ratings_parser.add_argument(
        "--development-leakage-inventory", type=Path, required=True
    )
    ratings_parser.add_argument(
        "--development-leakage-source",
        action="append",
        required=True,
        metavar="ROLE:NAME=PATH",
    )
    ratings_parser.add_argument(
        "--development-source-receipt",
        action="append",
        required=True,
        metavar="ROLE:NAME=PATH",
    )
    ratings_parser.add_argument(
        "--development-scanner-model-dir", type=Path, required=True
    )
    ratings_parser.add_argument("--expected-git-head", required=True)
    ratings_parser.add_argument(
        "--generation-receipt",
        type=Path,
        action="append",
        required=True,
        help="frozen generation receipt; repeat once per opaque model label",
    )
    ratings_parser.add_argument(
        "--expected-model-label",
        action="append",
        required=True,
        help="predeclared opaque model label; repeat once per model arm",
    )
    ratings_parser.add_argument(
        "--leakage-source",
        action="append",
        required=True,
        metavar="ROLE:NAME=PATH",
        help="re-screen against each source sealed into the benchmark manifest",
    )
    ratings_parser.add_argument("--leakage-receipt", type=Path, required=True)
    ratings_parser.add_argument(
        "--blocked-registry-receipt", type=Path, required=True
    )
    ratings_parser.add_argument("--manifest-out", type=Path)
    ratings_parser.set_defaults(func=validate_ratings_command)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (BenchmarkValidationError, json.JSONDecodeError, OSError) as exc:
        if isinstance(exc, BenchmarkValidationError):
            for error in exc.errors:
                print(f"ERROR: {error}", file=sys.stderr)
        else:
            print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
