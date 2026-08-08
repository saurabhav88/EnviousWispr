#!/usr/bin/env python3
"""Publish a metadata-only inventory of the original EG-1 replay rows."""

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

from eg1_replay_normalizer_v1 import NORMALIZER_VERSION, normalize_identity


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
NORMALIZER_PATH = SCRIPT_PATH.with_name("eg1_replay_normalizer_v1.py")
DEFAULT_CONTRACT = (
    REPO_ROOT / "scripts/eval/contracts/eg1_replay_inventory_v1.json"
)
SCHEMA_VERSION = "eg1-replay-inventory-v1"
INVENTORY_FILENAME = "inventory.jsonl"
RECEIPT_FILENAME = "receipt.json"
DECISIONS = {
    "historical_type_b_overlap_blocked",
    "invalid_normalization_quarantined",
    "duplicate_group_quarantined",
    "candidate_only",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--out-bundle", required=True, type=Path)
    parser.add_argument("--expected-git-head", required=True)
    return parser.parse_args()


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_once(path: Path) -> tuple[bytes, str]:
    value = path.read_bytes()
    return value, sha256_bytes(value)


def git_output(repo_root: Path, *arguments: str) -> bytes:
    try:
        return subprocess.run(
            ["git", *arguments],
            cwd=repo_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except subprocess.CalledProcessError as error:
        raise ValueError(f"cannot verify Git state: {' '.join(arguments)}") from error


def relative_tracked_path(path: Path, repo_root: Path) -> str:
    try:
        return str(path.resolve().relative_to(repo_root.resolve()))
    except ValueError as error:
        raise ValueError("tracked binding path must be inside the repository") from error


def validate_git_state(
    expected_head: str,
    repo_root: Path,
    tracked_paths: tuple[Path, ...],
) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", expected_head):
        raise ValueError("expected Git HEAD must be a lowercase 40-character SHA-1")
    actual_head = git_output(repo_root, "rev-parse", "HEAD").decode().strip()
    if actual_head != expected_head:
        raise ValueError("Git HEAD differs from the predeclared commit")
    if git_output(repo_root, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("tracked worktree must be clean before inventory publication")
    for path in tracked_paths:
        relative = relative_tracked_path(path, repo_root)
        committed_bytes = git_output(repo_root, "show", f"{actual_head}:{relative}")
        if sha256_bytes(committed_bytes) != read_once(path)[1]:
            raise ValueError(f"committed bytes differ from live file: {relative}")
    return actual_head


def require_ignored_output(output: Path, repo_root: Path) -> None:
    try:
        relative = output.resolve().relative_to(repo_root.resolve())
    except ValueError as error:
        raise ValueError("output bundle must be inside the repository") from error
    result = subprocess.run(
        ["git", "check-ignore", "-q", "--", str(relative)],
        cwd=repo_root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise ValueError("output bundle must be covered by a repository ignore rule")


def rows_from_bytes(value: bytes, label: str) -> list[dict[str, Any]]:
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{label} is not valid UTF-8") from error
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"{label} row {line_number} is not valid JSON") from error
        if not isinstance(row, dict):
            raise ValueError(f"{label} row {line_number} is not an object")
        rows.append(row)
    return rows


def require_string_fields(
    rows: list[dict[str, Any]],
    label: str,
    fields: tuple[str, ...],
    *,
    nonempty: bool = True,
) -> None:
    for row_number, row in enumerate(rows, 1):
        if any(
            field not in row
            or not isinstance(row[field], str)
            or (nonempty and not row[field].strip())
            for field in fields
        ):
            raise ValueError(f"{label} row {row_number} has invalid required fields")


def require_unique_ids(rows: list[dict[str, Any]], label: str) -> set[str]:
    values = [row["id"] for row in rows]
    if len(values) != len(set(values)):
        raise ValueError(f"{label} contains duplicate row IDs")
    return set(values)


def fingerprint_row(row: dict[str, Any]) -> str:
    return sha256_bytes(canonical_json(row))


def validate_contract(contract: dict[str, Any]) -> None:
    expected_keys = {
        "schema_version",
        "normalizer",
        "tool_bindings",
        "sources",
        "policy",
        "expected_counts",
    }
    if set(contract) != expected_keys or contract.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("inventory contract schema changed")
    if contract.get("normalizer") != {
        "version": NORMALIZER_VERSION,
        "unicode_form": "NFKC",
        "case_mapping": "casefold",
        "token_pattern": r"[^\W_]+",
        "separator": "single_space",
        "empty_word_fallback": "full_string_symbol_preserving",
        "fallback_whitespace": "single_space",
        "identity_domains": ["word", "full_symbol_fallback"],
    }:
        raise ValueError("normalizer contract changed")
    if contract.get("policy") != {
        "historical_overlap_fields": ["asr_input", "expected_output"],
        "replay_overlap_fields": ["input", "output"],
        "overlap_comparison": "cross_field_union",
        "duplicate_scope": "all_remaining_rows",
        "duplicate_fields": ["normalized_input", "normalized_output"],
        "duplicate_disposition": "quarantine_entire_group",
        "candidate_disposition": "candidate_only",
        "candidate_training_eligible": False,
    }:
        raise ValueError("inventory decision policy changed")
    counts = contract.get("expected_counts")
    required_counts = {
        "total_replay_rows",
        "historical_type_b_overlap_blocked",
        "post_overlap_rows",
        "invalid_normalization_quarantined",
        "duplicate_group_quarantined",
        "candidate_only",
        "training_eligible",
        "unresolved",
        "duplicate_canonical_replay_rows",
        "fallback_normalized_historical_fields",
        "fallback_normalized_replay_fields",
        "fallback_normalized_replay_rows",
    }
    if not isinstance(counts, dict) or set(counts) != required_counts:
        raise ValueError("inventory expected-count schema changed")
    if any(type(value) is not int or value < 0 for value in counts.values()):
        raise ValueError("inventory expected counts are invalid")


def validate_bindings(
    contract: dict[str, Any],
    repo_root: Path,
    script_path: Path,
    normalizer_path: Path,
) -> dict[str, dict[str, str]]:
    bindings = contract.get("tool_bindings")
    expected_paths = {
        "builder": relative_tracked_path(script_path, repo_root),
        "normalizer": relative_tracked_path(normalizer_path, repo_root),
    }
    if not isinstance(bindings, dict) or set(bindings) != set(expected_paths):
        raise ValueError("tool binding inventory changed")
    receipts: dict[str, dict[str, str]] = {}
    for name, relative in expected_paths.items():
        binding = bindings.get(name)
        if not isinstance(binding, dict) or set(binding) != {"path", "sha256"}:
            raise ValueError("tool binding schema changed")
        if binding.get("path") != relative:
            raise ValueError("tool binding path changed")
        actual_sha = read_once(repo_root / relative)[1]
        if binding.get("sha256") != actual_sha:
            raise ValueError(f"{name} hash differs from the sealed contract")
        receipts[name] = {"path": relative, "sha256": actual_sha}
    return receipts


def load_sources(
    contract: dict[str, Any], repo_root: Path
) -> tuple[dict[str, list[dict[str, Any]]], list[dict[str, Any]], dict[str, bytes]]:
    sources = contract.get("sources")
    expected_roles = {
        "historical_type_b_approved",
        "historical_type_b_overflow",
        "historical_type_b_all",
        "replay_training_original",
    }
    if not isinstance(sources, dict) or set(sources) != expected_roles:
        raise ValueError("source inventory changed")
    parsed: dict[str, list[dict[str, Any]]] = {}
    captured: dict[str, bytes] = {}
    receipts: list[dict[str, Any]] = []
    for role in sorted(expected_roles):
        source = sources.get(role)
        if not isinstance(source, dict) or set(source) != {"path", "sha256", "row_count"}:
            raise ValueError("source binding schema changed")
        relative = source.get("path")
        expected_sha = source.get("sha256")
        expected_rows = source.get("row_count")
        if (
            not isinstance(relative, str)
            or not relative
            or Path(relative).is_absolute()
            or not isinstance(expected_sha, str)
            or not re.fullmatch(r"[0-9a-f]{64}", expected_sha)
            or type(expected_rows) is not int
            or expected_rows < 0
        ):
            raise ValueError("source binding values are invalid")
        path = repo_root / relative
        try:
            path.resolve().relative_to(repo_root.resolve())
        except ValueError as error:
            raise ValueError("source path escapes the repository") from error
        value, actual_sha = read_once(path)
        if actual_sha != expected_sha:
            raise ValueError(f"source hash changed for role: {role}")
        rows = rows_from_bytes(value, role)
        if len(rows) != expected_rows:
            raise ValueError(f"source row count changed for role: {role}")
        captured[relative] = value
        parsed[role] = rows
        receipts.append(
            {
                "role": role,
                "path": relative,
                "sha256": actual_sha,
                "row_count": len(rows),
            }
        )
    return parsed, receipts, captured


def validate_source_relationships(parsed: dict[str, list[dict[str, Any]]]) -> None:
    replay = parsed["replay_training_original"]
    require_string_fields(replay, "replay source", ("id", "source"))
    require_string_fields(
        replay, "replay source", ("input", "output"), nonempty=False
    )
    if any(set(row) != {"id", "source", "input", "output"} for row in replay):
        raise ValueError("replay source row schema changed")
    require_unique_ids(replay, "replay source")

    type_b_roles = (
        "historical_type_b_approved",
        "historical_type_b_overflow",
        "historical_type_b_all",
    )
    type_b_ids: dict[str, set[str]] = {}
    for role in type_b_roles:
        rows = parsed[role]
        require_string_fields(rows, role, ("id", "asr_input", "expected_output"))
        type_b_ids[role] = require_unique_ids(rows, role)
    approved = type_b_ids["historical_type_b_approved"]
    overflow = type_b_ids["historical_type_b_overflow"]
    all_ids = type_b_ids["historical_type_b_all"]
    if approved & overflow or approved | overflow != all_ids:
        raise ValueError("historical Type B views are not an exact disjoint ID union")
    union_fingerprints = Counter(
        fingerprint_row(row)
        for role in ("historical_type_b_approved", "historical_type_b_overflow")
        for row in parsed[role]
    )
    all_fingerprints = Counter(
        fingerprint_row(row) for row in parsed["historical_type_b_all"]
    )
    if union_fingerprints != all_fingerprints:
        raise ValueError("historical Type B all-view rows differ from approved plus overflow")


def make_inventory(
    replay_rows: list[dict[str, Any]], historical_rows: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    historical_identities = [
        normalize_identity(row[field])
        for row in historical_rows
        for field in ("asr_input", "expected_output")
    ]
    if any(domain == "invalid" for domain, _ in historical_identities):
        raise ValueError("historical Type B contains invalid normalized text")
    historical_text = set(historical_identities)
    historical_fallback_fields = sum(
        domain == "full_symbol_fallback" for domain, _ in historical_identities
    )
    intermediate: list[dict[str, Any]] = []
    for row in replay_rows:
        normalized_input = normalize_identity(row["input"])
        normalized_output = normalize_identity(row["output"])
        intermediate.append(
            {
                "fingerprint": fingerprint_row(row),
                "normalized_input": normalized_input,
                "normalized_output": normalized_output,
                "invalid": "invalid"
                in {normalized_input[0], normalized_output[0]},
                "overlap": normalized_input in historical_text
                or normalized_output in historical_text,
            }
        )
    fingerprints = [row["fingerprint"] for row in intermediate]
    duplicate_canonical = len(fingerprints) - len(set(fingerprints))
    post_overlap = [row for row in intermediate if not row["overlap"]]
    remaining = [row for row in post_overlap if not row["invalid"]]
    input_counts = Counter(row["normalized_input"] for row in remaining)
    output_counts = Counter(row["normalized_output"] for row in remaining)

    inventory: list[dict[str, Any]] = []
    for row in intermediate:
        if row["invalid"]:
            decision = "invalid_normalization_quarantined"
            reasons = ["empty_after_word_and_full_string_normalization"]
        elif row["overlap"]:
            decision = "historical_type_b_overlap_blocked"
            reasons = ["historical_type_b_input_or_output_collision"]
        else:
            reasons = []
            if input_counts[row["normalized_input"]] > 1:
                reasons.append("remaining_duplicate_normalized_input_group")
            if output_counts[row["normalized_output"]] > 1:
                reasons.append("remaining_duplicate_normalized_output_group")
            decision = "duplicate_group_quarantined" if reasons else "candidate_only"
        inventory.append(
            {
                "row_fingerprint_sha256": row["fingerprint"],
                "decision": decision,
                "reason_codes": reasons,
                "training_eligible": False,
            }
        )
    inventory.sort(key=lambda row: row["row_fingerprint_sha256"])
    observed = Counter(row["decision"] for row in inventory)
    unresolved = sum(row["decision"] not in DECISIONS for row in inventory)
    counts = {
        "total_replay_rows": len(replay_rows),
        "historical_type_b_overlap_blocked": observed[
            "historical_type_b_overlap_blocked"
        ],
        "post_overlap_rows": len(post_overlap),
        "invalid_normalization_quarantined": observed[
            "invalid_normalization_quarantined"
        ],
        "duplicate_group_quarantined": observed["duplicate_group_quarantined"],
        "candidate_only": observed["candidate_only"],
        "training_eligible": sum(bool(row["training_eligible"]) for row in inventory),
        "unresolved": unresolved,
        "duplicate_canonical_replay_rows": duplicate_canonical,
        "fallback_normalized_historical_fields": historical_fallback_fields,
        "fallback_normalized_replay_fields": sum(
            identity[0] == "full_symbol_fallback"
            for row in intermediate
            for identity in (row["normalized_input"], row["normalized_output"])
        ),
        "fallback_normalized_replay_rows": sum(
            "full_symbol_fallback"
            in {row["normalized_input"][0], row["normalized_output"][0]}
            for row in intermediate
        ),
    }
    return inventory, counts


def encode_inventory(rows: list[dict[str, Any]]) -> bytes:
    return b"".join(canonical_json(row) for row in rows)


def write_exclusive(path: Path, value: bytes) -> None:
    with path.open("xb") as handle:
        written = handle.write(value)
        if written != len(value):
            raise OSError("short evidence write")
        handle.flush()
        os.fsync(handle.fileno())


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def build_bundle(
    contract_path: Path,
    output: Path,
    expected_head: str,
    *,
    repo_root: Path = REPO_ROOT,
    script_path: Path = SCRIPT_PATH,
    normalizer_path: Path = NORMALIZER_PATH,
) -> dict[str, Any]:
    repo_root = repo_root.resolve()
    contract_path = contract_path.resolve()
    output = output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("output bundle already exists; refusing to overwrite evidence")
    if not output.parent.is_dir():
        raise ValueError("output bundle parent directory must already exist")
    require_ignored_output(output, repo_root)
    tracked_paths = (script_path, normalizer_path, contract_path)
    execution_head = validate_git_state(expected_head, repo_root, tracked_paths)

    contract_bytes, contract_sha = read_once(contract_path)
    try:
        contract = json.loads(contract_bytes)
    except json.JSONDecodeError as error:
        raise ValueError("inventory contract is not valid JSON") from error
    if not isinstance(contract, dict):
        raise ValueError("inventory contract must be an object")
    validate_contract(contract)
    tool_receipts = validate_bindings(
        contract, repo_root, script_path, normalizer_path
    )
    parsed, source_receipts, captured = load_sources(contract, repo_root)
    validate_source_relationships(parsed)
    inventory, counts = make_inventory(
        parsed["replay_training_original"], parsed["historical_type_b_all"]
    )
    if counts != contract["expected_counts"]:
        raise ValueError("observed inventory counts differ from the sealed contract")
    if (
        counts["unresolved"] != 0
        or counts["training_eligible"] != 0
        or any(row["training_eligible"] is not False for row in inventory)
        or any(row["decision"] not in DECISIONS for row in inventory)
    ):
        raise ValueError("inventory contains unresolved or training-eligible candidates")
    inventory_bytes = encode_inventory(inventory)
    receipt_payload: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "publication_strategy": "receipt_last",
        "execution_git_head": execution_head,
        "contract": {
            "path": relative_tracked_path(contract_path, repo_root),
            "sha256": contract_sha,
        },
        "tool_bindings": tool_receipts,
        "normalizer": contract["normalizer"],
        "sources": source_receipts,
        "policy": contract["policy"],
        "observed_counts": counts,
        "inventory": {
            "path": INVENTORY_FILENAME,
            "sha256": sha256_bytes(inventory_bytes),
            "row_count": len(inventory),
        },
    }
    receipt_payload["receipt_payload_sha256"] = sha256_bytes(
        canonical_json(receipt_payload)
    )
    receipt_bytes = canonical_json(receipt_payload)

    output.mkdir()
    try:
        write_exclusive(output / INVENTORY_FILENAME, inventory_bytes)
        for relative, captured_bytes in captured.items():
            if read_once(repo_root / relative)[1] != sha256_bytes(captured_bytes):
                raise ValueError("source changed during inventory publication")
        validate_git_state(expected_head, repo_root, tracked_paths)
        validate_bindings(contract, repo_root, script_path, normalizer_path)
        write_exclusive(output / RECEIPT_FILENAME, receipt_bytes)
        fsync_directory(output)
    except BaseException:
        shutil.rmtree(output, ignore_errors=True)
        raise
    return receipt_payload


def main() -> int:
    args = parse_args()
    try:
        receipt = build_bundle(
            args.contract,
            args.out_bundle,
            args.expected_git_head,
        )
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
    print(
        json.dumps(
            {
                "bundle": str(args.out_bundle),
                "counts": receipt["observed_counts"],
                "receipt_sha256": sha256_bytes(canonical_json(receipt)),
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
