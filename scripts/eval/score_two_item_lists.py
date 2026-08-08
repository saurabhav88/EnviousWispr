#!/usr/bin/env python3
"""Deterministically score audited two-item list development cases.

This scorer is intentionally narrow. It checks only facts that the corpus can
prove mechanically: exactly two bullet lines, no extra prose beyond an optional
header, all audited required phrases, and no audited forbidden phrases. Human or
model-assisted semantic review remains a separate gate.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


BULLET_RE = re.compile(r"^\s*[-*•]\s+\S")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", nargs="+", required=True)
    parser.add_argument("--candidates", nargs="+", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--model-id", help="Force multiple candidate shards into one model group")
    return parser.parse_args()


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def normalized(text: str) -> str:
    value = unicodedata.normalize("NFKC", text).casefold()
    value = value.replace("’", "'").replace("–", "-").replace("—", "-")
    value = re.sub(r"[-_/]", " ", value)
    value = re.sub(r"[^\w$%.']+", " ", value)
    return " ".join(value.split())


def contains_phrase(text: str, phrase: str) -> bool:
    haystack = f" {normalized(text)} "
    needle = normalized(phrase)
    return bool(needle) and f" {needle} " in haystack


def wilson(successes: int, total: int) -> tuple[float, float]:
    if total == 0:
        return 0.0, 0.0
    z = 1.959963984540054
    p = successes / total
    denominator = 1 + z * z / total
    center = (p + z * z / (2 * total)) / denominator
    margin = z * math.sqrt((p * (1 - p) + z * z / (4 * total)) / total) / denominator
    return center - margin, center + margin


def structure_ok(output: str) -> tuple[bool, int, list[str]]:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    bullets = [line for line in lines if BULLET_RE.match(line)]
    other = [line for line in lines if not BULLET_RE.match(line)]
    bare_list = len(lines) == 2 and len(bullets) == 2
    headed_list = (
        len(lines) == 3
        and not BULLET_RE.match(lines[0])
        and (lines[0].endswith(":") or lines[0].endswith("—"))
        and all(BULLET_RE.match(line) for line in lines[1:])
    )
    return bare_list or headed_list, len(bullets), other


def main() -> None:
    args = parse_args()
    cases: dict[str, dict[str, Any]] = {}
    for raw_path in args.corpus:
        for case in read_jsonl(Path(raw_path)):
            if case["id"] in cases:
                raise SystemExit(f"Duplicate corpus id: {case['id']}")
            cases[case["id"]] = case

    grouped_rows: dict[str, list[dict[str, Any]]] = defaultdict(list)
    grouped_paths: dict[str, list[str]] = defaultdict(list)
    for raw_path in args.candidates:
        path = Path(raw_path)
        rows = read_jsonl(path)
        if not rows:
            raise SystemExit(f"Empty candidate file: {path}")
        model_id = args.model_id or str(rows[0].get("model_id", path.stem))
        grouped_rows[model_id].extend(rows)
        grouped_paths[model_id].append(str(path))

    results: dict[str, Any] = {"case_count": len(cases), "models": {}}
    for model_id, rows in grouped_rows.items():
        path_label = ", ".join(grouped_paths[model_id])
        by_id = {row["id"]: row for row in rows}
        if len(by_id) != len(rows):
            raise SystemExit(f"{model_id}: duplicate candidate ids across {path_label}")
        missing = sorted(set(cases) - set(by_id))
        extra = sorted(set(by_id) - set(cases))
        if missing or extra:
            raise SystemExit(f"{model_id}: missing={missing}, extra={extra}")

        details: list[dict[str, Any]] = []
        breakdown: dict[str, Counter[str]] = defaultdict(Counter)
        for case_id, case in cases.items():
            row = by_id[case_id]
            output = str(row.get("output", row.get("candidate", ""))).strip()
            absent_required = [p for p in case["required"] if not contains_phrase(output, p)]
            present_forbidden = [p for p in case["forbidden"] if contains_phrase(output, p)]
            valid_structure, bullet_count, extra_lines = structure_ok(output)
            strict = not absent_required and not present_forbidden and valid_structure
            details.append(
                {
                    "id": case_id,
                    "domain": case["domain"],
                    "list_type": case["list_type"],
                    "structure_ok": valid_structure,
                    "bullet_count": bullet_count,
                    "extra_lines": extra_lines,
                    "absent_required": absent_required,
                    "present_forbidden": present_forbidden,
                    "strict": strict,
                    "output": output,
                }
            )
            for key in (f"domain:{case['domain']}", f"list_type:{case['list_type']}"):
                breakdown[key]["total"] += 1
                breakdown[key]["strict"] += int(strict)

        strict_count = sum(item["strict"] for item in details)
        low, high = wilson(strict_count, len(details))
        results["models"][model_id] = {
            "candidate_paths": grouped_paths[model_id],
            "strict": strict_count,
            "total": len(details),
            "strict_rate": strict_count / len(details),
            "wilson_95": [low, high],
            "structure_ok": sum(item["structure_ok"] for item in details),
            "required_ok": sum(not item["absent_required"] for item in details),
            "forbidden_ok": sum(not item["present_forbidden"] for item in details),
            "breakdown": {key: dict(value) for key, value in sorted(breakdown.items())},
            "failures": [item for item in details if not item["strict"]],
        }

    output_path = Path(args.out)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: {"strict": value["strict"], "total": value["total"]} for key, value in results["models"].items()}, indent=2))


if __name__ == "__main__":
    main()
