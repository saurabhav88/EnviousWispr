#!/usr/bin/env python3
"""Build the model-blind 1,890-slot Type B V2 replacement manifest."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import shutil
from typing import Any


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
APPROVED = REPO_ROOT / "scripts/eval/corpus/type_b_approved_1890.jsonl"
OVERFLOW = REPO_ROOT / "scripts/eval/corpus/type_b_overflow_900.jsonl"
ALL_TYPE_B = REPO_ROOT / "scripts/eval/corpus/type_b_all_v1.jsonl"
TRAINING = REPO_ROOT / "scripts/eval/runs/bakeoff-1265/train_sft_v2.jsonl"
SOURCE_HASHES = {
    APPROVED: "27993adc574242e6bf2aef7430dbc2c6776ebbb6dd547d61f561d4e693d22a6b",
    OVERFLOW: "1267e5c8ccf84ea745bd2b1bcdcac9d912b8dadb8c14ef76515eee24139759fa",
    ALL_TYPE_B: "eb83421b84cd728f8aac96054b4d3518661a40e0c0a33961e3d14b07b118da4d",
    TRAINING: "5afc6b9435c7bef08df17ba3c4edcb889b8329cd7c1520c49d681999a666f568",
}
PROVISIONAL_APPROVED_IDS = (
    "SCT-003",
    "ME-001",
    "TC-001",
    "TC-015",
    "TC-020",
    "TC-029",
    "TC-043",
    "TC-057",
    "TC-071",
    "TC-085",
    "TC-099",
    "TC-113",
    "TC-127",
    "TC-141",
    "TC-155",
    "TC-169",
    "TC-183",
    "TC-211",
    "TC-225",
    "TC-239",
    "TC-253",
    "TC-267",
)
PROVISIONAL_OVERFLOW_IDS = ("SCT-OF-003",)
TARGET_TOTAL = 1890
FRESH_TOTAL = 1867
TRAP_CATEGORIES = {
    "self_correction_trap",
    "list_format_trap",
    "filler_removal_trap",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-bundle", required=True, type=Path)
    parser.add_argument("--seed", type=int, default=1265)
    return parser.parse_args()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_once(path: Path) -> tuple[bytes, str]:
    value = path.read_bytes()
    return value, sha256_bytes(value)


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


def family_id(seed: int, category: str, length_bucket: int, index: int) -> str:
    digest = hashlib.sha256(
        f"type-b-v2|{seed}|{category}|{length_bucket}|{index}".encode()
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

    source_bytes: dict[Path, bytes] = {}
    source_receipts: list[dict[str, Any]] = []
    for path, expected_sha in SOURCE_HASHES.items():
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
    if set(PROVISIONAL_APPROVED_IDS) - set(approved_by_id):
        raise ValueError("a provisional approved ID is missing")
    if set(PROVISIONAL_OVERFLOW_IDS) - set(overflow_by_id):
        raise ValueError("a provisional overflow ID is missing")

    target_cells = Counter(
        (row["category"], int(row["length_bucket"])) for row in approved
    )
    target_category_metadata: dict[str, tuple[str, str]] = {}
    for row in approved:
        metadata = (row["tier"], row["subset"])
        prior = target_category_metadata.setdefault(row["category"], metadata)
        if prior != metadata:
            raise ValueError(f"category metadata is inconsistent: {row['category']}")

    retained_source_rows = [approved_by_id[value] for value in PROVISIONAL_APPROVED_IDS]
    retained_source_rows.extend(overflow_by_id[value] for value in PROVISIONAL_OVERFLOW_IDS)
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
                        args.seed, category, length_bucket, cell_index
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

    manifest_bytes = encode_jsonl(manifest)
    manifest_sha = sha256_bytes(manifest_bytes)
    receipt = {
        "status": "type_b_v2_slots_sealed_text_generation_blocked",
        "seed": args.seed,
        "target_total": TARGET_TOTAL,
        "provisional_retained": len(retained_source_rows),
        "fresh_required": FRESH_TOTAL,
        "candidate_model_output_seen": False,
        "manifest": {
            "path": "manifest.jsonl",
            "sha256": manifest_sha,
            "distributions": distributions(manifest),
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
        for path, expected_sha in SOURCE_HASHES.items():
            if read_once(path)[1] != expected_sha:
                raise RuntimeError(f"source changed during manifest publication: {path}")
        write_exclusive(output / "receipt.json", receipt_bytes)
    except BaseException:
        if created:
            shutil.rmtree(output)
        raise
    print(json.dumps({"slots": len(manifest), "fresh_required": FRESH_TOTAL}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
