#!/usr/bin/env python3
"""Seal metadata-only Type B V2 authoring assignments and mixed packets."""

from __future__ import annotations

import argparse
from collections import Counter, deque
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from typing import Any, Callable


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
CONTRACT_PATH = (
    REPO_ROOT
    / "scripts/eval/contracts/eg1_type_b_v2_authoring_workflow_v1.json"
)
CONTRACT_SCHEMA = "eg1-type-b-v2-authoring-workflow-contract-v1"
ASSIGNMENT_SCHEMA = "eg1-type-b-v2-authoring-assignment-v1"
PACKET_SCHEMA = "eg1-type-b-v2-authoring-packet-v1"
RECEIPT_SCHEMA = "eg1-type-b-v2-authoring-workflow-receipt-v1"
EXPECTED_ARTIFACTS = [
    "assignment_custody.jsonl",
    "authoring_packets.jsonl",
    "merge_gate_requirements.json",
    "receipt.json",
]
EXPECTED_SCENARIO_FIELDS = [
    "domain",
    "register",
    "difficulty",
    "asr_disfluency_shape",
    "risk",
    "required_entities",
    "required_numbers",
    "required_timing",
    "required_scope",
    "prohibited_edits",
    "primary_behavior",
    "trap",
    "secondary_behaviors",
]
EXPECTED_ALLOCATION_COUNTS = {
    "target_total": 1890,
    "provisional_retained": 23,
    "fresh_required": 1867,
    "replacement_reserves": 23,
    "fresh_authorship_total": 1890,
    "all_slot_records": 1913,
}
ALLOCATION_ROW_FIELDS = {
    "slot_id",
    "semantic_family_id",
    "source",
    "source_case_id",
    "category",
    "length_bucket",
    "tier",
    "subset",
    "trap",
    "author_lane",
    "reviewer_lane",
    "text_authored",
    "benchmark_eligible",
    "training_eligible",
    "candidate_model_output_seen",
}
RESERVE_EXTRA_FIELDS = {"reserved_for_source_case_id"}


class ValidationFailure(ValueError):
    """Raised when a sealed input or fail-closed invariant is invalid."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--allocation-receipt", required=True, type=Path)
    parser.add_argument("--blocked-registry-receipt", required=True, type=Path)
    parser.add_argument("--out-bundle", required=True, type=Path)
    parser.add_argument("--expected-git-head", required=True)
    return parser.parse_args()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_once(path: Path) -> tuple[bytes, str]:
    try:
        value = path.read_bytes()
    except OSError as error:
        raise ValidationFailure(f"required input cannot be read: {path.name}") from error
    return value, sha256_bytes(value)


def parse_object(value: bytes, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationFailure(f"{label} is not valid JSON") from error
    if not isinstance(parsed, dict):
        raise ValidationFailure(f"{label} must be a JSON object")
    return parsed


def parse_rows(value: bytes, label: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        lines = value.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ValidationFailure(f"{label} is not UTF-8") from error
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValidationFailure(f"{label}:{number} is not valid JSON") from error
        if not isinstance(row, dict):
            raise ValidationFailure(f"{label}:{number} must be an object")
        rows.append(row)
    return rows


def encode_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n").encode()


def encode_jsonl(rows: list[dict[str, Any]]) -> bytes:
    return b"".join(
        (json.dumps(row, ensure_ascii=True, sort_keys=True) + "\n").encode()
        for row in rows
    )


def git_output(*arguments: str) -> bytes:
    try:
        return subprocess.run(
            ["git", *arguments],
            cwd=REPO_ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except subprocess.CalledProcessError as error:
        raise ValidationFailure(f"cannot verify Git state: {' '.join(arguments)}") from error


def validate_git_state(expected_head: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", expected_head):
        raise ValidationFailure("expected Git HEAD must be a lowercase 40-character SHA-1")
    actual_head = git_output("rev-parse", "HEAD").decode().strip()
    if actual_head != expected_head:
        raise ValidationFailure("Git HEAD differs from the predeclared commit")
    if git_output("status", "--porcelain", "--untracked-files=no"):
        raise ValidationFailure("tracked worktree must be clean before packet publication")
    for path in (SCRIPT_PATH, CONTRACT_PATH):
        relative = str(path.relative_to(REPO_ROOT))
        committed = git_output("show", f"{actual_head}:{relative}")
        if sha256_bytes(committed) != read_once(path)[1]:
            raise ValidationFailure(f"committed bytes differ from live file: {relative}")
    return actual_head


def validate_ignored_output(path: Path) -> None:
    try:
        relative = path.resolve().relative_to(REPO_ROOT.resolve())
    except ValueError as error:
        raise ValidationFailure("output bundle must be inside the repository") from error
    result = subprocess.run(
        ["git", "check-ignore", "--no-index", "--quiet", str(relative)],
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise ValidationFailure("output bundle must be covered by a Git ignore rule")


def opaque_id(namespace: str, *values: str) -> str:
    digest = sha256_bytes("\0".join((namespace, *values)).encode())
    return f"tb2-{namespace}-{digest[:24]}"


def validate_contract(contract: dict[str, Any], *, strict: bool) -> None:
    required = {
        "schema_version",
        "workflow_id",
        "status",
        "seed",
        "production_inputs",
        "scenario_card",
        "lane_contract",
        "packet_contract",
        "merge_gate_requirements",
        "publication",
    }
    if set(contract) != required:
        raise ValidationFailure("authoring workflow contract top-level schema changed")
    if contract.get("schema_version") != CONTRACT_SCHEMA:
        raise ValidationFailure("authoring workflow contract schema changed")
    if contract.get("workflow_id") != "eg1-type-b-v2-authoring-workflow-2026-07-15":
        raise ValidationFailure("authoring workflow ID changed")
    if contract.get("status") not in {
        "pending_clean_blocked_registry_receipt_authorship_blocked",
        "sealed_registry_bound_metadata_only_authorship_blocked",
    }:
        raise ValidationFailure("authoring workflow dependency status changed")
    if contract.get("seed") != 1265:
        raise ValidationFailure("authoring workflow seed changed")
    inputs = contract.get("production_inputs")
    if not isinstance(inputs, dict) or set(inputs) != {"allocation", "blocked_registry"}:
        raise ValidationFailure("production input binding schema changed")
    allocation = inputs.get("allocation")
    if not isinstance(allocation, dict) or allocation != {
        "receipt_schema": "legacy-type-b-v2-allocation-receipt-v1",
        "receipt_sha256": "aa125a30fef59b93ee646217aa2002fe819cb00823021386f01064bbc4ba4ad8",
        "execution_git_head": "de5b8fbf1a821005fe5014eb61b5d92372f8b2c3",
        "allocation_contract_sha256": "1f683a8e9448fb73a5e763d3342a7cdb9cde452d3be9d7d586b8a372924b67c2",
        "builder_sha256": "f4e4cee02ff38bf0b6ba5473f308b17aa087dd98ca8b05819fcb6aee7e4b6cd0",
        "manifest_sha256": "ac76dd4534b9a96f9cad42f98de071ed007d9d9997a38ff20779cfc8dd1d1844",
        "replacement_reserves_sha256": "40e0c82d707fbea933f28e17439658fea12cf1df2383883f2fec9d834fd6ecb1",
        "counts": EXPECTED_ALLOCATION_COUNTS,
    }:
        raise ValidationFailure("exact allocation receipt binding changed")
    registry = inputs.get("blocked_registry")
    if not isinstance(registry, dict) or set(registry) != {
        "status",
        "receipt_schema",
        "receipt_sha256",
        "execution_git_head",
        "registry_id",
        "allocation_contract_sha256",
        "allocator_builder_sha256",
        "counts",
        "family_artifact",
        "text_hash_artifact",
        "source_coverage_artifact",
        "provisional_decisions_artifact",
        "decision_summary",
    }:
        raise ValidationFailure("blocked registry binding schema changed")
    fixed_registry = {
        "receipt_schema": "eg1-type-b-v2-blocked-registry-receipt-v1",
        "registry_id": "eg1-type-b-v2-blocked-registry-2026-07-15",
        "allocation_contract_sha256": "1f683a8e9448fb73a5e763d3342a7cdb9cde452d3be9d7d586b8a372924b67c2",
        "allocator_builder_sha256": "f4e4cee02ff38bf0b6ba5473f308b17aa087dd98ca8b05819fcb6aee7e4b6cd0",
        "counts": {
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
        },
        "decision_summary": {
            "reason_code": "semantic_family_clearance_not_proven",
            "replace": 23,
            "retain": 0,
            "same_cell_reserves_bound": 23,
        },
    }
    if any(registry.get(key) != value for key, value in fixed_registry.items()):
        raise ValidationFailure("fixed blocked registry interface changed")
    artifact_contracts = {
        "family_artifact": {
            "name": "blocked_family_registry.jsonl",
            "schema_version": "eg1-type-b-v2-blocked-family-v1",
            "validator_source_role": "blocked_family_registry",
            "row_count": 7198,
        },
        "text_hash_artifact": {
            "name": "blocked_text_hashes.jsonl",
            "schema_version": "eg1-type-b-v2-blocked-text-hash-v1",
            "validator_source_role": "blocked_text_hash_registry",
            "row_count": 13733,
        },
        "source_coverage_artifact": {
            "name": "source_coverage.jsonl",
            "schema_version": "eg1-type-b-v2-source-coverage-v1",
            "validator_source_role": None,
            "row_count": 11236,
        },
        "provisional_decisions_artifact": {
            "name": "provisional_decisions.jsonl",
            "schema_version": "eg1-type-b-v2-provisional-decision-v1",
            "validator_source_role": None,
            "row_count": 23,
        },
    }
    for name, fixed_artifact in artifact_contracts.items():
        artifact = registry.get(name)
        if (
            not isinstance(artifact, dict)
            or set(artifact) != {*fixed_artifact, "sha256"}
            or any(artifact.get(key) != value for key, value in fixed_artifact.items())
        ):
            raise ValidationFailure(f"fixed registry artifact interface changed: {name}")
    pending = registry.get("status") == "pending_final_clean_receipt"
    sealed = registry.get("status") == "sealed_final_clean_receipt"
    binding_hashes = [
        registry.get("receipt_sha256"),
        *(registry[name].get("sha256") for name in artifact_contracts),
    ]
    binding_values = [registry.get("execution_git_head"), *binding_hashes]
    if pending:
        if contract.get("status") != "pending_clean_blocked_registry_receipt_authorship_blocked" or any(
            value is not None for value in binding_values
        ):
            raise ValidationFailure("pending registry binding must remain empty and blocked")
    elif sealed:
        if contract.get("status") != "sealed_registry_bound_metadata_only_authorship_blocked" or not all(
            isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)
            for value in binding_hashes
        ):
            raise ValidationFailure("sealed registry binding is incomplete or malformed")
        if not re.fullmatch(r"[0-9a-f]{40}", registry["execution_git_head"]):
            raise ValidationFailure("sealed registry producing commit is malformed")
    else:
        raise ValidationFailure("blocked registry dependency status is invalid")
    publication = contract.get("publication")
    if publication != {
        "artifact_names": EXPECTED_ARTIFACTS,
        "exclusive_bundle": True,
        "receipt_last": True,
        "metadata_only": True,
        "benchmark_prose_allowed": False,
        "raw_source_ids_allowed": False,
        "candidate_model_output_allowed": False,
    }:
        raise ValidationFailure("authoring publication contract changed")
    lane = contract.get("lane_contract")
    if lane != {
        "identity_status": "unassigned",
        "required_distinct_lanes": [
            "author",
            "semantic_minimal_edit_reviewer",
            "family_leakage_reviewer",
        ],
        "human_identity_fields_must_remain_null": True,
        "candidate_model_output_enabled": False,
    }:
        raise ValidationFailure("required independent lane contract changed")
    card = contract.get("scenario_card")
    if card != {
        "required_before_prose": True,
        "required_fields": EXPECTED_SCENARIO_FIELDS,
        "preassigned_ids": [
            "scenario_family_id",
            "scenario_id",
            "authoring_template_id",
        ],
    }:
        raise ValidationFailure("scenario card contract changed")
    packet = contract.get("packet_contract")
    if packet != {
        "minimum_slots": 12,
        "maximum_slots": 16,
        "expected_slots_per_packet": 15,
        "mixed_category_minimum": 2,
        "include_custody_states": [
            "fresh_primary",
            "activated_replacement_reserve",
        ],
    }:
        raise ValidationFailure("mixed packet contract changed")
    expected_gates = {
        "author_source_identity_minimum": 8,
        "human_native_original_fraction_minimum": 0.5,
        "synthetic_generator_family_minimum": 3,
        "synthetic_provider_fraction_maximum_overall": 0.2,
        "synthetic_provider_fraction_maximum_per_category": 0.25,
        "semantic_and_leakage_reviewers_must_be_separate": True,
        "stratified_double_coding_fraction_minimum": 0.15,
        "stratified_double_coding_fraction_maximum": 0.2,
        "high_risk_double_review_fraction": 1.0,
        "wave_stop_if_raw_agreement_below": 0.95,
        "wave_stop_if_reliability_below": 0.8,
        "all_statuses": "pending",
    }
    if contract.get("merge_gate_requirements") != expected_gates:
        raise ValidationFailure("TYPE-B-003 merge gate requirements changed")
    if strict:
        live = parse_object(CONTRACT_PATH.read_bytes(), "live workflow contract")
        if contract != live:
            raise ValidationFailure("runtime contract differs from sealed workflow contract")


def require_production_ready(contract: dict[str, Any]) -> None:
    registry_binding = contract["production_inputs"]["blocked_registry"]
    if (
        registry_binding.get("status") != "sealed_final_clean_receipt"
        or not isinstance(registry_binding.get("receipt_sha256"), str)
        or not isinstance(registry_binding.get("execution_git_head"), str)
        or any(
            not isinstance(registry_binding[name].get("sha256"), str)
            for name in (
                "family_artifact",
                "text_hash_artifact",
                "source_coverage_artifact",
                "provisional_decisions_artifact",
            )
        )
    ):
        raise ValidationFailure(
            "production authoring publication is blocked pending the final clean registry receipt"
        )


def require_sha(value: Any, expected: str, label: str) -> None:
    if value != expected:
        raise ValidationFailure(f"{label} differs from the sealed contract")


def validate_allocation_receipt(
    receipt: dict[str, Any], expected: dict[str, Any], receipt_sha: str
) -> tuple[dict[str, Any], dict[str, Any]]:
    require_sha(receipt_sha, expected["receipt_sha256"], "allocation receipt hash")
    required_values = {
        "status": "type_b_v2_slots_sealed_text_generation_blocked",
        "seed": 1265,
        "candidate_model_output_seen": False,
        "execution_git_head": expected["execution_git_head"],
        "publication": "exclusive_bundle_receipt_last",
    }
    for key, value in required_values.items():
        if receipt.get(key) != value:
            raise ValidationFailure(f"allocation receipt {key} changed")
    for key, value in expected["counts"].items():
        if receipt.get(key) != value:
            raise ValidationFailure(f"allocation receipt count changed: {key}")
    contract = receipt.get("allocation_contract")
    builder = receipt.get("builder")
    manifest = receipt.get("manifest")
    reserves = receipt.get("replacement_reserve_manifest")
    if not all(isinstance(item, dict) for item in (contract, builder, manifest, reserves)):
        raise ValidationFailure("allocation receipt artifact bindings are missing")
    require_sha(contract.get("sha256"), expected["allocation_contract_sha256"], "allocation contract hash")
    require_sha(builder.get("sha256"), expected["builder_sha256"], "allocator builder hash")
    require_sha(manifest.get("sha256"), expected["manifest_sha256"], "allocation manifest hash")
    require_sha(reserves.get("sha256"), expected["replacement_reserves_sha256"], "replacement reserve hash")
    eligibility = receipt.get("eligibility_gate")
    if not isinstance(eligibility, dict) or eligibility.get("all_rows_benchmark_eligible_now") is not False:
        raise ValidationFailure("allocation eligibility must remain blocked")
    return manifest, reserves


def validate_registry_receipt(
    receipt: dict[str, Any], expected: dict[str, Any], receipt_sha: str
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any]]:
    require_sha(receipt_sha, expected["receipt_sha256"], "blocked registry receipt hash")
    for key, value in {
        "schema_version": expected["receipt_schema"],
        "status": "sources_sealed_all_provisional_replaced_authorship_blocked",
        "execution_git_head": expected["execution_git_head"],
        "registry_id": expected["registry_id"],
        "publication": "exclusive_bundle_receipt_last",
    }.items():
        if receipt.get(key) != value:
            raise ValidationFailure(f"blocked registry receipt {key} changed")
    allocator = receipt.get("allocator")
    if not isinstance(allocator, dict):
        raise ValidationFailure("blocked registry allocator binding is missing")
    require_sha(allocator.get("allocation_contract_sha256"), expected["allocation_contract_sha256"], "registry allocation contract hash")
    require_sha(allocator.get("builder_sha256"), expected["allocator_builder_sha256"], "registry allocator builder hash")
    if receipt.get("decision_summary") != expected["decision_summary"]:
        raise ValidationFailure("blocked registry replacement decision summary changed")
    privacy = receipt.get("privacy")
    authorship = receipt.get("authorship_gate")
    if not isinstance(privacy, dict) or not (
        privacy.get("metadata_only") is True
        and privacy.get("private_source_text_published") is False
        and privacy.get("private_source_row_ids_published_raw") is False
        and privacy.get("other_source_row_ids_published_raw") is False
    ):
        raise ValidationFailure("blocked registry privacy gate changed")
    expected_authorship_slots = expected.get("fresh_slots_required", 1890)
    if not isinstance(authorship, dict) or authorship != {
        "candidate_model_output_seen": False,
        "fresh_authorship_authorized": False,
        "fresh_benchmark_prose_authored": False,
        "fresh_slots_required": expected_authorship_slots,
    }:
        raise ValidationFailure("blocked registry authorship gate changed")
    if receipt.get("candidate_clearance_contract") != {
        "provenance_field": "blocked_family_clearances",
        "registry_artifact": "blocked_family_registry.jsonl",
        "registry_binding_field": "registry_sha256",
        "candidate_binding_field": "candidate_semantic_family_id",
        "required_status": "cleared",
        "independent_review_required": True,
    }:
        raise ValidationFailure("blocked family independent-clearance contract changed")
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, dict):
        raise ValidationFailure("blocked registry artifact bindings are missing")
    family_expected = expected["family_artifact"]
    text_expected = expected["text_hash_artifact"]
    coverage_expected = expected["source_coverage_artifact"]
    decisions_expected = expected["provisional_decisions_artifact"]
    expected_artifacts = (
        family_expected,
        text_expected,
        coverage_expected,
        decisions_expected,
    )
    artifact_names = [artifact["name"] for artifact in expected_artifacts]
    artifact_hashes = [artifact["sha256"] for artifact in expected_artifacts]
    if len(set(artifact_names)) != 4 or len(set(artifact_hashes)) != 4:
        raise ValidationFailure("all four blocked registry inputs must be distinct")
    if set(artifacts) != set(artifact_names):
        raise ValidationFailure("blocked registry receipt must authenticate exactly four artifacts")
    for artifact_expected in expected_artifacts:
        observed = artifacts.get(artifact_expected["name"])
        if not isinstance(observed, dict):
            raise ValidationFailure(f"registry artifact missing: {artifact_expected['name']}")
        require_sha(observed.get("sha256"), artifact_expected["sha256"], f"{artifact_expected['name']} hash")
        if observed.get("row_count") != artifact_expected["row_count"]:
            raise ValidationFailure(f"{artifact_expected['name']} row count changed")
        if observed.get("validator_source_role") != artifact_expected["validator_source_role"]:
            raise ValidationFailure(f"{artifact_expected['name']} validator source role changed")
    if receipt.get("counts") != expected["counts"]:
        raise ValidationFailure("blocked registry receipt aggregate counts changed")
    return family_expected, text_expected, coverage_expected, decisions_expected


def resolve_artifact(receipt_path: Path, artifact: dict[str, Any], label: str) -> tuple[Path, bytes]:
    name = artifact.get("path") or artifact.get("name")
    if not isinstance(name, str) or Path(name).name != name:
        raise ValidationFailure(f"{label} artifact path must be a bundle-local filename")
    path = receipt_path.parent / name
    value, digest = read_once(path)
    require_sha(digest, artifact["sha256"], f"{label} artifact hash")
    return path, value


def validate_allocation_rows(
    manifest_rows: list[dict[str, Any]],
    reserve_rows: list[dict[str, Any]],
    decision_rows: list[dict[str, Any]],
    counts: dict[str, int],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    if len(manifest_rows) != counts["target_total"] or len(reserve_rows) != counts["replacement_reserves"]:
        raise ValidationFailure("allocation row counts do not match the sealed receipt")
    seen_slots: set[str] = set()
    seen_families: set[str] = set()
    fresh: list[dict[str, Any]] = []
    replaced: list[dict[str, Any]] = []
    for row, reserve in [*( (row, False) for row in manifest_rows), *( (row, True) for row in reserve_rows)]:
        expected_fields = ALLOCATION_ROW_FIELDS | (RESERVE_EXTRA_FIELDS if reserve else set())
        if set(row) != expected_fields:
            raise ValidationFailure("allocation row schema changed")
        slot_id = row.get("slot_id")
        family_id = row.get("semantic_family_id")
        if not isinstance(slot_id, str) or not slot_id or slot_id in seen_slots:
            raise ValidationFailure("allocation slot IDs must be nonempty and globally unique")
        if not isinstance(family_id, str) or not family_id or family_id in seen_families:
            raise ValidationFailure("allocation family IDs must be nonempty and globally unique")
        seen_slots.add(slot_id)
        seen_families.add(family_id)
        if row.get("benchmark_eligible") is not False or row.get("training_eligible") is not False or row.get("candidate_model_output_seen") is not False:
            raise ValidationFailure("allocation row eligibility must remain blocked")
        if not isinstance(row.get("category"), str) or not row["category"]:
            raise ValidationFailure("allocation category is invalid")
        if not isinstance(row.get("length_bucket"), int):
            raise ValidationFailure("allocation length bucket is invalid")
        if reserve:
            if row.get("source") != "fresh_replacement_reserve_model_blind_required" or row.get("text_authored") is not False:
                raise ValidationFailure("replacement reserve is not model-blind and unauthored")
        elif row.get("source") == "fresh_model_blind_required":
            if row.get("source_case_id") is not None or row.get("text_authored") is not False:
                raise ValidationFailure("fresh primary allocation is not model-blind and unauthored")
            fresh.append(row)
        elif row.get("source") == "provisional_retained_requires_blind_family_review":
            if not isinstance(row.get("source_case_id"), str) or row.get("text_authored") is not True:
                raise ValidationFailure("provisional custody row changed")
            replaced.append(row)
        else:
            raise ValidationFailure("unknown allocation source lane")
    if len(fresh) != counts["fresh_required"] or len(replaced) != counts["provisional_retained"]:
        raise ValidationFailure("allocation source-lane counts changed")
    replacement_keys = [row["reserved_for_source_case_id"] for row in reserve_rows]
    replaced_keys = [row["source_case_id"] for row in replaced]
    if len(set(replacement_keys)) != len(replacement_keys) or set(replacement_keys) != set(replaced_keys):
        raise ValidationFailure("replacement reserve custody is missing, duplicated, or swapped")
    reserve_mapping = {
        row["reserved_for_source_case_id"]: row["slot_id"] for row in reserve_rows
    }
    decision_mapping = {
        row["source_case_id"]: row["replacement_reserve_slot_id"]
        for row in decision_rows
    }
    if len(decision_rows) != counts["replacement_reserves"] or decision_mapping != reserve_mapping:
        raise ValidationFailure("provisional decisions do not exactly bind all replacement reserves")
    return fresh, replaced, reserve_rows


def validate_registry_rows(
    family_rows: list[dict[str, Any]],
    text_rows: list[dict[str, Any]],
    coverage_rows: list[dict[str, Any]],
    decision_rows: list[dict[str, Any]],
    family_expected: dict[str, Any],
    text_expected: dict[str, Any],
    coverage_expected: dict[str, Any],
    decisions_expected: dict[str, Any],
) -> None:
    if (
        len(family_rows) != family_expected["row_count"]
        or len(text_rows) != text_expected["row_count"]
        or len(coverage_rows) != coverage_expected["row_count"]
        or len(decision_rows) != decisions_expected["row_count"]
    ):
        raise ValidationFailure("blocked registry artifact row count changed")
    family_ids: set[str] = set()
    for row in family_rows:
        if row.get("schema_version") != family_expected["schema_version"]:
            raise ValidationFailure("blocked family registry schema changed")
        value = row.get("semantic_family_id")
        if not isinstance(value, str) or not value or value in family_ids:
            raise ValidationFailure("blocked family registry IDs are invalid")
        family_ids.add(value)
    text_keys: set[tuple[str, str]] = set()
    for row in text_rows:
        if row.get("schema_version") != text_expected["schema_version"]:
            raise ValidationFailure("blocked text-hash registry schema changed")
        kind = row.get("field_kind")
        digest = row.get("normalized_text_sha256")
        if kind not in {"input", "output"} or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValidationFailure("blocked text-hash registry entry is invalid")
        key = (kind, digest)
        if key in text_keys:
            raise ValidationFailure("blocked text-hash registry contains duplicates")
        text_keys.add(key)
    coverage_ids: set[str] = set()
    for row in coverage_rows:
        if row.get("schema_version") != coverage_expected["schema_version"]:
            raise ValidationFailure("source coverage registry schema changed")
        registry_entry_id = row.get("registry_entry_id")
        source_row_hash = row.get("source_row_id_sha256")
        if (
            not isinstance(registry_entry_id, str)
            or not registry_entry_id
            or registry_entry_id in coverage_ids
            or not isinstance(source_row_hash, str)
            or not re.fullmatch(r"[0-9a-f]{64}", source_row_hash)
        ):
            raise ValidationFailure("source coverage registry entry is invalid")
        coverage_ids.add(registry_entry_id)
    decision_case_ids: set[str] = set()
    decision_reserve_ids: set[str] = set()
    for row in decision_rows:
        if row.get("schema_version") != decisions_expected["schema_version"]:
            raise ValidationFailure("provisional decision registry schema changed")
        case_id = row.get("source_case_id")
        reserve_id = row.get("replacement_reserve_slot_id")
        if (
            not isinstance(case_id, str)
            or not case_id
            or case_id in decision_case_ids
            or not isinstance(reserve_id, str)
            or not reserve_id
            or reserve_id in decision_reserve_ids
            or row.get("decision") != "replace"
            or row.get("reason_code") != "semantic_family_clearance_not_proven"
            or row.get("candidate_model_output_seen") is not False
            or row.get("fresh_benchmark_prose_authored") is not False
        ):
            raise ValidationFailure("provisional replacement decision is invalid")
        decision_case_ids.add(case_id)
        decision_reserve_ids.add(reserve_id)


def assignment_row(
    row: dict[str, Any],
    custody: str,
    active: bool,
    replacement_pair_id: str | None = None,
) -> dict[str, Any]:
    source_key = str(row.get("source_case_id") or row.get("reserved_for_source_case_id") or "none")
    fingerprint = opaque_id("allocation", row["slot_id"], row["semantic_family_id"], source_key)
    if not active:
        return {
            "schema_version": ASSIGNMENT_SCHEMA,
            "assignment_fingerprint": fingerprint,
            "custody_state": custody,
            "replacement_pair_id": replacement_pair_id,
            "category": row["category"],
            "length_bucket": row["length_bucket"],
            "tier": row["tier"],
            "subset": row["subset"],
            "trap": bool(row["trap"]),
            "authoring_enabled": False,
            "replacement_status": "replaced_by_bound_reserve",
            "scenario_family_id": None,
            "scenario_id": None,
            "authoring_template_id": None,
            "lane_ids": None,
            "human_identities": None,
            "scenario_card_status": "not_applicable_replaced_custody",
            "prose_authored": False,
            "candidate_model_output_seen": False,
            "benchmark_eligible": False,
            "training_eligible": False,
        }
    scenario_family = opaque_id("scenario-family", row["semantic_family_id"], row["category"])
    scenario = opaque_id("scenario", row["slot_id"], scenario_family)
    template = opaque_id("template", row["category"], str(row["length_bucket"]), str(bool(row["trap"])))
    lanes = {
        "author": opaque_id("lane-author", fingerprint),
        "semantic_minimal_edit_reviewer": opaque_id("lane-semantic-review", fingerprint),
        "family_leakage_reviewer": opaque_id("lane-leakage-review", fingerprint),
    }
    if len(set(lanes.values())) != 3:
        raise ValidationFailure("author and reviewer lanes are not distinct")
    return {
        "schema_version": ASSIGNMENT_SCHEMA,
        "assignment_fingerprint": fingerprint,
        "custody_state": custody,
        "replacement_pair_id": replacement_pair_id,
        "category": row["category"],
        "length_bucket": row["length_bucket"],
        "tier": row["tier"],
        "subset": row["subset"],
        "trap": bool(row["trap"]),
        "authoring_enabled": False,
        "replacement_status": "activated" if custody == "activated_replacement_reserve" else "not_required",
        "scenario_family_id": scenario_family,
        "scenario_id": scenario,
        "authoring_template_id": template,
        "lane_ids": lanes,
        "human_identities": {
            "author": None,
            "source": None,
            "synthetic_generator_family": None,
            "synthetic_provider": None,
            "semantic_minimal_edit_reviewer": None,
            "family_leakage_reviewer": None,
        },
        "scenario_card_status": "required_unwritten",
        "prose_authored": False,
        "candidate_model_output_seen": False,
        "benchmark_eligible": False,
        "training_eligible": False,
    }


def packet_sizes(total: int, minimum: int, maximum: int, preferred: int) -> list[int]:
    candidates: list[list[int]] = []
    for count in range((total + maximum - 1) // maximum, total // minimum + 1):
        base, remainder = divmod(total, count)
        if minimum <= base <= maximum and (remainder == 0 or base + 1 <= maximum):
            sizes = [base + 1] * remainder + [base] * (count - remainder)
            if all(minimum <= size <= maximum for size in sizes):
                candidates.append(
                    sorted(sizes, key=lambda size: (abs(size - preferred), -size))
                )
    if not candidates:
        raise ValidationFailure("active assignments cannot be partitioned into bounded packets")
    return min(
        candidates,
        key=lambda sizes: (
            sum(abs(size - preferred) for size in sizes),
            max(abs(size - preferred) for size in sizes),
            len(sizes),
        ),
    )


def mixed_order(assignments: list[dict[str, Any]], seed: int) -> list[dict[str, Any]]:
    queues: dict[str, deque[dict[str, Any]]] = {}
    for category in sorted({row["category"] for row in assignments}):
        members = [row for row in assignments if row["category"] == category]
        members.sort(key=lambda row: sha256_bytes(f"{seed}|{row['assignment_fingerprint']}".encode()))
        queues[category] = deque(members)
    ordered: list[dict[str, Any]] = []
    category_order = sorted(queues, key=lambda category: sha256_bytes(f"{seed}|{category}".encode()))
    cursor = 0
    while queues:
        category_order = [category for category in category_order if category in queues]
        category = category_order[cursor % len(category_order)]
        ordered.append(queues[category].popleft())
        if not queues[category]:
            del queues[category]
        cursor += 1
    return ordered


def build_outputs(
    contract: dict[str, Any],
    manifest_rows: list[dict[str, Any]],
    reserve_rows: list[dict[str, Any]],
    decision_rows: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    counts = contract["production_inputs"]["allocation"]["counts"]
    fresh, replaced, reserves = validate_allocation_rows(
        manifest_rows, reserve_rows, decision_rows, counts
    )
    reserve_by_case = {
        row["reserved_for_source_case_id"]: row for row in reserves
    }
    pair_ids = {
        case_id: opaque_id(
            "replacement-pair",
            case_id,
            reserve["slot_id"],
            reserve["semantic_family_id"],
        )
        for case_id, reserve in reserve_by_case.items()
    }
    assignments = [
        *(assignment_row(row, "fresh_primary", True) for row in fresh),
        *(
            assignment_row(
                row,
                "replaced_provisional_custody",
                False,
                pair_ids[row["source_case_id"]],
            )
            for row in replaced
        ),
        *(
            assignment_row(
                row,
                "activated_replacement_reserve",
                True,
                pair_ids[row["reserved_for_source_case_id"]],
            )
            for row in reserves
        ),
    ]
    assignments.sort(key=lambda row: row["assignment_fingerprint"])
    active = [row for row in assignments if row["custody_state"] in contract["packet_contract"]["include_custody_states"]]
    if len(active) != counts["fresh_authorship_total"] or len(assignments) != counts["all_slot_records"]:
        raise ValidationFailure("final assignment or reserve custody total changed")
    if len({row["assignment_fingerprint"] for row in assignments}) != len(assignments):
        raise ValidationFailure("assignment fingerprints are not unique")
    ordered = mixed_order(active, int(contract["seed"]))
    packet_contract = contract["packet_contract"]
    sizes = packet_sizes(
        len(ordered),
        packet_contract["minimum_slots"],
        packet_contract["maximum_slots"],
        packet_contract["expected_slots_per_packet"],
    )
    packets: list[dict[str, Any]] = []
    offset = 0
    for index, size in enumerate(sizes, 1):
        members = ordered[offset : offset + size]
        offset += size
        category_counts = dict(sorted(Counter(row["category"] for row in members).items()))
        if len(category_counts) < packet_contract["mixed_category_minimum"]:
            raise ValidationFailure("deterministic packet is not category-mixed")
        packets.append(
            {
                "schema_version": PACKET_SCHEMA,
                "packet_id": opaque_id("packet", str(contract["seed"]), str(index), *(row["assignment_fingerprint"] for row in members)),
                "packet_index": index,
                "slot_count": size,
                "assignment_fingerprints": [row["assignment_fingerprint"] for row in members],
                "category_counts": category_counts,
                "custody_counts": dict(sorted(Counter(row["custody_state"] for row in members).items())),
                "scenario_cards_complete": False,
                "human_identities_assigned": False,
                "prose_authored": False,
                "candidate_model_output_seen": False,
                "merge_eligible": False,
            }
        )
    if offset != len(ordered) or sum(row["slot_count"] for row in packets) != len(active):
        raise ValidationFailure("packet membership does not cover active assignments exactly once")
    requirements = {
        "schema_version": "eg1-type-b-v2-merge-gate-requirements-v1",
        "status": "pending",
        "merge_eligible": False,
        "requirements": [
            {"requirement": key, "threshold": value, "status": "pending", "observed": None, "satisfied": False}
            for key, value in contract["merge_gate_requirements"].items()
            if key != "all_statuses"
        ],
        "review_roles": {
            "semantic_minimal_edit": {"assigned_identity": None, "status": "pending"},
            "family_leakage": {"assigned_identity": None, "status": "pending"},
        },
        "wave_metrics": {"raw_agreement": None, "reliability": None, "status": "not_measured_stop"},
        "candidate_model_output_seen": False,
    }
    return assignments, packets, requirements


def write_exclusive(path: Path, value: bytes) -> None:
    with path.open("xb") as handle:
        written = handle.write(value)
        if written != len(value):
            raise OSError(f"short write for {path.name}")
        handle.flush()
        os.fsync(handle.fileno())


def build_bundle(
    *, contract: dict[str, Any], contract_sha: str, allocation_receipt_path: Path,
    registry_receipt_path: Path, output: Path, execution_git_head: str,
    pre_receipt_check: Callable[[], None] | None = None,
) -> dict[str, Any]:
    allocation_receipt_bytes, allocation_receipt_sha = read_once(allocation_receipt_path)
    registry_receipt_bytes, registry_receipt_sha = read_once(registry_receipt_path)
    allocation_receipt = parse_object(allocation_receipt_bytes, "allocation receipt")
    registry_receipt = parse_object(registry_receipt_bytes, "blocked registry receipt")
    expected_inputs = contract["production_inputs"]
    manifest_meta, reserve_meta = validate_allocation_receipt(allocation_receipt, expected_inputs["allocation"], allocation_receipt_sha)
    family_meta, text_meta, coverage_meta, decisions_meta = validate_registry_receipt(
        registry_receipt,
        expected_inputs["blocked_registry"],
        registry_receipt_sha,
    )
    if allocation_receipt["allocation_contract"]["sha256"] != registry_receipt["allocator"]["allocation_contract_sha256"] or allocation_receipt["builder"]["sha256"] != registry_receipt["allocator"]["builder_sha256"]:
        raise ValidationFailure("allocation and blocked registry receipts are not bound to the same allocator")
    manifest_path, manifest_bytes = resolve_artifact(allocation_receipt_path, manifest_meta, "allocation manifest")
    reserve_path, reserve_bytes = resolve_artifact(allocation_receipt_path, reserve_meta, "replacement reserve")
    family_path, family_bytes = resolve_artifact(registry_receipt_path, family_meta, "blocked family registry")
    text_path, text_bytes = resolve_artifact(registry_receipt_path, text_meta, "blocked text-hash registry")
    coverage_path, coverage_bytes = resolve_artifact(
        registry_receipt_path, coverage_meta, "source coverage registry"
    )
    decisions_path, decisions_bytes = resolve_artifact(
        registry_receipt_path, decisions_meta, "provisional decisions registry"
    )
    manifest_rows = parse_rows(manifest_bytes, "allocation manifest")
    reserve_rows = parse_rows(reserve_bytes, "replacement reserves")
    family_rows = parse_rows(family_bytes, "blocked family registry")
    text_rows = parse_rows(text_bytes, "blocked text-hash registry")
    coverage_rows = parse_rows(coverage_bytes, "source coverage registry")
    decision_rows = parse_rows(decisions_bytes, "provisional decisions registry")
    validate_registry_rows(
        family_rows,
        text_rows,
        coverage_rows,
        decision_rows,
        family_meta,
        text_meta,
        coverage_meta,
        decisions_meta,
    )
    assignments, packets, requirements = build_outputs(
        contract, manifest_rows, reserve_rows, decision_rows
    )
    artifact_bytes = {
        "assignment_custody.jsonl": encode_jsonl(assignments),
        "authoring_packets.jsonl": encode_jsonl(packets),
        "merge_gate_requirements.json": encode_json(requirements),
    }
    counts = Counter(row["custody_state"] for row in assignments)
    receipt = {
        "schema_version": RECEIPT_SCHEMA,
        "status": "metadata_packets_sealed_authorship_and_merge_blocked",
        "execution_git_head": execution_git_head,
        "contract": {"path": str(CONTRACT_PATH.relative_to(REPO_ROOT)), "sha256": contract_sha, "schema_version": CONTRACT_SCHEMA},
        "builder": {
            "path": str(SCRIPT_PATH.relative_to(REPO_ROOT)),
            "sha256": read_once(SCRIPT_PATH)[1],
        },
        "inputs": {
            "allocation_receipt_sha256": allocation_receipt_sha,
            "blocked_registry_receipt_sha256": registry_receipt_sha,
            "blocked_family_registry_sha256": family_meta["sha256"],
            "blocked_text_hash_registry_sha256": text_meta["sha256"],
            "source_coverage_registry_sha256": coverage_meta["sha256"],
            "provisional_decisions_registry_sha256": decisions_meta["sha256"],
            "distinct_registry_artifacts": len(
                {
                    family_meta["sha256"],
                    text_meta["sha256"],
                    coverage_meta["sha256"],
                    decisions_meta["sha256"],
                }
            )
            == 4,
        },
        "counts": {
            "final_assignments": counts["fresh_primary"] + counts["activated_replacement_reserve"],
            "fresh_primary": counts["fresh_primary"],
            "activated_replacement_reserve": counts["activated_replacement_reserve"],
            "replaced_provisional_custody": counts["replaced_provisional_custody"],
            "all_custody_records": len(assignments),
            "packets": len(packets),
            "packet_slots": sum(row["slot_count"] for row in packets),
        },
        "artifacts": {
            "assignment_custody.jsonl": {
                "sha256": sha256_bytes(artifact_bytes["assignment_custody.jsonl"]),
                "bytes": len(artifact_bytes["assignment_custody.jsonl"]),
                "row_count": len(assignments),
            },
            "authoring_packets.jsonl": {
                "sha256": sha256_bytes(artifact_bytes["authoring_packets.jsonl"]),
                "bytes": len(artifact_bytes["authoring_packets.jsonl"]),
                "row_count": len(packets),
            },
            "merge_gate_requirements.json": {
                "sha256": sha256_bytes(artifact_bytes["merge_gate_requirements.json"]),
                "bytes": len(artifact_bytes["merge_gate_requirements.json"]),
                "object_count": 1,
            },
        },
        "authorship_gate": {
            "scenario_cards_complete": False,
            "human_or_source_identities_assigned": False,
            "author_reviewer_identity_separation_verified": False,
            "candidate_model_output_seen": False,
            "benchmark_prose_authored": False,
            "authorship_authorized": False,
        },
        "merge_gate": {"status": "pending", "requirements_satisfied": 0, "merge_eligible": False},
        "privacy": {"metadata_only": True, "raw_source_ids_published": False, "benchmark_prose_published": False, "candidate_output_published": False},
        "publication": "exclusive_bundle_receipt_last",
    }
    receipt_bytes = encode_json(receipt)
    input_snapshots = {
        allocation_receipt_path: allocation_receipt_sha,
        registry_receipt_path: registry_receipt_sha,
        manifest_path: sha256_bytes(manifest_bytes),
        reserve_path: sha256_bytes(reserve_bytes),
        family_path: sha256_bytes(family_bytes),
        text_path: sha256_bytes(text_bytes),
        coverage_path: sha256_bytes(coverage_bytes),
        decisions_path: sha256_bytes(decisions_bytes),
    }
    created = False
    try:
        output.mkdir()
        created = True
        for name in EXPECTED_ARTIFACTS[:-1]:
            write_exclusive(output / name, artifact_bytes[name])
        for path, digest in input_snapshots.items():
            if read_once(path)[1] != digest:
                raise RuntimeError(f"sealed input changed during publication: {path.name}")
        if pre_receipt_check is not None:
            pre_receipt_check()
        write_exclusive(output / "receipt.json", receipt_bytes)
    except BaseException:
        if created:
            shutil.rmtree(output)
        raise
    return receipt


def main() -> int:
    args = parse_args()
    output = args.out_bundle.expanduser()
    if output.exists() or output.is_symlink():
        raise SystemExit("--out-bundle already exists; refusing to overwrite evidence")
    if not output.parent.is_dir():
        raise SystemExit("--out-bundle parent directory must already exist")
    validate_ignored_output(output)
    execution_git_head = validate_git_state(args.expected_git_head)
    contract_bytes, contract_sha = read_once(CONTRACT_PATH)
    contract = parse_object(contract_bytes, "authoring workflow contract")
    validate_contract(contract, strict=True)
    require_production_ready(contract)
    receipt = build_bundle(
        contract=contract,
        contract_sha=contract_sha,
        allocation_receipt_path=args.allocation_receipt.expanduser(),
        registry_receipt_path=args.blocked_registry_receipt.expanduser(),
        output=output,
        execution_git_head=execution_git_head,
        pre_receipt_check=lambda: validate_git_state(args.expected_git_head),
    )
    print(json.dumps(receipt["counts"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
