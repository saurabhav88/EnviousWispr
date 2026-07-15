#!/usr/bin/env python3
"""Predeclare a checkpoint-order English list pilot without reading outputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import runpy
import time
from dataclasses import asdict
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--generator", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--pilot-count-per-role", type=int, default=75)
    parser.add_argument("--full-count-per-role", type=int, default=100)
    parser.add_argument("--seed", type=int, default=20260715)
    parser.add_argument("--audit-corpus", action="append", default=[])
    parser.add_argument("--prior-batch", action="append", default=[])
    return parser.parse_args()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def distribution(rows: list[dict[str, Any]], field: str) -> dict[str, int]:
    values: dict[str, int] = {}
    for row in rows:
        key = str(row[field])
        values[key] = values.get(key, 0) + 1
    return dict(sorted(values.items()))


def main() -> None:
    args = parse_args()
    if args.pilot_count_per_role <= 0 or args.pilot_count_per_role > args.full_count_per_role:
        raise SystemExit("pilot count must be between 1 and full count")
    generator = Path(args.generator).resolve()
    module = runpy.run_path(str(generator), run_name="pilot_manifest")
    positive = module["balanced_specs"]("positive_list", args.full_count_per_role, args.seed)
    restraint = module["balanced_specs"]("prose_restraint", args.full_count_per_role, args.seed + 1)
    selected = {
        "positive_list": [asdict(spec) for spec in positive[: args.pilot_count_per_role]],
        "prose_restraint": [asdict(spec) for spec in restraint[: args.pilot_count_per_role]],
    }
    sources = []
    for role, paths in (
        ("training_and_eval", args.audit_corpus),
        ("prior_generated_batches", args.prior_batch),
    ):
        for raw_path in paths:
            path = Path(raw_path).resolve()
            if not path.is_file():
                raise SystemExit(f"missing source: {path}")
            sources.append({"role": role, "path": str(path), "sha256": file_sha256(path)})
    definition = {
        "selection_rule": "first_n_checkpoint_order_without_output_inspection",
        "pilot_count_per_role": args.pilot_count_per_role,
        "full_count_per_role": args.full_count_per_role,
        "seed": args.seed,
        "selected_specs": selected,
        "audit_sources": sources,
    }
    axes = ("domain", "case_type", "item_count", "length_bucket", "compound_required")
    manifest = {
        "status": "predeclared_candidate_pilot",
        "created_at_epoch": time.time(),
        "model_blind": True,
        "native_reviewed": False,
        "training_eligible": False,
        "frozen": False,
        "selection_rule": definition["selection_rule"],
        "selection_used_model_outputs": False,
        "generator": str(generator),
        "generator_sha256": file_sha256(generator),
        "pilot_definition_sha256": canonical_sha256(definition),
        "pilot_count_per_role": args.pilot_count_per_role,
        "full_count_per_role": args.full_count_per_role,
        "seed": args.seed,
        "selected_specs": selected,
        "selected_distributions": {
            role: {axis: distribution(rows, axis) for axis in axes}
            for role, rows in selected.items()
        },
        "excluded_from_pilot_but_reserved_for_full_run": {
            "positive_list": [spec.spec_id for spec in positive[args.pilot_count_per_role :]],
            "prose_restraint": [spec.spec_id for spec in restraint[args.pilot_count_per_role :]],
        },
        "audit_sources": sources,
    }
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x", encoding="utf-8") as handle:
        handle.write(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"path": str(output), "sha256": file_sha256(output), "pilot_definition_sha256": manifest["pilot_definition_sha256"]}, indent=2))


if __name__ == "__main__":
    main()
