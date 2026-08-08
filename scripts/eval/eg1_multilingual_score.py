#!/usr/bin/env python3
"""Deterministic safety/structure scorer for EG-1 multilingual experiments.

This scorer deliberately does not claim fluency or native grammar quality.
Those fields require blinded human review. It answers narrower questions that
can be checked reproducibly: required content, forbidden content, script
retention, and requested list structure.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+")
    parser.add_argument("--details-dir")
    parser.add_argument("--summary-output")
    return parser.parse_args()


def normalize(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).casefold()
    value = value.replace("ё", "е")
    value = value.translate(
        str.maketrans({"«": '"', "»": '"', "“": '"', "”": '"', "—": "-", "–": "-"})
    )
    return re.sub(r"\s+", " ", value).strip()


def contains_phrase(normalized_output: str, phrase: str) -> bool:
    needle = normalize(phrase)
    # List structure and markers are scored independently from item content.
    needle = re.sub(r"^(?:[-*•]|\d+[.)])\s+", "", needle)
    escaped = re.escape(needle).replace(r"\ ", r"\s+")
    return bool(re.search(rf"(?<!\w){escaped}(?!\w)", normalized_output))


def wilson(successes: int, total: int, z: float = 1.96) -> list[float | None]:
    if total == 0:
        return [None, None]
    probability = successes / total
    denominator = 1 + z * z / total
    center = (probability + z * z / (2 * total)) / denominator
    spread = (
        z
        * math.sqrt(probability * (1 - probability) / total + z * z / (4 * total * total))
        / denominator
    )
    return [round(max(0.0, center - spread), 4), round(min(1.0, center + spread), 4)]


def script_retained(lang: str, output: str) -> bool:
    letters = [character for character in output if character.isalpha()]
    if not letters:
        return False
    if lang == "ru":
        target = sum("CYRILLIC" in unicodedata.name(character, "") for character in letters)
        return target / len(letters) >= 0.45
    if lang == "zh":
        target = sum("CJK UNIFIED" in unicodedata.name(character, "") for character in letters)
        return target / len(letters) >= 0.35
    return True


def structure_ok(categories: Iterable[str], output: str) -> bool:
    category_set = set(categories)
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    if "list_bullets" in category_set:
        return sum(bool(re.match(r"^[-*•—–]\s+\S", line)) for line in lines) >= 2
    if "list_numbered" in category_set:
        numbers = []
        for line in lines:
            match = re.match(r"^(\d+)[.)]\s+\S", line)
            if match:
                numbers.append(int(match.group(1)))
        return len(numbers) >= 2 and numbers == list(range(1, len(numbers) + 1))
    if "restraint" in category_set and not ({"quoted_content"} & category_set):
        item_lines = sum(
            bool(re.match(r"^(?:[-*•—–]|\d+[.)])\s+\S", line)) for line in lines
        )
        return item_lines < 2
    return True


def score_row(row: dict[str, Any]) -> dict[str, Any]:
    output = row.get("output", "")
    normalized_output = normalize(output)
    required = row.get("required", [])
    forbidden = row.get("forbidden", [])
    required_results = {
        phrase: contains_phrase(normalized_output, phrase) for phrase in required
    }
    forbidden_results = {
        phrase: not contains_phrase(normalized_output, phrase) for phrase in forbidden
    }
    result = dict(row)
    result["deterministic_score"] = {
        "nonempty": bool(output.strip()),
        "script_retained": script_retained(row.get("lang", ""), output),
        "required_all": all(required_results.values()),
        "forbidden_all": all(forbidden_results.values()),
        "structure_ok": structure_ok(row.get("categories", []), output),
        "required": required_results,
        "forbidden": forbidden_results,
        "native_review_required": True,
    }
    checks = result["deterministic_score"]
    checks["strict_deterministic_pass"] = all(
        checks[key]
        for key in ("nonempty", "script_retained", "required_all", "forbidden_all", "structure_ok")
    )
    return result


def aggregate(rows: list[dict[str, Any]]) -> dict[str, Any]:
    metrics = [
        "nonempty",
        "script_retained",
        "required_all",
        "forbidden_all",
        "structure_ok",
        "strict_deterministic_pass",
    ]
    summary: dict[str, Any] = {
        "run_id": rows[0].get("run_id") if rows else None,
        "model_id": rows[0].get("model_id") if rows else None,
        "n": len(rows),
        "warning": "Deterministic checks only; fluency and grammar still require blinded native review.",
        "metrics": {},
        "by_category": {},
    }
    for metric in metrics:
        successes = sum(bool(row["deterministic_score"][metric]) for row in rows)
        summary["metrics"][metric] = {
            "successes": successes,
            "total": len(rows),
            "rate": round(successes / len(rows), 4) if rows else None,
            "wilson_95": wilson(successes, len(rows)),
        }

    category_rows: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        for category in row.get("categories", []):
            category_rows[category].append(row)
    for category, members in sorted(category_rows.items()):
        successes = sum(
            bool(row["deterministic_score"]["strict_deterministic_pass"])
            for row in members
        )
        summary["by_category"][category] = {
            "successes": successes,
            "total": len(members),
            "rate": round(successes / len(members), 4),
            "wilson_95": wilson(successes, len(members)),
        }
    return summary


def main() -> None:
    args = parse_args()
    details_dir = Path(args.details_dir).resolve() if args.details_dir else None
    if details_dir:
        details_dir.mkdir(parents=True, exist_ok=True)

    summaries: list[dict[str, Any]] = []
    for input_name in args.inputs:
        input_path = Path(input_name).resolve()
        with input_path.open(encoding="utf-8") as handle:
            scored = [score_row(json.loads(line)) for line in handle if line.strip()]
        summary = aggregate(scored)
        summary["input"] = str(input_path)
        summaries.append(summary)
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        if details_dir:
            detail_path = details_dir / f"{input_path.stem}.scored.jsonl"
            with detail_path.open("w", encoding="utf-8") as handle:
                for row in scored:
                    handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    if args.summary_output:
        Path(args.summary_output).resolve().write_text(
            json.dumps(summaries, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )


if __name__ == "__main__":
    main()
