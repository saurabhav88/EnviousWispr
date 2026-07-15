#!/usr/bin/env python3
"""Compare paired EG-1 JSONL outputs without opening benchmark gold answers."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


LIST_LINE_RE = re.compile(r"^\s*(?:[-*•]|\d+[.)])\s+", re.MULTILINE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--baseline-field", default="output")
    parser.add_argument("--candidate-field", default="candidate")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def load_rows(path: Path) -> dict[str, dict]:
    rows: dict[str, dict] = {}
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            row = json.loads(line)
            row_id = str(row["id"])
            if row_id in rows:
                raise ValueError(f"duplicate id {row_id!r} in {path}:{line_number}")
            rows[row_id] = row
    return rows


def canonical(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    return "\n".join(line.rstrip() for line in text.splitlines())


def list_line_count(text: str) -> int:
    return len(LIST_LINE_RE.findall(text))


def main() -> None:
    args = parse_args()
    baseline = load_rows(args.baseline)
    candidate = load_rows(args.candidate)
    baseline_ids = set(baseline)
    candidate_ids = set(candidate)
    if baseline_ids != candidate_ids:
        raise ValueError(
            "paired ids differ: "
            f"missing_candidate={sorted(baseline_ids - candidate_ids)} "
            f"missing_baseline={sorted(candidate_ids - baseline_ids)}"
        )

    changed: list[dict] = []
    exact_matches = 0
    canonical_matches = 0
    list_structure_changes = 0
    for row_id in baseline:
        left = str(baseline[row_id][args.baseline_field])
        right = str(candidate[row_id][args.candidate_field])
        if left == right:
            exact_matches += 1
        if canonical(left) == canonical(right):
            canonical_matches += 1
        if left != right:
            left_lists = list_line_count(left)
            right_lists = list_line_count(right)
            if left_lists != right_lists:
                list_structure_changes += 1
            changed.append(
                {
                    "id": row_id,
                    "baseline_list_lines": left_lists,
                    "candidate_list_lines": right_lists,
                    "baseline": left,
                    "candidate": right,
                }
            )

    report = json.dumps(
        {
            "baseline": str(args.baseline),
            "candidate": str(args.candidate),
            "rows": len(baseline),
            "exact_matches": exact_matches,
            "canonical_matches": canonical_matches,
            "changed": len(changed),
            "list_structure_changes": list_structure_changes,
            "changed_rows": changed,
        },
        ensure_ascii=False,
        indent=2,
    )
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report + "\n", encoding="utf-8")
    else:
        print(report)


if __name__ == "__main__":
    main()
