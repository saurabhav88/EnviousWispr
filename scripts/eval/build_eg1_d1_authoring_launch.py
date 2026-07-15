#!/usr/bin/env python3
"""Bind a private approved roster to D1 authorship and native review slots.

This stage is metadata-only. It never authors prose, approves a review, runs a
model, or grants training eligibility. When shared-concept briefs are not yet
sealed, only the 1,600 native-original rows can become ready to author.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import Any

import build_eg1_multilingual_d1 as d1


SCRIPT_PATH = Path(__file__).resolve()
D1_BUILDER_PATH = Path(d1.__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
ROSTER_SCHEMA = "eg1-d1-private-authoring-roster-v1"
ASSIGNMENT_SCHEMA = "eg1-d1-authoring-assignment-v1"
RECEIPT_SCHEMA = "eg1-d1-authoring-launch-receipt-v1"
HUMAN_NATIVE_FRACTION_MINIMUM = 0.5
SAFE_ID = re.compile(r"[a-z0-9][a-z0-9._:-]{2,127}")
SAFE_MODEL_TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/+@-]{1,255}")
HUMAN_FIELDS = {
    "participant_id",
    "participant_type",
    "languages",
    "roles",
    "availability_status",
    "identity_reference_id",
    "consent_reference_id",
}
SYNTHETIC_FIELDS = {
    "participant_id",
    "participant_type",
    "languages",
    "roles",
    "availability_status",
    "model_id",
    "configuration_id",
    "critic_model_id",
    "critic_configuration_id",
}
ROSTER_FIELDS = {
    "schema_version",
    "roster_id",
    "status",
    "approved_by_id",
    "approved_at",
    "approval_reference_id",
    "participants",
}


class ValidationFailure(ValueError):
    """Raised when launch metadata cannot be trusted."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--packet-receipt", required=True, type=Path)
    parser.add_argument("--roster", required=True, type=Path)
    parser.add_argument("--shared-concept-registry", type=Path)
    parser.add_argument("--out-bundle", required=True, type=Path)
    parser.add_argument("--expected-git-head", required=True)
    return parser.parse_args()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_bytes(path: Path, label: str) -> tuple[bytes, str]:
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
        text_value = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValidationFailure(f"{label} is not valid UTF-8 JSONL") from error
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(text_value.splitlines(), 1):
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


def encode_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def encode_jsonl(rows: list[dict[str, Any]]) -> bytes:
    return b"".join(
        (json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n").encode()
        for row in rows
    )


def receipt_path(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT.resolve()))
    except ValueError:
        return str(resolved)


def is_safe_id(value: Any) -> bool:
    return isinstance(value, str) and SAFE_ID.fullmatch(value) is not None


def is_safe_model_token(value: Any) -> bool:
    return isinstance(value, str) and SAFE_MODEL_TOKEN.fullmatch(value) is not None


def is_utc_timestamp(value: Any) -> bool:
    if not isinstance(value, str) or not value.endswith("Z"):
        return False
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return False
    return True


def validate_private_path(path: Path, label: str, *, must_exist: bool) -> Path:
    candidate = path.expanduser()
    if must_exist and (not candidate.is_file() or candidate.is_symlink()):
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


def validate_output_path(path: Path) -> Path:
    if path.exists() or path.is_symlink():
        raise ValidationFailure("output bundle already exists")
    resolved_parent = path.expanduser().parent.resolve()
    resolved = resolved_parent / path.name
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


def validate_git_state(expected_head: str, tracked_paths: list[Path]) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", expected_head):
        raise ValidationFailure("expected Git HEAD must be a lowercase 40-character SHA-1")
    actual_head = git_output("rev-parse", "HEAD").decode().strip()
    if actual_head != expected_head:
        raise ValidationFailure("Git HEAD differs from the predeclared commit")
    if git_output("status", "--porcelain", "--untracked-files=no"):
        raise ValidationFailure("tracked worktree must be clean before launch publication")
    for path in tracked_paths:
        try:
            relative = path.resolve().relative_to(REPO_ROOT.resolve())
        except ValueError as error:
            raise ValidationFailure("tracked launch input is outside the repository") from error
        committed = git_output("show", f"{actual_head}:{relative}")
        live, _ = read_bytes(path, str(relative))
        if committed != live:
            raise ValidationFailure(f"committed bytes differ from live file: {relative}")
    return actual_head


def validate_roster(
    roster: dict[str, Any], contract: dict[str, Any]
) -> list[dict[str, Any]]:
    if set(roster) != ROSTER_FIELDS:
        raise ValidationFailure("private roster top-level schema changed")
    if roster.get("schema_version") != ROSTER_SCHEMA:
        raise ValidationFailure("private roster schema is unsupported")
    for field in ("roster_id", "approved_by_id", "approval_reference_id"):
        if not is_safe_id(roster.get(field)):
            raise ValidationFailure(f"private roster {field} must be an opaque safe ID")
    if roster.get("status") != "approved_for_assignment":
        raise ValidationFailure("private roster is not approved for assignment")
    if not is_utc_timestamp(roster.get("approved_at")):
        raise ValidationFailure("private roster approval timestamp is invalid")
    participants = roster.get("participants")
    if not isinstance(participants, list) or not participants:
        raise ValidationFailure("private roster participants must be a nonempty list")

    allowed_languages = set(contract.get("languages", []))
    validated: list[dict[str, Any]] = []
    participant_ids: set[str] = set()
    human_identity_references: set[str] = set()
    for index, participant in enumerate(participants, 1):
        if not isinstance(participant, dict):
            raise ValidationFailure(f"roster participant {index} must be an object")
        participant_type = participant.get("participant_type")
        expected_fields = (
            HUMAN_FIELDS if participant_type == "human_native" else SYNTHETIC_FIELDS
            if participant_type == "synthetic_native"
            else None
        )
        if expected_fields is None:
            raise ValidationFailure(f"roster participant {index} has unsupported type")
        if set(participant) != expected_fields:
            raise ValidationFailure(f"roster participant {index} schema changed")
        participant_id = participant.get("participant_id")
        if not is_safe_id(participant_id):
            raise ValidationFailure(f"roster participant {index} needs an opaque safe ID")
        if participant_id in participant_ids:
            raise ValidationFailure(f"duplicate roster participant ID: {participant_id}")
        participant_ids.add(participant_id)
        if participant.get("availability_status") != "confirmed":
            raise ValidationFailure(f"{participant_id}: availability is not confirmed")
        languages = participant.get("languages")
        if (
            not isinstance(languages, list)
            or not languages
            or any(not isinstance(language, str) for language in languages)
            or len(languages) != len(set(languages))
            or not set(languages).issubset(allowed_languages)
        ):
            raise ValidationFailure(f"{participant_id}: language qualifications are invalid")
        roles = participant.get("roles")
        if (
            not isinstance(roles, list)
            or not roles
            or len(roles) != len(set(roles))
            or not set(roles).issubset({"author", "native_reviewer"})
        ):
            raise ValidationFailure(f"{participant_id}: roles are invalid")
        if participant_type == "human_native":
            for field in ("identity_reference_id", "consent_reference_id"):
                if not is_safe_id(participant.get(field)):
                    raise ValidationFailure(f"{participant_id}: {field} must be an opaque safe ID")
            identity_reference = participant["identity_reference_id"]
            if identity_reference in human_identity_references:
                raise ValidationFailure(
                    f"duplicate human identity reference: {identity_reference}"
                )
            human_identity_references.add(identity_reference)
        else:
            if roles != ["author"]:
                raise ValidationFailure(f"{participant_id}: synthetic sources may only author")
            for field in (
                "model_id",
                "configuration_id",
                "critic_model_id",
                "critic_configuration_id",
            ):
                if not is_safe_model_token(participant.get(field)):
                    raise ValidationFailure(f"{participant_id}: {field} is invalid")
            if (
                participant["model_id"],
                participant["configuration_id"],
            ) == (
                participant["critic_model_id"],
                participant["critic_configuration_id"],
            ):
                raise ValidationFailure(f"{participant_id}: synthetic author and critic are identical")
        validated.append(participant)

    for language in contract["languages"]:
        authors = [
            participant
            for participant in validated
            if "author" in participant["roles"] and language in participant["languages"]
        ]
        human_authors = [
            participant for participant in authors
            if participant["participant_type"] == "human_native"
        ]
        reviewers = [
            participant
            for participant in validated
            if participant["participant_type"] == "human_native"
            and "native_reviewer" in participant["roles"]
            and language in participant["languages"]
        ]
        if not authors or not human_authors:
            raise ValidationFailure(f"{language}: at least one human-native author is required")
        if not reviewers:
            raise ValidationFailure(f"{language}: at least one human-native reviewer is required")
        for author in authors:
            if not any(
                reviewer["participant_id"] != author["participant_id"]
                for reviewer in reviewers
            ):
                raise ValidationFailure(
                    f"{language}: {author['participant_id']} has no independent native reviewer"
                )
    return sorted(validated, key=lambda participant: participant["participant_id"])


def deterministic_order(
    rows: list[dict[str, Any]], *, seed: int, roster_id: str, namespace: str
) -> list[dict[str, Any]]:
    return sorted(
        rows,
        key=lambda row: sha256_bytes(
            f"{seed}|{roster_id}|{namespace}|{row['family_id']}".encode()
        ),
    )


def choose_participant(
    participants: list[dict[str, Any]], *, seed_material: str, index: int
) -> dict[str, Any]:
    ordered = sorted(participants, key=lambda participant: participant["participant_id"])
    offset = int(sha256_bytes(seed_material.encode())[:8], 16) % len(ordered)
    return ordered[(offset + index) % len(ordered)]


def build_assignments(
    contract: dict[str, Any],
    slots: list[dict[str, Any]],
    participants: list[dict[str, Any]],
    roster_id: str,
    shared_concepts_sealed: bool,
) -> list[dict[str, Any]]:
    assignments: dict[str, dict[str, Any]] = {}
    seed = int(contract["seed"])
    for language in contract["languages"]:
        authors = [
            participant for participant in participants
            if "author" in participant["roles"] and language in participant["languages"]
        ]
        human_authors = [
            participant for participant in authors
            if participant["participant_type"] == "human_native"
        ]
        reviewers = [
            participant for participant in participants
            if participant["participant_type"] == "human_native"
            and "native_reviewer" in participant["roles"]
            and language in participant["languages"]
        ]
        for origin_mode in contract["origin_modes"]:
            group = [
                slot for slot in slots
                if slot["language"] == language and slot["origin_mode"] == origin_mode
            ]
            ordered = deterministic_order(
                group,
                seed=seed,
                roster_id=roster_id,
                namespace=f"{language}|{origin_mode}",
            )
            blocked = origin_mode == "shared_concept_independent_rewrite" and not shared_concepts_sealed
            human_quota = math.ceil(len(ordered) * HUMAN_NATIVE_FRACTION_MINIMUM)
            for index, slot in enumerate(ordered):
                row = {
                    "schema_version": ASSIGNMENT_SCHEMA,
                    **slot,
                    "packet_filename": f"d1-authoring-{language}.jsonl",
                    "assignment_id": "d1-assignment-" + sha256_bytes(
                        f"{roster_id}|{slot['family_id']}".encode()
                    )[:24],
                    "candidate_model_output_seen": False,
                    "prose_authored": False,
                    "native_review_approved": False,
                }
                if blocked:
                    row.update(
                        {
                            "launch_status": "blocked_shared_concept_registry",
                            "author_id": None,
                            "author_type": None,
                            "author_model_id": None,
                            "author_configuration_id": None,
                            "critic_model_id": None,
                            "critic_configuration_id": None,
                            "native_reviewer_id": None,
                            "native_reviewer_type": None,
                            "authoring_status": "blocked",
                            "review_status": "blocked",
                        }
                    )
                else:
                    author_pool = human_authors if index < human_quota else authors
                    author = choose_participant(
                        author_pool,
                        seed_material=f"{seed}|{roster_id}|author|{language}|{origin_mode}",
                        index=index,
                    )
                    eligible_reviewers = [
                        reviewer for reviewer in reviewers
                        if reviewer["participant_id"] != author["participant_id"]
                    ]
                    reviewer = choose_participant(
                        eligible_reviewers,
                        seed_material=f"{seed}|{roster_id}|review|{slot['family_id']}",
                        index=index,
                    )
                    row.update(
                        {
                            "launch_status": "ready_to_author",
                            "author_id": author["participant_id"],
                            "author_type": author["participant_type"],
                            "author_model_id": author.get("model_id"),
                            "author_configuration_id": author.get("configuration_id"),
                            "critic_model_id": author.get("critic_model_id"),
                            "critic_configuration_id": author.get("critic_configuration_id"),
                            "native_reviewer_id": reviewer["participant_id"],
                            "native_reviewer_type": reviewer["participant_type"],
                            "authoring_status": "ready",
                            "review_status": "waiting_for_authored_row",
                        }
                    )
                assignments[slot["family_id"]] = row
    return [assignments[slot["family_id"]] for slot in slots]


def snapshot_inputs(
    contract_path: Path,
    packet_receipt_path: Path,
    roster_path: Path,
    shared_registry_path: Path | None,
) -> tuple[dict[Path, bytes], dict[Path, str], list[Path]]:
    paths = [
        SCRIPT_PATH,
        D1_BUILDER_PATH,
        contract_path,
        packet_receipt_path,
        roster_path,
    ]
    if shared_registry_path:
        paths.append(shared_registry_path)
    blobs: dict[Path, bytes] = {}
    snapshots: dict[Path, str] = {}
    for path in paths:
        blobs[path], snapshots[path] = read_bytes(path, path.name)

    packet_receipt = parse_object(blobs[packet_receipt_path], "packet receipt")
    packets = packet_receipt.get("packets")
    if not isinstance(packets, list):
        raise ValidationFailure("packet receipt packets must be a list")
    packet_paths: list[Path] = []
    for packet in packets:
        filename = packet.get("filename") if isinstance(packet, dict) else None
        if (
            not isinstance(filename, str)
            or not filename
            or Path(filename).name != filename
        ):
            raise ValidationFailure("packet receipt contains an unsafe filename")
        packet_path = packet_receipt_path.parent / filename
        if not packet_path.is_file() or packet_path.is_symlink():
            raise ValidationFailure(f"missing immutable authoring packet: {filename}")
        blobs[packet_path], snapshots[packet_path] = read_bytes(
            packet_path, f"authoring packet {filename}"
        )
        packet_paths.append(packet_path)
    return blobs, snapshots, packet_paths


def verify_packet_set(
    *,
    contract_path: Path,
    packet_receipt_path: Path,
    shared_registry_path: Path | None,
    blobs: dict[Path, bytes],
    snapshots: dict[Path, str],
    packet_paths: list[Path],
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]:
    contract = parse_object(blobs[contract_path], "D1 contract")
    slots = d1.build_slots(contract)
    plan_errors = d1.verify_plan(contract, slots)
    if plan_errors:
        raise ValidationFailure("; ".join(plan_errors))
    shared_registry = (
        parse_object(blobs[shared_registry_path], "shared-concept registry")
        if shared_registry_path
        else None
    )
    expected_receipt = d1.build_authoring_packet_receipt(
        contract_path=contract_path,
        contract=contract,
        slots=slots,
        shared_registry_path=shared_registry_path,
        shared_registry=shared_registry,
        contract_sha256=snapshots[contract_path],
        builder_sha256=snapshots[D1_BUILDER_PATH],
        shared_registry_sha256=(
            snapshots[shared_registry_path] if shared_registry_path else None
        ),
    )
    actual_receipt = parse_object(blobs[packet_receipt_path], "packet receipt")
    if actual_receipt != expected_receipt:
        raise ValidationFailure(
            "packet receipt does not match the current contract, builder, allocation, "
            "or shared-concept registry"
        )
    packets_by_name = {path.name: path for path in packet_paths}
    for packet in actual_receipt["packets"]:
        packet_path = packets_by_name.get(packet["filename"])
        if packet_path is None:
            raise ValidationFailure(f"missing immutable authoring packet: {packet['filename']}")
        if snapshots[packet_path] != packet["packet_sha256"]:
            raise ValidationFailure(f"authoring packet hash changed: {packet['filename']}")
        expected_rows = [slot for slot in slots if slot["language"] == packet["language"]]
        if parse_jsonl(blobs[packet_path], packet["filename"]) != expected_rows:
            raise ValidationFailure(f"authoring packet allocation changed: {packet['filename']}")
    return contract, slots, actual_receipt


def build_launch_bundle(
    *,
    contract_path: Path,
    packet_receipt_path: Path,
    roster_path: Path,
    shared_registry_path: Path | None,
    output_path: Path,
    execution_git_head: str,
) -> dict[str, Any]:
    blobs, snapshots, packet_paths = snapshot_inputs(
        contract_path, packet_receipt_path, roster_path, shared_registry_path
    )
    contract, slots, packet_receipt = verify_packet_set(
        contract_path=contract_path,
        packet_receipt_path=packet_receipt_path,
        shared_registry_path=shared_registry_path,
        blobs=blobs,
        snapshots=snapshots,
        packet_paths=packet_paths,
    )
    roster_bytes = blobs[roster_path]
    roster_sha = snapshots[roster_path]
    roster = parse_object(roster_bytes, "private roster")
    participants = validate_roster(roster, contract)
    shared_status = packet_receipt["shared_concept_authoring"]["status"]
    assignments = build_assignments(
        contract,
        slots,
        participants,
        roster["roster_id"],
        shared_status == "sealed",
    )
    assigned = [row for row in assignments if row["launch_status"] == "ready_to_author"]
    blocked = [row for row in assignments if row["launch_status"] != "ready_to_author"]
    human_count = sum(row["author_type"] == "human_native" for row in assigned)
    if human_count < math.ceil(len(assigned) * HUMAN_NATIVE_FRACTION_MINIMUM):
        raise ValidationFailure("human-native author assignment fraction fell below 50%")
    if any(
        row["native_reviewer_type"] != "human_native"
        or row["native_reviewer_id"] == row["author_id"]
        for row in assigned
    ):
        raise ValidationFailure("independent human-native review assignment failed")
    for language in contract["languages"]:
        language_rows = [row for row in assigned if row["language"] == language]
        language_humans = sum(row["author_type"] == "human_native" for row in language_rows)
        if language_humans < math.ceil(
            len(language_rows) * HUMAN_NATIVE_FRACTION_MINIMUM
        ):
            raise ValidationFailure(f"{language}: human-native assignment fraction fell below 50%")

    assignment_bytes = encode_jsonl(assignments)
    participant_counts = Counter(
        (participant["participant_type"], role)
        for participant in participants
        for role in participant["roles"]
    )
    receipt = {
        "schema_version": RECEIPT_SCHEMA,
        "status": (
            "all_authorship_assignments_ready"
            if not blocked
            else "native_original_authorship_ready_shared_concepts_blocked"
        ),
        "execution_git_head": execution_git_head,
        "contract": {
            "path": receipt_path(contract_path),
            "sha256": snapshots[contract_path],
        },
        "builder": {
            "path": str(SCRIPT_PATH.relative_to(REPO_ROOT)),
            "sha256": snapshots[SCRIPT_PATH],
        },
        "inputs": {
            "packet_receipt_sha256": snapshots[packet_receipt_path],
            "packet_set_sha256": packet_receipt["packet_set_sha256"],
            "roster_id": roster["roster_id"],
            "roster_sha256": roster_sha,
            "shared_concept_status": shared_status,
            "shared_concept_registry_sha256": (
                snapshots[shared_registry_path] if shared_registry_path else None
            ),
        },
        "counts": {
            "total_slots": len(assignments),
            "ready_to_author": len(assigned),
            "blocked_shared_concept_slots": len(blocked),
            "human_native_author_assignments": human_count,
            "synthetic_native_author_assignments": len(assigned) - human_count,
            "human_native_roster_authors": participant_counts[("human_native", "author")],
            "human_native_roster_reviewers": participant_counts[("human_native", "native_reviewer")],
            "synthetic_native_roster_authors": participant_counts[("synthetic_native", "author")],
            "language_ready": dict(sorted(Counter(row["language"] for row in assigned).items())),
        },
        "gates": {
            "human_native_author_fraction_minimum": HUMAN_NATIVE_FRACTION_MINIMUM,
            "human_native_author_fraction_satisfied": True,
            "all_assigned_reviewers_human_native": True,
            "author_reviewer_identity_separation_verified": True,
            "all_rows_native_review_approved": False,
            "training_eligible": False,
            "release_eligible": False,
        },
        "privacy": {
            "private_roster_tracked_by_this_repo": False,
            "raw_names_emails_or_contact_details_allowed": False,
            "opaque_id_format_enforced": True,
            "prose_published": False,
            "candidate_model_output_published": False,
        },
        "artifacts": {
            "assignments.jsonl": {
                "sha256": sha256_bytes(assignment_bytes),
                "row_count": len(assignments),
            }
        },
        "publication": "exclusive_private_bundle_receipt_last",
    }
    receipt_bytes = encode_json(receipt)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(
        tempfile.mkdtemp(prefix=f".{output_path.name}.", dir=output_path.parent)
    )
    try:
        (temporary / "assignments.jsonl").write_bytes(assignment_bytes)
        for path, expected_sha in snapshots.items():
            if d1.sha256_file(path) != expected_sha:
                raise ValidationFailure(f"launch input changed during publication: {path.name}")
        (temporary / "receipt.json").write_bytes(receipt_bytes)
        os.replace(temporary, output_path)
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return receipt


def main() -> int:
    args = parse_args()
    try:
        contract_path = args.contract.resolve()
        packet_receipt_path = validate_private_path(
            args.packet_receipt, "packet receipt", must_exist=True
        )
        roster_path = validate_private_path(args.roster, "private roster", must_exist=True)
        shared_registry_path = (
            validate_private_path(
                args.shared_concept_registry,
                "shared-concept registry",
                must_exist=True,
            )
            if args.shared_concept_registry
            else None
        )
        output_path = validate_output_path(args.out_bundle)
        execution_git_head = validate_git_state(
            args.expected_git_head, [SCRIPT_PATH, D1_BUILDER_PATH, contract_path]
        )
        receipt = build_launch_bundle(
            contract_path=contract_path,
            packet_receipt_path=packet_receipt_path,
            roster_path=roster_path,
            shared_registry_path=shared_registry_path,
            output_path=output_path,
            execution_git_head=execution_git_head,
        )
    except ValidationFailure as error:
        print(f"D1 authoring launch blocked: {error}", file=os.sys.stderr)
        return 2
    print(json.dumps(receipt["counts"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
