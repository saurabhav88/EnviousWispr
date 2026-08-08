#!/usr/bin/env python3
"""Mechanically score positive-list activation and prose-restraint outputs."""

from __future__ import annotations

import argparse
import json
import math
import re
from collections import defaultdict
from pathlib import Path
from typing import Any


LIST_LINE_RE = re.compile(r"^\s*(?:[-*•]|\d+[.)])\s+\S")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--positive-corpus", type=Path, required=True)
    parser.add_argument("--trap-corpus", type=Path, required=True)
    parser.add_argument("--positive-candidates", type=Path, nargs="+", required=True)
    parser.add_argument("--trap-candidates", type=Path, nargs="+", required=True)
    parser.add_argument("--out", type=Path, required=True)
    return parser.parse_args()


def rows(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def output_text(row: dict[str, Any]) -> str:
    return str(row.get("output", row.get("candidate", ""))).strip()


def list_lines(text: str) -> int:
    return sum(bool(LIST_LINE_RE.match(line)) for line in text.splitlines())


def wilson(successes: int, total: int) -> list[float]:
    if total == 0:
        return [0.0, 0.0]
    z = 1.959963984540054
    p = successes / total
    denominator = 1 + z * z / total
    center = (p + z * z / (2 * total)) / denominator
    margin = z * math.sqrt((p * (1 - p) + z * z / (4 * total)) / total) / denominator
    return [center - margin, center + margin]


def group(paths: list[Path]) -> dict[str, dict[str, dict[str, Any]]]:
    grouped: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    for path in paths:
        part = rows(path)
        if not part:
            raise ValueError(f"empty candidate file: {path}")
        model_id = str(part[0].get("model_id", path.stem))
        for row in part:
            row_id = str(row["id"])
            if row_id in grouped[model_id]:
                raise ValueError(f"duplicate candidate id {row_id!r} for {model_id}")
            grouped[model_id][row_id] = row
    return grouped


def main() -> None:
    args = parse_args()
    positive = {str(row["id"]): row for row in rows(args.positive_corpus)}
    traps = {str(row["id"]): row for row in rows(args.trap_corpus)}
    positive_groups = group(args.positive_candidates)
    trap_groups = group(args.trap_candidates)
    if set(positive_groups) != set(trap_groups):
        raise ValueError("positive and trap candidate model sets differ")

    report: dict[str, Any] = {
        "positive_corpus": str(args.positive_corpus),
        "trap_corpus": str(args.trap_corpus),
        "models": {},
    }
    for model_id in sorted(positive_groups):
        positive_rows = positive_groups[model_id]
        trap_rows = trap_groups[model_id]
        if set(positive_rows) != set(positive):
            raise ValueError(f"{model_id}: positive IDs do not match corpus")
        if set(trap_rows) != set(traps):
            raise ValueError(f"{model_id}: trap IDs do not match corpus")

        positive_details = []
        for row_id, case in positive.items():
            count = list_lines(output_text(positive_rows[row_id]))
            intended = int(case["item_count"])
            positive_details.append(
                {
                    "id": row_id,
                    "list_lines": count,
                    "intended_items": intended,
                    "activated": count >= 2,
                    "intended_count": count == intended,
                }
            )
        trap_details = []
        for row_id in traps:
            count = list_lines(output_text(trap_rows[row_id]))
            trap_details.append({"id": row_id, "list_lines": count, "false_list": count >= 2})

        activated = sum(item["activated"] for item in positive_details)
        intended_count = sum(item["intended_count"] for item in positive_details)
        false_lists = sum(item["false_list"] for item in trap_details)
        report["models"][model_id] = {
            "positive_total": len(positive_details),
            "activated": activated,
            "activated_wilson_95": wilson(activated, len(positive_details)),
            "intended_count": intended_count,
            "intended_count_wilson_95": wilson(intended_count, len(positive_details)),
            "trap_total": len(trap_details),
            "false_lists": false_lists,
            "restraint": len(trap_details) - false_lists,
            "restraint_wilson_95": wilson(len(trap_details) - false_lists, len(trap_details)),
            "positive_mismatches": [item for item in positive_details if not item["intended_count"]],
            "false_list_cases": [item for item in trap_details if item["false_list"]],
        }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        json.dumps(
            {
                model: {
                    "activated": score["activated"],
                    "intended_count": score["intended_count"],
                    "false_lists": score["false_lists"],
                }
                for model, score in report["models"].items()
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
