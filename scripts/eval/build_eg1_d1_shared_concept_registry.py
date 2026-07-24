#!/usr/bin/env python3
"""Prepare and seal the private D1 shared-concept registry.

``allocate`` publishes only the 80 language-neutral concept slots and their 400
family bindings. It contains no prose, identities, approvals, or model output.

``seal`` accepts a separately completed private file, verifies independent
concept review and family-separation approval, then publishes the exact registry
consumed by the D1 packet, launch, merge, and training-export gates. Both modes
require a clean predeclared Git commit and publish an exclusive bundle with the
receipt written last.
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
from typing import Any, Callable

import build_eg1_multilingual_d1 as d1


SCRIPT_PATH = Path(__file__).resolve()
D1_BUILDER_PATH = Path(d1.__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
DEFAULT_CONTRACT_PATH = SCRIPT_PATH.with_name("eg1_multilingual_d1_contract_v1.json")

ALLOCATION_ROW_SCHEMA = "eg1-d1-shared-concept-allocation-row-v1"
ALLOCATION_RECEIPT_SCHEMA = "eg1-d1-shared-concept-allocation-receipt-v1"
COMPLETION_SCHEMA = "eg1-d1-shared-concept-private-completion-v1"
PRODUCER_BINDING_SCHEMA = "eg1-d1-shared-concept-producer-binding-v1"
SEAL_RECEIPT_SCHEMA = "eg1-d1-shared-concept-seal-receipt-v1"
PUBLICATION = "exclusive_private_bundle_receipt_last"

ALLOCATION_FILENAMES = (
    "shared-concept-slots.jsonl",
    "private-completion-template.json",
    "receipt.json",
)
SEAL_FILENAMES = ("shared-concept-registry.json", "receipt.json")
SAFE_ID = re.compile(r"[a-z0-9][a-z0-9._:-]{2,127}")
SHA256 = re.compile(r"[0-9a-f]{64}")
GIT_SHA = re.compile(r"[0-9a-f]{40}")

COMPLETION_TOP_FIELDS = {
    "schema_version",
    "registry_id",
    "status",
    "approval",
    "concepts",
}
APPROVAL_FIELDS = {
    "approved_for_authoring",
    "approved_by_reference_id",
    "approval_reference_id",
    "approved_at",
}
COMPLETION_CONCEPT_FIELDS = {
    "cross_language_concept_id",
    "brief_id",
    "brief",
    "brief_sha256",
    "concept_author_reference_id",
    "concept_reviewer_reference_id",
    "review_reference_id",
    "reviewed_at",
    "language_neutrality_approved",
    "meaning_safety_approved",
    "family_separation_approved",
    "candidate_model_output_seen",
}
SHAPE_FIELDS = (
    "stratum",
    "behavior",
    "domain",
    "length_bucket",
    "difficulty",
    "safety_risk",
    "item_count",
    "list_type",
    "restraint_type",
)


class ValidationFailure(ValueError):
    """Raised when a shared-concept artifact cannot be trusted."""


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def encode_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def encode_jsonl(rows: list[dict[str, Any]]) -> bytes:
    return b"".join(
        (json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n").encode()
        for row in rows
    )


def read_snapshot(path: Path, label: str) -> tuple[bytes, str]:
    if not path.is_file() or path.is_symlink():
        raise ValidationFailure(f"{label} must be an existing regular file")
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


def parse_jsonl(value: bytes, label: str) -> list[dict[str, Any]]:
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValidationFailure(f"{label} is not valid UTF-8 JSONL") from error
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
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
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return False
    return parsed.utcoffset() is not None and parsed.utcoffset().total_seconds() == 0


def path_for_receipt(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT.resolve()))
    except ValueError:
        return str(resolved)


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
        raise ValidationFailure("cannot verify Git state") from error


def git_committed_bytes(execution_head: str, path: Path) -> bytes | None:
    try:
        relative = path.resolve().relative_to(REPO_ROOT.resolve())
    except ValueError:
        return None
    try:
        return subprocess.run(
            ["git", "show", f"{execution_head}:{relative}"],
            cwd=REPO_ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None


def validate_historical_control(
    *, execution_head: str, record: Any, expected_path: Path, label: str
) -> None:
    if not isinstance(record, dict) or set(record) != {"path", "sha256"}:
        raise ValidationFailure(f"allocation {label} binding schema changed")
    if record.get("path") != path_for_receipt(expected_path):
        raise ValidationFailure(f"allocation {label} path changed")
    expected_sha = record.get("sha256")
    if not isinstance(expected_sha, str) or SHA256.fullmatch(expected_sha) is None:
        raise ValidationFailure(f"allocation {label} hash is invalid")
    committed = git_committed_bytes(execution_head, expected_path)
    if committed is None or sha256_bytes(committed) != expected_sha:
        raise ValidationFailure(f"allocation producing {label} binding is invalid")


def validate_git_state(expected_head: str, tracked_paths: list[Path]) -> str:
    if GIT_SHA.fullmatch(expected_head) is None:
        raise ValidationFailure("expected Git HEAD must be a lowercase 40-character SHA-1")
    actual_head = git_output("rev-parse", "HEAD").decode().strip()
    if actual_head != expected_head:
        raise ValidationFailure("Git HEAD differs from the predeclared commit")
    if git_output("status", "--porcelain", "--untracked-files=no"):
        raise ValidationFailure("tracked worktree must be clean before publication")
    for path in tracked_paths:
        try:
            relative = path.resolve().relative_to(REPO_ROOT.resolve())
        except ValueError as error:
            raise ValidationFailure("tracked producer input is outside the repository") from error
        committed = git_output("show", f"{actual_head}:{relative}")
        live, _ = read_snapshot(path, str(relative))
        if committed != live:
            raise ValidationFailure(f"committed bytes differ from live file: {relative}")
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
    return resolved


def build_concept_slots(
    contract: dict[str, Any], slots: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    languages = contract.get("languages")
    if languages != ["en", "de", "fr", "es", "ru"]:
        raise ValidationFailure("shared-concept allocation requires EN/DE/FR/ES/RU")
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for slot in slots:
        concept_id = slot.get("cross_language_concept_id")
        if slot.get("origin_mode") == "shared_concept_independent_rewrite":
            if not isinstance(concept_id, str) or not concept_id:
                raise ValidationFailure("shared-concept slot lacks a concept ID")
            grouped[concept_id].append(slot)
        elif concept_id is not None:
            raise ValidationFailure("native-original slot carries a shared-concept ID")

    if len(grouped) != 80:
        raise ValidationFailure(f"expected 80 shared concepts, got {len(grouped)}")

    rows: list[dict[str, Any]] = []
    for concept_id in sorted(grouped):
        concept_slots = grouped[concept_id]
        by_language = {str(slot["language"]): slot for slot in concept_slots}
        if len(concept_slots) != 5 or set(by_language) != set(languages):
            raise ValidationFailure(f"{concept_id}: must bind exactly one family per language")
        reference = concept_slots[0]
        for field in SHAPE_FIELDS:
            if len({json.dumps(slot[field], sort_keys=True) for slot in concept_slots}) != 1:
                raise ValidationFailure(f"{concept_id}: cross-language {field} differs")
        rows.append(
            {
                "schema_version": ALLOCATION_ROW_SCHEMA,
                "cross_language_concept_id": concept_id,
                "brief_id": f"d1-brief-{concept_id.lower()}",
                "allocated_shape": {
                    field: reference[field] for field in SHAPE_FIELDS
                },
                "family_bindings": [
                    {
                        "language": language,
                        "family_id": by_language[language]["family_id"],
                        "pair_id": by_language[language]["pair_id"],
                    }
                    for language in languages
                ],
                "custody": {
                    "status": "awaiting_private_authorship_and_review",
                    "concept_author_reference_id": None,
                    "concept_reviewer_reference_id": None,
                    "review_reference_id": None,
                    "language_neutrality_approved": False,
                    "meaning_safety_approved": False,
                    "family_separation_approved": False,
                    "candidate_model_output_seen": False,
                },
            }
        )
    return rows


def build_completion_template(concept_rows: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "schema_version": COMPLETION_SCHEMA,
        "registry_id": None,
        "status": "draft",
        "approval": {
            "approved_for_authoring": False,
            "approved_by_reference_id": None,
            "approval_reference_id": None,
            "approved_at": None,
        },
        "concepts": [
            {
                "cross_language_concept_id": row["cross_language_concept_id"],
                "brief_id": row["brief_id"],
                "brief": None,
                "brief_sha256": None,
                "concept_author_reference_id": None,
                "concept_reviewer_reference_id": None,
                "review_reference_id": None,
                "reviewed_at": None,
                "language_neutrality_approved": False,
                "meaning_safety_approved": False,
                "family_separation_approved": False,
                "candidate_model_output_seen": False,
            }
            for row in concept_rows
        ],
    }


def slot_set_sha256(slots: list[dict[str, Any]]) -> str:
    return d1.canonical_json_sha256(
        [
            {
                "family_id": slot["family_id"],
                **{field: slot[field] for field in d1.SLOT_FIELDS},
            }
            for slot in slots
        ]
    )


def build_allocation_artifacts(
    *,
    contract_path: Path,
    contract_bytes: bytes,
    contract_sha256: str,
    d1_builder_sha256: str,
    producer_sha256: str,
    execution_git_head: str,
) -> tuple[dict[str, bytes], dict[str, Any]]:
    contract = parse_object(contract_bytes, "D1 contract")
    slots = d1.build_slots(contract)
    plan_errors = d1.verify_plan(contract, slots)
    if plan_errors:
        raise ValidationFailure("; ".join(plan_errors))
    concept_rows = build_concept_slots(contract, slots)
    template = build_completion_template(concept_rows)
    artifact_bytes = {
        "shared-concept-slots.jsonl": encode_jsonl(concept_rows),
        "private-completion-template.json": encode_json(template),
    }
    language_rows = Counter(
        binding["language"]
        for row in concept_rows
        for binding in row["family_bindings"]
    )
    stratum_concepts = Counter(row["allocated_shape"]["stratum"] for row in concept_rows)
    payload = {
        "schema_version": ALLOCATION_RECEIPT_SCHEMA,
        "status": "allocation_ready_private_briefs_unwritten",
        "execution_git_head": execution_git_head,
        "contract": {
            "path": path_for_receipt(contract_path),
            "sha256": contract_sha256,
        },
        "d1_builder": {
            "path": path_for_receipt(D1_BUILDER_PATH),
            "sha256": d1_builder_sha256,
        },
        "producer": {
            "path": path_for_receipt(SCRIPT_PATH),
            "sha256": producer_sha256,
        },
        "allocation": {
            "total_d1_rows": len(slots),
            "native_original_rows": sum(
                slot["origin_mode"] == "native_original" for slot in slots
            ),
            "shared_concept_rows": sum(
                slot["origin_mode"] == "shared_concept_independent_rewrite"
                for slot in slots
            ),
            "shared_concepts": len(concept_rows),
            "language_rows": dict(sorted(language_rows.items())),
            "stratum_concepts": dict(sorted(stratum_concepts.items())),
            "slot_set_sha256": slot_set_sha256(slots),
        },
        "artifacts": {
            name: {
                "sha256": sha256_bytes(value),
                "row_count": len(concept_rows) if name.endswith(".jsonl") else 80,
            }
            for name, value in artifact_bytes.items()
        },
        "gates": {
            "private_briefs_present": False,
            "private_identities_present": False,
            "native_approvals_present": False,
            "candidate_model_output_seen": False,
            "training_eligible": False,
            "release_eligible": False,
        },
        "publication": PUBLICATION,
    }
    receipt = {**payload, "receipt_payload_sha256": d1.canonical_json_sha256(payload)}
    return artifact_bytes, receipt


def validate_allocation_bundle(
    *, contract_path: Path, allocation_bundle: Path
) -> tuple[
    dict[str, Any],
    list[dict[str, Any]],
    dict[str, tuple[bytes, str]],
]:
    if not allocation_bundle.is_dir() or allocation_bundle.is_symlink():
        raise ValidationFailure("allocation bundle must be an existing regular directory")
    members = {path.name for path in allocation_bundle.iterdir()}
    if members != set(ALLOCATION_FILENAMES):
        raise ValidationFailure("allocation bundle membership differs from the sealed contract")
    snapshots = {
        name: read_snapshot(allocation_bundle / name, f"allocation {name}")
        for name in ALLOCATION_FILENAMES
    }
    receipt = parse_object(snapshots["receipt.json"][0], "allocation receipt")
    if set(receipt) != {
        "schema_version",
        "status",
        "execution_git_head",
        "contract",
        "d1_builder",
        "producer",
        "allocation",
        "artifacts",
        "gates",
        "publication",
        "receipt_payload_sha256",
    }:
        raise ValidationFailure("allocation receipt schema changed")
    if (
        receipt.get("schema_version") != ALLOCATION_RECEIPT_SCHEMA
        or receipt.get("status") != "allocation_ready_private_briefs_unwritten"
        or receipt.get("publication") != PUBLICATION
    ):
        raise ValidationFailure("allocation receipt status changed")
    payload = dict(receipt)
    payload_sha = payload.pop("receipt_payload_sha256", None)
    if payload_sha != d1.canonical_json_sha256(payload):
        raise ValidationFailure("allocation receipt payload binding is invalid")
    execution_head = receipt.get("execution_git_head")
    if not isinstance(execution_head, str) or GIT_SHA.fullmatch(execution_head) is None:
        raise ValidationFailure("allocation receipt has no valid producing commit")
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", execution_head, "HEAD"],
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if ancestor.returncode != 0:
        raise ValidationFailure("allocation producing commit is not in current history")
    validate_historical_control(
        execution_head=execution_head,
        record=receipt.get("contract"),
        expected_path=contract_path,
        label="contract",
    )
    validate_historical_control(
        execution_head=execution_head,
        record=receipt.get("d1_builder"),
        expected_path=D1_BUILDER_PATH,
        label="D1 builder",
    )
    validate_historical_control(
        execution_head=execution_head,
        record=receipt.get("producer"),
        expected_path=SCRIPT_PATH,
        label="producer",
    )
    contract_bytes, contract_sha = read_snapshot(contract_path, "D1 contract")
    if receipt["contract"]["sha256"] != contract_sha:
        raise ValidationFailure("D1 contract changed after shared-concept allocation")
    contract = parse_object(contract_bytes, "D1 contract")
    slots = d1.build_slots(contract)
    plan_errors = d1.verify_plan(contract, slots)
    if plan_errors:
        raise ValidationFailure("; ".join(plan_errors))
    expected_concepts = build_concept_slots(contract, slots)
    expected_artifacts = {
        "shared-concept-slots.jsonl": encode_jsonl(expected_concepts),
        "private-completion-template.json": encode_json(
            build_completion_template(expected_concepts)
        ),
    }
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != set(expected_artifacts):
        raise ValidationFailure("allocation artifact receipt schema changed")
    for name, expected_bytes in expected_artifacts.items():
        if snapshots[name][0] != expected_bytes:
            raise ValidationFailure(f"allocation artifact changed: {name}")
        expected_record = {
            "sha256": snapshots[name][1],
            "row_count": 80,
        }
        if artifacts.get(name) != expected_record:
            raise ValidationFailure(f"allocation artifact binding changed: {name}")
    language_rows = Counter(
        binding["language"]
        for row in expected_concepts
        for binding in row["family_bindings"]
    )
    stratum_concepts = Counter(
        row["allocated_shape"]["stratum"] for row in expected_concepts
    )
    if receipt.get("allocation") != {
        "total_d1_rows": 2000,
        "native_original_rows": 1600,
        "shared_concept_rows": 400,
        "shared_concepts": 80,
        "language_rows": dict(sorted(language_rows.items())),
        "stratum_concepts": dict(sorted(stratum_concepts.items())),
        "slot_set_sha256": slot_set_sha256(slots),
    }:
        raise ValidationFailure("current D1 slot identity differs from allocation")
    if receipt.get("gates") != {
        "private_briefs_present": False,
        "private_identities_present": False,
        "native_approvals_present": False,
        "candidate_model_output_seen": False,
        "training_eligible": False,
        "release_eligible": False,
    }:
        raise ValidationFailure("allocation blocked gates changed")
    concept_rows = parse_jsonl(
        snapshots["shared-concept-slots.jsonl"][0], "shared-concept slots"
    )
    return receipt, concept_rows, snapshots


def validate_completion(
    completion: dict[str, Any], concept_rows: list[dict[str, Any]]
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if set(completion) != COMPLETION_TOP_FIELDS:
        raise ValidationFailure("private completion top-level schema changed")
    if completion.get("schema_version") != COMPLETION_SCHEMA:
        raise ValidationFailure("private completion schema is unsupported")
    if completion.get("status") != "approved_for_sealing":
        raise ValidationFailure("private completion is not approved for sealing")
    registry_id = completion.get("registry_id")
    if not is_safe_id(registry_id):
        raise ValidationFailure("private completion registry_id must be an opaque safe ID")
    approval = completion.get("approval")
    if not isinstance(approval, dict) or set(approval) != APPROVAL_FIELDS:
        raise ValidationFailure("private completion approval schema changed")
    if approval.get("approved_for_authoring") is not True:
        raise ValidationFailure("private completion is not approved for authoring")
    for field in ("approved_by_reference_id", "approval_reference_id"):
        if not is_safe_id(approval.get(field)):
            raise ValidationFailure(f"private completion {field} must be an opaque safe ID")
    if not is_utc_timestamp(approval.get("approved_at")):
        raise ValidationFailure("private completion approval timestamp is invalid")
    approval_at = datetime.fromisoformat(
        approval["approved_at"][:-1] + "+00:00"
    )

    concepts = completion.get("concepts")
    if not isinstance(concepts, list):
        raise ValidationFailure("private completion concepts must be a list")
    expected = {row["cross_language_concept_id"]: row for row in concept_rows}
    actual: dict[str, dict[str, Any]] = {}
    brief_hashes: set[str] = set()
    review_reference_ids: set[str] = set()
    validated: list[dict[str, Any]] = []
    for index, concept in enumerate(concepts, 1):
        if not isinstance(concept, dict) or set(concept) != COMPLETION_CONCEPT_FIELDS:
            raise ValidationFailure(f"private concept {index} schema changed")
        concept_id = concept.get("cross_language_concept_id")
        if not isinstance(concept_id, str) or concept_id not in expected:
            raise ValidationFailure(f"private concept {index} is not allocated")
        if concept_id in actual:
            raise ValidationFailure(f"private completion duplicates {concept_id}")
        actual[concept_id] = concept
        if concept.get("brief_id") != expected[concept_id]["brief_id"]:
            raise ValidationFailure(f"{concept_id}: brief ID differs from allocation")
        brief = concept.get("brief")
        if (
            not isinstance(brief, str)
            or not brief.strip()
            or len(brief) > 2000
            or any(ord(character) < 32 and character not in "\n\r\t" for character in brief)
        ):
            raise ValidationFailure(f"{concept_id}: brief is empty or invalid")
        brief_sha = sha256_bytes(brief.encode("utf-8"))
        if concept.get("brief_sha256") != brief_sha:
            raise ValidationFailure(f"{concept_id}: brief hash does not match")
        if brief_sha in brief_hashes:
            raise ValidationFailure(f"{concept_id}: brief duplicates another concept")
        brief_hashes.add(brief_sha)
        for field in (
            "concept_author_reference_id",
            "concept_reviewer_reference_id",
            "review_reference_id",
        ):
            if not is_safe_id(concept.get(field)):
                raise ValidationFailure(f"{concept_id}: {field} must be an opaque safe ID")
        review_reference_id = concept["review_reference_id"]
        if review_reference_id in review_reference_ids:
            raise ValidationFailure(f"{concept_id}: review_reference_id is reused")
        review_reference_ids.add(review_reference_id)
        if concept["concept_author_reference_id"] == concept["concept_reviewer_reference_id"]:
            raise ValidationFailure(f"{concept_id}: concept author and reviewer are identical")
        if not is_utc_timestamp(concept.get("reviewed_at")):
            raise ValidationFailure(f"{concept_id}: review timestamp is invalid")
        reviewed_at = datetime.fromisoformat(
            concept["reviewed_at"][:-1] + "+00:00"
        )
        if reviewed_at > approval_at:
            raise ValidationFailure(f"{concept_id}: review occurs after final approval")
        for field in (
            "language_neutrality_approved",
            "meaning_safety_approved",
            "family_separation_approved",
        ):
            if concept.get(field) is not True:
                raise ValidationFailure(f"{concept_id}: {field} is not approved")
        if concept.get("candidate_model_output_seen") is not False:
            raise ValidationFailure(f"{concept_id}: candidate model output must remain unseen")
        validated.append(concept)

    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    if missing or extra or len(concepts) != 80:
        raise ValidationFailure(
            f"private completion coverage differs; missing={len(missing)}, "
            f"extra={len(extra)}, rows={len(concepts)}"
        )
    return approval, sorted(validated, key=lambda row: row["cross_language_concept_id"])


def build_sealed_registry(
    *,
    completion: dict[str, Any],
    completion_sha256: str,
    concept_rows: list[dict[str, Any]],
    allocation_receipt_sha256: str,
    contract_sha256: str,
    d1_builder_sha256: str,
    producer_sha256: str,
    execution_git_head: str,
    slots: list[dict[str, Any]],
) -> dict[str, Any]:
    approval, concepts = validate_completion(completion, concept_rows)
    payload = {
        "schema_version": d1.SHARED_CONCEPT_SCHEMA,
        "registry_id": completion["registry_id"],
        "status": "sealed",
        "approval": {
            "approved_for_authoring": True,
            "approved_by": approval["approved_by_reference_id"],
            "approval_reference": approval["approval_reference_id"],
        },
        "concepts": [
            {
                "cross_language_concept_id": concept["cross_language_concept_id"],
                "brief_id": concept["brief_id"],
                "brief": concept["brief"],
                "brief_sha256": concept["brief_sha256"],
            }
            for concept in concepts
        ],
    }
    language_rows = Counter(
        binding["language"]
        for row in concept_rows
        for binding in row["family_bindings"]
    )
    producer_binding = {
        "schema_version": PRODUCER_BINDING_SCHEMA,
        "status": "producer_validated_private_completion",
        "execution_git_head": execution_git_head,
        "private_completion_sha256": completion_sha256,
        "allocation_receipt_sha256": allocation_receipt_sha256,
        "contract_sha256": contract_sha256,
        "d1_builder_sha256": d1_builder_sha256,
        "registry_builder_sha256": producer_sha256,
        "slot_set_sha256": slot_set_sha256(slots),
        "registry_payload_sha256": d1.canonical_json_sha256(payload),
        "concept_count": len(concept_rows),
        "shared_row_count": sum(language_rows.values()),
        "language_rows": dict(sorted(language_rows.items())),
        "independent_concept_reviews": len(concepts),
        "language_neutrality_approvals": len(concepts),
        "meaning_safety_approvals": len(concepts),
        "family_separation_approvals": len(concepts),
        "candidate_model_output_seen": False,
        "publication": PUBLICATION,
    }
    return {**payload, "producer_binding": producer_binding}


def build_seal_artifacts(
    *,
    contract_path: Path,
    contract_bytes: bytes,
    contract_sha256: str,
    d1_builder_sha256: str,
    producer_sha256: str,
    execution_git_head: str,
    allocation_receipt: dict[str, Any],
    allocation_receipt_sha256: str,
    concept_rows: list[dict[str, Any]],
    completion: dict[str, Any],
    completion_sha256: str,
) -> tuple[dict[str, bytes], dict[str, Any]]:
    contract = parse_object(contract_bytes, "D1 contract")
    slots = d1.build_slots(contract)
    expected_concepts = build_concept_slots(contract, slots)
    if concept_rows != expected_concepts:
        raise ValidationFailure("allocation concept rows differ from current D1 slots")
    registry = build_sealed_registry(
        completion=completion,
        completion_sha256=completion_sha256,
        concept_rows=concept_rows,
        allocation_receipt_sha256=allocation_receipt_sha256,
        contract_sha256=contract_sha256,
        d1_builder_sha256=d1_builder_sha256,
        producer_sha256=producer_sha256,
        execution_git_head=execution_git_head,
        slots=slots,
    )
    registry_bytes = encode_json(registry)
    artifact_bytes = {"shared-concept-registry.json": registry_bytes}
    payload = {
        "schema_version": SEAL_RECEIPT_SCHEMA,
        "status": "shared_concepts_sealed_authoring_unblocked_training_still_blocked",
        "execution_git_head": execution_git_head,
        "contract": {
            "path": path_for_receipt(contract_path),
            "sha256": contract_sha256,
        },
        "d1_builder": {
            "path": path_for_receipt(D1_BUILDER_PATH),
            "sha256": d1_builder_sha256,
        },
        "producer": {
            "path": path_for_receipt(SCRIPT_PATH),
            "sha256": producer_sha256,
        },
        "inputs": {
            "allocation_receipt_sha256": allocation_receipt_sha256,
            "allocation_execution_git_head": allocation_receipt["execution_git_head"],
            "private_completion_sha256": completion_sha256,
        },
        "counts": {
            "concepts": 80,
            "shared_rows": 400,
            "language_rows": {language: 80 for language in contract["languages"]},
            "independent_concept_reviews": 80,
        },
        "gates": {
            "all_concepts_language_neutrality_approved": True,
            "all_concepts_meaning_safety_approved": True,
            "all_concepts_family_separation_approved": True,
            "all_concept_reviews_independent": True,
            "candidate_model_output_seen": False,
            "native_row_reviews_complete": False,
            "training_eligible": False,
            "release_eligible": False,
        },
        "privacy": {
            "bundle_must_remain_untracked": True,
            "private_completion_published": False,
            "raw_names_emails_or_contact_details_allowed": False,
            "opaque_reference_ids_required": True,
        },
        "artifacts": {
            "shared-concept-registry.json": {
                "sha256": sha256_bytes(registry_bytes),
                "row_count": 80,
            }
        },
        "publication": PUBLICATION,
    }
    receipt = {**payload, "receipt_payload_sha256": d1.canonical_json_sha256(payload)}
    return artifact_bytes, receipt


def write_exclusive(path: Path, value: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(value)
    except BaseException:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        raise


def publish_bundle(
    *,
    output_bundle: Path,
    artifact_bytes: dict[str, bytes],
    receipt: dict[str, Any],
    expected_filenames: tuple[str, ...],
    before_receipt: Callable[[], None],
) -> None:
    if set(artifact_bytes) != set(expected_filenames[:-1]):
        raise ValidationFailure("publication artifact membership changed")
    output_bundle.parent.mkdir(parents=True, exist_ok=True)
    created = False
    try:
        try:
            output_bundle.mkdir(mode=0o700)
        except FileExistsError as error:
            raise ValidationFailure("output bundle already exists") from error
        created = True
        for filename in expected_filenames[:-1]:
            write_exclusive(output_bundle / filename, artifact_bytes[filename])
        before_receipt()
        for filename in expected_filenames[:-1]:
            persisted, _ = read_snapshot(
                output_bundle / filename,
                f"published artifact {filename}",
            )
            if persisted != artifact_bytes[filename]:
                raise ValidationFailure(
                    f"published artifact changed before receipt: {filename}"
                )
        write_exclusive(output_bundle / "receipt.json", encode_json(receipt))
    except BaseException:
        if created:
            shutil.rmtree(output_bundle)
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    allocate = subparsers.add_parser("allocate", help="publish metadata-only concept slots")
    allocate.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT_PATH)
    allocate.add_argument("--out-bundle", required=True, type=Path)
    allocate.add_argument("--expected-git-head", required=True)
    seal = subparsers.add_parser("seal", help="validate a private completion and seal it")
    seal.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT_PATH)
    seal.add_argument("--allocation-bundle", required=True, type=Path)
    seal.add_argument("--private-completion", required=True, type=Path)
    seal.add_argument("--out-bundle", required=True, type=Path)
    seal.add_argument("--expected-git-head", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        contract_path = args.contract.resolve()
        output_bundle = validate_output_bundle(args.out_bundle)
        tracked_paths = [SCRIPT_PATH, D1_BUILDER_PATH, contract_path]
        execution_head = validate_git_state(args.expected_git_head, tracked_paths)
        contract_bytes, contract_sha = read_snapshot(contract_path, "D1 contract")
        _, d1_sha = read_snapshot(D1_BUILDER_PATH, "D1 builder")
        _, producer_sha = read_snapshot(SCRIPT_PATH, "shared-concept producer")
        tracked_snapshots = {
            contract_path: contract_sha,
            D1_BUILDER_PATH: d1_sha,
            SCRIPT_PATH: producer_sha,
        }

        if args.command == "allocate":
            artifacts, receipt = build_allocation_artifacts(
                contract_path=contract_path,
                contract_bytes=contract_bytes,
                contract_sha256=contract_sha,
                d1_builder_sha256=d1_sha,
                producer_sha256=producer_sha,
                execution_git_head=execution_head,
            )
            input_snapshots: dict[Path, str] = {}
            expected_filenames = ALLOCATION_FILENAMES
        else:
            allocation_bundle = validate_private_file(
                args.allocation_bundle / "receipt.json", "allocation receipt"
            ).parent
            allocation_receipt, concept_rows, allocation_snapshots = (
                validate_allocation_bundle(
                    contract_path=contract_path,
                    allocation_bundle=allocation_bundle,
                )
            )
            completion_path = validate_private_file(
                args.private_completion, "private completion"
            )
            completion_bytes, completion_sha = read_snapshot(
                completion_path, "private completion"
            )
            completion = parse_object(completion_bytes, "private completion")
            allocation_receipt_sha = allocation_snapshots["receipt.json"][1]
            artifacts, receipt = build_seal_artifacts(
                contract_path=contract_path,
                contract_bytes=contract_bytes,
                contract_sha256=contract_sha,
                d1_builder_sha256=d1_sha,
                producer_sha256=producer_sha,
                execution_git_head=execution_head,
                allocation_receipt=allocation_receipt,
                allocation_receipt_sha256=allocation_receipt_sha,
                concept_rows=concept_rows,
                completion=completion,
                completion_sha256=completion_sha,
            )
            input_snapshots = {
                completion_path: completion_sha,
                **{
                    allocation_bundle / name: snapshot[1]
                    for name, snapshot in allocation_snapshots.items()
                },
            }
            expected_filenames = SEAL_FILENAMES

        def before_receipt() -> None:
            for path, expected_sha in {**tracked_snapshots, **input_snapshots}.items():
                _, actual_sha = read_snapshot(path, path.name)
                if actual_sha != expected_sha:
                    raise ValidationFailure(f"input changed during publication: {path.name}")
            validate_git_state(args.expected_git_head, tracked_paths)

        publish_bundle(
            output_bundle=output_bundle,
            artifact_bytes=artifacts,
            receipt=receipt,
            expected_filenames=expected_filenames,
            before_receipt=before_receipt,
        )
    except ValidationFailure as error:
        print(f"D1 shared-concept publication blocked: {error}", file=os.sys.stderr)
        return 2
    print(json.dumps(receipt.get("counts", receipt.get("allocation")), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
