#!/usr/bin/env python3
"""Validate and assemble a bounded multilingual EG-1 training smoke set."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import unicodedata
from collections import Counter
from pathlib import Path
from typing import Any


LANGUAGES = {"de", "en", "es", "fr", "ru"}
LIST_CATEGORIES = {"explicit_list", "implicit_list", "ordinal_list"}
LIST_LINE = re.compile(r"^\s*(?:[-*•–—]|\d+[.)])\s+\S", re.MULTILINE)
CYRILLIC = re.compile(r"[\u0400-\u04ff]")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--batch-dir", required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--audit-corpus", action="append", default=[])
    parser.add_argument(
        "--expect",
        action="append",
        default=[],
        metavar="LANG=COUNT",
        help="Required generated-row count for a language; repeat per language.",
    )
    return parser.parse_args()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold()
    return " ".join(text.split())


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            if not isinstance(row, dict):
                raise ValueError(f"{path}:{line_number}: expected a JSON object")
            rows.append(row)
    return rows


def parse_expectations(items: list[str]) -> dict[str, int]:
    expected: dict[str, int] = {}
    for item in items:
        language, separator, raw_count = item.partition("=")
        if not separator or language not in LANGUAGES:
            raise ValueError(f"Invalid --expect value: {item}")
        expected[language] = int(raw_count)
    return expected


def main() -> None:
    args = parse_args()
    baseline_path = Path(args.baseline).resolve()
    batch_dir = Path(args.batch_dir).resolve()
    prompt_path = Path(args.prompt).resolve()
    output_path = Path(args.output).resolve()
    report_path = Path(args.report).resolve()
    expected = parse_expectations(args.expect)

    batch_paths = sorted(
        path.resolve()
        for path in batch_dir.glob("*.jsonl")
        if path.resolve() != output_path
    )
    if not batch_paths:
        raise SystemExit("No generated JSONL batches found")

    errors: list[str] = []
    baseline_rows = read_jsonl(baseline_path)
    baseline_inputs = {normalized(str(row.get("input", ""))) for row in baseline_rows}

    audit_inputs: set[str] = set()
    audit_files: list[dict[str, Any]] = []
    for raw_path in args.audit_corpus:
        path = Path(raw_path).resolve()
        rows = read_jsonl(path)
        audit_inputs.update(normalized(str(row.get("input", ""))) for row in rows)
        audit_files.append(
            {"path": str(path), "sha256": file_sha256(path), "row_count": len(rows)}
        )

    generated_rows: list[dict[str, Any]] = []
    source_files: list[dict[str, Any]] = []
    for path in batch_paths:
        try:
            rows = read_jsonl(path)
        except ValueError as exc:
            errors.append(str(exc))
            continue
        generated_rows.extend(rows)
        source_files.append(
            {"path": str(path), "sha256": file_sha256(path), "row_count": len(rows)}
        )

    id_counts = Counter(str(row.get("id", "")) for row in generated_rows)
    input_counts = Counter(normalized(str(row.get("input", ""))) for row in generated_rows)
    language_counts = Counter(str(row.get("lang", "")) for row in generated_rows)
    category_counts = Counter(
        (str(row.get("lang", "")), str(row.get("primary_category", "")))
        for row in generated_rows
    )

    for row_number, row in enumerate(generated_rows, 1):
        row_id = str(row.get("id", ""))
        language = str(row.get("lang", ""))
        category = str(row.get("primary_category", ""))
        input_text = str(row.get("input", ""))
        output_text = str(row.get("output", ""))
        input_key = normalized(input_text)

        if not row_id:
            errors.append(f"generated row {row_number}: missing id")
        elif language and not row_id.startswith(f"{language}-"):
            errors.append(f"{row_id}: id does not start with language prefix {language}-")
        if row.get("split") != "train":
            errors.append(f"{row_id}: split must be train")
        if language not in LANGUAGES:
            errors.append(f"{row_id}: unsupported language {language!r}")
        if not input_text.strip() or not output_text.strip():
            errors.append(f"{row_id}: input and output must be non-empty")
        if input_key in baseline_inputs:
            errors.append(f"{row_id}: exact normalized input overlaps the baseline training set")
        if input_key in audit_inputs:
            errors.append(f"{row_id}: exact normalized input overlaps an evaluation corpus")
        if language == "ru" and not CYRILLIC.search(input_text + output_text):
            errors.append(f"{row_id}: Russian row contains no Cyrillic text")
        if language != "ru" and CYRILLIC.search(input_text + output_text):
            errors.append(f"{row_id}: non-Russian row unexpectedly contains Cyrillic text")

        list_lines = LIST_LINE.findall(output_text)
        if category in LIST_CATEGORIES and len(list_lines) < 2:
            errors.append(f"{row_id}: {category} output has fewer than two list lines")
        if category == "list_trap" and list_lines:
            errors.append(f"{row_id}: list_trap output incorrectly contains list lines")

    for duplicate_id, count in id_counts.items():
        if not duplicate_id or count > 1:
            errors.append(f"generated id {duplicate_id!r} appears {count} times")
    for duplicate_input, count in input_counts.items():
        if not duplicate_input or count > 1:
            errors.append(f"generated normalized input {duplicate_input!r} appears {count} times")
    for language, count in expected.items():
        actual = language_counts.get(language, 0)
        if actual != count:
            errors.append(f"language {language}: expected {count} generated rows, found {actual}")

    report: dict[str, Any] = {
        "status": "pass" if not errors else "fail",
        "baseline": {
            "path": str(baseline_path),
            "sha256": file_sha256(baseline_path),
            "row_count": len(baseline_rows),
        },
        "prompt": {"path": str(prompt_path), "sha256": file_sha256(prompt_path)},
        "generated_row_count": len(generated_rows),
        "combined_row_count": len(baseline_rows) + len(generated_rows),
        "expected_language_counts": expected,
        "actual_language_counts": dict(sorted(language_counts.items())),
        "category_counts": {
            f"{language}:{category}": count
            for (language, category), count in sorted(category_counts.items())
        },
        "source_files": source_files,
        "audit_corpora": audit_files,
        "errors": errors,
    }

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    if errors:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        raise SystemExit(f"Training-data validation failed with {len(errors)} error(s)")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as handle:
        for row in [*baseline_rows, *generated_rows]:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    report["combined_sha256"] = file_sha256(output_path)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
