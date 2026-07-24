#!/usr/bin/env python3
"""Validate complete blind judgments and unblind EG-1 semantic A/B results."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
from typing import Any, Callable

from eg1_english_list_contract import (
    load_contract,
    require_binding,
    validate_binding_commit,
)


LABELS = ("output_1", "output_2")
ARMS = ("baseline", "candidate")
SEVERITY = {"S0": 0, "S1": 1, "S2": 2, "S3": 3, "S4": 4}
TAGS = {
    "identity",
    "quantity",
    "timing",
    "negation",
    "scope",
    "attribution",
    "obligation",
    "fabrication",
    "medical",
    "legal",
    "financial",
    "other",
}
SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
BUILDER_PATH = REPO_ROOT / "scripts" / "eval" / "build_eg1_english_list_blind_review.py"
CANONICAL_RUBRIC = (
    REPO_ROOT
    / "docs"
    / "experiments"
    / "eg1-multilingual"
    / "ENGLISH-LIST-SEMANTIC-REVIEW-RUBRIC-V1.md"
)
CANONICAL_DECISION_CONTRACT = (
    REPO_ROOT
    / "docs"
    / "experiments"
    / "eg1-multilingual"
    / "ENGLISH-LIST-PILOT75-DECISION-CONTRACT-V2.md"
)
BOUND_HASH_PATHS = {
    "blind_packet_builder_sha256": BUILDER_PATH,
    "semantic_rubric_sha256": CANONICAL_RUBRIC,
    "semantic_unblinder_sha256": SCRIPT_PATH,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--packet-bundle", required=True, type=Path)
    parser.add_argument("--mapping-bundle", required=True, type=Path)
    parser.add_argument("--judgments", required=True, type=Path)
    parser.add_argument("--expected-packet-receipt-sha256", required=True)
    parser.add_argument("--expected-mapping-receipt-sha256", required=True)
    parser.add_argument("--out", required=True, type=Path)
    return parser.parse_args()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_once(path: Path, label: str) -> tuple[bytes, str]:
    try:
        value = path.read_bytes()
    except OSError as error:
        raise ValueError(f"cannot read {label}") from error
    return value, sha256_bytes(value)


def require_sha(actual: str, expected: Any, label: str) -> None:
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError(f"expected {label} SHA-256 is invalid")
    if actual != expected:
        raise ValueError(f"{label} differs from its bound SHA-256")


def parse_json(value: bytes, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is invalid JSON") from error
    if not isinstance(parsed, dict):
        raise ValueError(f"{label} is not an object")
    return parsed


def parse_jsonl(value: bytes, label: str) -> list[dict[str, Any]]:
    try:
        lines = value.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ValueError(f"{label} is not UTF-8") from error
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"{label}:{line_number} is invalid JSON") from error
        if not isinstance(row, dict):
            raise ValueError(f"{label}:{line_number} is not an object")
        rows.append(row)
    return rows


def direct_child(bundle: Path, value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} path is invalid")
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts or len(relative.parts) != 1:
        raise ValueError(f"{label} path is not a direct bundle child")
    path = bundle / relative
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"{label} is unavailable")
    return path


def validate_judgment(row: dict[str, Any]) -> tuple[str, str]:
    expected_fields = {"case_id", "label", "meaning_damage", "severity", "tags", "note"}
    if set(row) != expected_fields:
        raise ValueError("judgment fields are invalid")
    case_id = row["case_id"]
    label = row["label"]
    if not isinstance(case_id, str) or not case_id or label not in LABELS:
        raise ValueError("judgment case/label is invalid")
    if (
        type(row["meaning_damage"]) is not bool
        or not isinstance(row["severity"], str)
        or row["severity"] not in SEVERITY
    ):
        raise ValueError(f"{case_id}/{label}: judgment damage/severity is invalid")
    if row["meaning_damage"] != (SEVERITY[row["severity"]] >= 2):
        raise ValueError(f"{case_id}/{label}: damage flag disagrees with severity")
    if (
        not isinstance(row["tags"], list)
        or any(not isinstance(tag, str) for tag in row["tags"])
        or len(set(row["tags"])) != len(row["tags"])
        or any(tag not in TAGS for tag in row["tags"])
    ):
        raise ValueError(f"{case_id}/{label}: tags are invalid")
    if not isinstance(row["note"], str) or not row["note"].strip():
        raise ValueError(f"{case_id}/{label}: note is invalid")
    return case_id, label


def verify_bound_files(bindings: dict[str, str]) -> list[tuple[Path, str, str]]:
    sources: list[tuple[Path, str, str]] = []
    for key, path in BOUND_HASH_PATHS.items():
        _, actual = read_once(path, key)
        require_binding(bindings, key, actual)
        sources.append((path, actual, key))
    return sources


def validate_contract_receipt(
    receipt: dict[str, Any],
) -> tuple[str, dict[str, str], str, list[tuple[Path, str, str]]]:
    _, contract_sha, bindings = load_contract(CANONICAL_DECISION_CONTRACT)
    execution_head = validate_binding_commit(
        bindings, CANONICAL_DECISION_CONTRACT, REPO_ROOT
    )
    record = receipt.get("decision_contract")
    if not isinstance(record, dict):
        raise ValueError("packet receipt lacks the executable decision contract")
    require_sha(contract_sha, record.get("sha256"), "decision contract")
    if record.get("bindings") != bindings:
        raise ValueError("packet bindings differ from the executable decision contract")
    if record.get("execution_git_head") != execution_head:
        raise ValueError("packet Git head differs from the binding commit")
    sources = verify_bound_files(bindings)
    sources.append((CANONICAL_DECISION_CONTRACT, contract_sha, "decision contract"))
    return contract_sha, bindings, execution_head, sources


def verify_sources_unchanged(sources: list[tuple[Path, str, str]]) -> None:
    for path, expected, label in sources:
        if read_once(path, label)[1] != expected:
            raise RuntimeError(f"{label} changed before semantic report publication")


def write_atomic_exclusive(
    path: Path, value: bytes, before_link: Callable[[], None] | None = None
) -> None:
    temporary = path.parent / f".{path.name}.{secrets.token_hex(16)}.tmp"
    try:
        with temporary.open("xb") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        if before_link is not None:
            before_link()
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise SystemExit(
                "--out already exists; refusing to overwrite semantic evidence"
            ) from error
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    if args.out.exists() or args.out.is_symlink():
        raise SystemExit("--out already exists; refusing to overwrite semantic evidence")
    if not args.out.parent.is_dir():
        raise SystemExit("--out parent directory must already exist")

    packet_receipt_path = args.packet_bundle / "receipt.json"
    packet_receipt_bytes, packet_receipt_sha = read_once(packet_receipt_path, "packet receipt")
    require_sha(
        packet_receipt_sha, args.expected_packet_receipt_sha256, "packet receipt"
    )
    packet_receipt = parse_json(packet_receipt_bytes, "packet receipt")
    if packet_receipt.get("status") != "arm_blind_semantic_packet_ready":
        raise ValueError("packet receipt is not reviewable")

    packet_path = direct_child(
        args.packet_bundle, packet_receipt["packet"].get("path"), "packet"
    )
    packet_bytes, packet_sha = read_once(packet_path, "packet")
    require_sha(packet_sha, packet_receipt["packet"].get("sha256"), "packet")
    packet = parse_jsonl(packet_bytes, "packet")
    case_ids = [row.get("case_id") for row in packet]
    if (
        len(case_ids) != packet_receipt.get("case_count")
        or len(set(case_ids)) != len(case_ids)
        or any(not isinstance(case_id, str) or not case_id for case_id in case_ids)
        or any(
            set(row) != {"case_id", "raw_transcript", *LABELS}
            or any(
                not isinstance(row[key], str) or not row[key].strip()
                for key in ("raw_transcript", *LABELS)
            )
            for row in packet
        )
    ):
        raise ValueError("packet case coverage is invalid")
    expected_pairs = {(case_id, label) for case_id in case_ids for label in LABELS}

    judgment_bytes, judgment_sha = read_once(args.judgments, "judgments")
    judgments = parse_jsonl(judgment_bytes, "judgments")
    judgment_by_pair: dict[tuple[str, str], dict[str, Any]] = {}
    for row in judgments:
        pair = validate_judgment(row)
        if pair in judgment_by_pair:
            raise ValueError(f"duplicate judgment: {pair[0]}/{pair[1]}")
        judgment_by_pair[pair] = row
    missing = sorted(expected_pairs - set(judgment_by_pair))
    extra = sorted(set(judgment_by_pair) - expected_pairs)
    if missing or extra:
        raise ValueError(f"judgment coverage mismatch: missing={missing}, extra={extra}")

    # The private mapping is deliberately unreadable until every public
    # judgment has passed schema, uniqueness, and complete-coverage checks.
    contract_sha, bindings, execution_head, bound_sources = validate_contract_receipt(
        packet_receipt
    )
    mapping_receipt_path = args.mapping_bundle / "receipt.json"
    mapping_receipt_bytes, mapping_receipt_sha = read_once(
        mapping_receipt_path, "mapping receipt"
    )
    require_sha(
        mapping_receipt_sha, args.expected_mapping_receipt_sha256, "mapping receipt"
    )
    if packet_receipt.get("mapping_receipt_sha256") != mapping_receipt_sha:
        raise ValueError("packet does not bind the mapping receipt")
    mapping_receipt = parse_json(mapping_receipt_bytes, "mapping receipt")
    if mapping_receipt.get("status") != "sealed_arm_mapping_ready_for_post_review_unblind":
        raise ValueError("mapping receipt is not unblindable")
    if mapping_receipt.get("explicit_arm_names") != list(ARMS):
        raise ValueError("mapping arm names are invalid")
    if mapping_receipt.get("packet_sha256") != packet_sha:
        raise ValueError("mapping receipt does not bind the packet")
    if mapping_receipt.get("decision_contract") != packet_receipt.get("decision_contract"):
        raise ValueError("mapping and packet bind different decision contracts")
    if mapping_receipt.get("ab_receipt_sha256") != packet_receipt.get("ab_receipt_sha256"):
        raise ValueError("mapping and packet bind different A/B evidence")

    mapping_path = direct_child(
        args.mapping_bundle, mapping_receipt["mapping"].get("path"), "mapping"
    )
    mapping_bytes, mapping_sha = read_once(mapping_path, "mapping")
    require_sha(mapping_sha, mapping_receipt["mapping"].get("sha256"), "mapping")
    if packet_receipt.get("mapping_sha256") != mapping_sha:
        raise ValueError("packet does not bind the mapping data")
    mapping = parse_jsonl(mapping_bytes, "mapping")
    mapping_by_case: dict[str, dict[str, str]] = {}
    for row in mapping:
        if set(row) != {"case_id", "output_1_arm", "output_2_arm"}:
            raise ValueError("mapping fields are invalid")
        case_id = row["case_id"]
        arms = (row["output_1_arm"], row["output_2_arm"])
        if case_id in mapping_by_case or set(arms) != set(ARMS):
            raise ValueError("mapping case/arms are invalid")
        mapping_by_case[case_id] = {"output_1": arms[0], "output_2": arms[1]}
    if set(mapping_by_case) != set(case_ids):
        raise ValueError("mapping does not cover every packet case exactly once")

    unblinded: list[dict[str, Any]] = []
    candidate_only: list[str] = []
    baseline_only: list[str] = []
    candidate_worse: list[str] = []
    severity_counts = {arm: CounterTemplate() for arm in ARMS}
    for case_id in case_ids:
        by_arm: dict[str, dict[str, Any]] = {}
        for label in LABELS:
            arm = mapping_by_case[case_id][label]
            judgment = judgment_by_pair[(case_id, label)]
            by_arm[arm] = judgment
            severity_counts[arm][judgment["severity"]] += 1
        baseline = by_arm["baseline"]
        candidate = by_arm["candidate"]
        if candidate["meaning_damage"] and not baseline["meaning_damage"]:
            candidate_only.append(case_id)
        if baseline["meaning_damage"] and not candidate["meaning_damage"]:
            baseline_only.append(case_id)
        if (
            candidate["meaning_damage"]
            and SEVERITY[candidate["severity"]] > SEVERITY[baseline["severity"]]
        ):
            candidate_worse.append(case_id)
        unblinded.append(
            {
                "case_id": case_id,
                "baseline": baseline,
                "candidate": candidate,
            }
        )

    semantic_pass = not candidate_only and not candidate_worse
    report = {
        "status": "arm_blind_semantic_review_unblinded",
        "case_count": len(case_ids),
        "judgment_count": len(judgments),
        "coverage_complete": True,
        "candidate_only_meaning_damage_ids": candidate_only,
        "baseline_only_meaning_damage_ids": baseline_only,
        "candidate_worse_severity_ids": candidate_worse,
        "severity_counts": {
            arm: {key: severity_counts[arm][key] for key in SEVERITY} for arm in ARMS
        },
        "semantic_advancement_condition_pass": semantic_pass,
        "sources": {
            "packet_receipt_sha256": packet_receipt_sha,
            "packet_sha256": packet_sha,
            "mapping_receipt_sha256": mapping_receipt_sha,
            "mapping_sha256": mapping_sha,
            "judgments_sha256": judgment_sha,
            "decision_contract_sha256": contract_sha,
            "decision_contract_bindings": bindings,
            "execution_git_head": execution_head,
        },
        "case_results": unblinded,
    }
    publication_sources = [
        (packet_receipt_path, packet_receipt_sha, "packet receipt"),
        (mapping_receipt_path, mapping_receipt_sha, "mapping receipt"),
        (packet_path, packet_sha, "packet"),
        (mapping_path, mapping_sha, "mapping"),
        (args.judgments, judgment_sha, "judgments"),
        *bound_sources,
    ]
    report_bytes = (
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    write_atomic_exclusive(
        args.out,
        report_bytes,
        before_link=lambda: verify_sources_unchanged(publication_sources),
    )
    print(json.dumps({"semantic_pass": semantic_pass, "cases": len(case_ids)}))
    return 0


class CounterTemplate(dict[str, int]):
    def __missing__(self, key: str) -> int:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
