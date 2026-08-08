#!/usr/bin/env python3
"""Allocate, launch, and seal the 800-row multilingual V2 development corpus.

Allocation and launch are metadata-only. Merge is the first stage allowed to
consume benchmark prose, and it writes an evaluation-authorized bundle only
after the private roster, independent native reviews, and leakage evidence all
pass.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from typing import Any, Callable, Iterable, Sequence

import multilingual_benchmark_v2 as v2
import scan_eg1_multilingual_development_leakage as leakage_scanner


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
CONTRACT_PATH = (
    REPO_ROOT
    / "scripts/eval/contracts/eg1_multilingual_development_authoring_v1.json"
)
BENCHMARK_VALIDATOR_PATH = Path(v2.__file__).resolve()
BENCHMARK_SCHEMA_PATH = SCRIPT_PATH.with_name("multilingual_benchmark_v2.schema.json")
RATING_SCHEMA_PATH = v2.RATING_SCHEMA_PATH

CONTRACT_SCHEMA = "eg1-multilingual-development-authoring-contract-v1"
ALLOCATION_ROW_SCHEMA = "eg1-multilingual-development-allocation-v1"
PACKET_SCHEMA = "eg1-multilingual-development-packet-v1"
ALLOCATION_RECEIPT_SCHEMA = "eg1-multilingual-development-allocation-receipt-v1"
ROSTER_SCHEMA = "eg1-multilingual-development-private-roster-v1"
ASSIGNMENT_SCHEMA = "eg1-multilingual-development-assignment-v1"
ASSIGNED_PACKET_SCHEMA = "eg1-multilingual-development-assigned-packet-v1"
LAUNCH_RECEIPT_SCHEMA = "eg1-multilingual-development-launch-receipt-v1"
NATIVE_REVIEW_SEAL_SCHEMA = "eg1-multilingual-development-native-review-seal-v1"
CONTRAST_COMPARABILITY_SEAL_SCHEMA = (
    "eg1-multilingual-development-contrast-comparability-seal-v1"
)
LEAKAGE_SOURCE_RECEIPT_SCHEMA = "eg1-multilingual-leakage-source-receipt-v1"
LEAKAGE_INVENTORY_SCHEMA = "eg1-multilingual-leakage-inventory-v1"
MERGE_RECEIPT_SCHEMA = "eg1-multilingual-development-merge-receipt-v1"
SHARED_BRIEF_REGISTRY_SCHEMA = (
    "eg1-multilingual-development-shared-concept-brief-registry-v1"
)
SHARED_BRIEF_RECEIPT_SCHEMA = (
    "eg1-multilingual-development-shared-concept-brief-receipt-v1"
)
ASSURANCE_SCOPE = (
    "operator_attested_unsigned_private_evidence_reopened_by_verifier"
)
APPROVED_SCANNER_ID = leakage_scanner.SCHEMA_VERSION
APPROVED_SCANNER_PATH = "scripts/eval/scan_eg1_multilingual_development_leakage.py"
APPROVED_SCANNER_CONTRACT_PATH = (
    "scripts/eval/contracts/eg1_multilingual_development_leakage_scanner_v1.json"
)
LEAKAGE_SCANNER_CONTRACT_PATH = REPO_ROOT / APPROVED_SCANNER_CONTRACT_PATH

ALLOCATION_ARTIFACTS = (
    "allocation.jsonl",
    "author_packets.jsonl",
    "reviewer_packets.jsonl",
    "receipt.json",
)
SHARED_BRIEF_ARTIFACTS = (
    "shared-concept-briefs.json",
    "receipt.json",
)
LAUNCH_ARTIFACTS = (
    "assignments.jsonl",
    "author_packets.jsonl",
    "reviewer_packets.jsonl",
    "receipt.json",
)
MERGE_ARTIFACTS = (
    "development-corpus.jsonl",
    "development-corpus.manifest.json",
    "receipt.json",
)

SAFE_ID = re.compile(r"[a-z0-9][a-z0-9._:-]{2,127}")
SHA256 = re.compile(r"[0-9a-f]{64}")
CONTROL_PATHS = (
    SCRIPT_PATH,
    CONTRACT_PATH,
    BENCHMARK_VALIDATOR_PATH,
    BENCHMARK_SCHEMA_PATH,
    RATING_SCHEMA_PATH,
)
ALLOCATION_FIELDS = {
    "schema_version",
    "slot_id",
    "case_id",
    "semantic_family_id",
    "shared_concept_brief_id",
    "split",
    "language",
    "domain",
    "behavior",
    "contrast_set_id",
    "contrast_brief_id",
    "contrast_archetype",
    "difficulty",
    "safety_risk",
    "source_type",
    "author_packet_id",
    "reviewer_packet_id",
    "prose_authored",
    "native_review_approved",
    "candidate_model_output_seen",
    "evaluation_eligible",
}
PACKET_FIELDS = {
    "schema_version",
    "packet_id",
    "role",
    "language",
    "row_count",
    "slot_ids",
    "case_ids",
    "shared_concept_brief_ids",
    "behavior_counts",
    "domain_counts",
    "difficulty_counts",
    "source_type_counts",
    "identities_assigned",
    "prose_authored",
    "candidate_model_output_seen",
    "merge_eligible",
}
ASSIGNMENT_FIELDS = {
    "schema_version",
    "assignment_id",
    "slot_id",
    "case_id",
    "language",
    "shared_concept_brief_id",
    "shared_concept_brief_sha256",
    "author_packet_id",
    "reviewer_packet_id",
    "author_id",
    "native_reviewer_id",
    "candidate_model_output_seen",
    "prose_authored",
    "native_review_approved",
    "evaluation_eligible",
}
ASSIGNED_PACKET_FIELDS = {
    "schema_version",
    "packet_id",
    "role",
    "language",
    "participant_id",
    "row_count",
    "slot_ids",
    "assignment_ids",
    "shared_concept_brief_bindings",
    "candidate_model_output_seen",
    "prose_authored",
    "native_review_approved",
}
ROSTER_FIELDS = {
    "schema_version",
    "roster_id",
    "status",
    "approved_by_id",
    "approved_at",
    "approval_reference_id",
    "candidate_model_output_seen",
    "participants",
}
PARTICIPANT_FIELDS = {
    "participant_id",
    "participant_type",
    "identity_reference_id",
    "consent_reference_id",
    "consent_status",
    "availability_status",
    "native_attestations",
    "languages",
    "roles",
}
NATIVE_REVIEW_FIELDS = {
    "case_id",
    "assignment_id",
    "author_id",
    "reviewer_id",
    "author_native_attested",
    "reviewer_native_attested",
    "independent_of_author",
    "status",
    "row_sha256",
    "shared_concept_brief_id",
    "shared_concept_brief_sha256",
    "faithful_to_shared_brief",
}
COMPARABILITY_REVIEW_FIELDS = {
    "contrast_set_id",
    "contrast_brief_id",
    "contrast_archetype",
    "positive_case_id",
    "restraint_case_id",
    "positive_row_sha256",
    "restraint_row_sha256",
    "reviewer_id",
    "reviewer_native_attested",
    "independent_of_authors_and_row_reviewers",
    "status",
}
IMMUTABLE_ROW_BINDINGS = (
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
)
FORBIDDEN_CANDIDATE_KEYS = {
    "candidate_output",
    "candidate_text",
    "model_output",
    "generated_output",
    "prediction",
    "model_label",
    "arm_label",
    "candidate_score",
    "model_score",
    "candidate_rating",
}
CANDIDATE_EXPOSURE_FLAG = "candidate_model_output_seen"
PACKET_SHIFTS = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 1, 3, 5, 7, 8, 9)
REVIEWER_SHIFT_ORDER = (7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12, 5, 14)
CONTRAST_ARCHETYPES = (
    "explicit_two_item_activation_boundary",
    "scoped_two_item_activation_boundary",
    "natural_bullet_activation_boundary",
    "spoken_ordinal_activation_boundary",
)


class ValidationFailure(ValueError):
    """Raised when the development authoring evidence cannot be trusted."""


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def opaque_id(namespace: str, *values: str) -> str:
    digest = sha256_bytes("\0".join((namespace, *values)).encode("utf-8"))
    return f"eg1d-{namespace}-{digest[:24]}"


def encode_json(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def encode_jsonl(rows: Iterable[dict[str, Any]]) -> bytes:
    return b"".join(
        (json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
        for row in rows
    )


def read_snapshot(path: Path, label: str) -> tuple[bytes, str]:
    try:
        value = path.read_bytes()
    except OSError as error:
        raise ValidationFailure(f"{label} cannot be read") from error
    return value, sha256_bytes(value)


def parse_object(value: bytes, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationFailure(f"{label} is not valid UTF-8 JSON") from error
    if not isinstance(parsed, dict):
        raise ValidationFailure(f"{label} must be a JSON object")
    return parsed


def parse_rows(value: bytes, label: str) -> list[dict[str, Any]]:
    try:
        lines = value.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ValidationFailure(f"{label} is not valid UTF-8") from error
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValidationFailure(
                f"{label} line {line_number} is not valid JSON"
            ) from error
        if not isinstance(row, dict):
            raise ValidationFailure(f"{label} line {line_number} must be an object")
        rows.append(row)
    return rows


def is_safe_id(value: Any) -> bool:
    return isinstance(value, str) and SAFE_ID.fullmatch(value) is not None


def is_utc_timestamp(value: Any) -> bool:
    if not isinstance(value, str) or not value.endswith("Z"):
        return False
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return False
    return True


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
        raise ValidationFailure(
            f"cannot verify Git state: {' '.join(arguments)}"
        ) from error


def repo_relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT.resolve()))
    except ValueError as error:
        raise ValidationFailure(f"tracked control is outside the repository: {path}") from error


def validate_git_state(expected_head: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", expected_head):
        raise ValidationFailure("expected Git HEAD must be a lowercase 40-character SHA-1")
    actual_head = git_output("rev-parse", "HEAD").decode().strip()
    if actual_head != expected_head:
        raise ValidationFailure("Git HEAD differs from the predeclared commit")
    if git_output("status", "--porcelain", "--untracked-files=no"):
        raise ValidationFailure("tracked worktree must be clean before publication")
    for path in CONTROL_PATHS:
        live, _ = read_snapshot(path, repo_relative(path))
        committed = git_output("show", f"{actual_head}:{repo_relative(path)}")
        if live != committed:
            raise ValidationFailure(
                f"committed bytes differ from live file: {repo_relative(path)}"
            )
    return actual_head


def validate_private_file(path: Path, label: str) -> Path:
    candidate = path.expanduser()
    if not candidate.is_file() or candidate.is_symlink():
        raise ValidationFailure(f"{label} must be an existing regular private file")
    resolved = candidate.resolve()
    try:
        relative = resolved.relative_to(REPO_ROOT.resolve())
    except ValueError:
        return resolved
    tracked = subprocess.run(
        ["git", "ls-files", "--error-unmatch", str(relative)],
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if tracked.returncode == 0:
        raise ValidationFailure(f"{label} must not be tracked by Git")
    ignored = subprocess.run(
        ["git", "check-ignore", "--quiet", str(relative)],
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if ignored.returncode != 0:
        raise ValidationFailure(f"{label} must be covered by a Git ignore rule")
    return resolved


def validate_output_bundle(path: Path) -> Path:
    candidate = path.expanduser()
    if candidate.exists() or candidate.is_symlink():
        raise ValidationFailure("output bundle already exists")
    resolved = candidate.parent.resolve() / candidate.name
    try:
        relative = resolved.relative_to(REPO_ROOT.resolve())
    except ValueError as error:
        raise ValidationFailure("output bundle must stay inside the repository") from error
    ignored = subprocess.run(
        ["git", "check-ignore", "--no-index", "--quiet", str(relative)],
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if ignored.returncode != 0:
        raise ValidationFailure("output bundle must be covered by a Git ignore rule")
    if not resolved.parent.is_dir():
        raise ValidationFailure("output bundle parent directory must already exist")
    return resolved


def write_exclusive(path: Path, value: bytes) -> None:
    with path.open("xb") as handle:
        written = handle.write(value)
        if written != len(value):
            raise OSError(f"short write for {path.name}")
        handle.flush()
        os.fsync(handle.fileno())


def exact_bundle(receipt_path: Path, expected: Sequence[str], label: str) -> dict[str, bytes]:
    if receipt_path.name != "receipt.json" or not receipt_path.is_file() or receipt_path.is_symlink():
        raise ValidationFailure(f"{label} receipt must be a regular receipt.json file")
    parent = receipt_path.parent
    observed = {path.name for path in parent.iterdir()}
    if observed != set(expected):
        raise ValidationFailure(
            f"{label} bundle members changed; expected={sorted(expected)}, observed={sorted(observed)}"
        )
    blobs: dict[str, bytes] = {}
    for name in expected:
        path = parent / name
        if not path.is_file() or path.is_symlink():
            raise ValidationFailure(f"{label} artifact is not a regular file: {name}")
        blobs[name] = read_snapshot(path, f"{label} {name}")[0]
    return blobs


def validate_contract(contract: dict[str, Any]) -> None:
    required = {
        "schema_version",
        "workflow_id",
        "status",
        "seed",
        "languages",
        "domains",
        "behaviors",
        "allocation",
        "packet_contract",
        "shared_brief_contract",
        "inference_contract",
        "roster_contract",
        "merge_gates",
        "publication",
    }
    if set(contract) != required:
        raise ValidationFailure("development authoring contract schema changed")
    if contract.get("schema_version") != CONTRACT_SCHEMA:
        raise ValidationFailure("development authoring contract version changed")
    if contract.get("workflow_id") != "eg1-multilingual-development-authoring-2026-07-15":
        raise ValidationFailure("development authoring workflow ID changed")
    if contract.get("status") != "approved_metadata_only_workflow" or contract.get("seed") != 1265:
        raise ValidationFailure("development authoring contract is not approved")
    if tuple(contract.get("languages", [])) != v2.LANGUAGES:
        raise ValidationFailure("development authoring languages changed")
    if tuple(contract.get("domains", [])) != v2.DOMAINS:
        raise ValidationFailure("development authoring domains changed")
    if tuple(contract.get("behaviors", [])) != v2.BEHAVIORS:
        raise ValidationFailure("development authoring behaviors changed")
    allocation = contract.get("allocation")
    if allocation != {
        "split": "development",
        "cases_per_behavior_domain": 2,
        "rows_per_language": 160,
        "total_rows": 800,
        "native_original_fraction_minimum": 0.8,
        "shared_concept_fraction": 0.2,
        "difficulty_values": ["routine", "challenging", "adversarial"],
    }:
        raise ValidationFailure("development allocation contract changed")
    if contract.get("packet_contract") != {
        "author_packets_per_language": 10,
        "reviewer_packets_per_language": 10,
        "rows_per_packet": 16,
        "every_packet_contains_every_behavior_once": True,
    }:
        raise ValidationFailure("development packet contract changed")
    if contract.get("shared_brief_contract") != {
        "briefs": 32,
        "shared_rows": 160,
        "languages_per_brief": 5,
        "allocation_publishes_ids_only": True,
        "strict_descendant_seal_required": True,
        "independent_concept_review_required": True,
        "concept_identity_namespace": "private_roster.identity_reference_id",
        "required_concept_roles": ["concept_author", "concept_reviewer"],
        "local_rewrite_fidelity_required": True,
        "candidate_model_output_seen": False,
    }:
        raise ValidationFailure("development shared brief contract changed")
    if contract.get("inference_contract") != {
        "pooled_cluster_field": "semantic_family_id",
        "pooled_independent_family_clusters": 672,
        "per_language_independent_rows": 160,
        "contrast_pair_field": "contrast_set_id",
        "contrast_sets": 200,
        "native_contrast_sets": 160,
        "shared_contrast_sets": 40,
        "comparability_approval_required": True,
        "minimum_comparability_reviewers_per_language": 5,
        "maximum_contrast_sets_per_comparability_reviewer_language": 8,
        "human_variance_cluster_fields": [
            "concept_author_id",
            "concept_reviewer_id",
            "author_id",
            "native_reviewer_id",
        ],
    }:
        raise ValidationFailure("development inference contract changed")
    if contract.get("roster_contract") != {
        "participant_types_by_role": {
            "concept_author": "human",
            "concept_reviewer": "human",
            "author": "human_native",
            "native_reviewer": "human_native",
        },
        "role_lanes": [
            "concept_author",
            "concept_reviewer",
            "author",
            "native_reviewer",
        ],
        "role_assignments_singular": True,
        "roles_must_be_disjoint": True,
        "opaque_identity_references_only": True,
        "per_language_native_attestation_required": True,
        "consent_required": True,
        "minimum_concept_custodians_per_lane": 5,
        "maximum_briefs_per_concept_custodian": 8,
        "minimum_participants_per_lane_language": 5,
        "maximum_packets_per_participant_language": 2,
    }:
        raise ValidationFailure("development roster contract changed")
    publication = contract.get("publication")
    if not isinstance(publication, dict) or any(
        publication.get(field) is not expected
        for field, expected in {
            "private_gitignored_bundles": True,
            "exclusive_bundle": True,
            "receipt_last": True,
            "allocation_and_launch_metadata_only": True,
            "benchmark_prose_before_merge_allowed": False,
            "raw_names_emails_or_contact_details_allowed": False,
            "candidate_model_output_allowed": False,
        }.items()
    ) or publication.get("custody_assurance_scope") != ASSURANCE_SCOPE:
        raise ValidationFailure("development publication guardrails changed")
    merge = contract.get("merge_gates")
    if merge != {
        "operator_attested_all_rows_native_authored": True,
        "operator_attested_all_rows_independently_native_reviewed": True,
        "author_reviewer_identity_separation": True,
        "required_leakage_roles": [
            "training",
            "prior_eval",
            "blocked_family_registry",
            "blocked_text_hash_registry",
        ],
        "required_leakage_methods": [
            "exact_normalized",
            "token_ngram_jaccard",
            "character_ngram_jaccard",
            "embedding_cosine",
        ],
        "blocked_registry_receipt_required": True,
        "exhaustive_source_inventory_required": True,
        "source_producing_receipts_required": True,
        "authenticated_scanner_provenance_required": True,
        "approved_scanner_id": APPROVED_SCANNER_ID,
        "approved_scanner_path": APPROVED_SCANNER_PATH,
        "approved_scanner_contract_path": APPROVED_SCANNER_CONTRACT_PATH,
        "contrast_comparability_seal_required": True,
        "independent_release_custodian_inventory_signature_required": True,
        "candidate_model_output_seen": False,
    }:
        raise ValidationFailure("development merge candidate-output gate changed")
    if set(merge.get("required_leakage_roles", [])) != set(v2.REQUIRED_FROZEN_LEAKAGE_ROLES):
        raise ValidationFailure("development leakage roles changed")
    if tuple(merge.get("required_leakage_methods", [])) != v2.REQUIRED_SCREEN_METHODS:
        raise ValidationFailure("development leakage methods changed")


def safety_for(domain: str, occurrence: int) -> str:
    if domain == "medical":
        return "medical"
    if domain == "legal_financial":
        return "legal" if occurrence == 0 else "financial"
    return "standard"


def list_pair_index(behavior_index: int) -> int | None:
    if 8 <= behavior_index <= 11:
        return behavior_index - 8
    if 12 <= behavior_index <= 15:
        return behavior_index - 12
    return None


def shared_cells_for(behavior_index: int) -> set[int]:
    pair_index = list_pair_index(behavior_index)
    source_index = pair_index if pair_index is not None else behavior_index
    return {(source_index * 3) % 10, ((source_index * 3) + 5) % 10}


def build_allocation(contract: dict[str, Any]) -> list[dict[str, Any]]:
    validate_contract(contract)
    rows: list[dict[str, Any]] = []
    seed = str(contract["seed"])
    for language_index, language in enumerate(contract["languages"]):
        for behavior_index, behavior in enumerate(contract["behaviors"]):
            shared_cells = shared_cells_for(behavior_index)
            pair_index = list_pair_index(behavior_index)
            for domain_index, domain in enumerate(contract["domains"]):
                for occurrence in range(2):
                    cell_index = domain_index * 2 + occurrence
                    source_type = (
                        "shared_concept_local_rewrite"
                        if cell_index in shared_cells
                        else "native_original"
                    )
                    difficulty = contract["allocation"]["difficulty_values"][
                        cell_index % 3
                    ]
                    family_values = [behavior, domain, str(occurrence)]
                    if source_type == "native_original":
                        family_values.insert(0, language)
                    semantic_family_id = opaque_id("family", seed, *family_values)
                    shared_concept_brief_id = (
                        opaque_id("brief", seed, semantic_family_id)
                        if source_type == "shared_concept_local_rewrite"
                        else None
                    )
                    contrast_set_id = (
                        opaque_id(
                            "contrast",
                            seed,
                            language,
                            str(pair_index),
                            domain,
                            str(occurrence),
                        )
                        if pair_index is not None
                        else None
                    )
                    contrast_brief_id = (
                        opaque_id(
                            "contrast-brief",
                            seed,
                            language,
                            str(pair_index),
                            domain,
                            str(occurrence),
                        )
                        if pair_index is not None
                        else None
                    )
                    contrast_archetype = (
                        CONTRAST_ARCHETYPES[pair_index]
                        if pair_index is not None
                        else None
                    )
                    case_id = opaque_id(
                        "case", seed, language, behavior, domain, str(occurrence)
                    )
                    slot_id = opaque_id("slot", seed, case_id)
                    author_packet = (
                        cell_index + PACKET_SHIFTS[behavior_index] + language_index
                    ) % 10
                    reviewer_packet = (
                        cell_index
                        + PACKET_SHIFTS[REVIEWER_SHIFT_ORDER[behavior_index]]
                        + language_index
                        + 1
                    ) % 10
                    rows.append(
                        {
                            "schema_version": ALLOCATION_ROW_SCHEMA,
                            "slot_id": slot_id,
                            "case_id": case_id,
                            "semantic_family_id": semantic_family_id,
                            "shared_concept_brief_id": shared_concept_brief_id,
                            "split": "development",
                            "language": language,
                            "domain": domain,
                            "behavior": behavior,
                            "contrast_set_id": contrast_set_id,
                            "contrast_brief_id": contrast_brief_id,
                            "contrast_archetype": contrast_archetype,
                            "difficulty": difficulty,
                            "safety_risk": safety_for(domain, occurrence),
                            "source_type": source_type,
                            "author_packet_id": f"eg1d-author-{language}-{author_packet + 1:02d}",
                            "reviewer_packet_id": f"eg1d-review-{language}-{reviewer_packet + 1:02d}",
                            "prose_authored": False,
                            "native_review_approved": False,
                            "candidate_model_output_seen": False,
                            "evaluation_eligible": False,
                        }
                    )
    validate_allocation(rows, contract)
    return rows


def validate_allocation(rows: list[dict[str, Any]], contract: dict[str, Any]) -> None:
    if len(rows) != 800:
        raise ValidationFailure(f"allocation has {len(rows)} rows, expected 800")
    seen_slots: set[str] = set()
    seen_cases: set[str] = set()
    family_signatures: dict[str, tuple[Any, ...]] = {}
    language_counts: Counter[str] = Counter()
    cell_counts: Counter[tuple[str, str, str]] = Counter()
    source_counts: Counter[tuple[str, str]] = Counter()
    difficulty_by_behavior: dict[tuple[str, str], set[str]] = defaultdict(set)
    packet_members: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    contrast_sets: dict[str, list[dict[str, Any]]] = defaultdict(list)
    shared_briefs: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for index, row in enumerate(rows, 1):
        if set(row) != ALLOCATION_FIELDS:
            raise ValidationFailure(f"allocation row {index} schema changed")
        if row.get("schema_version") != ALLOCATION_ROW_SCHEMA:
            raise ValidationFailure(f"allocation row {index} schema version changed")
        for field in ("slot_id", "case_id", "semantic_family_id"):
            if not is_safe_id(row.get(field)):
                raise ValidationFailure(f"allocation row {index} has invalid {field}")
        for field in ("contrast_set_id", "contrast_brief_id"):
            if row.get(field) is not None and not is_safe_id(row.get(field)):
                raise ValidationFailure(f"allocation row {index} has invalid {field}")
        shared_brief_id = row.get("shared_concept_brief_id")
        if row.get("source_type") == "shared_concept_local_rewrite":
            if not is_safe_id(shared_brief_id):
                raise ValidationFailure(
                    f"allocation row {index} shared concept lacks a brief ID"
                )
            shared_briefs[shared_brief_id].append(row)
        elif shared_brief_id is not None:
            raise ValidationFailure(
                f"allocation row {index} native-original slot carries a shared brief"
            )
        if row["slot_id"] in seen_slots or row["case_id"] in seen_cases:
            raise ValidationFailure("allocation contains duplicate slot_id or case_id")
        seen_slots.add(row["slot_id"])
        seen_cases.add(row["case_id"])
        if row.get("candidate_model_output_seen") is not False or row.get("prose_authored") is not False:
            raise ValidationFailure("allocation exposes candidate output or benchmark prose")
        if row.get("native_review_approved") is not False or row.get("evaluation_eligible") is not False:
            raise ValidationFailure("allocation grants review or evaluation eligibility")
        if row.get("split") != "development":
            raise ValidationFailure("allocation contains a non-development row")
        if row.get("language") not in contract["languages"] or row.get("domain") not in contract["domains"] or row.get("behavior") not in contract["behaviors"]:
            raise ValidationFailure("allocation contains an unsupported matrix value")
        if row.get("difficulty") not in contract["allocation"]["difficulty_values"]:
            raise ValidationFailure("allocation contains an unsupported difficulty")
        pair_index = list_pair_index(contract["behaviors"].index(row["behavior"]))
        expected_archetype = (
            CONTRAST_ARCHETYPES[pair_index] if pair_index is not None else None
        )
        if (
            (pair_index is None)
            != (row.get("contrast_set_id") is None)
            or (pair_index is None)
            != (row.get("contrast_brief_id") is None)
            or row.get("contrast_archetype") != expected_archetype
        ):
            raise ValidationFailure("allocation contrast metadata is invalid")
        expected_safety = safety_for(row["domain"], 0)
        if row["domain"] == "legal_financial":
            if row.get("safety_risk") not in {"legal", "financial"}:
                raise ValidationFailure("legal-financial allocation safety is invalid")
        elif row.get("safety_risk") != expected_safety:
            raise ValidationFailure("allocation safety differs from its domain")
        signature = (
            row["domain"],
            row["behavior"],
            row["difficulty"],
            row["safety_risk"],
        )
        prior = family_signatures.setdefault(row["semantic_family_id"], signature)
        if prior != signature:
            raise ValidationFailure("shared semantic family changes its stratum signature")
        language_counts[row["language"]] += 1
        cell_counts[(row["language"], row["behavior"], row["domain"])] += 1
        source_counts[(row["language"], row["source_type"])] += 1
        difficulty_by_behavior[(row["language"], row["behavior"])].add(
            row["difficulty"]
        )
        packet_members[("author", row["author_packet_id"])].append(row)
        packet_members[("native_reviewer", row["reviewer_packet_id"])].append(row)
        if row["contrast_set_id"] is not None:
            contrast_sets[row["contrast_set_id"]].append(row)
    for language in contract["languages"]:
        if language_counts[language] != 160:
            raise ValidationFailure(f"{language}: allocation row count is not 160")
        if source_counts[(language, "native_original")] != 128 or source_counts[(language, "shared_concept_local_rewrite")] != 32:
            raise ValidationFailure(f"{language}: native/shared allocation is not 80/20")
        for behavior in contract["behaviors"]:
            if difficulty_by_behavior[(language, behavior)] != set(
                contract["allocation"]["difficulty_values"]
            ):
                raise ValidationFailure(
                    f"{language}/{behavior}: all difficulty levels are required"
                )
            for domain in contract["domains"]:
                if cell_counts[(language, behavior, domain)] != 2:
                    raise ValidationFailure(
                        f"{language}/{behavior}/{domain}: expected exactly two rows"
                    )
    expected_packets = len(contract["languages"]) * 10 * 2
    if len(packet_members) != expected_packets:
        raise ValidationFailure("author/reviewer packet count changed")
    for (role, packet_id), members in packet_members.items():
        if len(members) != 16:
            raise ValidationFailure(f"{packet_id}: expected 16 {role} rows")
        behavior_counts = Counter(row["behavior"] for row in members)
        if set(behavior_counts) != set(contract["behaviors"]) or set(behavior_counts.values()) != {1}:
            raise ValidationFailure(f"{packet_id}: packet does not contain every behavior once")
        if max(Counter(row["domain"] for row in members).values()) - min(Counter(row["domain"] for row in members).values()) > 1:
            raise ValidationFailure(f"{packet_id}: domain distribution is not balanced")
        difficulty_counts = Counter(row["difficulty"] for row in members)
        if set(difficulty_counts) != set(contract["allocation"]["difficulty_values"]):
            raise ValidationFailure(f"{packet_id}: packet is missing a difficulty stratum")
    contrast_source_counts: Counter[str] = Counter()
    for contrast_id, members in contrast_sets.items():
        if len(members) != 2:
            raise ValidationFailure(f"{contrast_id}: contrast set must contain two rows")
        positive = [row for row in members if row["behavior"] in v2.POSITIVE_LIST_BEHAVIORS]
        restraint = [row for row in members if row["behavior"] in v2.RESTRAINT_BEHAVIORS]
        if len(positive) != 1 or len(restraint) != 1:
            raise ValidationFailure(f"{contrast_id}: contrast roles are invalid")
        for field in ("language", "domain", "difficulty", "safety_risk"):
            if positive[0][field] != restraint[0][field]:
                raise ValidationFailure(f"{contrast_id}: contrast {field} differs")
        for field in ("contrast_brief_id", "contrast_archetype", "source_type"):
            if positive[0][field] != restraint[0][field]:
                raise ValidationFailure(f"{contrast_id}: contrast {field} differs")
        contrast_source_counts[positive[0]["source_type"]] += 1
    if len(contrast_sets) != 200 or contrast_source_counts != Counter(
        {"native_original": 160, "shared_concept_local_rewrite": 40}
    ):
        raise ValidationFailure("contrast allocation must be 160 native/native and 40 shared/shared")
    family_counts = Counter(row["semantic_family_id"] for row in rows)
    if (
        len(family_counts) != 672
        or Counter(family_counts.values()) != Counter({1: 640, 5: 32})
    ):
        raise ValidationFailure("pooled allocation must contain exactly 672 family clusters")
    if len(shared_briefs) != 32:
        raise ValidationFailure(
            f"allocation must contain exactly 32 shared concept briefs, got {len(shared_briefs)}"
        )
    for brief_id, members in shared_briefs.items():
        if (
            len(members) != 5
            or {row["language"] for row in members} != set(v2.LANGUAGES)
            or len({row["semantic_family_id"] for row in members}) != 1
            or len(
                {
                    (
                        row["behavior"],
                        row["domain"],
                        row["difficulty"],
                        row["safety_risk"],
                    )
                    for row in members
                }
            )
            != 1
        ):
            raise ValidationFailure(
                f"{brief_id}: shared brief must bind one matching slot in every language"
            )


def build_packets(rows: list[dict[str, Any]], role: str) -> list[dict[str, Any]]:
    field = "author_packet_id" if role == "author" else "reviewer_packet_id"
    packets: list[dict[str, Any]] = []
    for packet_id in sorted({row[field] for row in rows}):
        members = sorted(
            (row for row in rows if row[field] == packet_id),
            key=lambda row: row["slot_id"],
        )
        packets.append(
            {
                "schema_version": PACKET_SCHEMA,
                "packet_id": packet_id,
                "role": role,
                "language": members[0]["language"],
                "row_count": len(members),
                "slot_ids": [row["slot_id"] for row in members],
                "case_ids": [row["case_id"] for row in members],
                "shared_concept_brief_ids": sorted(
                    {
                        row["shared_concept_brief_id"]
                        for row in members
                        if row["shared_concept_brief_id"] is not None
                    }
                ),
                "behavior_counts": dict(sorted(Counter(row["behavior"] for row in members).items())),
                "domain_counts": dict(sorted(Counter(row["domain"] for row in members).items())),
                "difficulty_counts": dict(sorted(Counter(row["difficulty"] for row in members).items())),
                "source_type_counts": dict(sorted(Counter(row["source_type"] for row in members).items())),
                "identities_assigned": False,
                "prose_authored": False,
                "candidate_model_output_seen": False,
                "merge_eligible": False,
            }
        )
    return packets


def control_bindings(snapshots: dict[Path, str]) -> dict[str, dict[str, str]]:
    return {
        "contract": {"path": repo_relative(CONTRACT_PATH), "sha256": snapshots[CONTRACT_PATH]},
        "builder": {"path": repo_relative(SCRIPT_PATH), "sha256": snapshots[SCRIPT_PATH]},
        "benchmark_validator": {"path": repo_relative(BENCHMARK_VALIDATOR_PATH), "sha256": snapshots[BENCHMARK_VALIDATOR_PATH]},
        "benchmark_schema": {"path": repo_relative(BENCHMARK_SCHEMA_PATH), "sha256": snapshots[BENCHMARK_SCHEMA_PATH]},
        "rating_schema": {"path": repo_relative(RATING_SCHEMA_PATH), "sha256": snapshots[RATING_SCHEMA_PATH]},
    }


def snapshot_paths(paths: Iterable[Path]) -> tuple[dict[Path, bytes], dict[Path, str]]:
    blobs: dict[Path, bytes] = {}
    digests: dict[Path, str] = {}
    for path in paths:
        blobs[path], digests[path] = read_snapshot(path, path.name)
    return blobs, digests


def publish_bundle(
    output: Path,
    artifact_bytes: dict[str, bytes],
    receipt_bytes: bytes,
    snapshots: dict[Path, str],
    pre_receipt_check: Callable[[], None] | None = None,
) -> None:
    created = False
    try:
        output.mkdir()
        created = True
        for name, value in artifact_bytes.items():
            write_exclusive(output / name, value)
        if pre_receipt_check is not None:
            pre_receipt_check()
        for name, value in artifact_bytes.items():
            if read_snapshot(output / name, name)[1] != sha256_bytes(value):
                raise ValidationFailure(f"published artifact changed before receipt: {name}")
        for path, digest in snapshots.items():
            if read_snapshot(path, path.name)[1] != digest:
                raise ValidationFailure(f"sealed input changed during publication: {path.name}")
        write_exclusive(output / "receipt.json", receipt_bytes)
    except BaseException:
        if created:
            shutil.rmtree(output, ignore_errors=True)
        raise


def allocate_bundle(
    *,
    contract: dict[str, Any],
    output: Path,
    execution_git_head: str,
    pre_receipt_check: Callable[[], None] | None = None,
) -> dict[str, Any]:
    _, snapshots = snapshot_paths(CONTROL_PATHS)
    rows = build_allocation(contract)
    author_packets = build_packets(rows, "author")
    reviewer_packets = build_packets(rows, "native_reviewer")
    artifact_bytes = {
        "allocation.jsonl": encode_jsonl(rows),
        "author_packets.jsonl": encode_jsonl(author_packets),
        "reviewer_packets.jsonl": encode_jsonl(reviewer_packets),
    }
    receipt = {
        "schema_version": ALLOCATION_RECEIPT_SCHEMA,
        "status": "metadata_allocation_sealed_authorship_blocked",
        "execution_git_head": execution_git_head,
        "controls": control_bindings(snapshots),
        "counts": {
            "rows": len(rows),
            "rows_per_language": dict(sorted(Counter(row["language"] for row in rows).items())),
            "author_packets": len(author_packets),
            "reviewer_packets": len(reviewer_packets),
            "rows_per_packet": 16,
            "pooled_independent_family_clusters": 672,
            "contrast_sets": 200,
            "native_contrast_sets": 160,
            "shared_contrast_sets": 40,
        },
        "artifacts": {
            name: {
                "sha256": sha256_bytes(value),
                "bytes": len(value),
                "row_count": len(rows if name == "allocation.jsonl" else author_packets if name == "author_packets.jsonl" else reviewer_packets),
            }
            for name, value in artifact_bytes.items()
        },
        "gates": {
            "exact_800_rows": True,
            "exact_160_per_language": True,
            "exact_two_per_behavior_domain_cell": True,
            "balanced_author_packets": True,
            "balanced_reviewer_packets": True,
            "matched_contrast_source_types": True,
            "cell_varying_difficulty": True,
            "contrast_comparability_approved": False,
            "roster_bound": False,
            "native_review_complete": False,
            "leakage_screen_complete": False,
            "evaluation_eligible": False,
        },
        "privacy": {
            "metadata_only": True,
            "prose_published": False,
            "identities_published": False,
            "candidate_output_published": False,
        },
        "inference_policy": {
            "pooled_metrics_cluster_by": "semantic_family_id",
            "pooled_independent_clusters": 672,
            "per_language_rows_are_family_independent": True,
            "per_language_independent_rows": 160,
            "contrast_metrics_pair_and_cluster_by": "contrast_set_id",
            "contrast_metrics_blocked_until_comparability_seal": True,
            "human_variance_cluster_fields_after_roster_binding": [
                "concept_author_id",
                "concept_reviewer_id",
                "author_id",
                "native_reviewer_id",
            ],
        },
        "assurance": {
            "scope": ASSURANCE_SCOPE,
            "candidate_output_nonexposure": "operator_attested",
        },
        "publication": "exclusive_private_bundle_receipt_last",
    }
    publish_bundle(output, artifact_bytes, encode_json(receipt), snapshots, pre_receipt_check)
    return receipt


def require_git_ancestor(ancestor: str, descendant: str, label: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", ancestor) or not re.fullmatch(
        r"[0-9a-f]{40}", descendant
    ):
        raise ValidationFailure(f"{label} Git commit binding is invalid")
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, descendant],
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    if result.returncode == 1:
        raise ValidationFailure(f"{label} producing commit is not an ancestor")
    if result.returncode != 0:
        raise ValidationFailure(f"cannot authenticate {label} producing commit")


def validate_control_receipt(
    receipt: dict[str, Any], expected_head: str
) -> dict[str, Any]:
    producing_head = receipt.get("execution_git_head")
    if not isinstance(producing_head, str):
        raise ValidationFailure("receipt producing Git commit is missing")
    require_git_ancestor(producing_head, expected_head, "receipt")
    controls = receipt.get("controls")
    if not isinstance(controls, dict) or set(controls) != {
        "contract",
        "builder",
        "benchmark_validator",
        "benchmark_schema",
        "rating_schema",
    }:
        raise ValidationFailure("receipt control bindings are missing")
    expected = {
        "contract": CONTRACT_PATH,
        "builder": SCRIPT_PATH,
        "benchmark_validator": BENCHMARK_VALIDATOR_PATH,
        "benchmark_schema": BENCHMARK_SCHEMA_PATH,
        "rating_schema": RATING_SCHEMA_PATH,
    }
    for label, path in expected.items():
        binding = controls.get(label)
        if not isinstance(binding, dict) or binding.get("path") != repo_relative(path) or not isinstance(binding.get("sha256"), str) or not SHA256.fullmatch(binding["sha256"]):
            raise ValidationFailure(f"receipt {label} binding is invalid")
        committed = git_output("show", f"{producing_head}:{repo_relative(path)}")
        if sha256_bytes(committed) != binding["sha256"]:
            raise ValidationFailure(f"receipt {label} differs from its producing commit")
    contract_bytes = git_output(
        "show", f"{producing_head}:{repo_relative(CONTRACT_PATH)}"
    )
    contract = parse_object(contract_bytes, "receipt producing contract")
    validate_contract(contract)
    return contract


def authenticate_allocation(
    receipt_path: Path, _contract: dict[str, Any], expected_head: str
) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, bytes], dict[str, Any]]:
    blobs = exact_bundle(receipt_path, ALLOCATION_ARTIFACTS, "allocation")
    receipt = parse_object(blobs["receipt.json"], "allocation receipt")
    if set(receipt) != {
        "schema_version",
        "status",
        "execution_git_head",
        "controls",
        "counts",
        "artifacts",
        "gates",
        "privacy",
        "inference_policy",
        "assurance",
        "publication",
    }:
        raise ValidationFailure("allocation receipt schema changed")
    if receipt.get("schema_version") != ALLOCATION_RECEIPT_SCHEMA or receipt.get("status") != "metadata_allocation_sealed_authorship_blocked":
        raise ValidationFailure("allocation receipt status or schema is invalid")
    sealed_contract = validate_control_receipt(receipt, expected_head)
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != set(ALLOCATION_ARTIFACTS[:-1]):
        raise ValidationFailure("allocation receipt artifact inventory changed")
    for name in ALLOCATION_ARTIFACTS[:-1]:
        meta = artifacts.get(name)
        expected_row_count = 800 if name == "allocation.jsonl" else 50
        if meta != {
            "sha256": sha256_bytes(blobs[name]),
            "bytes": len(blobs[name]),
            "row_count": expected_row_count,
        }:
            raise ValidationFailure(f"allocation artifact hash changed: {name}")
    rows = parse_rows(blobs["allocation.jsonl"], "allocation")
    canonical_rows = build_allocation(sealed_contract)
    if rows != canonical_rows:
        raise ValidationFailure("allocation differs from the deterministic producing contract")
    if parse_rows(blobs["author_packets.jsonl"], "author packets") != build_packets(rows, "author"):
        raise ValidationFailure("author packet allocation changed")
    if parse_rows(blobs["reviewer_packets.jsonl"], "reviewer packets") != build_packets(rows, "native_reviewer"):
        raise ValidationFailure("reviewer packet allocation changed")
    if receipt.get("counts") != {
        "rows": 800,
        "rows_per_language": {language: 160 for language in v2.LANGUAGES},
        "author_packets": 50,
        "reviewer_packets": 50,
        "rows_per_packet": 16,
        "pooled_independent_family_clusters": 672,
        "contrast_sets": 200,
        "native_contrast_sets": 160,
        "shared_contrast_sets": 40,
    } or receipt.get("gates") != {
        "exact_800_rows": True,
        "exact_160_per_language": True,
        "exact_two_per_behavior_domain_cell": True,
        "balanced_author_packets": True,
        "balanced_reviewer_packets": True,
        "matched_contrast_source_types": True,
        "cell_varying_difficulty": True,
        "contrast_comparability_approved": False,
        "roster_bound": False,
        "native_review_complete": False,
        "leakage_screen_complete": False,
        "evaluation_eligible": False,
    } or receipt.get("privacy") != {
        "metadata_only": True,
        "prose_published": False,
        "identities_published": False,
        "candidate_output_published": False,
    } or receipt.get("inference_policy") != {
        "pooled_metrics_cluster_by": "semantic_family_id",
        "pooled_independent_clusters": 672,
        "per_language_rows_are_family_independent": True,
        "per_language_independent_rows": 160,
        "contrast_metrics_pair_and_cluster_by": "contrast_set_id",
        "contrast_metrics_blocked_until_comparability_seal": True,
        "human_variance_cluster_fields_after_roster_binding": [
            "concept_author_id",
            "concept_reviewer_id",
            "author_id",
            "native_reviewer_id",
        ],
    } or receipt.get("assurance") != {
        "scope": ASSURANCE_SCOPE,
        "candidate_output_nonexposure": "operator_attested",
    } or receipt.get("publication") != "exclusive_private_bundle_receipt_last":
        raise ValidationFailure("allocation receipt counts or privacy gate changed")
    return rows, receipt, blobs, sealed_contract


def reject_candidate_output_evidence(value: Any, label: str) -> None:
    if isinstance(value, dict):
        for key, nested in value.items():
            normalized = str(key).strip().lower()
            if normalized in FORBIDDEN_CANDIDATE_KEYS:
                raise ValidationFailure(f"{label} contains forbidden candidate output key")
            if normalized == CANDIDATE_EXPOSURE_FLAG and nested is not False:
                raise ValidationFailure(f"{label} candidate output exposure flag must be false")
            reject_candidate_output_evidence(nested, label)
    elif isinstance(value, list):
        for nested in value:
            reject_candidate_output_evidence(nested, label)


def shared_brief_allocations(
    rows: Sequence[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        brief_id = row.get("shared_concept_brief_id")
        if row.get("source_type") == "shared_concept_local_rewrite":
            if not is_safe_id(brief_id):
                raise ValidationFailure("shared allocation row lacks a brief ID")
            grouped[brief_id].append(row)
        elif brief_id is not None:
            raise ValidationFailure("native-original allocation row carries a shared brief")
    if len(grouped) != 32:
        raise ValidationFailure("shared allocation must contain exactly 32 brief IDs")
    result: dict[str, dict[str, Any]] = {}
    for brief_id, members in grouped.items():
        languages = sorted(row["language"] for row in members)
        families = {row["semantic_family_id"] for row in members}
        signatures = {
            (
                row["behavior"],
                row["domain"],
                row["difficulty"],
                row["safety_risk"],
            )
            for row in members
        }
        if len(members) != 5 or languages != sorted(v2.LANGUAGES) or len(families) != 1 or len(signatures) != 1:
            raise ValidationFailure(
                f"{brief_id}: allocation must bind one matching row in every language"
            )
        behavior, domain, difficulty, safety_risk = next(iter(signatures))
        result[brief_id] = {
            "semantic_family_id": next(iter(families)),
            "brief_id": brief_id,
            "allocated_signature": {
                "behavior": behavior,
                "domain": domain,
                "difficulty": difficulty,
                "safety_risk": safety_risk,
            },
            "languages": languages,
            "case_ids": sorted(row["case_id"] for row in members),
        }
    return result


def require_strict_git_descendant(
    ancestor: str, descendant: str, label: str
) -> None:
    if ancestor == descendant:
        raise ValidationFailure(f"{label} must be sealed in a strict descendant commit")
    require_git_ancestor(ancestor, descendant, label)


def validate_shared_brief_registry(
    registry: dict[str, Any],
    allocation: Sequence[dict[str, Any]],
    allocation_receipt_sha256: str,
    allocation_execution_head: str,
    sealing_head: str,
    participants: Sequence[dict[str, Any]],
    roster_id: str,
    roster_sha256: str,
) -> list[dict[str, Any]]:
    required = {
        "schema_version",
        "status",
        "allocation_receipt_sha256",
        "allocation_execution_git_head",
        "producing_git_head",
        "sealing_git_head",
        "roster_id",
        "roster_sha256",
        "candidate_model_output_seen",
        "assurance_scope",
        "concepts",
    }
    if set(registry) != required:
        raise ValidationFailure("shared brief registry schema changed")
    if (
        registry.get("schema_version") != SHARED_BRIEF_REGISTRY_SCHEMA
        or registry.get("status") != "sealed_for_development_authoring"
        or registry.get("allocation_receipt_sha256")
        != allocation_receipt_sha256
        or registry.get("allocation_execution_git_head")
        != allocation_execution_head
        or registry.get("sealing_git_head") != sealing_head
        or registry.get("roster_id") != roster_id
        or registry.get("roster_sha256") != roster_sha256
        or registry.get("candidate_model_output_seen") is not False
        or registry.get("assurance_scope") != ASSURANCE_SCOPE
    ):
        raise ValidationFailure("shared brief registry binding changed")
    producing_head = registry.get("producing_git_head")
    if not isinstance(producing_head, str):
        raise ValidationFailure("shared brief producing commit is missing")
    require_strict_git_descendant(
        allocation_execution_head, producing_head, "shared brief production"
    )
    require_git_ancestor(producing_head, sealing_head, "shared brief sealing")
    reject_candidate_output_evidence(registry, "shared brief registry")
    expected = shared_brief_allocations(allocation)
    concept_authors = {
        participant["identity_reference_id"]
        for participant in participants
        if participant["roles"] == ["concept_author"]
    }
    concept_reviewers = {
        participant["identity_reference_id"]
        for participant in participants
        if participant["roles"] == ["concept_reviewer"]
    }
    concepts = registry.get("concepts")
    if not isinstance(concepts, list) or len(concepts) != 32:
        raise ValidationFailure("shared brief registry must contain exactly 32 concepts")
    observed: dict[str, dict[str, Any]] = {}
    hashes: set[str] = set()
    author_clusters: Counter[str] = Counter()
    reviewer_clusters: Counter[str] = Counter()
    for index, concept in enumerate(concepts, 1):
        fields = {
            "semantic_family_id",
            "brief_id",
            "brief",
            "brief_sha256",
            "allocated_signature",
            "languages",
            "case_ids",
            "concept_author_id",
            "concept_reviewer_id",
            "language_neutrality_approved",
            "meaning_safety_approved",
            "family_separation_approved",
            "independent_review",
            "candidate_model_output_seen",
        }
        if not isinstance(concept, dict) or set(concept) != fields:
            raise ValidationFailure(f"shared brief concept {index} schema changed")
        brief_id = concept.get("brief_id")
        if not isinstance(brief_id, str) or brief_id not in expected or brief_id in observed:
            raise ValidationFailure(f"shared brief concept {index} is duplicate or unallocated")
        observed[brief_id] = concept
        allocated = expected[brief_id]
        for field in (
            "semantic_family_id",
            "brief_id",
            "allocated_signature",
            "languages",
            "case_ids",
        ):
            if concept.get(field) != allocated[field]:
                raise ValidationFailure(f"{brief_id}: shared brief differs from allocation")
        brief = concept.get("brief")
        if not isinstance(brief, str) or not brief.strip() or len(brief) > 2000:
            raise ValidationFailure(f"{brief_id}: shared brief prose is invalid")
        brief_sha = sha256_bytes(brief.encode("utf-8"))
        if concept.get("brief_sha256") != brief_sha or brief_sha in hashes:
            raise ValidationFailure(f"{brief_id}: shared brief hash is invalid or duplicate")
        hashes.add(brief_sha)
        author_id = concept.get("concept_author_id")
        reviewer_id = concept.get("concept_reviewer_id")
        if not is_safe_id(author_id) or not is_safe_id(reviewer_id) or author_id == reviewer_id:
            raise ValidationFailure(f"{brief_id}: concept author/reviewer identity is invalid")
        if author_id not in concept_authors or reviewer_id not in concept_reviewers:
            raise ValidationFailure(
                f"{brief_id}: concept custodian is not registered for the required roster role"
            )
        author_clusters[author_id] += 1
        reviewer_clusters[reviewer_id] += 1
        for field in (
            "language_neutrality_approved",
            "meaning_safety_approved",
            "family_separation_approved",
            "independent_review",
        ):
            if concept.get(field) is not True:
                raise ValidationFailure(f"{brief_id}: {field} must be true")
        if concept.get("candidate_model_output_seen") is not False:
            raise ValidationFailure(f"{brief_id}: candidate output must remain unseen")
    if set(observed) != set(expected):
        raise ValidationFailure("shared brief registry coverage differs from allocation")
    minimum = 5
    maximum = 8
    if len(author_clusters) < minimum or len(reviewer_clusters) < minimum:
        raise ValidationFailure(
            "shared brief custody requires at least five concept authors and five concept reviewers"
        )
    if max(author_clusters.values()) > maximum or max(reviewer_clusters.values()) > maximum:
        raise ValidationFailure(
            "a concept custodian exceeds eight shared briefs"
        )
    return [observed[brief_id] for brief_id in sorted(observed)]


def seal_shared_brief_bundle(
    *,
    contract: dict[str, Any],
    allocation_receipt_path: Path,
    private_completion_path: Path,
    roster_path: Path,
    output: Path,
    execution_git_head: str,
    pre_receipt_check: Callable[[], None] | None = None,
) -> dict[str, Any]:
    watched = [
        *[allocation_receipt_path.parent / name for name in ALLOCATION_ARTIFACTS],
        private_completion_path,
        roster_path,
        *CONTROL_PATHS,
    ]
    blobs, digests = snapshot_paths(watched)
    allocation, allocation_receipt, _, sealed_contract = authenticate_allocation(
        allocation_receipt_path, contract, execution_git_head
    )
    if sealed_contract != contract:
        raise ValidationFailure("shared brief and allocation contracts differ")
    roster = parse_object(blobs[roster_path], "private roster")
    participants = validate_roster(roster, sealed_contract)
    completion = parse_object(blobs[private_completion_path], "private shared brief completion")
    completion["sealing_git_head"] = execution_git_head
    completion["roster_id"] = roster["roster_id"]
    completion["roster_sha256"] = digests[roster_path]
    concepts = validate_shared_brief_registry(
        completion,
        allocation,
        digests[allocation_receipt_path],
        allocation_receipt["execution_git_head"],
        execution_git_head,
        participants,
        roster["roster_id"],
        digests[roster_path],
    )
    registry_bytes = encode_json({**completion, "concepts": concepts})
    concept_author_counts = dict(
        sorted(Counter(concept["concept_author_id"] for concept in concepts).items())
    )
    concept_reviewer_counts = dict(
        sorted(Counter(concept["concept_reviewer_id"] for concept in concepts).items())
    )
    _, controls = snapshot_paths(CONTROL_PATHS)
    receipt = {
        "schema_version": SHARED_BRIEF_RECEIPT_SCHEMA,
        "status": "all_32_shared_concepts_sealed_authoring_unblocked",
        "execution_git_head": execution_git_head,
        "controls": control_bindings(controls),
        "inputs": {
            "allocation_receipt_sha256": digests[allocation_receipt_path],
            "allocation_execution_git_head": allocation_receipt["execution_git_head"],
            "private_completion_sha256": digests[private_completion_path],
            "roster_id": roster["roster_id"],
            "roster_sha256": digests[roster_path],
        },
        "counts": {
            "briefs": 32,
            "shared_rows": 160,
            "languages_per_brief": 5,
            "independent_reviews": 32,
            "concept_author_briefs": concept_author_counts,
            "concept_reviewer_briefs": concept_reviewer_counts,
        },
        "gates": {
            "all_briefs_language_neutrality_approved": True,
            "all_briefs_meaning_safety_approved": True,
            "all_briefs_family_separation_approved": True,
            "all_brief_reviews_independent": True,
            "minimum_five_concept_custodians_per_lane": True,
            "maximum_eight_briefs_per_concept_custodian": True,
            "candidate_model_output_seen": False,
            "native_rewrite_reviews_complete": False,
            "evaluation_eligible": False,
        },
        "artifacts": {
            "shared-concept-briefs.json": {
                "sha256": sha256_bytes(registry_bytes),
                "bytes": len(registry_bytes),
                "object_count": 1,
            }
        },
        "assurance": {"scope": ASSURANCE_SCOPE},
        "publication": "exclusive_private_bundle_receipt_last",
    }
    publish_bundle(
        output,
        {"shared-concept-briefs.json": registry_bytes},
        encode_json(receipt),
        digests,
        pre_receipt_check,
    )
    return receipt


def authenticate_shared_brief_bundle(
    receipt_path: Path,
    allocation_receipt_path: Path,
    allocation: Sequence[dict[str, Any]],
    roster_path: Path,
    contract: dict[str, Any],
    expected_head: str,
) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, bytes]]:
    blobs = exact_bundle(receipt_path, SHARED_BRIEF_ARTIFACTS, "shared brief")
    receipt = parse_object(blobs["receipt.json"], "shared brief receipt")
    if set(receipt) != {
        "schema_version",
        "status",
        "execution_git_head",
        "controls",
        "inputs",
        "counts",
        "gates",
        "artifacts",
        "assurance",
        "publication",
    }:
        raise ValidationFailure("shared brief receipt schema changed")
    if (
        receipt.get("schema_version") != SHARED_BRIEF_RECEIPT_SCHEMA
        or receipt.get("status")
        != "all_32_shared_concepts_sealed_authoring_unblocked"
    ):
        raise ValidationFailure("shared brief receipt is not authoring-ready")
    sealed_contract = validate_control_receipt(receipt, expected_head)
    if sealed_contract != contract:
        raise ValidationFailure("shared brief and downstream contracts differ")
    allocation_receipt_bytes, allocation_receipt_sha = read_snapshot(
        allocation_receipt_path, "allocation receipt"
    )
    allocation_receipt = parse_object(
        allocation_receipt_bytes, "allocation receipt"
    )
    roster_bytes, roster_sha = read_snapshot(roster_path, "private roster")
    roster = parse_object(roster_bytes, "private roster")
    participants = validate_roster(roster, contract)
    inputs = receipt.get("inputs")
    if not isinstance(inputs, dict) or inputs != {
        "allocation_receipt_sha256": allocation_receipt_sha,
        "allocation_execution_git_head": allocation_receipt.get("execution_git_head"),
        "private_completion_sha256": inputs.get("private_completion_sha256"),
        "roster_id": roster.get("roster_id"),
        "roster_sha256": roster_sha,
    } or not isinstance(inputs.get("private_completion_sha256"), str) or not SHA256.fullmatch(inputs["private_completion_sha256"]):
        raise ValidationFailure("shared brief receipt input binding changed")
    registry = parse_object(
        blobs["shared-concept-briefs.json"], "shared brief registry"
    )
    concepts = validate_shared_brief_registry(
        registry,
        allocation,
        allocation_receipt_sha,
        allocation_receipt["execution_git_head"],
        receipt["execution_git_head"],
        participants,
        roster["roster_id"],
        roster_sha,
    )
    if receipt.get("counts") != {
        "briefs": 32,
        "shared_rows": 160,
        "languages_per_brief": 5,
        "independent_reviews": 32,
        "concept_author_briefs": dict(
            sorted(
                Counter(
                    concept["concept_author_id"] for concept in concepts
                ).items()
            )
        ),
        "concept_reviewer_briefs": dict(
            sorted(
                Counter(
                    concept["concept_reviewer_id"] for concept in concepts
                ).items()
            )
        ),
    } or receipt.get("gates") != {
        "all_briefs_language_neutrality_approved": True,
        "all_briefs_meaning_safety_approved": True,
        "all_briefs_family_separation_approved": True,
        "all_brief_reviews_independent": True,
        "minimum_five_concept_custodians_per_lane": True,
        "maximum_eight_briefs_per_concept_custodian": True,
        "candidate_model_output_seen": False,
        "native_rewrite_reviews_complete": False,
        "evaluation_eligible": False,
    } or receipt.get("assurance") != {"scope": ASSURANCE_SCOPE} or receipt.get("publication") != "exclusive_private_bundle_receipt_last":
        raise ValidationFailure("shared brief receipt gates changed")
    artifact = receipt.get("artifacts")
    expected_artifact = {
        "shared-concept-briefs.json": {
            "sha256": sha256_bytes(blobs["shared-concept-briefs.json"]),
            "bytes": len(blobs["shared-concept-briefs.json"]),
            "object_count": 1,
        }
    }
    if artifact != expected_artifact:
        raise ValidationFailure("shared brief registry artifact binding changed")
    return concepts, receipt, blobs


def validate_roster(roster: dict[str, Any], contract: dict[str, Any]) -> list[dict[str, Any]]:
    if set(roster) != ROSTER_FIELDS or roster.get("schema_version") != ROSTER_SCHEMA:
        raise ValidationFailure("private roster schema changed")
    for field in ("roster_id", "approved_by_id", "approval_reference_id"):
        if not is_safe_id(roster.get(field)):
            raise ValidationFailure(f"private roster {field} must be an opaque safe ID")
    if roster.get("status") != "approved_for_development_authoring" or not is_utc_timestamp(roster.get("approved_at")):
        raise ValidationFailure("private roster is not approved")
    if roster.get("candidate_model_output_seen") is not False:
        raise ValidationFailure("private roster was exposed to candidate model output")
    participants = roster.get("participants")
    if not isinstance(participants, list) or not participants:
        raise ValidationFailure("private roster participants are missing")
    ids: set[str] = set()
    identities: set[str] = set()
    allowed_roles = {
        "concept_author",
        "concept_reviewer",
        "author",
        "native_reviewer",
    }
    validated: list[dict[str, Any]] = []
    for index, participant in enumerate(participants, 1):
        if not isinstance(participant, dict) or set(participant) != PARTICIPANT_FIELDS:
            raise ValidationFailure(f"roster participant {index} schema changed")
        participant_id = participant.get("participant_id")
        identity_id = participant.get("identity_reference_id")
        if not is_safe_id(participant_id) or not is_safe_id(identity_id) or not is_safe_id(participant.get("consent_reference_id")):
            raise ValidationFailure(f"roster participant {index} needs opaque IDs")
        if participant_id in ids or identity_id in identities:
            raise ValidationFailure("private roster contains duplicate participant or identity")
        ids.add(participant_id)
        identities.add(identity_id)
        if participant.get("consent_status") != "granted" or participant.get("availability_status") != "confirmed":
            raise ValidationFailure(f"{participant_id}: consent or availability is not ready")
        languages = participant.get("languages")
        attestations = participant.get("native_attestations")
        roles = participant.get("roles")
        if (
            not isinstance(roles, list)
            or len(roles) != 1
            or roles[0] not in allowed_roles
        ):
            raise ValidationFailure(
                f"{participant_id}: roster roles must be singular and disjoint"
            )
        role = roles[0]
        expected_type = contract["roster_contract"]["participant_types_by_role"][role]
        if participant.get("participant_type") != expected_type:
            raise ValidationFailure(
                f"{participant_id}: participant type does not match roster role"
            )
        if role in {"author", "native_reviewer"}:
            if (
                not isinstance(languages, list)
                or not languages
                or len(languages) != len(set(languages))
                or not set(languages).issubset(set(contract["languages"]))
            ):
                raise ValidationFailure(
                    f"{participant_id}: language qualifications are invalid"
                )
            if (
                not isinstance(attestations, dict)
                or set(attestations) != set(languages)
                or any(attestations.get(language) is not True for language in languages)
            ):
                raise ValidationFailure(
                    f"{participant_id}: per-language native attestations are invalid"
                )
        elif languages != [] or attestations != {}:
            raise ValidationFailure(
                f"{participant_id}: concept custodians must not claim native-language coverage"
            )
        validated.append(participant)
    if ids & identities:
        raise ValidationFailure(
            "private roster participant and identity reference namespaces must be disjoint"
        )
    minimum_concept = contract["roster_contract"][
        "minimum_concept_custodians_per_lane"
    ]
    for role in ("concept_author", "concept_reviewer"):
        count = sum(participant["roles"] == [role] for participant in validated)
        if count < minimum_concept:
            raise ValidationFailure(
                f"private roster requires at least {minimum_concept} {role} custodians"
            )
    for language in contract["languages"]:
        author_ids = {
            participant["identity_reference_id"]
            for participant in validated
            if participant["roles"] == ["author"] and language in participant["languages"]
        }
        reviewer_ids = {
            participant["identity_reference_id"]
            for participant in validated
            if participant["roles"] == ["native_reviewer"] and language in participant["languages"]
        }
        minimum = contract["roster_contract"]["minimum_participants_per_lane_language"]
        if (
            len(author_ids) < minimum
            or len(reviewer_ids) < minimum
            or author_ids & reviewer_ids
        ):
            raise ValidationFailure(
                f"{language}: at least {minimum} separate native authors and reviewers are required"
            )
    return sorted(validated, key=lambda row: row["participant_id"])


def packet_participant(
    participants: list[dict[str, Any]], language: str, role: str, packet_id: str, seed: int
) -> str:
    eligible = [
        row for row in participants
        if row["roles"] == [role] and language in row["languages"]
    ]
    eligible.sort(
        key=lambda row: sha256_bytes(
            f"{seed}|{language}|{role}|{row['participant_id']}".encode()
        )
    )
    packet_number = int(packet_id.rsplit("-", 1)[1]) - 1
    return eligible[packet_number % len(eligible)]["participant_id"]


def build_assignments(
    rows: list[dict[str, Any]],
    participants: list[dict[str, Any]],
    seed: int,
    brief_concepts: Sequence[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    briefs = {concept["brief_id"]: concept for concept in brief_concepts}
    participant_identity_by_id = {
        participant["participant_id"]: participant["identity_reference_id"]
        for participant in participants
    }
    if set(briefs) != set(shared_brief_allocations(rows)):
        raise ValidationFailure("launch shared brief coverage differs from allocation")
    assignments: list[dict[str, Any]] = []
    for row in rows:
        author_id = packet_participant(
            participants, row["language"], "author", row["author_packet_id"], seed
        )
        reviewer_id = packet_participant(
            participants,
            row["language"],
            "native_reviewer",
            row["reviewer_packet_id"],
            seed,
        )
        if author_id == reviewer_id:
            raise ValidationFailure(f"{row['case_id']}: author/reviewer identity collision")
        assignments.append(
            {
                "schema_version": ASSIGNMENT_SCHEMA,
                "assignment_id": opaque_id("assignment", str(seed), row["slot_id"]),
                "slot_id": row["slot_id"],
                "case_id": row["case_id"],
                "language": row["language"],
                "shared_concept_brief_id": row["shared_concept_brief_id"],
                "shared_concept_brief_sha256": (
                    briefs[row["shared_concept_brief_id"]]["brief_sha256"]
                    if row["shared_concept_brief_id"] is not None
                    else None
                ),
                "author_packet_id": row["author_packet_id"],
                "reviewer_packet_id": row["reviewer_packet_id"],
                "author_id": author_id,
                "native_reviewer_id": reviewer_id,
                "candidate_model_output_seen": False,
                "prose_authored": False,
                "native_review_approved": False,
                "evaluation_eligible": False,
            }
        )
    by_slot = {row["slot_id"]: row for row in assignments}
    if len(by_slot) != 800:
        raise ValidationFailure("launch assignments do not cover 800 unique slots")
    assigned_packets: dict[str, list[dict[str, Any]]] = {}
    for role, field in (("author", "author_packet_id"), ("native_reviewer", "reviewer_packet_id")):
        for packet_id in sorted({row[field] for row in assignments}):
            members = sorted(
                (row for row in assignments if row[field] == packet_id),
                key=lambda row: row["slot_id"],
            )
            participant_field = "author_id" if role == "author" else "native_reviewer_id"
            participant_ids = {row[participant_field] for row in members}
            if len(participant_ids) != 1 or len(members) != 16:
                raise ValidationFailure(f"{packet_id}: packet assignment is not singular and complete")
            assigned_packets.setdefault(role, []).append(
                {
                    "schema_version": ASSIGNED_PACKET_SCHEMA,
                    "packet_id": packet_id,
                    "role": role,
                    "language": members[0]["language"],
                    "participant_id": next(iter(participant_ids)),
                    "row_count": len(members),
                    "slot_ids": [row["slot_id"] for row in members],
                    "assignment_ids": [row["assignment_id"] for row in members],
                    "shared_concept_brief_bindings": sorted(
                        [
                            {
                                "brief_id": row["shared_concept_brief_id"],
                                "brief_sha256": row["shared_concept_brief_sha256"],
                            }
                            for row in members
                            if row["shared_concept_brief_id"] is not None
                        ],
                        key=lambda binding: binding["brief_id"],
                    ),
                    "candidate_model_output_seen": False,
                    "prose_authored": False,
                    "native_review_approved": False,
                }
            )
    maximum = 2
    for role in ("author", "native_reviewer"):
        counts = Counter(
            (packet["language"], packet["participant_id"])
            for packet in assigned_packets[role]
        )
        if any(count > maximum for count in counts.values()):
            raise ValidationFailure(
                f"{role}: a participant exceeds two packets in one language"
            )
        for language in v2.LANGUAGES:
            if len({participant for (lang, participant) in counts if lang == language}) < 5:
                raise ValidationFailure(
                    f"{language}: {role} packet assignments use fewer than five people"
                )
    assignments_by_brief: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for assignment in assignments:
        if assignment["shared_concept_brief_id"] is not None:
            assignments_by_brief[assignment["shared_concept_brief_id"]].append(
                assignment
            )
    for brief_id, members in assignments_by_brief.items():
        concept = briefs[brief_id]
        local_identity_references = {
            participant_identity_by_id[participant_id]
            for member in members
            for participant_id in (
                member["author_id"],
                member["native_reviewer_id"],
            )
        }
        concept_ids = {
            concept["concept_author_id"],
            concept["concept_reviewer_id"],
        }
        if len(members) != 5 or local_identity_references & concept_ids:
            raise ValidationFailure(
                f"{brief_id}: concept and all local author/reviewer identities must be distinct"
            )
    return assignments, assigned_packets["author"], assigned_packets["native_reviewer"]


def launch_bundle(
    *,
    contract: dict[str, Any],
    allocation_receipt_path: Path,
    shared_brief_receipt_path: Path,
    roster_path: Path,
    output: Path,
    execution_git_head: str,
    pre_receipt_check: Callable[[], None] | None = None,
) -> dict[str, Any]:
    input_paths = [
        allocation_receipt_path.parent / name for name in ALLOCATION_ARTIFACTS
    ] + [
        shared_brief_receipt_path.parent / name for name in SHARED_BRIEF_ARTIFACTS
    ] + [roster_path, *CONTROL_PATHS]
    input_blobs, input_digests = snapshot_paths(input_paths)
    rows, allocation_receipt, allocation_blobs, sealed_contract = authenticate_allocation(
        allocation_receipt_path, contract, execution_git_head
    )
    for name in ALLOCATION_ARTIFACTS:
        if allocation_blobs[name] != input_blobs[allocation_receipt_path.parent / name]:
            raise ValidationFailure(
                f"allocation input changed during launch validation: {name}"
            )
    brief_concepts, _, shared_brief_blobs = authenticate_shared_brief_bundle(
        shared_brief_receipt_path,
        allocation_receipt_path,
        rows,
        roster_path,
        sealed_contract,
        execution_git_head,
    )
    for name in SHARED_BRIEF_ARTIFACTS:
        if shared_brief_blobs[name] != input_blobs[
            shared_brief_receipt_path.parent / name
        ]:
            raise ValidationFailure(
                f"shared brief input changed during launch validation: {name}"
            )
    roster_bytes = input_blobs[roster_path]
    roster_sha = input_digests[roster_path]
    roster = parse_object(roster_bytes, "private roster")
    participants = validate_roster(roster, sealed_contract)
    assignments, author_packets, reviewer_packets = build_assignments(
        rows, participants, int(sealed_contract["seed"]), brief_concepts
    )
    artifact_bytes = {
        "assignments.jsonl": encode_jsonl(assignments),
        "author_packets.jsonl": encode_jsonl(author_packets),
        "reviewer_packets.jsonl": encode_jsonl(reviewer_packets),
    }
    control_digests = {path: input_digests[path] for path in CONTROL_PATHS}
    receipt = {
        "schema_version": LAUNCH_RECEIPT_SCHEMA,
        "status": "all_800_assignments_ready_native_review_pending",
        "execution_git_head": execution_git_head,
        "controls": control_bindings(control_digests),
        "inputs": {
            "allocation_receipt_sha256": input_digests[allocation_receipt_path],
            "allocation_artifact_set_sha256": sha256_bytes(
                encode_json(
                    {
                        name: input_digests[allocation_receipt_path.parent / name]
                        for name in ALLOCATION_ARTIFACTS
                    }
                )
            ),
            "shared_brief_receipt_sha256": input_digests[
                shared_brief_receipt_path
            ],
            "shared_brief_registry_sha256": input_digests[
                shared_brief_receipt_path.parent / "shared-concept-briefs.json"
            ],
            "roster_id": roster["roster_id"],
            "roster_sha256": roster_sha,
        },
        "counts": {
            "assignments": len(assignments),
            "author_packets": len(author_packets),
            "reviewer_packets": len(reviewer_packets),
            "author_assignments": dict(sorted(Counter(row["author_id"] for row in assignments).items())),
            "reviewer_assignments": dict(sorted(Counter(row["native_reviewer_id"] for row in assignments).items())),
            "author_packets_by_language_participant": {
                language: dict(
                    sorted(
                        Counter(
                            packet["participant_id"]
                            for packet in author_packets
                            if packet["language"] == language
                        ).items()
                    )
                )
                for language in v2.LANGUAGES
            },
            "reviewer_packets_by_language_participant": {
                language: dict(
                    sorted(
                        Counter(
                            packet["participant_id"]
                            for packet in reviewer_packets
                            if packet["language"] == language
                        ).items()
                    )
                )
                for language in v2.LANGUAGES
            },
            "concept_author_briefs": dict(
                sorted(
                    Counter(
                        concept["concept_author_id"] for concept in brief_concepts
                    ).items()
                )
            ),
            "concept_reviewer_briefs": dict(
                sorted(
                    Counter(
                        concept["concept_reviewer_id"] for concept in brief_concepts
                    ).items()
                )
            ),
        },
        "artifacts": {
            name: {
                "sha256": sha256_bytes(value),
                "bytes": len(value),
                "row_count": len(assignments if name == "assignments.jsonl" else author_packets if name == "author_packets.jsonl" else reviewer_packets),
            }
            for name, value in artifact_bytes.items()
        },
        "gates": {
            "operator_attested_private_roster_approved": True,
            "registered_concept_custody_roles_disjoint": True,
            "minimum_five_concept_custodians_per_lane": True,
            "maximum_eight_briefs_per_concept_custodian": True,
            "operator_attested_all_authors_human_native": True,
            "operator_attested_all_reviewers_human_native": True,
            "author_reviewer_lanes_disjoint": True,
            "minimum_five_people_per_lane_language": True,
            "maximum_two_packets_per_person_language": True,
            "all_rows_native_review_approved": False,
            "leakage_screen_complete": False,
            "evaluation_eligible": False,
        },
        "privacy": {
            "roster_tracked_by_repo": False,
            "raw_names_emails_or_contact_details_published": False,
            "prose_published": False,
            "candidate_output_published": False,
        },
        "analysis_clustering": {
            "concept_author_cluster_field": "concept_author_id",
            "concept_reviewer_cluster_field": "concept_reviewer_id",
            "author_cluster_field": "author_id",
            "reviewer_cluster_field": "native_reviewer_id",
            "human_variance_cluster_fields": [
                "concept_author_id",
                "concept_reviewer_id",
                "author_id",
                "native_reviewer_id",
            ],
            "packet_level_cluster_fields": ["language", "participant_id"],
        },
        "assurance": {
            "scope": ASSURANCE_SCOPE,
            "cryptographic_human_identity_or_custody_proof": False,
            "candidate_output_nonexposure": "operator_attested",
        },
        "publication": "exclusive_private_bundle_receipt_last",
    }
    publish_bundle(output, artifact_bytes, encode_json(receipt), input_digests, pre_receipt_check)
    return receipt


def authenticate_launch(
    receipt_path: Path,
    allocation_receipt_path: Path,
    shared_brief_receipt_path: Path,
    roster_path: Path,
    rows: list[dict[str, Any]],
    contract: dict[str, Any],
    expected_head: str,
) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, bytes]]:
    blobs = exact_bundle(receipt_path, LAUNCH_ARTIFACTS, "launch")
    receipt = parse_object(blobs["receipt.json"], "launch receipt")
    if set(receipt) != {
        "schema_version",
        "status",
        "execution_git_head",
        "controls",
        "inputs",
        "counts",
        "artifacts",
        "gates",
        "privacy",
        "analysis_clustering",
        "assurance",
        "publication",
    }:
        raise ValidationFailure("launch receipt schema changed")
    if receipt.get("schema_version") != LAUNCH_RECEIPT_SCHEMA or receipt.get("status") != "all_800_assignments_ready_native_review_pending":
        raise ValidationFailure("launch receipt status or schema is invalid")
    sealed_contract = validate_control_receipt(receipt, expected_head)
    allocation_receipt = parse_object(
        read_snapshot(allocation_receipt_path, "allocation receipt")[0],
        "allocation receipt",
    )
    allocation_contract = validate_control_receipt(allocation_receipt, expected_head)
    if sealed_contract != allocation_contract:
        raise ValidationFailure("launch and allocation contracts differ")
    if receipt.get("inputs", {}).get("allocation_receipt_sha256") != read_snapshot(allocation_receipt_path, "allocation receipt")[1]:
        raise ValidationFailure("launch receipt is bound to a different allocation")
    brief_concepts, _, _ = authenticate_shared_brief_bundle(
        shared_brief_receipt_path,
        allocation_receipt_path,
        rows,
        roster_path,
        sealed_contract,
        expected_head,
    )
    if (
        receipt.get("inputs", {}).get("shared_brief_receipt_sha256")
        != read_snapshot(shared_brief_receipt_path, "shared brief receipt")[1]
        or receipt.get("inputs", {}).get("shared_brief_registry_sha256")
        != read_snapshot(
            shared_brief_receipt_path.parent / "shared-concept-briefs.json",
            "shared brief registry",
        )[1]
    ):
        raise ValidationFailure("launch receipt is bound to stale shared briefs")
    roster_bytes, roster_sha = read_snapshot(roster_path, "private roster")
    if receipt.get("inputs", {}).get("roster_sha256") != roster_sha:
        raise ValidationFailure("launch receipt is bound to a stale private roster")
    roster = parse_object(roster_bytes, "private roster")
    participants = validate_roster(roster, sealed_contract)
    expected_assignments, expected_author_packets, expected_reviewer_packets = build_assignments(
        rows, participants, int(sealed_contract["seed"]), brief_concepts
    )
    observed = {
        "assignments.jsonl": parse_rows(blobs["assignments.jsonl"], "launch assignments"),
        "author_packets.jsonl": parse_rows(blobs["author_packets.jsonl"], "assigned author packets"),
        "reviewer_packets.jsonl": parse_rows(blobs["reviewer_packets.jsonl"], "assigned reviewer packets"),
    }
    expected_rows = {
        "assignments.jsonl": expected_assignments,
        "author_packets.jsonl": expected_author_packets,
        "reviewer_packets.jsonl": expected_reviewer_packets,
    }
    if observed != expected_rows:
        raise ValidationFailure("launch assignments differ from the sealed allocation and roster")
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != set(LAUNCH_ARTIFACTS[:-1]):
        raise ValidationFailure("launch receipt artifact inventory changed")
    for name in LAUNCH_ARTIFACTS[:-1]:
        meta = artifacts[name]
        expected_row_count = 800 if name == "assignments.jsonl" else 50
        if meta != {
            "sha256": sha256_bytes(blobs[name]),
            "bytes": len(blobs[name]),
            "row_count": expected_row_count,
        }:
            raise ValidationFailure(f"launch artifact hash changed: {name}")
    allocation_hashes = {
        name: read_snapshot(
            allocation_receipt_path.parent / name, f"allocation {name}"
        )[1]
        for name in ALLOCATION_ARTIFACTS
    }
    expected_inputs = {
        "allocation_receipt_sha256": allocation_hashes["receipt.json"],
        "allocation_artifact_set_sha256": sha256_bytes(
            encode_json(allocation_hashes)
        ),
        "shared_brief_receipt_sha256": read_snapshot(
            shared_brief_receipt_path, "shared brief receipt"
        )[1],
        "shared_brief_registry_sha256": read_snapshot(
            shared_brief_receipt_path.parent / "shared-concept-briefs.json",
            "shared brief registry",
        )[1],
        "roster_id": roster["roster_id"],
        "roster_sha256": roster_sha,
    }
    expected_counts = {
        "assignments": 800,
        "author_packets": 50,
        "reviewer_packets": 50,
        "author_assignments": dict(
            sorted(Counter(row["author_id"] for row in expected_assignments).items())
        ),
        "reviewer_assignments": dict(
            sorted(
                Counter(
                    row["native_reviewer_id"] for row in expected_assignments
                ).items()
            )
        ),
        "author_packets_by_language_participant": {
            language: dict(
                sorted(
                    Counter(
                        packet["participant_id"]
                        for packet in expected_author_packets
                        if packet["language"] == language
                    ).items()
                )
            )
            for language in v2.LANGUAGES
        },
        "reviewer_packets_by_language_participant": {
            language: dict(
                sorted(
                    Counter(
                        packet["participant_id"]
                        for packet in expected_reviewer_packets
                        if packet["language"] == language
                    ).items()
                )
            )
            for language in v2.LANGUAGES
        },
        "concept_author_briefs": dict(
            sorted(
                Counter(
                    concept["concept_author_id"] for concept in brief_concepts
                ).items()
            )
        ),
        "concept_reviewer_briefs": dict(
            sorted(
                Counter(
                    concept["concept_reviewer_id"] for concept in brief_concepts
                ).items()
            )
        ),
    }
    if receipt.get("inputs") != expected_inputs or receipt.get("counts") != expected_counts:
        raise ValidationFailure("launch receipt inputs or counts changed")
    if receipt.get("gates") != {
        "operator_attested_private_roster_approved": True,
        "registered_concept_custody_roles_disjoint": True,
        "minimum_five_concept_custodians_per_lane": True,
        "maximum_eight_briefs_per_concept_custodian": True,
        "operator_attested_all_authors_human_native": True,
        "operator_attested_all_reviewers_human_native": True,
        "author_reviewer_lanes_disjoint": True,
        "minimum_five_people_per_lane_language": True,
        "maximum_two_packets_per_person_language": True,
        "all_rows_native_review_approved": False,
        "leakage_screen_complete": False,
        "evaluation_eligible": False,
    } or receipt.get("privacy") != {
        "roster_tracked_by_repo": False,
        "raw_names_emails_or_contact_details_published": False,
        "prose_published": False,
        "candidate_output_published": False,
    } or receipt.get("analysis_clustering") != {
        "concept_author_cluster_field": "concept_author_id",
        "concept_reviewer_cluster_field": "concept_reviewer_id",
        "author_cluster_field": "author_id",
        "reviewer_cluster_field": "native_reviewer_id",
        "human_variance_cluster_fields": [
            "concept_author_id",
            "concept_reviewer_id",
            "author_id",
            "native_reviewer_id",
        ],
        "packet_level_cluster_fields": ["language", "participant_id"],
    } or receipt.get("assurance") != {
        "scope": ASSURANCE_SCOPE,
        "cryptographic_human_identity_or_custody_proof": False,
        "candidate_output_nonexposure": "operator_attested",
    } or receipt.get("publication") != "exclusive_private_bundle_receipt_last":
        raise ValidationFailure("launch receipt gates or assurance changed")
    return expected_assignments, receipt, blobs


def recursively_reject_candidate_output(value: Any, location: str = "root") -> None:
    if isinstance(value, dict):
        for key, nested in value.items():
            if key == CANDIDATE_EXPOSURE_FLAG:
                if nested is not False:
                    raise ValidationFailure(
                        f"candidate-output exposure is forbidden at {location}.{key}"
                    )
                continue
            if key in FORBIDDEN_CANDIDATE_KEYS:
                raise ValidationFailure(f"candidate-output field is forbidden at {location}.{key}")
            recursively_reject_candidate_output(nested, f"{location}.{key}")
    elif isinstance(value, list):
        for index, nested in enumerate(value):
            recursively_reject_candidate_output(nested, f"{location}[{index}]")


def validate_full_development_matrix(rows: list[dict[str, Any]]) -> None:
    if len(rows) != 800 or any(row.get("split") != "development" for row in rows):
        raise ValidationFailure("development corpus must contain exactly 800 development rows")
    language_counts = Counter(row.get("language") for row in rows)
    cell_counts = Counter(
        (row.get("language"), row.get("behavior"), row.get("domain"))
        for row in rows
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
    difficulty_by_behavior: dict[tuple[str, str], set[str]] = defaultdict(set)
    contrasts: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        difficulty_by_behavior[(row.get("language"), row.get("behavior"))].add(
            row.get("difficulty")
        )
        if row.get("contrast_set_id") is not None:
            contrasts[row["contrast_set_id"]].append(row)
    for language in v2.LANGUAGES:
        if language_counts[language] != 160:
            raise ValidationFailure(f"{language}: development row count is not 160")
        if (
            source_counts[(language, "native_original")] != 128
            or source_counts[(language, "shared_concept_local_rewrite")] != 32
        ):
            raise ValidationFailure(f"{language}: native/shared count is not exact 80/20")
        for behavior in v2.BEHAVIORS:
            if difficulty_by_behavior[(language, behavior)] != {
                "routine",
                "challenging",
                "adversarial",
            }:
                raise ValidationFailure(
                    f"{language}/{behavior}: all difficulty levels are required"
                )
            for domain in v2.DOMAINS:
                if cell_counts[(language, behavior, domain)] != 2:
                    raise ValidationFailure(
                        f"{language}/{behavior}/{domain}: development cell is incomplete"
                    )
    contrast_sources = Counter()
    for contrast_id, members in contrasts.items():
        if len(members) != 2:
            raise ValidationFailure(f"{contrast_id}: contrast set must contain two rows")
        member_sources = {
            row["provenance"]["source_type"] for row in members
        }
        if len(member_sources) != 1:
            raise ValidationFailure(f"{contrast_id}: contrast source types differ")
        contrast_sources[next(iter(member_sources))] += 1
    if len(contrasts) != 200 or contrast_sources != Counter(
        {"native_original": 160, "shared_concept_local_rewrite": 40}
    ):
        raise ValidationFailure("contrast matrix must be 160 native/native and 40 shared/shared")
    family_counts = Counter(row["semantic_family_id"] for row in rows)
    if len(family_counts) != 672:
        raise ValidationFailure("development corpus must contain 672 family clusters")


def validate_development_rows(
    rows: list[dict[str, Any]],
    allocation: list[dict[str, Any]],
    assignments: list[dict[str, Any]],
) -> None:
    try:
        v2.validate_rows(rows)
    except v2.BenchmarkValidationError as error:
        raise ValidationFailure(str(error)) from error
    recursively_reject_candidate_output(rows)
    validate_full_development_matrix(rows)
    allocation_by_case = {row["case_id"]: row for row in allocation}
    assignments_by_case = {row["case_id"]: row for row in assignments}
    rows_by_case = {row["case_id"]: row for row in rows}
    if len(rows_by_case) != 800 or set(rows_by_case) != set(allocation_by_case):
        raise ValidationFailure("completed corpus case coverage differs from allocation")
    for case_id, row in rows_by_case.items():
        slot = allocation_by_case[case_id]
        assignment = assignments_by_case.get(case_id)
        if assignment is None:
            raise ValidationFailure(f"{case_id}: launch assignment is missing")
        for field in IMMUTABLE_ROW_BINDINGS:
            if row.get(field) != slot[field]:
                raise ValidationFailure(f"{case_id}: allocated {field} changed")
        provenance = row.get("provenance")
        if not isinstance(provenance, dict) or provenance.get("source_type") != slot["source_type"]:
            raise ValidationFailure(f"{case_id}: source type differs from allocation")
        if provenance.get("source_ref") != assignment["assignment_id"]:
            raise ValidationFailure(f"{case_id}: source_ref differs from launch assignment")
        author = provenance.get("native_author")
        reviewer = provenance.get("independent_native_validator")
        if not isinstance(author, dict) or author.get("reviewer_id") != assignment["author_id"]:
            raise ValidationFailure(f"{case_id}: native author differs from launch assignment")
        if not isinstance(reviewer, dict) or reviewer.get("reviewer_id") != assignment["native_reviewer_id"] or reviewer.get("status") != "approved" or reviewer.get("independent_of_author") is not True:
            raise ValidationFailure(f"{case_id}: independent native review is not approved")
        if author.get("reviewer_id") == reviewer.get("reviewer_id"):
            raise ValidationFailure(f"{case_id}: author/reviewer identity collision")
        shared_binding = provenance.get("shared_concept_binding")
        if slot["shared_concept_brief_id"] is None:
            if shared_binding is not None or assignment["shared_concept_brief_sha256"] is not None:
                raise ValidationFailure(f"{case_id}: native row carries a shared brief")
        elif shared_binding != {
            "brief_id": assignment["shared_concept_brief_id"],
            "brief_sha256": assignment["shared_concept_brief_sha256"],
            "independent_local_rewrite": True,
            "candidate_model_output_seen": False,
        }:
            raise ValidationFailure(
                f"{case_id}: shared row lacks its sealed brief fidelity binding"
            )


def validate_native_review_seal(
    seal: dict[str, Any],
    rows: list[dict[str, Any]],
    assignments: list[dict[str, Any]],
    corpus_sha: str,
    allocation_receipt_sha: str,
    launch_receipt_sha: str,
    brief_concepts: Sequence[dict[str, Any]],
    participants: Sequence[dict[str, Any]],
) -> None:
    required = {
        "schema_version",
        "status",
        "corpus_sha256",
        "benchmark_content_sha256",
        "allocation_receipt_sha256",
        "launch_receipt_sha256",
        "candidate_model_output_seen",
        "assurance_scope",
        "reviews",
    }
    if set(seal) != required or seal.get("schema_version") != NATIVE_REVIEW_SEAL_SCHEMA:
        raise ValidationFailure("native-review seal schema changed")
    if (
        seal.get("status") != "all_800_independent_native_reviews_approved"
        or seal.get("candidate_model_output_seen") is not False
        or seal.get("assurance_scope") != ASSURANCE_SCOPE
    ):
        raise ValidationFailure("native-review seal is not clean and approved")
    expected_bindings = {
        "corpus_sha256": corpus_sha,
        "benchmark_content_sha256": v2.benchmark_content_sha256(rows),
        "allocation_receipt_sha256": allocation_receipt_sha,
        "launch_receipt_sha256": launch_receipt_sha,
    }
    for field, expected in expected_bindings.items():
        if seal.get(field) != expected:
            raise ValidationFailure(f"native-review seal {field} is stale")
    reviews = seal.get("reviews")
    if not isinstance(reviews, list) or len(reviews) != 800:
        raise ValidationFailure("native-review seal must contain 800 reviews")
    rows_by_case = {row["case_id"]: row for row in rows}
    assignments_by_case = {row["case_id"]: row for row in assignments}
    briefs = {concept["brief_id"]: concept for concept in brief_concepts}
    participant_identity_by_id = {
        participant["participant_id"]: participant["identity_reference_id"]
        for participant in participants
    }
    seen: set[str] = set()
    for review in reviews:
        if not isinstance(review, dict) or set(review) != NATIVE_REVIEW_FIELDS:
            raise ValidationFailure("native-review record schema changed")
        case_id = review.get("case_id")
        if case_id in seen or case_id not in rows_by_case:
            raise ValidationFailure("native-review seal has a duplicate or unknown case")
        seen.add(case_id)
        assignment = assignments_by_case[case_id]
        expected = {
            "assignment_id": assignment["assignment_id"],
            "author_id": assignment["author_id"],
            "reviewer_id": assignment["native_reviewer_id"],
            "row_sha256": v2.sha256_bytes(
                v2.canonical_json(rows_by_case[case_id]).encode("utf-8")
            ),
            "shared_concept_brief_id": assignment["shared_concept_brief_id"],
            "shared_concept_brief_sha256": assignment[
                "shared_concept_brief_sha256"
            ],
            "faithful_to_shared_brief": (
                True if assignment["shared_concept_brief_id"] is not None else None
            ),
        }
        if any(review.get(field) != value for field, value in expected.items()):
            raise ValidationFailure(f"{case_id}: native-review binding is stale")
        if review.get("author_native_attested") is not True or review.get("reviewer_native_attested") is not True or review.get("independent_of_author") is not True or review.get("status") != "approved" or review.get("author_id") == review.get("reviewer_id"):
            raise ValidationFailure(f"{case_id}: native review is not independently approved")
        brief_id = assignment["shared_concept_brief_id"]
        if brief_id is not None:
            concept = briefs.get(brief_id)
            reviewer_identity_reference = participant_identity_by_id.get(
                review["reviewer_id"]
            )
            if reviewer_identity_reference is None or reviewer_identity_reference in {
                concept["concept_author_id"],
                concept["concept_reviewer_id"],
            }:
                raise ValidationFailure(
                    f"{case_id}: local fidelity reviewer collides with concept custody"
                )
    if set(rows_by_case) != seen:
        raise ValidationFailure("native-review seal coverage is incomplete")


def validate_contrast_comparability_seal(
    seal: dict[str, Any],
    rows: list[dict[str, Any]],
    allocation: list[dict[str, Any]],
    assignments: list[dict[str, Any]],
    participants: list[dict[str, Any]],
    corpus_sha: str,
    allocation_receipt_sha: str,
    launch_receipt_sha: str,
) -> dict[str, Any]:
    required = {
        "schema_version",
        "status",
        "corpus_sha256",
        "benchmark_content_sha256",
        "allocation_receipt_sha256",
        "launch_receipt_sha256",
        "candidate_model_output_seen",
        "assurance_scope",
        "reviews",
    }
    if (
        set(seal) != required
        or seal.get("schema_version") != CONTRAST_COMPARABILITY_SEAL_SCHEMA
        or seal.get("status")
        != "all_200_model_blind_contrast_sets_comparable"
        or seal.get("candidate_model_output_seen") is not False
        or seal.get("assurance_scope") != ASSURANCE_SCOPE
    ):
        raise ValidationFailure("contrast-comparability seal is invalid")
    expected_bindings = {
        "corpus_sha256": corpus_sha,
        "benchmark_content_sha256": v2.benchmark_content_sha256(rows),
        "allocation_receipt_sha256": allocation_receipt_sha,
        "launch_receipt_sha256": launch_receipt_sha,
    }
    for field, expected in expected_bindings.items():
        if seal.get(field) != expected:
            raise ValidationFailure(f"contrast-comparability seal {field} is stale")
    reviews = seal.get("reviews")
    if not isinstance(reviews, list) or len(reviews) != 200:
        raise ValidationFailure("contrast-comparability seal must contain 200 reviews")
    rows_by_case = {row["case_id"]: row for row in rows}
    allocation_by_case = {row["case_id"]: row for row in allocation}
    assignments_by_case = {row["case_id"]: row for row in assignments}
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for slot in allocation:
        if slot["contrast_set_id"] is not None:
            groups[slot["contrast_set_id"]].append(slot)
    eligible = {
        (language, participant["participant_id"])
        for participant in participants
        if participant["roles"] == ["native_reviewer"]
        for language in participant["languages"]
        if participant["native_attestations"].get(language) is True
    }
    seen: set[str] = set()
    reviewer_counts: Counter[tuple[str, str]] = Counter()
    for review in reviews:
        if not isinstance(review, dict) or set(review) != COMPARABILITY_REVIEW_FIELDS:
            raise ValidationFailure("contrast-comparability review schema changed")
        contrast_id = review.get("contrast_set_id")
        if contrast_id in seen or contrast_id not in groups:
            raise ValidationFailure("contrast-comparability seal has duplicate or unknown set")
        seen.add(contrast_id)
        members = groups[contrast_id]
        positive = next(
            row for row in members if row["behavior"] in v2.POSITIVE_LIST_BEHAVIORS
        )
        restraint = next(
            row for row in members if row["behavior"] in v2.RESTRAINT_BEHAVIORS
        )
        reviewer_id = review.get("reviewer_id")
        language = positive["language"]
        excluded = {
            assignments_by_case[positive["case_id"]]["author_id"],
            assignments_by_case[restraint["case_id"]]["author_id"],
            assignments_by_case[positive["case_id"]]["native_reviewer_id"],
            assignments_by_case[restraint["case_id"]]["native_reviewer_id"],
        }
        expected = {
            "contrast_brief_id": positive["contrast_brief_id"],
            "contrast_archetype": positive["contrast_archetype"],
            "positive_case_id": positive["case_id"],
            "restraint_case_id": restraint["case_id"],
            "positive_row_sha256": v2.sha256_bytes(
                v2.canonical_json(rows_by_case[positive["case_id"]]).encode("utf-8")
            ),
            "restraint_row_sha256": v2.sha256_bytes(
                v2.canonical_json(rows_by_case[restraint["case_id"]]).encode("utf-8")
            ),
        }
        if any(review.get(field) != value for field, value in expected.items()):
            raise ValidationFailure(f"{contrast_id}: comparability binding is stale")
        if (
            (language, reviewer_id) not in eligible
            or reviewer_id in excluded
            or review.get("reviewer_native_attested") is not True
            or review.get("independent_of_authors_and_row_reviewers") is not True
            or review.get("status") != "comparable"
        ):
            raise ValidationFailure(
                f"{contrast_id}: comparability approval is not independent"
            )
        reviewer_counts[(language, reviewer_id)] += 1
    if seen != set(groups):
        raise ValidationFailure("contrast-comparability seal coverage is incomplete")
    counts_by_language: dict[str, dict[str, int]] = {}
    for language in v2.LANGUAGES:
        counts = {
            reviewer_id: count
            for (review_language, reviewer_id), count in sorted(
                reviewer_counts.items()
            )
            if review_language == language
        }
        if len(counts) < 5 or any(count > 8 for count in counts.values()):
            raise ValidationFailure(
                f"{language}: comparability review diversity or workload cap failed"
            )
        counts_by_language[language] = counts
    return {
        "identity_clusters": len(
            {reviewer_id for _, reviewer_id in reviewer_counts}
        ),
        "clusters_by_language": {
            language: len(counts) for language, counts in counts_by_language.items()
        },
        "sets_by_language_reviewer": counts_by_language,
    }


def parse_bound_path_specs(
    specs: Sequence[str], label: str
) -> dict[tuple[str, str], Path]:
    result: dict[tuple[str, str], Path] = {}
    for spec in specs:
        identity, separator, raw_path = spec.partition("=")
        parts = identity.split(":", 1)
        if (
            separator != "="
            or len(parts) != 2
            or not parts[0]
            or not parts[1]
            or not raw_path
        ):
            raise ValidationFailure(f"{label} must use role:name=path")
        key = (parts[0], parts[1])
        if key in result:
            raise ValidationFailure(f"duplicate {label} identity: {key}")
        path = Path(raw_path).expanduser().resolve()
        if not path.is_file() or path.is_symlink():
            raise ValidationFailure(f"missing {label}: {key}")
        result[key] = path
    return result


def validate_private_specs(specs: Sequence[str], label: str) -> list[str]:
    paths = parse_bound_path_specs(specs, label)
    return [
        f"{role}:{name}={validate_private_file(path, label)}"
        for (role, name), path in sorted(paths.items())
    ]


def source_record_count(path: Path) -> int:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return len(parse_rows(read_snapshot(path, path.name)[0], path.name))
    if isinstance(value, list):
        return len(value)
    if isinstance(value, dict):
        for field in ("rows", "records", "families", "items"):
            if isinstance(value.get(field), list):
                return len(value[field])
        return 1
    raise ValidationFailure(f"{path.name}: leakage source must contain JSON records")


def validate_leakage_inventory(
    inventory_path: Path,
    sources: Sequence[v2.LeakageSource],
    source_receipt_specs: Sequence[str],
    expected_head: str,
) -> tuple[dict[str, Any], dict[tuple[str, str], Path]]:
    inventory = parse_object(
        read_snapshot(inventory_path, "leakage inventory")[0],
        "leakage inventory",
    )
    required = {
        "schema_version",
        "status",
        "inventory_id",
        "producing_git_head",
        "operator_attested_exhaustive",
        "candidate_model_output_seen",
        "assurance_scope",
        "sources",
    }
    if (
        set(inventory) != required
        or inventory.get("schema_version") != LEAKAGE_INVENTORY_SCHEMA
        or inventory.get("status") != "exhaustive_source_inventory_operator_attested"
        or not is_safe_id(inventory.get("inventory_id"))
        or inventory.get("operator_attested_exhaustive") is not True
        or inventory.get("candidate_model_output_seen") is not False
        or inventory.get("assurance_scope") != ASSURANCE_SCOPE
    ):
        raise ValidationFailure("leakage inventory is invalid")
    producing_head = inventory.get("producing_git_head")
    if not isinstance(producing_head, str):
        raise ValidationFailure("leakage inventory producing commit is missing")
    require_git_ancestor(producing_head, expected_head, "leakage inventory")
    receipt_paths = parse_bound_path_specs(source_receipt_specs, "source receipt")
    source_map = {(source.role, source.name): source for source in sources}
    if set(receipt_paths) != set(source_map):
        raise ValidationFailure("source receipt inventory differs from leakage sources")
    entries = inventory.get("sources")
    if not isinstance(entries, list) or len(entries) != len(source_map):
        raise ValidationFailure("leakage inventory source count differs")
    observed: dict[tuple[str, str], dict[str, Any]] = {}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {
            "role",
            "name",
            "sha256",
            "record_count",
            "producer_receipt_sha256",
        }:
            raise ValidationFailure("leakage inventory entry schema changed")
        key = (entry.get("role"), entry.get("name"))
        if key in observed or key not in source_map:
            raise ValidationFailure("leakage inventory has duplicate or unknown source")
        source = source_map[key]
        receipt_path = receipt_paths[key]
        receipt = parse_object(
            read_snapshot(receipt_path, "source receipt")[0], "source receipt"
        )
        if set(receipt) != {
            "schema_version",
            "status",
            "role",
            "name",
            "source_sha256",
            "record_count",
            "producing_git_head",
            "producer_id",
            "operator_attested_exhaustive",
            "candidate_model_output_seen",
            "assurance_scope",
        }:
            raise ValidationFailure(f"{key}: source receipt schema changed")
        receipt_head = receipt.get("producing_git_head")
        if not isinstance(receipt_head, str):
            raise ValidationFailure(f"{key}: source receipt producing commit is missing")
        require_git_ancestor(receipt_head, expected_head, f"{key} source receipt")
        count = source_record_count(source.path)
        expected_receipt = {
            "schema_version": LEAKAGE_SOURCE_RECEIPT_SCHEMA,
            "status": "exhaustive_source_operator_attested",
            "role": source.role,
            "name": source.name,
            "source_sha256": source.sha256,
            "record_count": count,
            "producing_git_head": receipt_head,
            "producer_id": receipt.get("producer_id"),
            "operator_attested_exhaustive": True,
            "candidate_model_output_seen": False,
            "assurance_scope": ASSURANCE_SCOPE,
        }
        if not is_safe_id(receipt.get("producer_id")) or receipt != expected_receipt:
            raise ValidationFailure(f"{key}: source producing receipt is invalid")
        expected_entry = {
            "role": source.role,
            "name": source.name,
            "sha256": source.sha256,
            "record_count": count,
            "producer_receipt_sha256": read_snapshot(
                receipt_path, "source receipt"
            )[1],
        }
        if entry != expected_entry:
            raise ValidationFailure(f"{key}: leakage inventory binding is stale")
        observed[key] = entry
    if set(observed) != set(source_map):
        raise ValidationFailure("leakage inventory coverage is incomplete")
    return inventory, receipt_paths


def validate_blocked_registry_provenance(
    blocked_registry_receipt_path: Path,
    sources: Sequence[v2.LeakageSource],
    expected_head: str,
) -> dict[str, Any]:
    try:
        receipt = v2.validate_blocked_registry_receipt(
            blocked_registry_receipt_path, sources=sources
        )
    except v2.BenchmarkValidationError as error:
        raise ValidationFailure(str(error)) from error
    producing_head = receipt.get("execution_git_head")
    if not isinstance(producing_head, str):
        raise ValidationFailure("blocked-registry receipt producing commit is missing")
    require_git_ancestor(
        producing_head, expected_head, "blocked-registry receipt"
    )
    return receipt


def blocked_registry_dependency_paths(receipt_path: Path) -> list[Path]:
    receipt = parse_object(
        read_snapshot(receipt_path, "blocked-registry receipt")[0],
        "blocked-registry receipt",
    )
    producing_head = receipt.get("execution_git_head")
    contract_binding = receipt.get("contract")
    if (
        not isinstance(producing_head, str)
        or not isinstance(contract_binding, dict)
        or not isinstance(contract_binding.get("path"), str)
    ):
        raise ValidationFailure("blocked-registry dependency contract is missing")
    contract_bytes = git_output(
        "show", f"{producing_head}:{contract_binding['path']}"
    )
    contract = parse_object(
        contract_bytes, "blocked-registry producing contract"
    )
    artifacts = contract.get("expected_validator_artifacts")
    sources = contract.get("sources")
    if not isinstance(artifacts, dict) or not isinstance(sources, list):
        raise ValidationFailure("blocked-registry dependency closure is invalid")
    paths = [receipt_path]
    for name in sorted(artifacts):
        if not isinstance(name, str) or Path(name).name != name:
            raise ValidationFailure("blocked-registry artifact path is invalid")
        paths.append(receipt_path.parent / name)
    for source in sources:
        relative = source.get("path") if isinstance(source, dict) else None
        if not isinstance(relative, str) or Path(relative).is_absolute():
            raise ValidationFailure("blocked-registry source path is invalid")
        path = (REPO_ROOT / relative).resolve()
        try:
            path.relative_to(REPO_ROOT.resolve())
        except ValueError as error:
            raise ValidationFailure(
                "blocked-registry source path escapes the repository"
            ) from error
        paths.append(path)
    return list(dict.fromkeys(paths))


def validate_leakage(
    rows: list[dict[str, Any]],
    benchmark_path: Path,
    source_specs: Sequence[str],
    leakage_receipt_path: Path,
    blocked_registry_receipt_path: Path,
    inventory_path: Path,
    source_receipt_specs: Sequence[str],
    scanner_model_dir: Path,
    expected_head: str,
) -> tuple[list[v2.LeakageSource], dict[tuple[str, str], Path]]:
    leakage_receipt = parse_object(
        read_snapshot(leakage_receipt_path, "leakage receipt")[0],
        "leakage receipt",
    )
    recursively_reject_candidate_output(leakage_receipt, "leakage_receipt")
    try:
        sources = v2.parse_leakage_sources(source_specs)
    except v2.BenchmarkValidationError as error:
        raise ValidationFailure(str(error)) from error
    roles = {source.role for source in sources}
    if roles != set(v2.REQUIRED_FROZEN_LEAKAGE_ROLES):
        raise ValidationFailure(
            f"development leakage roles differ; expected={sorted(v2.REQUIRED_FROZEN_LEAKAGE_ROLES)}, observed={sorted(roles)}"
        )
    _, source_receipt_paths = validate_leakage_inventory(
        inventory_path, sources, source_receipt_specs, expected_head
    )
    validate_blocked_registry_provenance(
        blocked_registry_receipt_path, sources, expected_head
    )
    errors = v2.exact_leakage_errors(rows, sources)
    if errors:
        raise ValidationFailure("; ".join(errors))
    source_paths = {
        (source.role, source.name): source.path for source in sources
    }
    verification_model_dir = (
        scanner_model_dir
        if leakage_receipt.get("backend") == "production"
        else None
    )
    try:
        leakage_scanner.verify_receipt(
            leakage_receipt_path,
            contract_path=LEAKAGE_SCANNER_CONTRACT_PATH,
            benchmark_path=benchmark_path,
            sources=source_paths,
            inventory_path=inventory_path,
            source_receipt_paths=source_receipt_paths,
            blocked_registry_receipt_path=blocked_registry_receipt_path,
            expected_head=expected_head,
            model_dir=verification_model_dir,
        )
    except ValueError as error:
        raise ValidationFailure(str(error)) from error
    return sources, source_receipt_paths


def merge_bundle(
    *,
    contract: dict[str, Any],
    allocation_receipt_path: Path,
    shared_brief_receipt_path: Path,
    launch_receipt_path: Path,
    roster_path: Path,
    completed_corpus_path: Path,
    native_review_seal_path: Path,
    contrast_comparability_seal_path: Path,
    leakage_receipt_path: Path,
    blocked_registry_receipt_path: Path,
    leakage_inventory_path: Path,
    leakage_source_specs: Sequence[str],
    source_receipt_specs: Sequence[str],
    scanner_model_dir: Path,
    output: Path,
    execution_git_head: str,
    pre_receipt_check: Callable[[], None] | None = None,
) -> dict[str, Any]:
    try:
        prescanned_sources = v2.parse_leakage_sources(leakage_source_specs)
    except v2.BenchmarkValidationError as error:
        raise ValidationFailure(str(error)) from error
    prescanned_source_receipts = parse_bound_path_specs(
        source_receipt_specs, "source receipt"
    )
    blocked_dependency_paths = blocked_registry_dependency_paths(
        blocked_registry_receipt_path
    )
    initial_input_paths = [
        *[allocation_receipt_path.parent / name for name in ALLOCATION_ARTIFACTS],
        *[
            shared_brief_receipt_path.parent / name
            for name in SHARED_BRIEF_ARTIFACTS
        ],
        *[launch_receipt_path.parent / name for name in LAUNCH_ARTIFACTS],
        roster_path,
        completed_corpus_path,
        native_review_seal_path,
        contrast_comparability_seal_path,
        leakage_receipt_path,
        *blocked_dependency_paths,
        leakage_inventory_path,
        *(source.path for source in prescanned_sources),
        *prescanned_source_receipts.values(),
        *CONTROL_PATHS,
    ]
    _, input_digests = snapshot_paths(initial_input_paths)
    for source in prescanned_sources:
        if input_digests[source.path] != source.sha256:
            raise ValidationFailure("leakage source changed during initial snapshot")
    allocation, _, _, sealed_contract = authenticate_allocation(
        allocation_receipt_path, contract, execution_git_head
    )
    brief_concepts, _, _ = authenticate_shared_brief_bundle(
        shared_brief_receipt_path,
        allocation_receipt_path,
        allocation,
        roster_path,
        sealed_contract,
        execution_git_head,
    )
    assignments, _, _ = authenticate_launch(
        launch_receipt_path,
        allocation_receipt_path,
        shared_brief_receipt_path,
        roster_path,
        allocation,
        sealed_contract,
        execution_git_head,
    )
    roster = parse_object(
        read_snapshot(roster_path, "private roster")[0], "private roster"
    )
    participants = validate_roster(roster, sealed_contract)
    corpus_bytes, corpus_sha = read_snapshot(completed_corpus_path, "completed corpus")
    rows = parse_rows(corpus_bytes, "completed corpus")
    validate_development_rows(rows, allocation, assignments)
    native_seal_bytes, native_seal_sha = read_snapshot(
        native_review_seal_path, "native-review seal"
    )
    native_seal = parse_object(native_seal_bytes, "native-review seal")
    allocation_receipt_sha = read_snapshot(allocation_receipt_path, "allocation receipt")[1]
    launch_receipt_sha = read_snapshot(launch_receipt_path, "launch receipt")[1]
    validate_native_review_seal(
        native_seal,
        rows,
        assignments,
        corpus_sha,
        allocation_receipt_sha,
        launch_receipt_sha,
        brief_concepts,
        participants,
    )
    comparability_seal_bytes, comparability_seal_sha = read_snapshot(
        contrast_comparability_seal_path, "contrast-comparability seal"
    )
    comparability_seal = parse_object(
        comparability_seal_bytes, "contrast-comparability seal"
    )
    comparability_clusters = validate_contrast_comparability_seal(
        comparability_seal,
        rows,
        allocation,
        assignments,
        participants,
        corpus_sha,
        allocation_receipt_sha,
        launch_receipt_sha,
    )
    sources, source_receipt_paths = validate_leakage(
        rows,
        completed_corpus_path,
        leakage_source_specs,
        leakage_receipt_path,
        blocked_registry_receipt_path,
        leakage_inventory_path,
        source_receipt_specs,
        scanner_model_dir,
        execution_git_head,
    )
    leakage_receipt_sha = read_snapshot(leakage_receipt_path, "leakage receipt")[1]
    blocked_registry_receipt_sha = read_snapshot(
        blocked_registry_receipt_path, "blocked registry receipt"
    )[1]
    leakage_inventory_sha = read_snapshot(
        leakage_inventory_path, "leakage inventory"
    )[1]

    _, control_digests = snapshot_paths(CONTROL_PATHS)
    if {
        (source.role, source.name, source.sha256) for source in sources
    } != {
        (source.role, source.name, source.sha256) for source in prescanned_sources
    } or set(source_receipt_paths) != set(prescanned_source_receipts):
        raise ValidationFailure("leakage evidence inventory changed during validation")
    created = False
    try:
        output.mkdir()
        created = True
        corpus_output = output / "development-corpus.jsonl"
        write_exclusive(corpus_output, corpus_bytes)
        manifest = v2.build_manifest(
            rows=rows,
            corpus_path=corpus_output,
            sources=sources,
            receipt_path=leakage_receipt_path,
            blocked_registry_receipt_path=blocked_registry_receipt_path,
            release_profile=False,
        )
        if manifest.get("rating_schema_sha256") != input_digests[RATING_SCHEMA_PATH]:
            raise ValidationFailure(
                "rating schema changed while development manifest was built"
            )
        manifest_bytes = encode_json(manifest)
        write_exclusive(output / "development-corpus.manifest.json", manifest_bytes)
        receipt = {
            "schema_version": MERGE_RECEIPT_SCHEMA,
            "status": "development_evaluation_authorized_operator_attested_nonrelease",
            "execution_git_head": execution_git_head,
            "controls": control_bindings(control_digests),
            "inputs": {
                "allocation_receipt_sha256": allocation_receipt_sha,
                "shared_brief_receipt_sha256": input_digests[
                    shared_brief_receipt_path
                ],
                "shared_brief_registry_sha256": input_digests[
                    shared_brief_receipt_path.parent
                    / "shared-concept-briefs.json"
                ],
                "launch_receipt_sha256": launch_receipt_sha,
                "roster_sha256": input_digests[roster_path],
                "completed_corpus_sha256": corpus_sha,
                "native_review_seal_sha256": native_seal_sha,
                "contrast_comparability_seal_sha256": comparability_seal_sha,
                "leakage_receipt_sha256": leakage_receipt_sha,
                "blocked_registry_receipt_sha256": blocked_registry_receipt_sha,
                "leakage_inventory_sha256": leakage_inventory_sha,
                "source_receipts": [
                    {
                        "role": role,
                        "name": name,
                        "sha256": read_snapshot(path, "source receipt")[1],
                    }
                    for (role, name), path in sorted(source_receipt_paths.items())
                ],
                "leakage_sources": [
                    {"role": source.role, "name": source.name, "sha256": source.sha256}
                    for source in sources
                ],
            },
            "counts": {
                "rows": len(rows),
                "rows_per_language": dict(sorted(Counter(row["language"] for row in rows).items())),
                "native_reviews_approved": len(native_seal["reviews"]),
                "contrast_sets_comparability_approved": 200,
                "pooled_independent_family_clusters": 672,
                "shared_concept_briefs": 32,
                "shared_concept_rows": 160,
                "languages_per_shared_brief": 5,
                "concept_author_identity_clusters": len(
                    {concept["concept_author_id"] for concept in brief_concepts}
                ),
                "concept_reviewer_identity_clusters": len(
                    {concept["concept_reviewer_id"] for concept in brief_concepts}
                ),
                "author_identity_clusters": len(
                    {row["author_id"] for row in assignments}
                ),
                "reviewer_identity_clusters": len(
                    {row["native_reviewer_id"] for row in assignments}
                ),
                "comparability_reviewer_identity_clusters": comparability_clusters[
                    "identity_clusters"
                ],
                "comparability_reviewer_clusters_by_language": comparability_clusters[
                    "clusters_by_language"
                ],
                "comparability_sets_by_language_reviewer": comparability_clusters[
                    "sets_by_language_reviewer"
                ],
            },
            "gates": {
                "exact_800_row_matrix": True,
                "allocation_receipt_authenticated": True,
                "all_32_shared_concept_briefs_authenticated": True,
                "all_160_shared_rows_fidelity_approved": True,
                "private_roster_and_launch_authenticated": True,
                "operator_attested_all_rows_native_authored": True,
                "operator_attested_all_rows_independently_native_reviewed": True,
                "author_reviewer_identity_separation_verified": True,
                "contrast_comparability_independently_approved": True,
                "exhaustive_source_inventory_operator_attested": True,
                "blocked_registry_receipt_authenticated": True,
                "scanner_provenance_authenticated": True,
                "exact_and_fuzzy_leakage_screen_passed": True,
                "candidate_model_output_seen": False,
                "development_evaluation_eligible": True,
                "release_or_frozen_eligible": False,
                "independent_release_custodian_inventory_signature_present": False,
            },
            "artifacts": {
                "development-corpus.jsonl": {
                    "sha256": sha256_bytes(corpus_bytes),
                    "bytes": len(corpus_bytes),
                    "row_count": len(rows),
                    "benchmark_content_sha256": v2.benchmark_content_sha256(rows),
                },
                "development-corpus.manifest.json": {
                    "sha256": sha256_bytes(manifest_bytes),
                    "bytes": len(manifest_bytes),
                    "object_count": 1,
                },
            },
            "privacy": {
                "private_roster_published": False,
                "raw_names_emails_or_contact_details_published": False,
                "candidate_output_published": False,
            },
            "inference_policy": {
                "pooled_metrics_cluster_by": "semantic_family_id",
                "pooled_independent_clusters": 672,
                "per_language_rows_are_family_independent": True,
                "per_language_independent_rows": 160,
                "contrast_metrics_pair_and_cluster_by": "contrast_set_id",
                "contrast_sets": 200,
                "effective_sample_size_cluster_fields": [
                    "semantic_family_id",
                    "concept_author_id",
                    "concept_reviewer_id",
                    "author_id",
                    "native_reviewer_id",
                ],
                "contrast_effective_sample_size_cluster_fields": [
                    "contrast_set_id",
                    "concept_author_id",
                    "concept_reviewer_id",
                    "author_id",
                    "native_reviewer_id",
                    "comparability_reviewer_id",
                ],
            },
            "assurance": {
                "scope": ASSURANCE_SCOPE,
                "cryptographic_human_identity_or_custody_proof": False,
                "upstream_evidence_reopen_required_for_verification": True,
                "release_custody": "blocked_pending_independent_custodian_signature",
            },
            "publication": "exclusive_private_bundle_receipt_last",
        }
        if pre_receipt_check is not None:
            pre_receipt_check()
        if read_snapshot(corpus_output, corpus_output.name)[1] != sha256_bytes(corpus_bytes):
            raise ValidationFailure("development corpus changed before merge receipt")
        if read_snapshot(
            output / "development-corpus.manifest.json",
            "development corpus manifest",
        )[1] != sha256_bytes(manifest_bytes):
            raise ValidationFailure("development manifest changed before merge receipt")
        for path, digest in input_digests.items():
            if read_snapshot(path, path.name)[1] != digest:
                raise ValidationFailure(f"merge input changed during publication: {path.name}")
        write_exclusive(output / "receipt.json", encode_json(receipt))
    except BaseException:
        if created:
            shutil.rmtree(output, ignore_errors=True)
        raise
    return receipt


def authenticate_evaluation_bundle(
    bundle: Path,
    expected_head: str,
    allocation_receipt_path: Path,
    shared_brief_receipt_path: Path,
    launch_receipt_path: Path,
    roster_path: Path,
    native_review_seal_path: Path,
    contrast_comparability_seal_path: Path,
    leakage_receipt_path: Path,
    blocked_registry_receipt_path: Path,
    leakage_inventory_path: Path,
    leakage_source_specs: Sequence[str],
    source_receipt_specs: Sequence[str],
    scanner_model_dir: Path,
) -> dict[str, Any]:
    try:
        prescanned_sources = v2.parse_leakage_sources(leakage_source_specs)
    except v2.BenchmarkValidationError as error:
        raise ValidationFailure(str(error)) from error
    prescanned_source_receipts = parse_bound_path_specs(
        source_receipt_specs, "source receipt"
    )
    blocked_dependency_paths = blocked_registry_dependency_paths(
        blocked_registry_receipt_path
    )
    verification_paths = [
        *[bundle / name for name in MERGE_ARTIFACTS],
        *[allocation_receipt_path.parent / name for name in ALLOCATION_ARTIFACTS],
        *[
            shared_brief_receipt_path.parent / name
            for name in SHARED_BRIEF_ARTIFACTS
        ],
        *[launch_receipt_path.parent / name for name in LAUNCH_ARTIFACTS],
        roster_path,
        native_review_seal_path,
        contrast_comparability_seal_path,
        leakage_receipt_path,
        *blocked_dependency_paths,
        leakage_inventory_path,
        *(source.path for source in prescanned_sources),
        *prescanned_source_receipts.values(),
    ]
    _, verification_digests = snapshot_paths(verification_paths)
    blobs = exact_bundle(bundle / "receipt.json", MERGE_ARTIFACTS, "evaluation")
    receipt = parse_object(blobs["receipt.json"], "evaluation receipt")
    if set(receipt) != {
        "schema_version",
        "status",
        "execution_git_head",
        "controls",
        "inputs",
        "counts",
        "gates",
        "artifacts",
        "privacy",
        "inference_policy",
        "assurance",
        "publication",
    }:
        raise ValidationFailure("evaluation receipt schema changed")
    if (
        receipt.get("schema_version") != MERGE_RECEIPT_SCHEMA
        or receipt.get("status")
        != "development_evaluation_authorized_operator_attested_nonrelease"
    ):
        raise ValidationFailure("evaluation bundle is not authorized")
    merge_contract = validate_control_receipt(receipt, expected_head)
    if receipt.get("gates") != {
        "exact_800_row_matrix": True,
        "allocation_receipt_authenticated": True,
        "all_32_shared_concept_briefs_authenticated": True,
        "all_160_shared_rows_fidelity_approved": True,
        "private_roster_and_launch_authenticated": True,
        "operator_attested_all_rows_native_authored": True,
        "operator_attested_all_rows_independently_native_reviewed": True,
        "author_reviewer_identity_separation_verified": True,
        "contrast_comparability_independently_approved": True,
        "exhaustive_source_inventory_operator_attested": True,
        "blocked_registry_receipt_authenticated": True,
        "scanner_provenance_authenticated": True,
        "exact_and_fuzzy_leakage_screen_passed": True,
        "candidate_model_output_seen": False,
        "development_evaluation_eligible": True,
        "release_or_frozen_eligible": False,
        "independent_release_custodian_inventory_signature_present": False,
    }:
        raise ValidationFailure("evaluation authorization gates changed")
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != set(MERGE_ARTIFACTS[:-1]):
        raise ValidationFailure("evaluation artifact inventory changed")
    for name in MERGE_ARTIFACTS[:-1]:
        meta = artifacts[name]
        if not isinstance(meta, dict) or meta.get("sha256") != sha256_bytes(blobs[name]):
            raise ValidationFailure(f"evaluation artifact hash changed: {name}")
    rows = parse_rows(blobs["development-corpus.jsonl"], "development corpus")
    try:
        v2.validate_rows(rows)
    except v2.BenchmarkValidationError as error:
        raise ValidationFailure(str(error)) from error
    corpus_meta = artifacts["development-corpus.jsonl"]
    validate_full_development_matrix(rows)
    if (
        corpus_meta.get("bytes") != len(blobs["development-corpus.jsonl"])
        or corpus_meta.get("row_count") != 800
        or v2.benchmark_content_sha256(rows)
        != corpus_meta.get("benchmark_content_sha256")
    ):
        raise ValidationFailure("evaluation corpus content binding changed")
    allocation, _, _, allocation_contract = authenticate_allocation(
        allocation_receipt_path, merge_contract, expected_head
    )
    if allocation_contract != merge_contract:
        raise ValidationFailure("evaluation and allocation contracts differ")
    brief_concepts, _, _ = authenticate_shared_brief_bundle(
        shared_brief_receipt_path,
        allocation_receipt_path,
        allocation,
        roster_path,
        allocation_contract,
        expected_head,
    )
    assignments, _, _ = authenticate_launch(
        launch_receipt_path,
        allocation_receipt_path,
        shared_brief_receipt_path,
        roster_path,
        allocation,
        allocation_contract,
        expected_head,
    )
    roster = parse_object(
        read_snapshot(roster_path, "private roster")[0], "private roster"
    )
    participants = validate_roster(roster, allocation_contract)
    validate_development_rows(rows, allocation, assignments)
    corpus_sha = sha256_bytes(blobs["development-corpus.jsonl"])
    allocation_receipt_sha = read_snapshot(
        allocation_receipt_path, "allocation receipt"
    )[1]
    launch_receipt_sha = read_snapshot(launch_receipt_path, "launch receipt")[1]
    native_seal = parse_object(
        read_snapshot(native_review_seal_path, "native-review seal")[0],
        "native-review seal",
    )
    validate_native_review_seal(
        native_seal,
        rows,
        assignments,
        corpus_sha,
        allocation_receipt_sha,
        launch_receipt_sha,
        brief_concepts,
        participants,
    )
    comparability_seal = parse_object(
        read_snapshot(
            contrast_comparability_seal_path, "contrast-comparability seal"
        )[0],
        "contrast-comparability seal",
    )
    comparability_clusters = validate_contrast_comparability_seal(
        comparability_seal,
        rows,
        allocation,
        assignments,
        participants,
        corpus_sha,
        allocation_receipt_sha,
        launch_receipt_sha,
    )
    sources, source_receipt_paths = validate_leakage(
        rows,
        bundle / "development-corpus.jsonl",
        leakage_source_specs,
        leakage_receipt_path,
        blocked_registry_receipt_path,
        leakage_inventory_path,
        source_receipt_specs,
        scanner_model_dir,
        expected_head,
    )
    manifest = parse_object(blobs["development-corpus.manifest.json"], "development manifest")
    try:
        v2._validate_development_corpus_and_manifest(
            bundle / "development-corpus.jsonl",
            bundle / "development-corpus.manifest.json",
        )
    except v2.BenchmarkValidationError as error:
        raise ValidationFailure(str(error)) from error
    inputs = receipt.get("inputs")
    counts = receipt.get("counts")
    privacy = receipt.get("privacy")
    if (
        manifest.get("corpus_source_sha256")
        != sha256_bytes(blobs["development-corpus.jsonl"])
        or manifest.get("benchmark_content_sha256")
        != v2.benchmark_content_sha256(rows)
        or not isinstance(inputs, dict)
        or inputs.get("leakage_receipt_sha256")
        != manifest.get("leakage_receipt_sha256")
        or inputs.get("blocked_registry_receipt_sha256")
        != manifest.get("blocked_registry_receipt_sha256")
        or inputs.get("leakage_sources") != manifest.get("leakage_sources")
        or inputs.get("allocation_receipt_sha256") != allocation_receipt_sha
        or inputs.get("shared_brief_receipt_sha256")
        != read_snapshot(shared_brief_receipt_path, "shared brief receipt")[1]
        or inputs.get("shared_brief_registry_sha256")
        != read_snapshot(
            shared_brief_receipt_path.parent / "shared-concept-briefs.json",
            "shared brief registry",
        )[1]
        or inputs.get("launch_receipt_sha256") != launch_receipt_sha
        or inputs.get("roster_sha256")
        != read_snapshot(roster_path, "private roster")[1]
        or inputs.get("completed_corpus_sha256") != corpus_sha
        or inputs.get("native_review_seal_sha256")
        != read_snapshot(native_review_seal_path, "native-review seal")[1]
        or inputs.get("contrast_comparability_seal_sha256")
        != read_snapshot(
            contrast_comparability_seal_path, "contrast-comparability seal"
        )[1]
        or inputs.get("leakage_receipt_sha256")
        != read_snapshot(leakage_receipt_path, "leakage receipt")[1]
        or inputs.get("blocked_registry_receipt_sha256")
        != read_snapshot(
            blocked_registry_receipt_path, "blocked registry receipt"
        )[1]
        or inputs.get("leakage_inventory_sha256")
        != read_snapshot(leakage_inventory_path, "leakage inventory")[1]
        or inputs.get("source_receipts")
        != [
            {
                "role": role,
                "name": name,
                "sha256": read_snapshot(path, "source receipt")[1],
            }
            for (role, name), path in sorted(source_receipt_paths.items())
        ]
        or inputs.get("leakage_sources")
        != [
            {"role": source.role, "name": source.name, "sha256": source.sha256}
            for source in sources
        ]
        or not isinstance(counts, dict)
        or counts.get("rows") != 800
        or counts.get("rows_per_language")
        != {language: 160 for language in v2.LANGUAGES}
        or counts.get("native_reviews_approved") != 800
        or counts.get("contrast_sets_comparability_approved") != 200
        or counts.get("pooled_independent_family_clusters") != 672
        or counts.get("shared_concept_briefs") != 32
        or counts.get("shared_concept_rows") != 160
        or counts.get("languages_per_shared_brief") != 5
        or counts.get("concept_author_identity_clusters")
        != len({concept["concept_author_id"] for concept in brief_concepts})
        or counts.get("concept_reviewer_identity_clusters")
        != len({concept["concept_reviewer_id"] for concept in brief_concepts})
        or counts.get("author_identity_clusters")
        != len({row["author_id"] for row in assignments})
        or counts.get("reviewer_identity_clusters")
        != len({row["native_reviewer_id"] for row in assignments})
        or counts.get("comparability_reviewer_identity_clusters")
        != comparability_clusters["identity_clusters"]
        or counts.get("comparability_reviewer_clusters_by_language")
        != comparability_clusters["clusters_by_language"]
        or counts.get("comparability_sets_by_language_reviewer")
        != comparability_clusters["sets_by_language_reviewer"]
        or privacy
        != {
            "private_roster_published": False,
            "raw_names_emails_or_contact_details_published": False,
            "candidate_output_published": False,
        }
        or receipt.get("publication")
        != "exclusive_private_bundle_receipt_last"
        or receipt.get("inference_policy")
        != {
            "pooled_metrics_cluster_by": "semantic_family_id",
            "pooled_independent_clusters": 672,
            "per_language_rows_are_family_independent": True,
            "per_language_independent_rows": 160,
            "contrast_metrics_pair_and_cluster_by": "contrast_set_id",
            "contrast_sets": 200,
            "effective_sample_size_cluster_fields": [
                "semantic_family_id",
                "concept_author_id",
                "concept_reviewer_id",
                "author_id",
                "native_reviewer_id",
            ],
            "contrast_effective_sample_size_cluster_fields": [
                "contrast_set_id",
                "concept_author_id",
                "concept_reviewer_id",
                "author_id",
                "native_reviewer_id",
                "comparability_reviewer_id",
            ],
        }
        or receipt.get("assurance")
        != {
            "scope": ASSURANCE_SCOPE,
            "cryptographic_human_identity_or_custody_proof": False,
            "upstream_evidence_reopen_required_for_verification": True,
            "release_custody": "blocked_pending_independent_custodian_signature",
        }
    ):
        raise ValidationFailure("evaluation manifest is not bound to the corpus")
    for path, digest in verification_digests.items():
        if read_snapshot(path, path.name)[1] != digest:
            raise ValidationFailure(
                f"evaluation evidence changed during verification: {path.name}"
            )
    return receipt


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    allocate = subparsers.add_parser("allocate", help="seal 800 metadata-only slots and balanced packets")
    allocate.add_argument("--expected-git-head", required=True)
    allocate.add_argument("--out-bundle", required=True, type=Path)

    seal_briefs = subparsers.add_parser(
        "seal-briefs", help="seal the 32 reviewed private shared-concept briefs"
    )
    seal_briefs.add_argument("--allocation-receipt", required=True, type=Path)
    seal_briefs.add_argument("--private-completion", required=True, type=Path)
    seal_briefs.add_argument("--roster", required=True, type=Path)
    seal_briefs.add_argument("--expected-git-head", required=True)
    seal_briefs.add_argument("--out-bundle", required=True, type=Path)

    launch = subparsers.add_parser("launch", help="bind a private native roster to author/reviewer packets")
    launch.add_argument("--allocation-receipt", required=True, type=Path)
    launch.add_argument("--shared-brief-receipt", required=True, type=Path)
    launch.add_argument("--roster", required=True, type=Path)
    launch.add_argument("--expected-git-head", required=True)
    launch.add_argument("--out-bundle", required=True, type=Path)

    merge = subparsers.add_parser("merge", help="seal the reviewed, leakage-clean development corpus")
    merge.add_argument("--allocation-receipt", required=True, type=Path)
    merge.add_argument("--shared-brief-receipt", required=True, type=Path)
    merge.add_argument("--launch-receipt", required=True, type=Path)
    merge.add_argument("--roster", required=True, type=Path)
    merge.add_argument("--completed-corpus", required=True, type=Path)
    merge.add_argument("--native-review-seal", required=True, type=Path)
    merge.add_argument("--contrast-comparability-seal", required=True, type=Path)
    merge.add_argument("--leakage-receipt", required=True, type=Path)
    merge.add_argument("--blocked-registry-receipt", required=True, type=Path)
    merge.add_argument("--leakage-inventory", required=True, type=Path)
    merge.add_argument("--leakage-source", action="append", required=True)
    merge.add_argument("--source-receipt", action="append", required=True)
    merge.add_argument("--scanner-model-dir", required=True, type=Path)
    merge.add_argument("--expected-git-head", required=True)
    merge.add_argument("--out-bundle", required=True, type=Path)

    verify = subparsers.add_parser("verify-eval", help="authenticate an evaluation-authorized bundle")
    verify.add_argument("--bundle", required=True, type=Path)
    verify.add_argument("--allocation-receipt", required=True, type=Path)
    verify.add_argument("--shared-brief-receipt", required=True, type=Path)
    verify.add_argument("--launch-receipt", required=True, type=Path)
    verify.add_argument("--roster", required=True, type=Path)
    verify.add_argument("--native-review-seal", required=True, type=Path)
    verify.add_argument("--contrast-comparability-seal", required=True, type=Path)
    verify.add_argument("--leakage-receipt", required=True, type=Path)
    verify.add_argument("--blocked-registry-receipt", required=True, type=Path)
    verify.add_argument("--leakage-inventory", required=True, type=Path)
    verify.add_argument("--leakage-source", action="append", required=True)
    verify.add_argument("--source-receipt", action="append", required=True)
    verify.add_argument("--scanner-model-dir", required=True, type=Path)
    verify.add_argument("--expected-git-head", required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        expected_head = validate_git_state(args.expected_git_head)
        contract_bytes, _ = read_snapshot(CONTRACT_PATH, "development authoring contract")
        contract = parse_object(contract_bytes, "development authoring contract")
        validate_contract(contract)
        if args.command == "allocate":
            output = validate_output_bundle(args.out_bundle)
            receipt = allocate_bundle(
                contract=contract,
                output=output,
                execution_git_head=expected_head,
                pre_receipt_check=lambda: validate_git_state(expected_head),
            )
        elif args.command == "seal-briefs":
            allocation_receipt = validate_private_file(
                args.allocation_receipt, "allocation receipt"
            )
            private_completion = validate_private_file(
                args.private_completion, "private shared brief completion"
            )
            roster = validate_private_file(args.roster, "private roster")
            output = validate_output_bundle(args.out_bundle)
            receipt = seal_shared_brief_bundle(
                contract=contract,
                allocation_receipt_path=allocation_receipt,
                private_completion_path=private_completion,
                roster_path=roster,
                output=output,
                execution_git_head=expected_head,
                pre_receipt_check=lambda: validate_git_state(expected_head),
            )
        elif args.command == "launch":
            allocation_receipt = validate_private_file(args.allocation_receipt, "allocation receipt")
            shared_brief_receipt = validate_private_file(
                args.shared_brief_receipt, "shared brief receipt"
            )
            roster = validate_private_file(args.roster, "private roster")
            output = validate_output_bundle(args.out_bundle)
            receipt = launch_bundle(
                contract=contract,
                allocation_receipt_path=allocation_receipt,
                shared_brief_receipt_path=shared_brief_receipt,
                roster_path=roster,
                output=output,
                execution_git_head=expected_head,
                pre_receipt_check=lambda: validate_git_state(expected_head),
            )
        elif args.command == "merge":
            allocation_receipt = validate_private_file(args.allocation_receipt, "allocation receipt")
            shared_brief_receipt = validate_private_file(
                args.shared_brief_receipt, "shared brief receipt"
            )
            launch_receipt = validate_private_file(args.launch_receipt, "launch receipt")
            roster = validate_private_file(args.roster, "private roster")
            completed = validate_private_file(args.completed_corpus, "completed corpus")
            native_seal = validate_private_file(args.native_review_seal, "native-review seal")
            comparability_seal = validate_private_file(
                args.contrast_comparability_seal, "contrast-comparability seal"
            )
            leakage_receipt = validate_private_file(args.leakage_receipt, "leakage receipt")
            blocked_registry_receipt = validate_private_file(
                args.blocked_registry_receipt, "blocked-registry receipt"
            )
            leakage_inventory = validate_private_file(
                args.leakage_inventory, "leakage inventory"
            )
            leakage_sources = validate_private_specs(
                args.leakage_source, "leakage source"
            )
            source_receipts = validate_private_specs(
                args.source_receipt, "source receipt"
            )
            output = validate_output_bundle(args.out_bundle)
            receipt = merge_bundle(
                contract=contract,
                allocation_receipt_path=allocation_receipt,
                shared_brief_receipt_path=shared_brief_receipt,
                launch_receipt_path=launch_receipt,
                roster_path=roster,
                completed_corpus_path=completed,
                native_review_seal_path=native_seal,
                contrast_comparability_seal_path=comparability_seal,
                leakage_receipt_path=leakage_receipt,
                blocked_registry_receipt_path=blocked_registry_receipt,
                leakage_inventory_path=leakage_inventory,
                leakage_source_specs=leakage_sources,
                source_receipt_specs=source_receipts,
                scanner_model_dir=args.scanner_model_dir.expanduser().resolve(),
                output=output,
                execution_git_head=expected_head,
                pre_receipt_check=lambda: validate_git_state(expected_head),
            )
        else:
            receipt = authenticate_evaluation_bundle(
                args.bundle.expanduser().resolve(),
                expected_head,
                validate_private_file(args.allocation_receipt, "allocation receipt"),
                validate_private_file(
                    args.shared_brief_receipt, "shared brief receipt"
                ),
                validate_private_file(args.launch_receipt, "launch receipt"),
                validate_private_file(args.roster, "private roster"),
                validate_private_file(args.native_review_seal, "native-review seal"),
                validate_private_file(
                    args.contrast_comparability_seal,
                    "contrast-comparability seal",
                ),
                validate_private_file(args.leakage_receipt, "leakage receipt"),
                validate_private_file(
                    args.blocked_registry_receipt, "blocked-registry receipt"
                ),
                validate_private_file(args.leakage_inventory, "leakage inventory"),
                validate_private_specs(args.leakage_source, "leakage source"),
                validate_private_specs(args.source_receipt, "source receipt"),
                args.scanner_model_dir.expanduser().resolve(),
            )
    except ValidationFailure as error:
        print(f"development authoring blocked: {error}", file=os.sys.stderr)
        return 2
    print(json.dumps({"status": receipt["status"], "counts": receipt.get("counts")}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
