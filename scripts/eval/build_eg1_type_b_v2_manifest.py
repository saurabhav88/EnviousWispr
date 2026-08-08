#!/usr/bin/env python3
"""Build the model-blind 1,890-slot Type B V2 replacement manifest."""

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


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
ALLOCATION_CONTRACT = (
    REPO_ROOT
    / "scripts"
    / "eval"
    / "contracts"
    / "eg1_type_b_v2_allocation_v1.json"
)
APPROVED = REPO_ROOT / "scripts/eval/corpus/type_b_approved_1890.jsonl"
OVERFLOW = REPO_ROOT / "scripts/eval/corpus/type_b_overflow_900.jsonl"
ALL_TYPE_B = REPO_ROOT / "scripts/eval/corpus/type_b_all_v1.jsonl"
TRAINING = REPO_ROOT / "scripts/eval/runs/bakeoff-1265/train_sft_v2.jsonl"
SOURCE_PATHS = (APPROVED, OVERFLOW, ALL_TYPE_B, TRAINING)
SCHEMA_VERSION = "eg1-type-b-v2-allocation-v1"
TARGET_TOTAL = 1890
FRESH_TOTAL = 1867
PROVISIONAL_TOTAL = 23
RESERVE_TOTAL = 23
FRESH_AUTHORSHIP_TOTAL = 1890
ALL_SLOT_RECORDS = 1913
TRAP_CATEGORIES = {
    "self_correction_trap",
    "list_format_trap",
    "filler_removal_trap",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-bundle", required=True, type=Path)
    parser.add_argument("--seed", type=int, default=1265)
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
        raise ValueError("tracked worktree must be clean before slot publication")
    for path in (SCRIPT_PATH, ALLOCATION_CONTRACT):
        relative = str(path.relative_to(REPO_ROOT))
        committed_bytes = git_output("show", f"{actual_head}:{relative}")
        if sha256_bytes(committed_bytes) != read_once(path)[1]:
            raise ValueError(f"committed bytes differ from live file: {relative}")
    return actual_head


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


def distributions(rows: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    return {
        "category": dict(sorted(Counter(str(row["category"]) for row in rows).items())),
        "length_bucket": dict(
            sorted(Counter(str(row["length_bucket"]) for row in rows).items())
        ),
        "trap": dict(sorted(Counter(str(row["trap"]).lower() for row in rows).items())),
        "tier": dict(sorted(Counter(str(row["tier"]) for row in rows).items())),
    }


def joint_cells(rows: list[dict[str, Any]]) -> dict[str, int]:
    return dict(
        sorted(
            (
                f"{category}|{length_bucket}",
                count,
            )
            for (category, length_bucket), count in Counter(
                (str(row["category"]), int(row["length_bucket"])) for row in rows
            ).items()
        )
    )


def trap_count(rows: list[dict[str, Any]]) -> int:
    count = 0
    for row in rows:
        value = row.get("trap")
        count += value if isinstance(value, bool) else row["category"] in TRAP_CATEGORIES
    return count


def family_id(
    seed: int, namespace: str, category: str, length_bucket: int, index: int
) -> str:
    digest = hashlib.sha256(
        f"type-b-v2|{seed}|{namespace}|{category}|{length_bucket}|{index}".encode()
    ).hexdigest()[:20]
    return f"tb2fam-{digest}"


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


def main() -> int:
    args = parse_args()
    output = args.out_bundle
    if output.exists() or output.is_symlink():
        raise SystemExit("--out-bundle already exists; refusing to overwrite evidence")
    if not output.parent.is_dir():
        raise SystemExit("--out-bundle parent directory must already exist")

    execution_git_head = validate_git_state(args.expected_git_head)
    contract_bytes, contract_sha = read_once(ALLOCATION_CONTRACT)
    contract = json.loads(contract_bytes)
    if not isinstance(contract, dict):
        raise ValueError("allocation contract must be an object")
    if contract.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("allocation contract schema changed")
    if contract.get("seed") != args.seed:
        raise ValueError("seed differs from the sealed allocation contract")
    expected_counts = {
        "final_benchmark": TARGET_TOTAL,
        "provisional_legacy": PROVISIONAL_TOTAL,
        "fresh_primary": FRESH_TOTAL,
        "replacement_reserve": RESERVE_TOTAL,
        "fresh_authorship_total": FRESH_AUTHORSHIP_TOTAL,
        "all_slot_records": ALL_SLOT_RECORDS,
    }
    if contract.get("counts") != expected_counts:
        raise ValueError("allocation contract counts changed")
    expected_traps = {
        "final_benchmark": 300,
        "provisional_legacy": 2,
        "fresh_primary": 298,
        "replacement_reserve": 2,
    }
    if contract.get("trap_counts") != expected_traps:
        raise ValueError("allocation contract trap counts changed")
    source_hashes = contract.get("source_sha256")
    expected_source_names = {str(path.relative_to(REPO_ROOT)) for path in SOURCE_PATHS}
    if not isinstance(source_hashes, dict) or set(source_hashes) != expected_source_names:
        raise ValueError("allocation contract source inventory changed")
    provisional_ids = contract.get("provisional_case_ids")
    if (
        not isinstance(provisional_ids, list)
        or len(provisional_ids) != PROVISIONAL_TOTAL
        or len(set(provisional_ids)) != PROVISIONAL_TOTAL
        or not all(isinstance(value, str) and value for value in provisional_ids)
    ):
        raise ValueError("allocation contract provisional IDs are invalid")
    final_joint_cells = contract.get("final_joint_cells")
    provisional_joint_cells = contract.get("provisional_joint_cells")
    if not isinstance(final_joint_cells, dict) or not isinstance(
        provisional_joint_cells, dict
    ):
        raise ValueError("allocation contract joint cells are invalid")

    source_bytes: dict[Path, bytes] = {}
    source_receipts: list[dict[str, Any]] = []
    for path in SOURCE_PATHS:
        expected_sha = source_hashes[str(path.relative_to(REPO_ROOT))]
        value, actual_sha = read_once(path)
        if actual_sha != expected_sha:
            raise ValueError(f"source changed: {path.relative_to(REPO_ROOT)}")
        source_bytes[path] = value
        source_receipts.append(
            {
                "path": str(path.relative_to(REPO_ROOT)),
                "sha256": actual_sha,
                "expected_sha256": expected_sha,
                "row_count": len(rows_from_bytes(value, str(path))),
            }
        )

    approved = rows_from_bytes(source_bytes[APPROVED], "approved Type B")
    overflow = rows_from_bytes(source_bytes[OVERFLOW], "overflow Type B")
    if len(approved) != TARGET_TOTAL or len(overflow) != 900:
        raise ValueError("Type B source row count changed")
    approved_by_id = {row["id"]: row for row in approved}
    overflow_by_id = {row["id"]: row for row in overflow}
    retained_source_rows: list[dict[str, Any]] = []
    for case_id in provisional_ids:
        matches = [
            source[case_id]
            for source in (approved_by_id, overflow_by_id)
            if case_id in source
        ]
        if len(matches) != 1:
            raise ValueError(f"provisional ID must resolve exactly once: {case_id}")
        retained_source_rows.append(matches[0])

    target_cells = Counter(
        (row["category"], int(row["length_bucket"])) for row in approved
    )
    if joint_cells(approved) != final_joint_cells:
        raise ValueError("approved source differs from sealed joint-cell allocation")
    target_category_metadata: dict[str, tuple[str, str]] = {}
    for row in approved:
        metadata = (row["tier"], row["subset"])
        prior = target_category_metadata.setdefault(row["category"], metadata)
        if prior != metadata:
            raise ValueError(f"category metadata is inconsistent: {row['category']}")

    if joint_cells(retained_source_rows) != provisional_joint_cells:
        raise ValueError("provisional sources differ from sealed joint-cell allocation")
    retained_cells = Counter(
        (row["category"], int(row["length_bucket"])) for row in retained_source_rows
    )
    fresh_cells = target_cells - retained_cells
    if sum(fresh_cells.values()) != FRESH_TOTAL:
        raise ValueError("fresh Type B quota does not total 1,867")

    manifest: list[dict[str, Any]] = []
    for row in retained_source_rows:
        tier, subset = target_category_metadata[row["category"]]
        manifest.append(
            {
                "slot_id": f"tb2-retained-{row['id'].lower()}",
                "semantic_family_id": f"provisional-{row['id'].lower()}",
                "source": "provisional_retained_requires_blind_family_review",
                "source_case_id": row["id"],
                "category": row["category"],
                "length_bucket": int(row["length_bucket"]),
                "tier": tier,
                "subset": subset,
                "trap": row["category"] in TRAP_CATEGORIES,
                "author_lane": None,
                "reviewer_lane": "blind_family_review_pending",
                "text_authored": True,
                "benchmark_eligible": False,
                "training_eligible": False,
                "candidate_model_output_seen": False,
            }
        )

    global_index = 0
    for category, length_bucket in sorted(fresh_cells):
        count = fresh_cells[(category, length_bucket)]
        tier, subset = target_category_metadata[category]
        for cell_index in range(count):
            author_index = cell_index % 4
            reviewer_index = (author_index + 1 + (cell_index % 3)) % 4
            manifest.append(
                {
                    "slot_id": f"tb2-fresh-{global_index + 1:04d}",
                    "semantic_family_id": family_id(
                        args.seed, "primary", category, length_bucket, cell_index
                    ),
                    "source": "fresh_model_blind_required",
                    "source_case_id": None,
                    "category": category,
                    "length_bucket": length_bucket,
                    "tier": tier,
                    "subset": subset,
                    "trap": category in TRAP_CATEGORIES,
                    "author_lane": f"author-{author_index + 1}",
                    "reviewer_lane": f"reviewer-{reviewer_index + 1}",
                    "text_authored": False,
                    "benchmark_eligible": False,
                    "training_eligible": False,
                    "candidate_model_output_seen": False,
                }
            )
            global_index += 1
    if len(manifest) != TARGET_TOTAL or len({row["slot_id"] for row in manifest}) != TARGET_TOTAL:
        raise ValueError("replacement manifest slot count/IDs are invalid")
    if len({row["semantic_family_id"] for row in manifest}) != TARGET_TOTAL:
        raise ValueError("replacement semantic family IDs are not unique")
    target_distribution_rows = [
        {
            "category": row["category"],
            "length_bucket": int(row["length_bucket"]),
            "trap": row["category"] in TRAP_CATEGORIES,
            "tier": row["tier"],
        }
        for row in approved
    ]
    if distributions(manifest) != distributions(target_distribution_rows):
        raise ValueError("replacement manifest does not preserve Type B balance")
    if joint_cells(manifest) != final_joint_cells:
        raise ValueError("replacement manifest does not preserve sealed joint cells")
    fresh_rows = [
        row for row in manifest if row["source"] == "fresh_model_blind_required"
    ]
    fresh_joint_cells = joint_cells(fresh_rows)
    if (
        len(fresh_rows) != FRESH_TOTAL
        or trap_count(fresh_rows) != expected_traps["fresh_primary"]
    ):
        raise ValueError("fresh primary allocation is invalid")

    reserves: list[dict[str, Any]] = []
    for index, source_row in enumerate(retained_source_rows, 1):
        category = str(source_row["category"])
        length_bucket = int(source_row["length_bucket"])
        tier, subset = target_category_metadata[category]
        reserves.append(
            {
                "slot_id": f"tb2-reserve-{index:04d}",
                "semantic_family_id": family_id(
                    args.seed, "reserve", category, length_bucket, index - 1
                ),
                "source": "fresh_replacement_reserve_model_blind_required",
                "source_case_id": None,
                "reserved_for_source_case_id": source_row["id"],
                "category": category,
                "length_bucket": length_bucket,
                "tier": tier,
                "subset": subset,
                "trap": category in TRAP_CATEGORIES,
                "author_lane": f"author-{((index - 1) % 4) + 1}",
                "reviewer_lane": f"reviewer-{(index % 4) + 1}",
                "text_authored": False,
                "benchmark_eligible": False,
                "training_eligible": False,
                "candidate_model_output_seen": False,
            }
        )
    if len(reserves) != RESERVE_TOTAL:
        raise ValueError("replacement reserve allocation is invalid")
    if joint_cells(reserves) != provisional_joint_cells:
        raise ValueError("replacement reserves are not same-cell matched")
    if trap_count(reserves) != expected_traps["replacement_reserve"]:
        raise ValueError("replacement reserve trap count is invalid")
    all_family_ids = {
        row["semantic_family_id"] for row in [*manifest, *reserves]
    }
    if len(all_family_ids) != ALL_SLOT_RECORDS:
        raise ValueError("primary and reserve semantic family IDs are not globally unique")

    manifest_bytes = encode_jsonl(manifest)
    manifest_sha = sha256_bytes(manifest_bytes)
    reserve_bytes = encode_jsonl(reserves)
    reserve_sha = sha256_bytes(reserve_bytes)
    _, builder_sha = read_once(SCRIPT_PATH)
    receipt = {
        "status": "type_b_v2_slots_sealed_text_generation_blocked",
        "seed": args.seed,
        "target_total": TARGET_TOTAL,
        "provisional_retained": len(retained_source_rows),
        "fresh_required": FRESH_TOTAL,
        "replacement_reserves": RESERVE_TOTAL,
        "fresh_authorship_total": FRESH_AUTHORSHIP_TOTAL,
        "all_slot_records": ALL_SLOT_RECORDS,
        "candidate_model_output_seen": False,
        "execution_git_head": execution_git_head,
        "allocation_contract": {
            "path": str(ALLOCATION_CONTRACT.relative_to(REPO_ROOT)),
            "sha256": contract_sha,
            "schema_version": SCHEMA_VERSION,
        },
        "builder": {
            "path": str(SCRIPT_PATH.relative_to(REPO_ROOT)),
            "sha256": builder_sha,
        },
        "manifest": {
            "path": "manifest.jsonl",
            "sha256": manifest_sha,
            "distributions": distributions(manifest),
        },
        "replacement_reserve_manifest": {
            "path": "replacement_reserves.jsonl",
            "sha256": reserve_sha,
            "distributions": distributions(reserves),
        },
        "joint_cells": {
            "final_benchmark": joint_cells(manifest),
            "provisional_legacy": joint_cells(retained_source_rows),
            "fresh_primary": fresh_joint_cells,
            "replacement_reserve": joint_cells(reserves),
        },
        "trap_counts": {
            "final_benchmark": trap_count(manifest),
            "provisional_legacy": trap_count(retained_source_rows),
            "fresh_primary": trap_count(fresh_rows),
            "replacement_reserve": trap_count(reserves),
        },
        "sources": source_receipts,
        "eligibility_gate": {
            "provisional_rows_require_blind_family_review_against_4107_rows_without_family_metadata": True,
            "fresh_rows_require_authoring_and_independent_review": True,
            "one_case_per_semantic_family": True,
            "exact_normalized_ngram_embedding_and_human_family_gates_required": True,
            "all_rows_benchmark_eligible_now": False,
        },
        "publication": "exclusive_bundle_receipt_last",
    }
    receipt_bytes = (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode()
    created = False
    try:
        output.mkdir()
        created = True
        write_exclusive(output / "manifest.jsonl", manifest_bytes)
        write_exclusive(output / "replacement_reserves.jsonl", reserve_bytes)
        if read_once(ALLOCATION_CONTRACT)[1] != contract_sha:
            raise RuntimeError("allocation contract changed during manifest publication")
        if read_once(SCRIPT_PATH)[1] != builder_sha:
            raise RuntimeError("builder changed during manifest publication")
        if validate_git_state(args.expected_git_head) != execution_git_head:
            raise RuntimeError("Git state changed during manifest publication")
        for path in SOURCE_PATHS:
            expected_sha = source_hashes[str(path.relative_to(REPO_ROOT))]
            if read_once(path)[1] != expected_sha:
                raise RuntimeError(f"source changed during manifest publication: {path}")
        write_exclusive(output / "receipt.json", receipt_bytes)
    except BaseException:
        if created:
            shutil.rmtree(output)
        raise
    print(
        json.dumps(
            {
                "slots": len(manifest),
                "fresh_required": FRESH_TOTAL,
                "replacement_reserves": len(reserves),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
