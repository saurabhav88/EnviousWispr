#!/usr/bin/env python3
"""Build a per-case randomized arm-blind semantic review packet and sealed map."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import re
import secrets
import shutil
from typing import Any

from eg1_english_list_contract import (
    load_contract,
    require_binding,
    validate_noncertifying_ab_runtime_receipt,
    validate_binding_commit,
)


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
CANONICAL_RUBRIC = (
    REPO_ROOT
    / "docs"
    / "experiments"
    / "eg1-multilingual"
    / "ENGLISH-LIST-SEMANTIC-REVIEW-RUBRIC-V1.md"
)
LABELS = ("output_1", "output_2")
ARMS = ("baseline", "candidate")
EXPECTED_LANE_CASES = 75
UNBLINDER_PATH = REPO_ROOT / "scripts" / "eval" / "unblind_eg1_english_list_semantic_review.py"
CANONICAL_DECISION_CONTRACT = (
    REPO_ROOT
    / "docs"
    / "experiments"
    / "eg1-multilingual"
    / "ENGLISH-LIST-PILOT75-DECISION-CONTRACT-V2.md"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--positive-corpus", required=True, type=Path)
    parser.add_argument("--restraint-corpus", required=True, type=Path)
    parser.add_argument("--ab-bundle", required=True, type=Path)
    parser.add_argument("--expected-ab-receipt-sha256", required=True)
    parser.add_argument("--rubric", required=True, type=Path)
    parser.add_argument("--expected-rubric-sha256", required=True)
    parser.add_argument("--packet-bundle", required=True, type=Path)
    parser.add_argument("--mapping-bundle", required=True, type=Path)
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Optional deterministic test seed. Production defaults to a random 256-bit secret.",
    )
    return parser.parse_args()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_once(path: Path, label: str) -> tuple[bytes, str]:
    try:
        value = path.read_bytes()
    except OSError as error:
        raise ValueError(f"cannot read {label}") from error
    return value, sha256_bytes(value)


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


def require_sha(actual: str, expected: Any, label: str) -> None:
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError(f"expected {label} SHA-256 is invalid")
    if actual != expected:
        raise ValueError(f"{label} differs from its bound SHA-256")


def resolve_recorded_path(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} path is invalid")
    path = Path(value)
    if path.is_absolute():
        return path
    if ".." in path.parts:
        raise ValueError(f"{label} path escapes the repository")
    return REPO_ROOT / path


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


def encode_jsonl(rows: list[dict[str, Any]]) -> bytes:
    return b"".join(
        (json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
        for row in rows
    )


def write_exclusive(path: Path, value: bytes) -> None:
    with path.open("xb") as handle:
        handle.write(value)
        handle.flush()
        os.fsync(handle.fileno())


def corpus_rows(value: bytes, label: str, seen: set[str]) -> list[dict[str, Any]]:
    rows = parse_jsonl(value, label)
    if len(rows) != EXPECTED_LANE_CASES:
        raise ValueError(f"{label} must contain exactly {EXPECTED_LANE_CASES} cases")
    for row in rows:
        case_id = row.get("id")
        transcript = row.get("input")
        if not isinstance(case_id, str) or not case_id or case_id in seen:
            raise ValueError("corpus has an invalid or duplicate case ID")
        if not isinstance(transcript, str) or not transcript.strip():
            raise ValueError(f"{case_id}: corpus has an invalid input")
        seen.add(case_id)
    return rows


def outputs_by_id(value: bytes, expected_ids: list[str], arm: str) -> dict[str, str]:
    rows = parse_jsonl(value, f"{arm} output")
    ids = [row.get("id") for row in rows]
    if ids != expected_ids or len(set(ids)) != len(ids):
        raise ValueError(f"{arm} output IDs/order differ from the corpora")
    outputs: dict[str, str] = {}
    for row in rows:
        value = row.get("candidate")
        if not isinstance(value, str) or not value.strip() or row.get("error") not in (None, ""):
            raise ValueError(f"{arm}:{row.get('id')} is not reviewable")
        outputs[row["id"]] = value
    return outputs


def validate_ab_contract(
    ab: dict[str, Any],
    contract_sha: str,
    bindings: dict[str, str],
    execution_head: str,
    rubric_sha: str,
    builder_sha: str,
    unblinder_sha: str,
) -> None:
    try:
        ab_bindings = ab["provenance"]["bindings"]
        decision_contract = ab["provenance"]["sources"]["decision_contract"]
        ab_git_head = ab["provenance"]["git_head"]
        ab_expected_git_head = ab["provenance"]["expected_git_head"]
    except (KeyError, TypeError) as error:
        raise ValueError("A/B receipt lacks semantic-review contract bindings") from error
    if ab_bindings != bindings:
        raise ValueError("A/B receipt bindings differ from the executable decision contract")
    require_binding(bindings, "blind_packet_builder_sha256", builder_sha)
    require_binding(bindings, "semantic_rubric_sha256", rubric_sha)
    require_binding(bindings, "semantic_unblinder_sha256", unblinder_sha)
    if ab_git_head != execution_head or ab_expected_git_head != execution_head:
        raise ValueError("A/B receipt Git head differs from the binding commit")
    if not isinstance(decision_contract, dict):
        raise ValueError("A/B receipt decision-contract source is invalid")
    contract_path = resolve_recorded_path(decision_contract.get("path"), "decision contract")
    if contract_path.resolve() != CANONICAL_DECISION_CONTRACT.resolve():
        raise ValueError("A/B receipt decision contract is not canonical")
    require_sha(contract_sha, decision_contract.get("sha256"), "decision contract")


def load_bound_ab(
    args: argparse.Namespace,
    positive_sha: str,
    restraint_sha: str,
    expected_ids: list[str],
    rubric_sha: str,
    builder_sha: str,
    unblinder_sha: str,
    contract_sha: str,
    bindings: dict[str, str],
    execution_head: str,
) -> tuple[
    dict[str, Any],
    list[tuple[Path, str, str]],
    str,
]:
    sources: list[tuple[Path, str, str]] = []
    ab_receipt_path = args.ab_bundle / "receipt.json"
    ab_bytes, ab_sha = read_once(ab_receipt_path, "A/B receipt")
    require_sha(ab_sha, args.expected_ab_receipt_sha256, "A/B receipt")
    sources.append((ab_receipt_path, ab_sha, "A/B receipt"))
    ab = parse_json(ab_bytes, "A/B receipt")
    validate_noncertifying_ab_runtime_receipt(ab)

    outputs: dict[str, dict[str, str]] = {}
    for arm in ARMS:
        try:
            record = ab["arms"][arm]
        except (KeyError, TypeError) as error:
            raise ValueError(f"A/B receipt is missing {arm}") from error
        if not isinstance(record, dict) or any(
            (
                record.get("inference_error_count") != 0,
                record.get("empty_output_count") != 0,
                record.get("runner_returncode") != 0,
                record.get("row_count") != len(expected_ids),
            )
        ):
            raise ValueError(f"A/B receipt {arm} failed inference health")
        path = direct_child(args.ab_bundle, record.get("path"), f"{arm} output")
        value, actual_sha = read_once(path, f"{arm} output")
        require_sha(actual_sha, record.get("sha256"), f"{arm} output")
        sources.append((path, actual_sha, f"{arm} output"))
        outputs[arm] = outputs_by_id(value, expected_ids, arm)

    try:
        render_record = ab["provenance"]["render_receipt"]
    except (KeyError, TypeError) as error:
        raise ValueError("A/B receipt does not bind the render receipt") from error
    render_path = resolve_recorded_path(render_record.get("path"), "render receipt")
    render_bytes, render_sha = read_once(render_path, "render receipt")
    require_sha(render_sha, render_record.get("sha256"), "render receipt")
    sources.append((render_path, render_sha, "render receipt"))
    render = parse_json(render_bytes, "render receipt")
    try:
        positive_source = render["sources"]["positive_corpus"]
        restraint_source = render["sources"]["restraint_corpus"]
    except (KeyError, TypeError) as error:
        raise ValueError("render receipt does not bind both corpora") from error
    for supplied, actual_sha, record, label in (
        (args.positive_corpus, positive_sha, positive_source, "positive corpus"),
        (args.restraint_corpus, restraint_sha, restraint_source, "restraint corpus"),
    ):
        recorded = resolve_recorded_path(record.get("path"), label)
        if recorded.resolve() != supplied.resolve():
            raise ValueError(f"supplied {label} is not receipt-bound")
        require_sha(actual_sha, record.get("sha256"), label)

    validate_ab_contract(
        ab,
        contract_sha,
        bindings,
        execution_head,
        rubric_sha,
        builder_sha,
        unblinder_sha,
    )
    sources.append((CANONICAL_DECISION_CONTRACT, contract_sha, "decision contract"))
    return outputs, sources, ab_sha


def lane_reversals(seed: int, lane: str) -> list[bool]:
    seed_width = max(32, (seed.bit_length() + 7) // 8)
    seed_bytes = seed.to_bytes(seed_width, "big")
    derived = hashlib.sha256(seed_bytes + b"\0" + lane.encode("utf-8")).digest()
    rng = random.Random(int.from_bytes(derived, "big"))
    values = [False] * 38 + [True] * 37
    rng.shuffle(values)
    return values


def verify_sources_unchanged(sources: list[tuple[Path, str, str]]) -> None:
    for path, expected, label in sources:
        if read_once(path, label)[1] != expected:
            raise RuntimeError(f"{label} changed before review evidence publication")


def main() -> int:
    args = parse_args()
    if args.rubric.resolve() != CANONICAL_RUBRIC.resolve():
        raise ValueError("rubric path is not canonical")
    for label, path in (
        ("packet bundle", args.packet_bundle),
        ("mapping bundle", args.mapping_bundle),
    ):
        if path.exists() or path.is_symlink():
            raise SystemExit(f"{label} already exists; refusing to overwrite evidence")
        if not path.parent.is_dir():
            raise SystemExit(f"{label} parent directory must already exist")
    if args.packet_bundle.parent.resolve() == args.mapping_bundle.parent.resolve():
        raise ValueError("packet and mapping bundles must have separate parent directories")

    _, rubric_sha = read_once(args.rubric, "rubric")
    if rubric_sha != args.expected_rubric_sha256:
        raise ValueError("rubric differs from its predeclared SHA-256")
    positive_bytes, positive_sha = read_once(args.positive_corpus, "positive corpus")
    restraint_bytes, restraint_sha = read_once(args.restraint_corpus, "restraint corpus")
    seen: set[str] = set()
    lanes = {
        "positive": corpus_rows(positive_bytes, "positive corpus", seen),
        "restraint": corpus_rows(restraint_bytes, "restraint corpus", seen),
    }
    corpus = [*lanes["positive"], *lanes["restraint"]]
    expected_ids = [row["id"] for row in corpus]
    _, builder_sha = read_once(SCRIPT_PATH, "blind packet builder")
    _, unblinder_sha = read_once(UNBLINDER_PATH, "semantic unblinder")
    _, contract_sha, bindings = load_contract(CANONICAL_DECISION_CONTRACT)
    execution_head = validate_binding_commit(
        bindings, CANONICAL_DECISION_CONTRACT, REPO_ROOT
    )
    outputs, bound_sources, ab_sha = load_bound_ab(
        args,
        positive_sha,
        restraint_sha,
        expected_ids,
        rubric_sha,
        builder_sha,
        unblinder_sha,
        contract_sha,
        bindings,
        execution_head,
    )
    all_sources = [
        (args.positive_corpus, positive_sha, "positive corpus"),
        (args.restraint_corpus, restraint_sha, "restraint corpus"),
        (args.rubric, rubric_sha, "rubric"),
        (SCRIPT_PATH, builder_sha, "blind packet builder"),
        (UNBLINDER_PATH, unblinder_sha, "semantic unblinder"),
        *bound_sources,
    ]

    seed = args.seed if args.seed is not None else secrets.randbits(256)
    if seed < 0:
        raise ValueError("seed must be non-negative")
    packet: list[dict[str, Any]] = []
    mapping: list[dict[str, Any]] = []
    lane_assignment_counts: dict[str, dict[str, int]] = {}
    for lane, rows in lanes.items():
        reversals = lane_reversals(seed, lane)
        lane_assignment_counts[lane] = {
            "baseline_as_output_1": reversals.count(False),
            "candidate_as_output_1": reversals.count(True),
        }
        for row, reverse in zip(rows, reversals, strict=True):
            case_id = row["id"]
            arms = ("candidate", "baseline") if reverse else ("baseline", "candidate")
            packet.append(
                {
                    "case_id": case_id,
                    "raw_transcript": row["input"],
                    "output_1": outputs[arms[0]][case_id],
                    "output_2": outputs[arms[1]][case_id],
                }
            )
            mapping.append(
                {
                    "case_id": case_id,
                    "output_1_arm": arms[0],
                    "output_2_arm": arms[1],
                }
            )
    if any(set(row) != {"case_id", "raw_transcript", *LABELS} for row in packet):
        raise RuntimeError("review packet contains forbidden fields")

    packet_bytes = encode_jsonl(packet)
    mapping_bytes = encode_jsonl(mapping)
    packet_sha = sha256_bytes(packet_bytes)
    mapping_sha = sha256_bytes(mapping_bytes)
    mapping_receipt = {
        "status": "sealed_arm_mapping_ready_for_post_review_unblind",
        "case_count": len(mapping),
        "seed_hex": format(seed, "064x"),
        "lane_assignment_counts": lane_assignment_counts,
        "mapping": {"path": "mapping.jsonl", "sha256": mapping_sha},
        "packet_sha256": packet_sha,
        "ab_receipt_sha256": ab_sha,
        "decision_contract": {
            "sha256": contract_sha,
            "bindings": bindings,
            "execution_git_head": execution_head,
        },
        "explicit_arm_names": list(ARMS),
        "publication": "exclusive_private_bundle_receipt_last",
    }
    mapping_receipt_bytes = (
        json.dumps(mapping_receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode()
    mapping_receipt_sha = sha256_bytes(mapping_receipt_bytes)
    packet_receipt = {
        "status": "arm_blind_semantic_packet_ready",
        "case_count": len(packet),
        "labels": list(LABELS),
        "per_case_randomization": True,
        "balanced_assignment_per_lane": {
            lane: [37, 38] for lane in lane_assignment_counts
        },
        "contains_expected_answers": False,
        "contains_arm_mapping": False,
        "contains_prompt_or_model_identity": False,
        "packet": {"path": "packet.jsonl", "sha256": packet_sha},
        "rubric": {
            "path": str(args.rubric),
            "sha256": rubric_sha,
            "expected_sha256": args.expected_rubric_sha256,
        },
        "ab_receipt_sha256": ab_sha,
        "mapping_receipt_sha256": mapping_receipt_sha,
        "mapping_sha256": mapping_sha,
        "decision_contract": {
            "sha256": contract_sha,
            "bindings": bindings,
            "execution_git_head": execution_head,
        },
        "seed_committed_in_separate_mapping_receipt": True,
        "publication": "exclusive_public_bundle_receipt_last",
    }
    packet_receipt_bytes = (
        json.dumps(packet_receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode()
    packet_created = mapping_created = False
    try:
        verify_sources_unchanged(all_sources)
        args.mapping_bundle.mkdir()
        mapping_created = True
        write_exclusive(args.mapping_bundle / "mapping.jsonl", mapping_bytes)
        write_exclusive(args.mapping_bundle / "receipt.json", mapping_receipt_bytes)

        args.packet_bundle.mkdir()
        packet_created = True
        write_exclusive(args.packet_bundle / "packet.jsonl", packet_bytes)
        write_exclusive(args.packet_bundle / "receipt.json", packet_receipt_bytes)
    except BaseException:
        if mapping_created:
            shutil.rmtree(args.mapping_bundle)
        if packet_created:
            shutil.rmtree(args.packet_bundle)
        raise

    print(json.dumps({"cases": len(packet), "packet_sha256": packet_sha}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
