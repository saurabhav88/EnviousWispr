#!/usr/bin/env python3
"""Freeze and validate EG-1 leakage thresholds from metadata-only score rows."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from decimal import Decimal, ROUND_HALF_UP
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
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
GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
TOOL_REPO_PATH = "scripts/eval/calibrate_eg1_leakage_thresholds.py"
CONTRACT_REPO_PATH = "scripts/eval/contracts/eg1_leakage_threshold_calibration_v1.json"
SCORE_GENERATOR_REPO_PATH = "scripts/eval/generate_eg1_leakage_calibration_scores.py"
SCORE_GENERATOR_SHA256 = "5f080563f059abdc43925ab96d51901cf26027f860156e4f06b3d021e157f59d"
CANONICAL_SCANNER_REPO_PATH = "scripts/eval/scan_eg1_multilingual_development_leakage.py"
CANONICAL_SCANNER_SHA256 = "f23d6c5d24c9aacdb6576bbbc714e3ec831f327345b486e15a7e29d0760ea768"
SCORE_RECEIPT_SCHEMA = "eg1-leakage-score-generation-receipt-v1"
CUSTODY_SCHEMA = "eg1-leakage-validation-custody-v1"
SCORE_DECIMALS = 8
SCORE_QUANTUM = Decimal("0.00000001")
CALIBRATION_NUMPY_VERSION = "2.4.4"
SCANNER_NUMPY_VERSION = "2.4.6"
EXPECTED_MODEL_TREE_SHA256 = "087413375b109d83ccd69bff217f841ce9029e9a6d7d3804129d65a5f9bf319e"
EXPECTED_SCANNER_RUNTIME = {
    "sentence_transformers": "5.6.0", "transformers": "5.12.1",
    "torch": "2.12.1", "numpy": SCANNER_NUMPY_VERSION,
}


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(
            value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        )
        + "\n"
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def git_output(arguments: Sequence[str]) -> bytes:
    return subprocess.run(
        ["git", *arguments], cwd=REPO_ROOT, check=True, stdout=subprocess.PIPE
    ).stdout


def current_git_head() -> str:
    return git_output(["rev-parse", "HEAD"]).decode().strip()


def require_strict_commit_ancestor(
    ancestor: str, descendant: str, label: str, repo_root: Path = REPO_ROOT
) -> None:
    if ancestor == descendant or subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, descendant], cwd=repo_root
    ).returncode != 0:
        raise ValueError(f"{label} must be sealed in a later descendant commit")


def committed_artifact_bytes(
    path: Path, expected_head: str, repo_root: Path = REPO_ROOT
) -> tuple[bytes, dict[str, Any], str]:
    resolved = path.resolve()
    try:
        relative = str(resolved.relative_to(repo_root.resolve()))
    except ValueError as error:
        raise ValueError("evidence artifact must be inside the repository") from error
    live = read_bytes(resolved, "evidence artifact")
    value = parse_json(live, "evidence artifact")
    producing = value.get("producing_git_head") if isinstance(value, dict) else None
    if producing is None and isinstance(value, dict):
        provenance = value.get("scanner_provenance")
        if isinstance(provenance, dict):
            producing = provenance.get("producing_git_head")
    if not isinstance(producing, str) or not GIT_SHA.fullmatch(producing):
        raise ValueError("evidence artifact producing commit is invalid")
    sealing = subprocess.run(
        ["git", "log", "-1", "--format=%H", expected_head, "--", relative],
        cwd=repo_root, check=True, text=True, stdout=subprocess.PIPE,
    ).stdout.strip()
    if not GIT_SHA.fullmatch(sealing):
        raise ValueError("evidence artifact has no committed sealing revision")
    for ancestor, descendant in ((producing, sealing), (sealing, expected_head)):
        if subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, descendant], cwd=repo_root).returncode != 0:
            raise ValueError("evidence artifact history is not an ancestor chain")
    committed = subprocess.run(
        ["git", "show", f"{sealing}:{relative}"], cwd=repo_root,
        check=True, stdout=subprocess.PIPE,
    ).stdout
    if committed != live:
        raise ValueError("evidence artifact differs from committed producer bytes")
    return live, value, sealing


def validate_score_generation_receipt(
    receipt_path: Path, upstream_path: Path, scores_bytes: bytes,
    split: str, contract_bytes: bytes, expected_head: str,
) -> tuple[str, str]:
    receipt_bytes, receipt, sealing = committed_artifact_bytes(receipt_path, expected_head)
    upstream_bytes, upstream, _ = committed_artifact_bytes(upstream_path, expected_head)
    required = {
        "schema_version", "status", "split", "score_rows_sha256", "score_row_count",
        "contract_sha256", "producing_git_head", "generator_path", "generator_sha256",
        "upstream_scanner_receipt_path", "upstream_scanner_receipt_sha256",
        "scanner_provenance_sha256", "model_tree_sha256", "source_inventory_sha256",
        "runtime_versions", "methods", "axes", "score_decimals", "contains_raw_text",
        "candidate_model_output_seen",
        "pair_input_sha256",
        "quality_evidence", "production_thresholds_approved", "assurance_scope",
    }
    if not isinstance(receipt, dict) or set(receipt) != required:
        raise ValueError("score-generation receipt schema changed")
    relative_upstream = str(upstream_path.resolve().relative_to(REPO_ROOT))
    rows = read_score_rows(scores_bytes, validate_contract(parse_json(contract_bytes, "calibration contract")))
    provenance = upstream.get("scanner_provenance") if isinstance(upstream, dict) else None
    embedding = upstream.get("embedding_runtime") if isinstance(upstream, dict) else None
    tree = embedding.get("model_tree") if isinstance(embedding, dict) else None
    runtime = embedding.get("runtime_versions") if isinstance(embedding, dict) else None
    if (
        receipt.get("schema_version") != SCORE_RECEIPT_SCHEMA
        or receipt.get("status") != "operator_attested_noncertifying_scores"
        or receipt.get("split") != split
        or receipt.get("score_rows_sha256") != sha256_bytes(scores_bytes)
        or receipt.get("score_row_count") != len(rows)
        or receipt.get("contract_sha256") != sha256_bytes(contract_bytes)
        or receipt.get("upstream_scanner_receipt_path") != relative_upstream
        or receipt.get("upstream_scanner_receipt_sha256") != sha256_bytes(upstream_bytes)
        or receipt.get("scanner_provenance_sha256") != sha256_bytes(canonical_json(provenance))
        or not isinstance(provenance, dict)
        or provenance.get("scanner_path") != CANONICAL_SCANNER_REPO_PATH
        or provenance.get("scanner_sha256") != CANONICAL_SCANNER_SHA256
        or not isinstance(tree, dict)
        or receipt.get("model_tree_sha256") != tree.get("tree_sha256")
        or receipt.get("model_tree_sha256") != EXPECTED_MODEL_TREE_SHA256
        or receipt.get("source_inventory_sha256") != upstream.get("source_inventory_sha256")
        or receipt.get("runtime_versions") != runtime
        or runtime != EXPECTED_SCANNER_RUNTIME
        or receipt.get("methods") != ["token_ngram_jaccard", "character_ngram_jaccard", "embedding_cosine"]
        or receipt.get("axes") != ["input_input", "output_output", "input_output", "output_input"]
        or receipt.get("score_decimals") != SCORE_DECIMALS
        or receipt.get("contains_raw_text") is not False
        or receipt.get("candidate_model_output_seen") is not False
        or not isinstance(receipt.get("pair_input_sha256"), str)
        or not SHA256.fullmatch(receipt["pair_input_sha256"])
        or receipt.get("quality_evidence") is not False
        or receipt.get("production_thresholds_approved") is not False
        or receipt.get("assurance_scope") != "operator_attested_unsigned_pair_semantics_nonrelease"
    ):
        raise ValueError("score-generation receipt binding is invalid")
    generator_path = receipt.get("generator_path")
    if generator_path != SCORE_GENERATOR_REPO_PATH or receipt.get("generator_sha256") != SCORE_GENERATOR_SHA256:
        raise ValueError("score generator is not the contract-pinned canonical generator")
    committed_generator = git_output(["show", f"{receipt['producing_git_head']}:{generator_path}"])
    if sha256_bytes(committed_generator) != receipt.get("generator_sha256"):
        raise ValueError("score generator differs from committed bytes")
    return sha256_bytes(receipt_bytes), sealing


def validate_custody_artifact(
    path: Path, *, freeze_path: Path, calibration_scores_bytes: bytes,
    validation_scores_bytes: bytes, calibration_score_receipt_sha: str,
    validation_score_receipt_sha: str, contract_bytes: bytes, expected_head: str,
    calibration_score_sealing: str, validation_score_sealing: str,
) -> str:
    freeze_bytes, _, freeze_sealing = committed_artifact_bytes(freeze_path, expected_head)
    artifact_bytes, value, custody_sealing = committed_artifact_bytes(path, expected_head)
    require_strict_commit_ancestor(
        freeze_sealing, custody_sealing, "custody artifact", REPO_ROOT
    )
    require_strict_commit_ancestor(
        calibration_score_sealing, freeze_sealing, "freeze", REPO_ROOT
    )
    require_strict_commit_ancestor(
        freeze_sealing, validation_score_sealing, "validation score seal", REPO_ROOT
    )
    for ancestor, descendant, label in (
        (validation_score_sealing, custody_sealing, "validation score seal"),
        (custody_sealing, expected_head, "validation execution head"),
    ):
        if subprocess.run(
            ["git", "merge-base", "--is-ancestor", ancestor, descendant], cwd=REPO_ROOT
        ).returncode != 0:
            raise ValueError(f"{label} chronology is invalid")
    required = {
        "schema_version", "status", "producing_git_head", "contract_sha256",
        "freeze_receipt_sha256", "calibration_score_rows_sha256",
        "validation_score_rows_sha256", "calibration_score_receipt_sha256",
        "validation_score_receipt_sha256", "validation_execution_started",
        "operator_attested_pre_validation", "assurance_scope", "release_eligible",
    }
    expected = {
        "schema_version": CUSTODY_SCHEMA,
        "status": "validation_inputs_sealed_before_execution",
        "producing_git_head": value.get("producing_git_head") if isinstance(value, dict) else None,
        "contract_sha256": sha256_bytes(contract_bytes),
        "freeze_receipt_sha256": sha256_bytes(freeze_bytes),
        "calibration_score_rows_sha256": sha256_bytes(calibration_scores_bytes),
        "validation_score_rows_sha256": sha256_bytes(validation_scores_bytes),
        "calibration_score_receipt_sha256": calibration_score_receipt_sha,
        "validation_score_receipt_sha256": validation_score_receipt_sha,
        "validation_execution_started": False,
        "operator_attested_pre_validation": True,
        "assurance_scope": "operator_attested_unsigned_nonrelease",
        "release_eligible": False,
    }
    if not isinstance(value, dict) or set(value) != required or value != expected:
        raise ValueError("pre-validation custody artifact binding is invalid")
    return sha256_bytes(artifact_bytes)


def validate_provenance(receipt: dict[str, Any]) -> None:
    producing = receipt.get("producing_git_head")
    if not isinstance(producing, str) or not GIT_SHA.fullmatch(producing):
        raise ValueError("threshold freeze git provenance is invalid")
    current = current_git_head()
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", producing, current], cwd=REPO_ROOT
    )
    if ancestor.returncode != 0:
        raise ValueError("threshold freeze was not produced by an ancestor commit")
    bindings = (
        ("tool_path", "tool_sha256", TOOL_REPO_PATH),
        ("contract_path", "contract_sha256", CONTRACT_REPO_PATH),
    )
    for path_field, sha_field, expected_path in bindings:
        if receipt.get(path_field) != expected_path:
            raise ValueError("threshold freeze provenance path changed")
        committed = git_output(["show", f"{producing}:{expected_path}"])
        if sha256_bytes(committed) != receipt.get(sha_field):
            raise ValueError("threshold freeze provenance differs from committed bytes")


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
        "runtime",
        "score_generator",
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
    if value.get("runtime") != {
        "numpy_version": CALIBRATION_NUMPY_VERSION,
        "score_decimals": SCORE_DECIMALS,
        "rounding": "decimal_half_up",
    } or np.__version__ != CALIBRATION_NUMPY_VERSION:
        raise ValueError("calibration runtime changed")
    if value.get("score_generator") != {
        "path": SCORE_GENERATOR_REPO_PATH, "sha256": SCORE_GENERATOR_SHA256,
        "scanner_evidence_policy": "full_recomputation_accept_calibration_required_only",
        "scanner_path": CANONICAL_SCANNER_REPO_PATH,
        "scanner_sha256": CANONICAL_SCANNER_SHA256,
    }:
        raise ValueError("canonical score generator binding changed")
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
        row["scores"] = {
            method: float(
                Decimal(str(score)).quantize(SCORE_QUANTUM, rounding=ROUND_HALF_UP)
            )
            for method, score in scores.items()
        }
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
    minima = np.ones(replicates, dtype=np.float64)
    observed: dict[str, dict[str, float]] = {}
    for language in contract["languages"]:
        family_ids, indices = plans[language]
        observed[language] = {}
        for axis in contract["axes"]:
            values = np.asarray(
                [method_table[language][axis][family_id] for family_id in family_ids],
                dtype=np.float64,
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
        found = False
        while low <= high:
            middle = (low + high) // 2
            threshold = candidates[middle]
            lower, observed = simultaneous_sensitivity_lower(
                positives[method], threshold, plans, contract
            )
            if lower >= minimum:
                winner, winner_lower, winner_observed = threshold, lower, observed
                found = True
                low = middle + 1
            else:
                high = middle - 1
        if not found:
            raise ValueError(
                f"no {method} threshold meets the simultaneous sensitivity minimum"
            )
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
    producing_head = current_git_head()
    tool_bytes = read_bytes(SCRIPT_PATH, "calibration tool")
    if git_output(["show", f"{producing_head}:{TOOL_REPO_PATH}"]) != tool_bytes:
        raise ValueError("calibration tool differs from its producing commit")
    if git_output(["show", f"{producing_head}:{CONTRACT_REPO_PATH}"]) != contract_bytes:
        raise ValueError("calibration contract differs from its producing commit")
    return {
        "schema_version": schema,
        "status": status,
        "contract_sha256": sha256_bytes(contract_bytes),
        "contract_path": CONTRACT_REPO_PATH,
        "tool_sha256": sha256_bytes(tool_bytes),
        "tool_path": TOOL_REPO_PATH,
        "producing_git_head": producing_head,
        "score_rows_sha256": sha256_bytes(scores_bytes),
        "score_row_count": len(rows),
        "contains_raw_text": False,
        "candidate_model_output_seen": False,
        "release_eligible": False,
        "quality_evidence": False,
        "production_thresholds_approved": False,
        "assurance_scope": "operator_attested_unsigned_pair_semantics_nonrelease",
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
        "operator_attested_noncertifying_calibration",
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
        "contract_path",
        "tool_sha256",
        "tool_path",
        "producing_git_head",
        "score_rows_sha256",
        "score_row_count",
        "contains_raw_text",
        "candidate_model_output_seen",
        "release_eligible",
        "quality_evidence",
        "production_thresholds_approved",
        "assurance_scope",
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
        or value.get("status") != "operator_attested_noncertifying_calibration"
        or value.get("contract_sha256") != contract_sha
        or value.get("release_profile_met") is not True
        or value.get("validation_data_seen") is not False
        or value.get("no_validation_driven_retuning") is not True
        or value.get("contains_raw_text") is not False
        or value.get("candidate_model_output_seen") is not False
        or value.get("release_eligible") is not False
        or value.get("quality_evidence") is not False
        or value.get("production_thresholds_approved") is not False
        or value.get("assurance_scope") != "operator_attested_unsigned_pair_semantics_nonrelease"
    ):
        raise ValueError("threshold freeze receipt is invalid")
    validate_provenance(value)
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
    calibration_scores_bytes: bytes,
    expected_calibration_scores_sha256: str,
) -> dict[str, Any]:
    if not SHA256.fullmatch(expected_freeze_sha256) or sha256_bytes(freeze_bytes) != expected_freeze_sha256:
        raise ValueError("threshold freeze receipt differs from its sealed SHA-256")
    contract = validate_contract(parse_json(contract_bytes, "calibration contract"))
    if (
        not SHA256.fullmatch(expected_calibration_scores_sha256)
        or sha256_bytes(calibration_scores_bytes)
        != expected_calibration_scores_sha256
    ):
        raise ValueError("calibration score rows differ from their sealed SHA-256")
    freeze = validate_freeze_receipt(
        parse_json(freeze_bytes, "threshold freeze receipt"), sha256_bytes(contract_bytes)
    )
    recomputed = build_freeze_receipt(contract_bytes, calibration_scores_bytes)
    # The verifier may run at a descendant commit. Preserve the already
    # authenticated producer identity while recomputing every data-derived field.
    for field in ("producing_git_head", "tool_path", "tool_sha256"):
        recomputed[field] = freeze[field]
    recomputed_freeze = canonical_json(recomputed)
    if recomputed_freeze != freeze_bytes:
        raise ValueError("threshold freeze does not exactly recompute from calibration scores")
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
        "operator_attested_noncertifying_validation_failed_statistics"
        if not passed
        else "operator_attested_noncertifying_validation_passed_statistics"
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
    if not bundle.parent.is_dir():
        raise ValueError("output bundle parent must already exist")
    reserved = False
    try:
        bundle.mkdir()
        reserved = True
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
        if reserved:
            shutil.rmtree(bundle, ignore_errors=True)
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="mode", required=True)
    subparsers.add_parser("approve")
    for mode in ("calibrate", "validate", "pilot"):
        child = subparsers.add_parser(mode)
        child.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
        child.add_argument("--scores", type=Path, required=True)
        child.add_argument("--score-generation-receipt", type=Path, required=True)
        child.add_argument("--upstream-scanner-receipt", type=Path, required=True)
        child.add_argument("--expected-git-head", required=True)
        child.add_argument("--out-bundle", type=Path, required=True)
        if mode == "validate":
            child.add_argument("--freeze-receipt", type=Path, required=True)
            child.add_argument("--calibration-scores", type=Path, required=True)
            child.add_argument("--calibration-score-generation-receipt", type=Path, required=True)
            child.add_argument("--calibration-upstream-scanner-receipt", type=Path, required=True)
            child.add_argument("--custody-artifact", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.mode == "approve":
        raise ValueError(
            "production threshold approval is blocked pending an authenticated native pair-corpus owner"
        )
    if current_git_head() != args.expected_git_head:
        raise ValueError("Git HEAD differs from expected head")
    if subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=no"],
        cwd=REPO_ROOT, check=True, stdout=subprocess.PIPE,
    ).stdout:
        raise ValueError("tracked worktree must be clean")
    contract_bytes = read_bytes(args.contract, "calibration contract")
    scores_bytes = read_bytes(args.scores, "score rows")
    score_receipt_sha, score_receipt_sealing = validate_score_generation_receipt(
        args.score_generation_receipt, args.upstream_scanner_receipt,
        scores_bytes, "validation" if args.mode == "validate" else "calibration",
        contract_bytes, args.expected_git_head,
    )
    if args.mode == "calibrate":
        receipt = build_freeze_receipt(contract_bytes, scores_bytes)
    elif args.mode == "validate":
        freeze_bytes, _, _ = committed_artifact_bytes(
            args.freeze_receipt, args.expected_git_head
        )
        calibration_scores_bytes = read_bytes(
            args.calibration_scores, "calibration score rows"
        )
        calibration_score_receipt_sha, calibration_score_receipt_sealing = validate_score_generation_receipt(
            args.calibration_score_generation_receipt,
            args.calibration_upstream_scanner_receipt,
            calibration_scores_bytes, "calibration", contract_bytes,
            args.expected_git_head,
        )
        custody_sha = validate_custody_artifact(
            args.custody_artifact, freeze_path=args.freeze_receipt,
            calibration_scores_bytes=calibration_scores_bytes,
            validation_scores_bytes=scores_bytes,
            calibration_score_receipt_sha=calibration_score_receipt_sha,
            validation_score_receipt_sha=score_receipt_sha,
            contract_bytes=contract_bytes, expected_head=args.expected_git_head,
            calibration_score_sealing=calibration_score_receipt_sealing,
            validation_score_sealing=score_receipt_sealing,
        )
        receipt = build_validation_receipt(
            contract_bytes,
            scores_bytes,
            freeze_bytes,
            sha256_bytes(freeze_bytes),
            calibration_scores_bytes,
            sha256_bytes(calibration_scores_bytes),
        )
        receipt["authenticated_custody_artifact_sha256"] = custody_sha
        receipt["calibration_score_generation_receipt_sha256"] = calibration_score_receipt_sha
        receipt["validation_score_generation_receipt_sha256"] = score_receipt_sha
    else:
        receipt = build_pilot_receipt(contract_bytes, scores_bytes)
    publish_receipt(args.out_bundle, receipt)
    return 2 if "failed_statistics" in receipt["status"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
