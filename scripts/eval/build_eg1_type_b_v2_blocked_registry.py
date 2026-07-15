#!/usr/bin/env python3
"""Seal the metadata-only Type B V2 blocked-family/leakage registry."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from typing import Any
import unicodedata


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
CONTRACT_PATH = (
    REPO_ROOT
    / "scripts/eval/contracts/eg1_type_b_v2_blocked_registry_v1.json"
)
ALLOCATION_CONTRACT_PATH = (
    REPO_ROOT / "scripts/eval/contracts/eg1_type_b_v2_allocation_v1.json"
)
ALLOCATOR_BUILDER_PATH = REPO_ROOT / "scripts/eval/build_eg1_type_b_v2_manifest.py"
CONTRACT_SCHEMA = "eg1-type-b-v2-blocked-registry-contract-v1"
ENTRY_SCHEMA = "eg1-type-b-v2-source-coverage-v1"
FAMILY_SCHEMA = "eg1-type-b-v2-blocked-family-v1"
TEXT_HASH_SCHEMA = "eg1-type-b-v2-blocked-text-hash-v1"
DECISION_SCHEMA = "eg1-type-b-v2-provisional-decision-v1"
NORMALIZATION_POLICY_ID = "nfkc-casefold-alnum-whitespace-v1"
EXPECTED_REGISTRY_ID = "eg1-type-b-v2-blocked-registry-2026-07-15"
EXPECTED_COUNTS = {
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
EXPECTED_ARTIFACT_NAMES = [
    "blocked_family_registry.jsonl",
    "blocked_text_hashes.jsonl",
    "source_coverage.jsonl",
    "provisional_decisions.jsonl",
    "receipt.json",
]
EXPECTED_VALIDATOR_SOURCE_BINDINGS = {
    "blocked_family_registry.jsonl": "blocked_family_registry",
    "blocked_text_hashes.jsonl": "blocked_text_hash_registry",
}
EXPECTED_VALIDATOR_ARTIFACTS = {
    "blocked_family_registry.jsonl": {
        "sha256": "117e54b76051ec9f75a25ecdb9c1b673e64093a1c1f9e31a02de42eaced1a851",
        "row_count": 7198,
        "validator_source_role": "blocked_family_registry",
    },
    "blocked_text_hashes.jsonl": {
        "sha256": "1a4f5f4a45b9d1590ce9a4453023c0a9a18b5976e72adf4a047e8cb5bffdd38e",
        "row_count": 13733,
        "validator_source_role": "blocked_text_hash_registry",
    },
    "source_coverage.jsonl": {
        "sha256": "aa11ac5ab73825fb218e08b574ad86cbfe8e23e7fc65cc40f0f3b32fa002da95",
        "row_count": 11236,
        "validator_source_role": None,
    },
    "provisional_decisions.jsonl": {
        "sha256": "778e220c434a532d997c61caf04bc1cd5e44c08befb45f5c16b7586b760ed5ad",
        "row_count": 23,
        "validator_source_role": None,
    },
}
EXPECTED_CANDIDATE_CLEARANCE_CONTRACT = {
    "provenance_field": "blocked_family_clearances",
    "registry_artifact": "blocked_family_registry.jsonl",
    "registry_binding_field": "registry_sha256",
    "candidate_binding_field": "candidate_semantic_family_id",
    "required_status": "cleared",
    "independent_review_required": True,
}
TOP_LEVEL_FIELDS = {
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
ALLOCATOR_FIELDS = {
    "allocation_contract_path",
    "allocation_contract_sha256",
    "builder_path",
    "builder_sha256",
}
SOURCE_FIELDS = {
    "role",
    "name",
    "path",
    "sha256",
    "row_count",
    "field_presence_counts",
    "id_field",
    "input_field",
    "output_field",
    "family_basis",
    "family_field",
}
DECISION_FIELDS = {
    "source_case_id",
    "decision",
    "reason_code",
    "replacement_reserve_slot_id",
}
ALLOWED_SOURCE_ROLES = {"legacy_benchmark", "prior_benchmark", "training"}
ALLOWED_FAMILY_BASES = {"origin_proxy", "row_proxy_only"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-bundle", required=True, type=Path)
    parser.add_argument("--expected-git-head", required=True)
    return parser.parse_args()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_once(path: Path) -> tuple[bytes, str]:
    value = path.read_bytes()
    return value, sha256_bytes(value)


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
        raise ValueError(f"cannot verify Git state: {' '.join(arguments)}") from error


def validate_git_state(expected_head: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", expected_head):
        raise ValueError("expected Git HEAD must be a lowercase 40-character SHA-1")
    actual_head = git_output("rev-parse", "HEAD").decode().strip()
    if actual_head != expected_head:
        raise ValueError("Git HEAD differs from the predeclared commit")
    if git_output("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("tracked worktree must be clean before registry publication")
    for path in (
        SCRIPT_PATH,
        CONTRACT_PATH,
        ALLOCATION_CONTRACT_PATH,
        ALLOCATOR_BUILDER_PATH,
    ):
        relative = str(path.relative_to(REPO_ROOT))
        committed_bytes = git_output("show", f"{actual_head}:{relative}")
        if sha256_bytes(committed_bytes) != read_once(path)[1]:
            raise ValueError(f"committed bytes differ from live file: {relative}")
    return actual_head


def parse_json_object(value: bytes, label: str) -> dict[str, Any]:
    parsed = json.loads(value)
    if not isinstance(parsed, dict):
        raise ValueError(f"{label} must be an object")
    return parsed


def rows_from_bytes(value: bytes, label: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(value.decode("utf-8").splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        if not isinstance(row, dict):
            raise ValueError(f"{label}:{line_number} is not an object")
        rows.append(row)
    return rows


def normalize_text(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    normalized = "".join(
        character
        if unicodedata.category(character)[0] in {"L", "M", "N"}
        else " "
        for character in normalized
    )
    return " ".join(normalized.split())


def opaque_id(namespace: str, *values: str) -> str:
    digest = sha256_bytes("\0".join((namespace, *values)).encode("utf-8"))
    return f"tb2-{namespace}-{digest}"


def encode_jsonl(rows: list[dict[str, Any]]) -> bytes:
    return b"".join(
        (json.dumps(row, ensure_ascii=True, sort_keys=True) + "\n").encode("utf-8")
        for row in rows
    )


def write_exclusive(path: Path, value: bytes) -> None:
    with path.open("xb") as handle:
        written = handle.write(value)
        if written != len(value):
            raise OSError(f"short write for {path.name}")
        handle.flush()
        os.fsync(handle.fileno())


def validate_contract(
    contract: dict[str, Any],
    allocation_contract: dict[str, Any],
    *,
    allocation_contract_sha: str,
    allocator_builder_sha: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if set(contract) != TOP_LEVEL_FIELDS:
        raise ValueError("blocked registry contract top-level schema changed")
    if contract.get("schema_version") != CONTRACT_SCHEMA:
        raise ValueError("blocked registry contract schema changed")
    if contract.get("status") != "sealed":
        raise ValueError("blocked registry contract is not sealed")
    if contract.get("registry_id") != EXPECTED_REGISTRY_ID:
        raise ValueError("blocked registry ID changed")
    if contract.get("normalization_policy_id") != NORMALIZATION_POLICY_ID:
        raise ValueError("blocked registry normalization policy changed")
    if contract.get("counts") != EXPECTED_COUNTS:
        raise ValueError("blocked registry expected counts changed")
    if contract.get("expected_validator_artifacts") != EXPECTED_VALIDATOR_ARTIFACTS:
        raise ValueError("blocked registry expected validator artifacts changed")
    if (
        contract.get("candidate_clearance_contract")
        != EXPECTED_CANDIDATE_CLEARANCE_CONTRACT
    ):
        raise ValueError("blocked registry candidate clearance contract changed")

    allocator = contract.get("allocator")
    if not isinstance(allocator, dict) or set(allocator) != ALLOCATOR_FIELDS:
        raise ValueError("blocked registry allocator binding schema changed")
    expected_allocator = {
        "allocation_contract_path": str(
            ALLOCATION_CONTRACT_PATH.relative_to(REPO_ROOT)
        ),
        "allocation_contract_sha256": allocation_contract_sha,
        "builder_path": str(ALLOCATOR_BUILDER_PATH.relative_to(REPO_ROOT)),
        "builder_sha256": allocator_builder_sha,
    }
    if allocator != expected_allocator:
        raise ValueError("blocked registry allocator binding changed")

    sources = contract.get("sources")
    if not isinstance(sources, list) or len(sources) != EXPECTED_COUNTS["sources"]:
        raise ValueError("blocked registry source inventory changed")
    seen_names: set[str] = set()
    seen_paths: set[str] = set()
    source_hashes: dict[str, str] = {}
    for index, source in enumerate(sources, 1):
        if not isinstance(source, dict) or set(source) != SOURCE_FIELDS:
            raise ValueError(f"source contract {index} schema changed")
        name = source.get("name")
        path = source.get("path")
        role = source.get("role")
        if not isinstance(name, str) or not name or name in seen_names:
            raise ValueError("source contract names must be unique nonempty strings")
        if not isinstance(path, str) or not path or path in seen_paths:
            raise ValueError("source contract paths must be unique nonempty strings")
        relative_path = Path(path)
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise ValueError(f"source contract {name} path must be repository-relative")
        if role not in ALLOWED_SOURCE_ROLES:
            raise ValueError(f"source contract {name} role is invalid")
        if source.get("family_basis") not in ALLOWED_FAMILY_BASES:
            raise ValueError(f"source contract {name} family basis is invalid")
        field_presence_counts = source.get("field_presence_counts")
        if (
            not isinstance(field_presence_counts, dict)
            or not field_presence_counts
            or any(
                not isinstance(field, str)
                or not field
                or not isinstance(count, int)
                or count <= 0
                for field, count in field_presence_counts.items()
            )
        ):
            raise ValueError(f"source contract {name} field presence is invalid")
        for field_name in ("id_field", "input_field", "output_field"):
            if source.get(field_name) not in field_presence_counts:
                raise ValueError(f"source contract {name} {field_name} is invalid")
        family_field = source.get("family_field")
        if source["family_basis"] == "origin_proxy":
            if family_field not in field_presence_counts:
                raise ValueError(f"source contract {name} family field is invalid")
        elif family_field is not None:
            raise ValueError(f"source contract {name} row proxy cannot name a family field")
        digest = source.get("sha256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError(f"source contract {name} hash is invalid")
        if not isinstance(source.get("row_count"), int) or source["row_count"] <= 0:
            raise ValueError(f"source contract {name} row count is invalid")
        seen_names.add(name)
        seen_paths.add(path)
        source_hashes[path] = digest

    allocation_sources = allocation_contract.get("source_sha256")
    if allocation_sources != source_hashes:
        raise ValueError("registry source inventory differs from allocator source inventory")

    policy = contract.get("decision_policy")
    if not isinstance(policy, dict) or set(policy) != {
        "allowed_decisions",
        "required_reason_code",
        "candidate_model_output_seen",
        "fresh_benchmark_prose_authored",
        "decisions",
    }:
        raise ValueError("decision policy schema changed")
    if policy.get("allowed_decisions") != ["replace"]:
        raise ValueError("decision policy must fail closed to replacement")
    if policy.get("required_reason_code") != "semantic_family_clearance_not_proven":
        raise ValueError("decision policy reason changed")
    if policy.get("candidate_model_output_seen") is not False:
        raise ValueError("candidate output must remain unseen")
    if policy.get("fresh_benchmark_prose_authored") is not False:
        raise ValueError("fresh benchmark prose must remain unauthored")
    decisions = policy.get("decisions")
    if not isinstance(decisions, list):
        raise ValueError("provisional decisions must be a list")
    decision_ids: list[str] = []
    reserve_ids: list[str] = []
    for index, decision in enumerate(decisions, 1):
        if not isinstance(decision, dict) or set(decision) != DECISION_FIELDS:
            raise ValueError(f"provisional decision {index} schema changed")
        case_id = decision.get("source_case_id")
        if not isinstance(case_id, str) or not case_id:
            raise ValueError(f"provisional decision {index} ID is invalid")
        if decision.get("decision") != "replace":
            raise ValueError(f"provisional decision {case_id} is unresolved")
        if decision.get("reason_code") != policy["required_reason_code"]:
            raise ValueError(f"provisional decision {case_id} reason is invalid")
        expected_reserve = f"tb2-reserve-{index:04d}"
        if decision.get("replacement_reserve_slot_id") != expected_reserve:
            raise ValueError(f"provisional decision {case_id} reserve binding is invalid")
        decision_ids.append(case_id)
        reserve_ids.append(expected_reserve)
    if len(decision_ids) != len(set(decision_ids)):
        raise ValueError("provisional decisions contain duplicate case IDs")
    if len(reserve_ids) != len(set(reserve_ids)):
        raise ValueError("provisional decisions contain duplicate reserve IDs")
    provisional_ids = allocation_contract.get("provisional_case_ids")
    if decision_ids != provisional_ids:
        raise ValueError("provisional decision coverage differs from allocator contract")
    if len(decisions) != EXPECTED_COUNTS["provisional_decisions"]:
        raise ValueError("provisional decision count is incomplete")

    publication = contract.get("publication")
    if not isinstance(publication, dict) or publication != {
        "artifact_names": EXPECTED_ARTIFACT_NAMES,
        "validator_source_roles": EXPECTED_VALIDATOR_SOURCE_BINDINGS,
        "exclusive_bundle": True,
        "receipt_last": True,
        "private_text_allowed": False,
    }:
        raise ValueError("blocked registry publication contract changed")
    return sources, decisions


def build_registry(
    sources: list[dict[str, Any]], source_bytes: dict[str, bytes]
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[dict[str, Any]],
    dict[str, dict[str, dict[str, Any]]],
    list[dict[str, Any]],
]:
    coverage: list[dict[str, Any]] = []
    family_members: dict[str, dict[str, Any]] = {}
    text_members: dict[tuple[str, str], dict[str, Any]] = {}
    source_lookup: dict[str, dict[str, dict[str, Any]]] = {}
    source_receipts: list[dict[str, Any]] = []

    for source in sources:
        name = source["name"]
        role = source["role"]
        rows = rows_from_bytes(source_bytes[name], name)
        if len(rows) != source["row_count"]:
            raise ValueError(f"source {name} row count changed")
        observed_presence = Counter(field for row in rows for field in row)
        if dict(sorted(observed_presence.items())) != source["field_presence_counts"]:
            raise ValueError(f"source {name} schema changed")
        seen_ids: set[str] = set()
        lookup: dict[str, dict[str, Any]] = {}
        source_family_ids: set[str] = set()
        source_input_hashes: set[str] = set()
        source_output_hashes: set[str] = set()
        normalized_empty_input_rows = 0
        normalized_empty_output_rows = 0
        for row_number, row in enumerate(rows, 1):
            source_row_id = row.get(source["id_field"])
            input_text = row.get(source["input_field"])
            output_text = row.get(source["output_field"])
            if not isinstance(source_row_id, str) or not source_row_id:
                raise ValueError(f"source {name} row {row_number} ID is unresolved")
            if source_row_id in seen_ids:
                raise ValueError(f"source {name} contains duplicate row ID")
            if not isinstance(input_text, str) or not input_text:
                raise ValueError(f"source {name} row {row_number} input is unresolved")
            if not isinstance(output_text, str) or not output_text:
                raise ValueError(f"source {name} row {row_number} output is unresolved")
            seen_ids.add(source_row_id)

            if source["family_basis"] == "origin_proxy":
                origin = row.get(source["family_field"])
                if not isinstance(origin, str) or not origin:
                    raise ValueError(f"source {name} row {row_number} origin is unresolved")
                blocked_family_id = opaque_id("family-origin", origin)
            else:
                blocked_family_id = opaque_id("family-row", name, source_row_id)
            normalized_input = normalize_text(input_text)
            normalized_output = normalize_text(output_text)
            if not normalized_input:
                normalized_empty_input_rows += 1
            if not normalized_output:
                normalized_empty_output_rows += 1
            input_hash = sha256_bytes(normalized_input.encode("utf-8"))
            output_hash = sha256_bytes(normalized_output.encode("utf-8"))
            entry_id = opaque_id("coverage", role, name, source_row_id)
            record = {
                "schema_version": ENTRY_SCHEMA,
                "registry_entry_id": entry_id,
                "source_role": role,
                "source_name": name,
                "source_row_id_sha256": sha256_bytes(source_row_id.encode("utf-8")),
                "blocked_family_id": blocked_family_id,
                "family_basis": source["family_basis"],
                "normalized_input_sha256": input_hash,
                "normalized_output_sha256": output_hash,
            }
            coverage.append(record)
            lookup[source_row_id] = record
            source_family_ids.add(blocked_family_id)
            source_input_hashes.add(input_hash)
            source_output_hashes.add(output_hash)

            family = family_members.setdefault(
                blocked_family_id,
                {
                    "basis": source["family_basis"],
                    "source_roles": set(),
                    "source_names": set(),
                    "source_row_count": 0,
                },
            )
            if family["basis"] != source["family_basis"]:
                raise ValueError("blocked family ID collision across incompatible bases")
            family["source_roles"].add(role)
            family["source_names"].add(name)
            family["source_row_count"] += 1

            for kind, digest in (("input", input_hash), ("output", output_hash)):
                text = text_members.setdefault(
                    (kind, digest),
                    {
                        "source_roles": set(),
                        "source_names": set(),
                        "source_row_count": 0,
                    },
                )
                text["source_roles"].add(role)
                text["source_names"].add(name)
                text["source_row_count"] += 1
        source_lookup[name] = lookup
        source_receipts.append(
            {
                "role": role,
                "name": name,
                "path": source["path"],
                "sha256": sha256_bytes(source_bytes[name]),
                "expected_sha256": source["sha256"],
                "row_count": len(rows),
                "unique_row_ids": len(seen_ids),
                "blocked_family_count": len(source_family_ids),
                "unique_normalized_input_hashes": len(source_input_hashes),
                "unique_normalized_output_hashes": len(source_output_hashes),
                "normalized_empty_input_rows": normalized_empty_input_rows,
                "normalized_empty_output_rows": normalized_empty_output_rows,
            }
        )

    if len({row["registry_entry_id"] for row in coverage}) != len(coverage):
        raise ValueError("source coverage contains duplicate registry entry IDs")
    coverage.sort(
        key=lambda row: (
            row["source_role"],
            row["source_name"],
            row["source_row_id_sha256"],
        )
    )
    families = [
        {
            "schema_version": FAMILY_SCHEMA,
            "semantic_family_id": family_id,
            "family_basis": metadata["basis"],
            "source_roles": sorted(metadata["source_roles"]),
            "source_names": sorted(metadata["source_names"]),
            "source_row_count": metadata["source_row_count"],
        }
        for family_id, metadata in sorted(family_members.items())
    ]
    text_hashes = [
        {
            "schema_version": TEXT_HASH_SCHEMA,
            "field_kind": kind,
            "normalized_text_sha256": digest,
            "source_roles": sorted(metadata["source_roles"]),
            "source_names": sorted(metadata["source_names"]),
            "source_row_count": metadata["source_row_count"],
        }
        for (kind, digest), metadata in sorted(text_members.items())
    ]
    return coverage, families, text_hashes, source_lookup, source_receipts


def build_decisions(
    decisions: list[dict[str, Any]],
    source_lookup: dict[str, dict[str, dict[str, Any]]],
) -> list[dict[str, Any]]:
    generated: list[dict[str, Any]] = []
    decision_sources = ("type_b_approved_1890", "type_b_overflow_900")
    for decision in decisions:
        case_id = decision["source_case_id"]
        matches = [
            (source_name, source_lookup[source_name][case_id])
            for source_name in decision_sources
            if case_id in source_lookup[source_name]
        ]
        if len(matches) != 1:
            raise ValueError(f"provisional decision must resolve exactly once: {case_id}")
        source_name, source_row = matches[0]
        generated.append(
            {
                "schema_version": DECISION_SCHEMA,
                **decision,
                "source_name": source_name,
                "blocked_family_id": source_row["blocked_family_id"],
                "normalized_input_sha256": source_row["normalized_input_sha256"],
                "normalized_output_sha256": source_row["normalized_output_sha256"],
                "candidate_model_output_seen": False,
                "fresh_benchmark_prose_authored": False,
            }
        )
    if len({row["source_case_id"] for row in generated}) != len(generated):
        raise ValueError("generated decisions contain duplicate case IDs")
    if len({row["replacement_reserve_slot_id"] for row in generated}) != len(generated):
        raise ValueError("generated decisions contain duplicate reserve IDs")
    return generated


def main() -> int:
    args = parse_args()
    output = args.out_bundle.expanduser()
    if output.exists() or output.is_symlink():
        raise SystemExit("--out-bundle already exists; refusing to overwrite evidence")
    if not output.parent.is_dir():
        raise SystemExit("--out-bundle parent directory must already exist")

    execution_git_head = validate_git_state(args.expected_git_head)
    contract_bytes, contract_sha = read_once(CONTRACT_PATH)
    allocation_bytes, allocation_sha = read_once(ALLOCATION_CONTRACT_PATH)
    allocator_bytes, allocator_sha = read_once(ALLOCATOR_BUILDER_PATH)
    contract = parse_json_object(contract_bytes, "blocked registry contract")
    allocation_contract = parse_json_object(
        allocation_bytes, "Type B allocation contract"
    )
    sources, decisions = validate_contract(
        contract,
        allocation_contract,
        allocation_contract_sha=allocation_sha,
        allocator_builder_sha=allocator_sha,
    )

    source_bytes: dict[str, bytes] = {}
    for source in sources:
        path = REPO_ROOT / source["path"]
        value, actual_sha = read_once(path)
        if actual_sha != source["sha256"]:
            raise ValueError(f"source changed: {source['path']}")
        source_bytes[source["name"]] = value

    coverage, families, text_hashes, source_lookup, source_receipts = build_registry(
        sources, source_bytes
    )
    decision_rows = build_decisions(decisions, source_lookup)
    observed_counts = {
        "sources": len(source_receipts),
        "source_rows": len(coverage),
        "blocked_families": len(families),
        "normalized_input_hashes": sum(
            row["field_kind"] == "input" for row in text_hashes
        ),
        "normalized_output_hashes": sum(
            row["field_kind"] == "output" for row in text_hashes
        ),
        "normalized_empty_input_rows": sum(
            row["normalized_empty_input_rows"] for row in source_receipts
        ),
        "normalized_empty_output_rows": sum(
            row["normalized_empty_output_rows"] for row in source_receipts
        ),
        "provisional_decisions": len(decision_rows),
        "replace": sum(row["decision"] == "replace" for row in decision_rows),
        "retain": sum(row["decision"] == "retain" for row in decision_rows),
    }
    if observed_counts != EXPECTED_COUNTS:
        raise ValueError(
            f"blocked registry coverage changed: expected {EXPECTED_COUNTS}, observed {observed_counts}"
        )

    artifact_rows = {
        "blocked_family_registry.jsonl": families,
        "blocked_text_hashes.jsonl": text_hashes,
        "source_coverage.jsonl": coverage,
        "provisional_decisions.jsonl": decision_rows,
    }
    artifact_bytes = {
        name: encode_jsonl(rows) for name, rows in artifact_rows.items()
    }
    observed_validator_artifacts = {
        name: {
            "sha256": sha256_bytes(artifact_bytes[name]),
            "row_count": len(artifact_rows[name]),
            "validator_source_role": EXPECTED_VALIDATOR_SOURCE_BINDINGS.get(name),
        }
        for name in artifact_rows
    }
    if observed_validator_artifacts != EXPECTED_VALIDATOR_ARTIFACTS:
        raise ValueError("blocked registry validator artifacts differ from sealed contract")
    receipt = {
        "schema_version": "eg1-type-b-v2-blocked-registry-receipt-v1",
        "status": "sources_sealed_all_provisional_replaced_authorship_blocked",
        "registry_id": contract["registry_id"],
        "normalization_policy_id": NORMALIZATION_POLICY_ID,
        "execution_git_head": execution_git_head,
        "contract": {
            "path": str(CONTRACT_PATH.relative_to(REPO_ROOT)),
            "sha256": contract_sha,
            "schema_version": CONTRACT_SCHEMA,
        },
        "builder": {
            "path": str(SCRIPT_PATH.relative_to(REPO_ROOT)),
            "sha256": read_once(SCRIPT_PATH)[1],
        },
        "allocator": {
            "allocation_contract_path": str(
                ALLOCATION_CONTRACT_PATH.relative_to(REPO_ROOT)
            ),
            "allocation_contract_sha256": allocation_sha,
            "builder_path": str(ALLOCATOR_BUILDER_PATH.relative_to(REPO_ROOT)),
            "builder_sha256": allocator_sha,
        },
        "counts": observed_counts,
        "sources": source_receipts,
        "artifacts": {
            name: {
                "sha256": sha256_bytes(value),
                "row_count": len(artifact_rows[name]),
                "validator_source_role": EXPECTED_VALIDATOR_SOURCE_BINDINGS.get(
                    name
                ),
            }
            for name, value in artifact_bytes.items()
        },
        "decision_summary": {
            "reason_code": "semantic_family_clearance_not_proven",
            "replace": len(decision_rows),
            "retain": 0,
            "same_cell_reserves_bound": len(decision_rows),
        },
        "candidate_clearance_contract": EXPECTED_CANDIDATE_CLEARANCE_CONTRACT,
        "privacy": {
            "private_source_text_published": False,
            "private_source_row_ids_published_raw": False,
            "safe_provisional_case_ids_published": True,
            "other_source_row_ids_published_raw": False,
            "metadata_only": True,
        },
        "authorship_gate": {
            "candidate_model_output_seen": False,
            "fresh_benchmark_prose_authored": False,
            "fresh_authorship_authorized": False,
            "fresh_slots_required": 1890,
        },
        "publication": "exclusive_bundle_receipt_last",
    }
    receipt_bytes = (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode()

    created = False
    try:
        output.mkdir()
        created = True
        for name in EXPECTED_ARTIFACT_NAMES[:-1]:
            write_exclusive(output / name, artifact_bytes[name])

        if read_once(CONTRACT_PATH)[1] != contract_sha:
            raise RuntimeError("blocked registry contract changed during publication")
        if read_once(ALLOCATION_CONTRACT_PATH)[1] != allocation_sha:
            raise RuntimeError("allocation contract changed during publication")
        if read_once(ALLOCATOR_BUILDER_PATH)[1] != allocator_sha:
            raise RuntimeError("allocator builder changed during publication")
        if validate_git_state(args.expected_git_head) != execution_git_head:
            raise RuntimeError("Git state changed during registry publication")
        for source in sources:
            path = REPO_ROOT / source["path"]
            if read_once(path)[1] != source["sha256"]:
                raise RuntimeError(f"source changed during publication: {source['path']}")
        write_exclusive(output / "receipt.json", receipt_bytes)
    except BaseException:
        if created:
            shutil.rmtree(output)
        raise

    print(
        json.dumps(
            {
                "sources": observed_counts["sources"],
                "source_rows": observed_counts["source_rows"],
                "blocked_families": observed_counts["blocked_families"],
                "decisions": observed_counts["provisional_decisions"],
                "replace": observed_counts["replace"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
