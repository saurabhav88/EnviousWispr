#!/usr/bin/env python3
"""Freeze and validate EG-1 leakage thresholds from metadata-only score rows."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
from typing import Any, Sequence

import numpy as np


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
DEFAULT_CONTRACT = (
    REPO_ROOT
    / "scripts/eval/contracts/eg1_leakage_threshold_calibration_v1.json"
)
CONTRACT_SCHEMA = "eg1-leakage-threshold-calibration-contract-v1"
SCORE_SCHEMA = "eg1-leakage-calibration-score-v1"
FREEZE_SCHEMA = "eg1-leakage-threshold-freeze-receipt-v1"
VALIDATION_SCHEMA = "eg1-leakage-threshold-validation-receipt-v1"
PILOT_SCHEMA = "eg1-leakage-threshold-pilot-receipt-v1"
LABELS = ("related_positive", "hard_negative")
ROW_FIELDS = {
    "schema_version",
    "row_id",
    "family_component_id",
    "source_wave_id",
    "split",
    "language",
    "axis",
    "length_stratum",
    "behavior",
    "label",
    "is_max_neighbor",
    "reference_family_count",
    "scores",
}
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(
            value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        )
        + "\n"
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_bytes(path: Path, label: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as error:
        raise ValueError(f"cannot read {label}") from error


def parse_json(value: bytes, label: str) -> Any:
    try:
        return json.loads(value)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is invalid JSON") from error


def validate_contract(value: Any) -> dict[str, Any]:
    required = {
        "schema_version",
        "languages",
        "axes",
        "methods",
        "length_strata",
        "behaviors",
        "release_profile",
        "statistics",
        "policy",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise ValueError("calibration contract schema changed")
    if value.get("schema_version") != CONTRACT_SCHEMA:
        raise ValueError("calibration contract version changed")
    if value.get("languages") != ["en", "de", "fr", "es", "ru"]:
        raise ValueError("calibration languages changed")
    if value.get("axes") != [
        "input_input",
        "output_output",
        "input_output",
        "output_input",
    ]:
        raise ValueError("calibration axes changed")
    if value.get("methods") != [
        "token_ngram_jaccard",
        "character_ngram_jaccard",
        "embedding_cosine",
    ]:
        raise ValueError("calibration methods changed")
    if value.get("length_strata") != ["1_7", "8_20", "21_50", "51_plus"]:
        raise ValueError("calibration length strata changed")
    if not isinstance(value.get("behaviors"), list) or len(value["behaviors"]) != 16:
        raise ValueError("calibration behaviors changed")
    profile = value.get("release_profile")
    if profile != {
        "calibration_families_per_language": 180,
        "validation_families_per_language": 120,
        "minimum_families_per_length_stratum": {
            "calibration": 20,
            "validation": 12,
        },
        "minimum_families_per_behavior": {
            "calibration": 5,
            "validation": 3,
        },
        "minimum_distinct_waves": {"calibration": 2, "validation": 2},
    }:
        raise ValueError("calibration release profile changed")
    statistics = value.get("statistics")
    if statistics != {
        "bootstrap_replicates": 10000,
        "bootstrap_seed": 1265,
        "simultaneous_confidence": 0.95,
        "minimum_simultaneous_sensitivity": 0.95,
        "threshold_boundary": "score_greater_than_or_equal_is_detected",
        "bootstrap_unit": "family_component_within_language_shared_across_axes",
    }:
        raise ValueError("calibration statistics contract changed")
    if value.get("policy") != {
        "exact_normalized_always_blocks": True,
        "hard_negative_rows_must_be_max_neighbor": True,
        "overlapping_positive_negative_bands_disable_auto_cutoff": True,
        "validation_may_select_or_change_thresholds": False,
        "pilot_is_quality_evidence": False,
        "candidate_model_output_allowed": False,
        "output_contains_raw_text": False,
    }:
        raise ValueError("calibration policy changed")
    return value


def read_score_rows(value: bytes, contract: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    try:
        lines = value.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ValueError("score rows are not UTF-8") from error
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"score row {line_number} is invalid JSON") from error
        if not isinstance(row, dict) or set(row) != ROW_FIELDS:
            raise ValueError(f"score row {line_number} schema changed")
        if row.get("schema_version") != SCORE_SCHEMA:
            raise ValueError(f"score row {line_number} version changed")
        for field in ("row_id", "family_component_id", "source_wave_id"):
            if not isinstance(row.get(field), str) or not SAFE_ID.fullmatch(row[field]):
                raise ValueError(f"score row {line_number} has invalid {field}")
        if row["row_id"] in seen_ids:
            raise ValueError("score rows contain duplicate row IDs")
        seen_ids.add(row["row_id"])
        for field, allowed in (
            ("split", ("calibration", "validation")),
            ("language", contract["languages"]),
            ("axis", contract["axes"]),
            ("length_stratum", contract["length_strata"]),
            ("behavior", contract["behaviors"]),
            ("label", LABELS),
        ):
            if row.get(field) not in allowed:
                raise ValueError(f"score row {line_number} has invalid {field}")
        is_negative = row["label"] == "hard_negative"
        if row.get("is_max_neighbor") is not is_negative:
            raise ValueError("hard negatives must be maximum-neighbor observations")
        count = row.get("reference_family_count")
        if type(count) is not int or count < 1:
            raise ValueError("reference family count must be positive")
        scores = row.get("scores")
        if not isinstance(scores, dict) or set(scores) != set(contract["methods"]):
            raise ValueError("score methods differ from the contract")
        if any(
            type(score) not in {int, float}
            or not math.isfinite(score)
            or not 0 <= score <= 1
            for score in scores.values()
        ):
            raise ValueError("scores must be finite numbers from zero to one")
        rows.append(row)
    if not rows:
        raise ValueError("score input is empty")
    return rows


def validate_family_structure(rows: Sequence[dict[str, Any]]) -> None:
    component_splits: dict[str, set[str]] = defaultdict(set)
    component_metadata: dict[tuple[str, str], tuple[str, str, str]] = {}
    observed: set[tuple[str, str, str, str, str]] = set()
    for row in rows:
        component_splits[row["family_component_id"]].add(row["split"])
        family_key = (row["language"], row["family_component_id"])
        metadata = (row["source_wave_id"], row["length_stratum"], row["behavior"])
        if family_key in component_metadata and component_metadata[family_key] != metadata:
            raise ValueError("family component changes wave or stratum metadata")
        component_metadata[family_key] = metadata
        key = (row["split"], *family_key, row["axis"], row["label"])
        if key in observed:
            raise ValueError("family component has duplicate axis/label scores")
        observed.add(key)
    if any(len(splits) != 1 for splits in component_splits.values()):
        raise ValueError("family components may not cross calibration and validation")


def validate_release_profile(
    rows: Sequence[dict[str, Any]], split: str, contract: dict[str, Any]
) -> dict[str, Any]:
    if any(row["split"] != split for row in rows):
        raise ValueError(f"{split} command may consume only {split} rows")
    validate_family_structure(rows)
    profile = contract["release_profile"]
    expected_families = profile[f"{split}_families_per_language"]
    family_metadata: dict[tuple[str, str], tuple[str, str, str]] = {}
    expected_axes_labels = {
        (axis, label) for axis in contract["axes"] for label in LABELS
    }
    coverage: dict[str, Any] = {}
    for language in contract["languages"]:
        language_rows = [row for row in rows if row["language"] == language]
        family_ids = sorted({row["family_component_id"] for row in language_rows})
        if len(family_ids) != expected_families:
            raise ValueError(
                f"{split}/{language} has {len(family_ids)} families; expected {expected_families}"
            )
        for family_id in family_ids:
            family_rows = [
                row for row in language_rows if row["family_component_id"] == family_id
            ]
            if {(row["axis"], row["label"]) for row in family_rows} != expected_axes_labels:
                raise ValueError("each family must supply both labels on all four axes")
            first = family_rows[0]
            family_metadata[(language, family_id)] = (
                first["source_wave_id"],
                first["length_stratum"],
                first["behavior"],
            )
        lengths = Counter(value[1] for key, value in family_metadata.items() if key[0] == language)
        behaviors = Counter(value[2] for key, value in family_metadata.items() if key[0] == language)
        waves = {value[0] for key, value in family_metadata.items() if key[0] == language}
        minimum_length = profile["minimum_families_per_length_stratum"][split]
        minimum_behavior = profile["minimum_families_per_behavior"][split]
        if any(lengths[value] < minimum_length for value in contract["length_strata"]):
            raise ValueError(f"{split}/{language} lacks required length coverage")
        if any(behaviors[value] < minimum_behavior for value in contract["behaviors"]):
            raise ValueError(f"{split}/{language} lacks required behavior coverage")
        if len(waves) < profile["minimum_distinct_waves"][split]:
            raise ValueError(f"{split}/{language} lacks independent source waves")
        if any(
            row["reference_family_count"] < expected_families - 1
            for row in language_rows
            if row["label"] == "hard_negative"
        ):
            raise ValueError(
                f"{split}/{language} hard negatives do not cover the full family pool"
            )
        coverage[language] = {
            "families": len(family_ids),
            "length_strata": dict(sorted(lengths.items())),
            "behaviors": dict(sorted(behaviors.items())),
            "distinct_waves": len(waves),
        }
    return coverage


def score_tables(
    rows: Sequence[dict[str, Any]], contract: dict[str, Any], label: str
) -> dict[str, dict[str, dict[str, dict[str, float]]]]:
    tables: dict[str, dict[str, dict[str, dict[str, float]]]] = {
        method: {
            language: {axis: {} for axis in contract["axes"]}
            for language in contract["languages"]
        }
        for method in contract["methods"]
    }
    for row in rows:
        if row["label"] != label:
            continue
        for method in contract["methods"]:
            tables[method][row["language"]][row["axis"]][
                row["family_component_id"]
            ] = float(row["scores"][method])
    return tables


def bootstrap_indices(
    tables: dict[str, dict[str, dict[str, dict[str, float]]]],
    contract: dict[str, Any],
) -> dict[str, tuple[list[str], np.ndarray]]:
    seed = contract["statistics"]["bootstrap_seed"]
    replicates = contract["statistics"]["bootstrap_replicates"]
    first_method = contract["methods"][0]
    result: dict[str, tuple[list[str], np.ndarray]] = {}
    for language_index, language in enumerate(contract["languages"]):
        family_ids = sorted(tables[first_method][language][contract["axes"][0]])
        rng = np.random.default_rng(seed + language_index)
        indices = rng.integers(
            0, len(family_ids), size=(replicates, len(family_ids)), dtype=np.int32
        )
        result[language] = (family_ids, indices)
    return result


def simultaneous_sensitivity_lower(
    method_table: dict[str, dict[str, dict[str, float]]],
    threshold: float,
    plans: dict[str, tuple[list[str], np.ndarray]],
    contract: dict[str, Any],
) -> tuple[float, dict[str, dict[str, float]]]:
    replicates = contract["statistics"]["bootstrap_replicates"]
    minima = np.ones(replicates, dtype=np.float32)
    observed: dict[str, dict[str, float]] = {}
    for language in contract["languages"]:
        family_ids, indices = plans[language]
        observed[language] = {}
        for axis in contract["axes"]:
            values = np.asarray(
                [method_table[language][axis][family_id] for family_id in family_ids],
                dtype=np.float32,
            )
            success = values >= threshold
            observed[language][axis] = round(float(np.mean(success)), 8)
            minima = np.minimum(minima, np.mean(success[indices], axis=1))
    alpha = 1.0 - contract["statistics"]["simultaneous_confidence"]
    lower = float(np.quantile(minima, alpha, method="lower"))
    return round(lower, 8), observed


def select_thresholds(
    positives: dict[str, dict[str, dict[str, dict[str, float]]]],
    negatives: dict[str, dict[str, dict[str, dict[str, float]]]],
    contract: dict[str, Any],
) -> dict[str, Any]:
    plans = bootstrap_indices(positives, contract)
    minimum = contract["statistics"]["minimum_simultaneous_sensitivity"]
    selected: dict[str, Any] = {}
    for method in contract["methods"]:
        candidates = sorted(
            {
                score
                for language in positives[method].values()
                for axis in language.values()
                for score in axis.values()
            }
        )
        low, high = 0, len(candidates) - 1
        winner = candidates[0]
        winner_lower = 0.0
        winner_observed: dict[str, dict[str, float]] = {}
        while low <= high:
            middle = (low + high) // 2
            threshold = candidates[middle]
            lower, observed = simultaneous_sensitivity_lower(
                positives[method], threshold, plans, contract
            )
            if lower >= minimum:
                winner, winner_lower, winner_observed = threshold, lower, observed
                low = middle + 1
            else:
                high = middle - 1
        negative_maximum = max(
            score
            for language in negatives[method].values()
            for axis in language.values()
            for score in axis.values()
        )
        overlap = negative_maximum >= winner
        selected[method] = {
            "review_cutoff": round(float(winner), 8),
            "auto_block_cutoff": None if overlap else round(float(winner), 8),
            "bands_overlap": overlap,
            "hard_negative_maximum": round(float(negative_maximum), 8),
            "calibration_simultaneous_sensitivity_lower": winner_lower,
            "observed_sensitivity": winner_observed,
            "decision_policy": (
                "manual_review_at_or_above_review_cutoff_no_auto_block"
                if overlap
                else "auto_block_at_or_above_review_cutoff"
            ),
        }
    return selected


def component_hashes(rows: Sequence[dict[str, Any]]) -> list[str]:
    return sorted(
        {
            sha256_bytes(row["family_component_id"].encode("utf-8"))
            for row in rows
        }
    )


def common_receipt(
    schema: str,
    status: str,
    contract_bytes: bytes,
    scores_bytes: bytes,
    rows: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "schema_version": schema,
        "status": status,
        "contract_sha256": sha256_bytes(contract_bytes),
        "tool_sha256": sha256_bytes(read_bytes(SCRIPT_PATH, "calibration tool")),
        "score_rows_sha256": sha256_bytes(scores_bytes),
        "score_row_count": len(rows),
        "contains_raw_text": False,
        "candidate_model_output_seen": False,
        "release_eligible": False,
    }


def build_freeze_receipt(
    contract_bytes: bytes, scores_bytes: bytes
) -> dict[str, Any]:
    contract = validate_contract(parse_json(contract_bytes, "calibration contract"))
    rows = read_score_rows(scores_bytes, contract)
    coverage = validate_release_profile(rows, "calibration", contract)
    positives = score_tables(rows, contract, "related_positive")
    negatives = score_tables(rows, contract, "hard_negative")
    thresholds = select_thresholds(positives, negatives, contract)
    receipt = common_receipt(
        FREEZE_SCHEMA,
        "thresholds_frozen_validation_unseen",
        contract_bytes,
        scores_bytes,
        rows,
    )
    receipt.update(
        {
            "release_profile_met": True,
            "validation_data_seen": False,
            "no_validation_driven_retuning": True,
            "bootstrap": contract["statistics"],
            "coverage": coverage,
            "thresholds": thresholds,
            "calibration_family_component_hashes": component_hashes(rows),
            "calibration_wave_ids": sorted({row["source_wave_id"] for row in rows}),
        }
    )
    return receipt


def validate_freeze_receipt(value: Any, contract_sha: str) -> dict[str, Any]:
    required = {
        "schema_version",
        "status",
        "contract_sha256",
        "tool_sha256",
        "score_rows_sha256",
        "score_row_count",
        "contains_raw_text",
        "candidate_model_output_seen",
        "release_eligible",
        "release_profile_met",
        "validation_data_seen",
        "no_validation_driven_retuning",
        "bootstrap",
        "coverage",
        "thresholds",
        "calibration_family_component_hashes",
        "calibration_wave_ids",
    }
    if (
        not isinstance(value, dict)
        or set(value) != required
        or value.get("schema_version") != FREEZE_SCHEMA
        or value.get("status") != "thresholds_frozen_validation_unseen"
        or value.get("contract_sha256") != contract_sha
        or value.get("tool_sha256")
        != sha256_bytes(read_bytes(SCRIPT_PATH, "calibration tool"))
        or value.get("release_profile_met") is not True
        or value.get("validation_data_seen") is not False
        or value.get("no_validation_driven_retuning") is not True
        or value.get("contains_raw_text") is not False
        or value.get("candidate_model_output_seen") is not False
        or value.get("release_eligible") is not False
    ):
        raise ValueError("threshold freeze receipt is invalid")
    hashes = value.get("calibration_family_component_hashes")
    if not isinstance(hashes, list) or any(
        not isinstance(item, str) or not SHA256.fullmatch(item) for item in hashes
    ) or hashes != sorted(set(hashes)):
        raise ValueError("threshold freeze family binding is invalid")
    thresholds = value.get("thresholds")
    threshold_fields = {
        "review_cutoff",
        "auto_block_cutoff",
        "bands_overlap",
        "hard_negative_maximum",
        "calibration_simultaneous_sensitivity_lower",
        "observed_sensitivity",
        "decision_policy",
    }
    if not isinstance(thresholds, dict) or set(thresholds) != {
        "token_ngram_jaccard",
        "character_ngram_jaccard",
        "embedding_cosine",
    }:
        raise ValueError("threshold freeze methods are invalid")
    for result in thresholds.values():
        if not isinstance(result, dict) or set(result) != threshold_fields:
            raise ValueError("threshold freeze result schema changed")
        review = result.get("review_cutoff")
        auto = result.get("auto_block_cutoff")
        observed = result.get("observed_sensitivity")
        if (
            type(review) not in {int, float}
            or not 0 <= review <= 1
            or (auto is not None and (type(auto) not in {int, float} or not review <= auto <= 1))
            or type(result.get("bands_overlap")) is not bool
            or (result.get("bands_overlap") is True) != (auto is None)
            or type(result.get("hard_negative_maximum")) not in {int, float}
            or not 0 <= result["hard_negative_maximum"] <= 1
            or type(result.get("calibration_simultaneous_sensitivity_lower"))
            not in {int, float}
            or result["calibration_simultaneous_sensitivity_lower"] < 0.95
            or not isinstance(observed, dict)
            or set(observed) != {"en", "de", "fr", "es", "ru"}
            or any(
                not isinstance(axes, dict)
                or set(axes)
                != {"input_input", "output_output", "input_output", "output_input"}
                or any(type(score) not in {int, float} or not 0 <= score <= 1 for score in axes.values())
                for axes in observed.values()
            )
            or result.get("decision_policy")
            != (
                "manual_review_at_or_above_review_cutoff_no_auto_block"
                if auto is None
                else "auto_block_at_or_above_review_cutoff"
            )
        ):
            raise ValueError("threshold freeze result is invalid")
    return value


def build_validation_receipt(
    contract_bytes: bytes,
    scores_bytes: bytes,
    freeze_bytes: bytes,
    expected_freeze_sha256: str,
) -> dict[str, Any]:
    if not SHA256.fullmatch(expected_freeze_sha256) or sha256_bytes(freeze_bytes) != expected_freeze_sha256:
        raise ValueError("threshold freeze receipt differs from its sealed SHA-256")
    contract = validate_contract(parse_json(contract_bytes, "calibration contract"))
    freeze = validate_freeze_receipt(
        parse_json(freeze_bytes, "threshold freeze receipt"), sha256_bytes(contract_bytes)
    )
    if freeze.get("bootstrap") != contract["statistics"]:
        raise ValueError("threshold freeze bootstrap contract changed")
    rows = read_score_rows(scores_bytes, contract)
    coverage = validate_release_profile(rows, "validation", contract)
    if set(component_hashes(rows)) & set(freeze["calibration_family_component_hashes"]):
        raise ValueError("validation reuses a calibration family component")
    if {row["source_wave_id"] for row in rows} & set(freeze["calibration_wave_ids"]):
        raise ValueError("validation reuses a calibration source wave")
    positives = score_tables(rows, contract, "related_positive")
    negatives = score_tables(rows, contract, "hard_negative")
    plans = bootstrap_indices(positives, contract)
    method_results: dict[str, Any] = {}
    passed = True
    manual_required = False
    for method in contract["methods"]:
        frozen = freeze["thresholds"].get(method)
        if not isinstance(frozen, dict) or type(frozen.get("review_cutoff")) not in {int, float}:
            raise ValueError("threshold freeze methods are invalid")
        cutoff = float(frozen["review_cutoff"])
        lower, observed = simultaneous_sensitivity_lower(
            positives[method], cutoff, plans, contract
        )
        negative_maximum = max(
            score
            for language in negatives[method].values()
            for axis in language.values()
            for score in axis.values()
        )
        sensitivity_pass = lower >= contract["statistics"]["minimum_simultaneous_sensitivity"]
        auto_cutoff = frozen.get("auto_block_cutoff")
        auto_false_positive = (
            auto_cutoff is not None and negative_maximum >= float(auto_cutoff)
        )
        passed = passed and sensitivity_pass and not auto_false_positive
        manual_required = manual_required or auto_cutoff is None
        method_results[method] = {
            "frozen_review_cutoff": cutoff,
            "frozen_auto_block_cutoff": auto_cutoff,
            "validation_simultaneous_sensitivity_lower": lower,
            "observed_sensitivity": observed,
            "hard_negative_maximum": round(float(negative_maximum), 8),
            "sensitivity_pass": sensitivity_pass,
            "auto_cutoff_false_positive": auto_false_positive,
            "threshold_changed_after_freeze": False,
        }
    status = (
        "validation_failed_frozen_thresholds_unchanged"
        if not passed
        else (
            "validation_passed_manual_review_required"
            if manual_required
            else "validation_passed"
        )
    )
    receipt = common_receipt(
        VALIDATION_SCHEMA, status, contract_bytes, scores_bytes, rows
    )
    receipt.update(
        {
            "release_profile_met": True,
            "freeze_receipt_sha256": expected_freeze_sha256,
            "thresholds_frozen_before_validation": True,
            "no_validation_driven_retuning": True,
            "coverage": coverage,
            "bootstrap": contract["statistics"],
            "method_results": method_results,
            "statistics_gate_passed": passed,
            "manual_review_required": manual_required,
        }
    )
    return receipt


def build_pilot_receipt(contract_bytes: bytes, scores_bytes: bytes) -> dict[str, Any]:
    contract = validate_contract(parse_json(contract_bytes, "calibration contract"))
    rows = read_score_rows(scores_bytes, contract)
    validate_family_structure(rows)
    receipt = common_receipt(
        PILOT_SCHEMA, "pilot_noncertifying", contract_bytes, scores_bytes, rows
    )
    receipt.update(
        {
            "release_profile_met": False,
            "thresholds_frozen": False,
            "quality_evidence": False,
            "family_language_counts": {
                split: {
                    language: len(
                        {
                            row["family_component_id"]
                            for row in rows
                            if row["split"] == split and row["language"] == language
                        }
                    )
                    for language in contract["languages"]
                }
                for split in ("calibration", "validation")
            },
        }
    )
    return receipt


def publish_receipt(bundle: Path, receipt: dict[str, Any]) -> None:
    if bundle.exists():
        raise ValueError("output bundle already exists")
    bundle.mkdir(parents=True)
    try:
        path = bundle / "receipt.json"
        with path.open("xb") as handle:
            value = canonical_json(receipt)
            if handle.write(value) != len(value):
                raise OSError("short receipt write")
            handle.flush()
            os.fsync(handle.fileno())
        descriptor = os.open(bundle, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except Exception:
        shutil.rmtree(bundle, ignore_errors=True)
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="mode", required=True)
    for mode in ("calibrate", "validate", "pilot"):
        child = subparsers.add_parser(mode)
        child.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
        child.add_argument("--scores", type=Path, required=True)
        child.add_argument("--expected-scores-sha256", required=True)
        child.add_argument("--out-bundle", type=Path, required=True)
        if mode == "validate":
            child.add_argument("--freeze-receipt", type=Path, required=True)
            child.add_argument("--expected-freeze-receipt-sha256", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    contract_bytes = read_bytes(args.contract, "calibration contract")
    scores_bytes = read_bytes(args.scores, "score rows")
    if (
        not SHA256.fullmatch(args.expected_scores_sha256)
        or sha256_bytes(scores_bytes) != args.expected_scores_sha256
    ):
        raise ValueError("score rows differ from their sealed SHA-256")
    if args.mode == "calibrate":
        receipt = build_freeze_receipt(contract_bytes, scores_bytes)
    elif args.mode == "validate":
        freeze_bytes = read_bytes(args.freeze_receipt, "threshold freeze receipt")
        receipt = build_validation_receipt(
            contract_bytes,
            scores_bytes,
            freeze_bytes,
            args.expected_freeze_receipt_sha256,
        )
    else:
        receipt = build_pilot_receipt(contract_bytes, scores_bytes)
    publish_receipt(args.out_bundle, receipt)
    return 2 if receipt["status"].startswith("validation_failed") else 0


if __name__ == "__main__":
    raise SystemExit(main())
