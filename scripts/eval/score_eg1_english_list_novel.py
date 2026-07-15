#!/usr/bin/env python3
"""Score model-blind English list development cases deterministically.

This scorer checks only audited spans and visible list structure. It does not
provide semantic, native-speaker, frozen-benchmark, or release-quality proof.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import tempfile
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any, Callable


BULLET_RE = re.compile(r"^\s*[-*•]\s+(\S.*)$")
NUMBER_RE = re.compile(r"^\s*(\d+)[.)]\s+(\S.*)$")
AXES = ("domain", "case_type", "item_count", "length_bucket", "compound_required")


def publish_exclusive(
    path: Path, value: bytes, before_link: Callable[[], None] | None = None
) -> None:
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp = Path(temp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        if before_link is not None:
            before_link()
        os.link(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--positive-corpus", type=Path, required=True)
    parser.add_argument("--restraint-corpus", type=Path, required=True)
    parser.add_argument("--candidates", type=Path, nargs="+", required=True)
    parser.add_argument("--out", type=Path, required=True)
    return parser.parse_args()


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError(f"{path}:{line_number}: row is not an object")
            rows.append(row)
    if not rows:
        raise ValueError(f"empty JSONL: {path}")
    return rows


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_inventory(path: Path) -> dict[str, str]:
    return {"path": str(path), "sha256": file_sha256(path)}


def verify_inventory(inventory: dict[str, str]) -> None:
    if file_sha256(Path(inventory["path"])) != inventory["sha256"]:
        raise RuntimeError(f"source changed during scoring: {inventory['path']}")


def normalized(text: str) -> str:
    value = unicodedata.normalize("NFKC", text).casefold()
    value = value.replace("’", "'").replace("–", "-").replace("—", "-")
    value = re.sub(r"[-_/]", " ", value)
    value = re.sub(r"[^\w$%]+", " ", value, flags=re.UNICODE)
    return " ".join(value.split())


def contains_phrase(text: str, phrase: str) -> bool:
    haystack = f" {normalized(text)} "
    needle = normalized(phrase)
    return bool(needle) and f" {needle} " in haystack


def wilson(successes: int, total: int) -> list[float] | None:
    if total == 0:
        return None
    z = 1.959963984540054
    rate = successes / total
    denominator = 1 + z * z / total
    center = (rate + z * z / (2 * total)) / denominator
    margin = z * math.sqrt((rate * (1 - rate) + z * z / (4 * total)) / total) / denominator
    return [center - margin, center + margin]


def metric(successes: int, total: int) -> dict[str, Any]:
    return {
        "successes": successes,
        "total": total,
        "rate": successes / total if total else None,
        "wilson_95": wilson(successes, total),
    }


def load_corpus(path: Path, role: str) -> dict[str, dict[str, Any]]:
    cases: dict[str, dict[str, Any]] = {}
    for line_number, case in enumerate(read_jsonl(path), 1):
        case_id = case.get("id")
        if not isinstance(case_id, str) or not case_id:
            raise ValueError(f"{path}:{line_number}: missing id")
        if case_id in cases:
            raise ValueError(f"{path}:{line_number}: duplicate corpus id {case_id!r}")
        if (
            case.get("split") != "dev"
            or case.get("gold_status") != "candidate_unreviewed"
            or case.get("native_reviewed") is not False
            or case.get("training_eligible") is not False
        ):
            raise ValueError(f"{case_id}: corpus is not development/unreviewed/non-training data")
        if case.get("benchmark_role") != role:
            raise ValueError(f"{case_id}: expected benchmark_role {role!r}")
        for field in ("domain", "case_type", "length_bucket"):
            if not isinstance(case.get(field), str) or not case[field]:
                raise ValueError(f"{case_id}: invalid {field}")
        if not isinstance(case.get("item_count"), int) or case["item_count"] < 1:
            raise ValueError(f"{case_id}: invalid item_count")
        if not isinstance(case.get("compound_required"), bool):
            raise ValueError(f"{case_id}: invalid compound_required")
        for field in ("items", "compound_items", "scope_anchors", "forbidden"):
            if not isinstance(case.get(field), list) or not all(
                isinstance(value, str) and value.strip() for value in case[field]
            ):
                raise ValueError(f"{case_id}: invalid {field}")
        if len(case["items"]) != case["item_count"] or not case["scope_anchors"]:
            raise ValueError(f"{case_id}: audited item/scope coverage is invalid")
        normalized_items = {normalized(value) for value in case["items"]}
        normalized_compounds = {normalized(value) for value in case["compound_items"]}
        if (
            len(normalized_items) != case["item_count"]
            or not normalized_compounds.issubset(normalized_items)
            or case["compound_required"] != bool(case["compound_items"])
        ):
            raise ValueError(f"{case_id}: audited compound/item contract is invalid")
        expected_format = case.get("expected_formatting")
        allowed = {"bullets", "numbered"} if role == "positive_list" else {"prose"}
        if expected_format not in allowed:
            raise ValueError(f"{case_id}: invalid expected_formatting {expected_format!r}")
        cases[case_id] = case
    return cases


def candidate_text(row: dict[str, Any]) -> str:
    value = row.get("output", row.get("candidate"))
    return value.strip() if isinstance(value, str) else ""


def candidate_error(row: dict[str, Any]) -> Any | None:
    value = row.get("error")
    return None if value is None or value == "" else value


def score_candidate(
    case: dict[str, Any],
    row: dict[str, Any],
    scorer: Callable[[dict[str, Any], str], dict[str, Any]],
) -> dict[str, Any]:
    output = candidate_text(row)
    result = scorer(case, output)
    error = candidate_error(row)
    inference_ok = error is None and bool(output)
    result["candidate_error"] = error
    result["empty_output"] = not bool(output)
    result["inference_ok"] = inference_ok
    if not inference_ok:
        result["strict"] = False
    return result


def load_candidates(paths: list[Path]) -> tuple[dict[str, dict[str, dict[str, Any]]], dict[str, list[str]]]:
    grouped: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    sources: dict[str, list[str]] = defaultdict(list)
    for path in paths:
        rows = read_jsonl(path)
        models_in_file: set[str] = set()
        for line_number, row in enumerate(rows, 1):
            model_id = row.get("model_id", path.stem)
            case_id = row.get("id")
            if not isinstance(model_id, str) or not model_id:
                raise ValueError(f"{path}:{line_number}: invalid model_id")
            if not isinstance(case_id, str) or not case_id:
                raise ValueError(f"{path}:{line_number}: invalid id")
            if case_id in grouped[model_id]:
                raise ValueError(f"{model_id}: duplicate candidate id {case_id!r}")
            grouped[model_id][case_id] = row
            models_in_file.add(model_id)
        for model_id in models_in_file:
            sources[model_id].append(str(path))
    return dict(grouped), {key: sorted(value) for key, value in sources.items()}


def line_structure(output: str) -> dict[str, Any]:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    bullets: list[str] = []
    numbered: list[tuple[int, str]] = []
    prose: list[str] = []
    for line in lines:
        bullet = BULLET_RE.match(line)
        number = NUMBER_RE.match(line)
        if bullet:
            bullets.append(bullet.group(1))
        elif number:
            numbered.append((int(number.group(1)), number.group(2)))
        else:
            prose.append(line)
    return {"bullets": bullets, "numbered": numbered, "prose": prose}


def preserved_spans(case: dict[str, Any], output: str) -> dict[str, Any]:
    missing_items = [value for value in case["items"] if not contains_phrase(output, value)]
    missing_scope = [value for value in case["scope_anchors"] if not contains_phrase(output, value)]
    retained_forbidden = [value for value in case["forbidden"] if contains_phrase(output, value)]
    return {
        "missing_items": missing_items,
        "missing_scope_anchors": missing_scope,
        "retained_forbidden": retained_forbidden,
        "items_preserved": not missing_items,
        "scope_preserved": not missing_scope,
        "preservation": not missing_items and not missing_scope,
        "forbidden_cleanup": not retained_forbidden,
        "content_damage": bool(missing_items or missing_scope),
    }


def score_positive(case: dict[str, Any], output: str) -> dict[str, Any]:
    structure = line_structure(output)
    expected = case["expected_formatting"]
    desired_lines = structure["bullets"] if expected == "bullets" else [text for _, text in structure["numbered"]]
    wrong_marker_count = len(structure["numbered"] if expected == "bullets" else structure["bullets"])
    numbering_ok = expected != "numbered" or [number for number, _ in structure["numbered"]] == list(
        range(1, len(structure["numbered"]) + 1)
    )
    header_ok = len(structure["prose"]) <= 1 and (
        not structure["prose"] or structure["prose"][0].endswith(":")
    )
    intended_count = len(desired_lines) == case["item_count"]
    structure_ok = intended_count and wrong_marker_count == 0 and numbering_ok and header_ok
    item_line_hits = {
        item: sum(contains_phrase(line, item) for line in desired_lines) for item in case["items"]
    }
    line_item_hits = [
        [item for item in case["items"] if contains_phrase(line, item)]
        for line in desired_lines
    ]
    compound_line_hits = {
        item: sum(contains_phrase(line, item) for line in desired_lines) for item in case["compound_items"]
    }
    atomic_items = all(count == 1 for count in item_line_hits.values()) and all(
        len(matches) == 1 for matches in line_item_hits
    )
    compound_atomic = all(count == 1 for count in compound_line_hits.values())
    spans = preserved_spans(case, output)
    all_list_lines = len(structure["bullets"]) + len(structure["numbered"])
    strict = structure_ok and atomic_items and spans["preservation"] and spans["forbidden_cleanup"]
    return {
        "id": case["id"],
        "role": "positive_list",
        "activated": all_list_lines >= 2,
        "expected_formatting": expected,
        "bullet_lines": len(structure["bullets"]),
        "numbered_lines": len(structure["numbered"]),
        "wrong_marker_count": wrong_marker_count,
        "numbering_ok": numbering_ok,
        "header_ok": header_ok,
        "intended_count": intended_count,
        "structure_ok": structure_ok,
        "item_line_hits": item_line_hits,
        "line_item_hits": line_item_hits,
        "compound_line_hits": compound_line_hits,
        "atomic_items": atomic_items,
        "compound_atomic": compound_atomic,
        **spans,
        "strict": strict,
    }


def score_restraint(case: dict[str, Any], output: str) -> dict[str, Any]:
    structure = line_structure(output)
    spans = preserved_spans(case, output)
    false_list = bool(structure["bullets"] or structure["numbered"])
    strict = not false_list and spans["preservation"] and spans["forbidden_cleanup"]
    return {
        "id": case["id"],
        "role": "prose_restraint",
        "bullet_lines": len(structure["bullets"]),
        "numbered_lines": len(structure["numbered"]),
        "false_list": false_list,
        **spans,
        "strict": strict,
    }


def metric_set(rows: list[dict[str, Any]], role: str) -> dict[str, Any]:
    total = len(rows)

    def success(row: dict[str, Any], key: str) -> bool:
        return row["inference_ok"] and row[key]

    common = {
        "inference_ok": metric(sum(row["inference_ok"] for row in rows), total),
        "preservation": metric(sum(success(row, "preservation") for row in rows), total),
        "items_preserved": metric(sum(success(row, "items_preserved") for row in rows), total),
        "scope_preserved": metric(sum(success(row, "scope_preserved") for row in rows), total),
        "forbidden_cleanup": metric(sum(success(row, "forbidden_cleanup") for row in rows), total),
        "strict": metric(sum(row["strict"] for row in rows), total),
        "content_damage": metric(
            sum(row["inference_ok"] and row["content_damage"] for row in rows), total
        ),
    }
    if role == "positive_list":
        return {
            "activation": metric(sum(success(row, "activated") for row in rows), total),
            "intended_count": metric(sum(success(row, "intended_count") for row in rows), total),
            "structure": metric(sum(success(row, "structure_ok") for row in rows), total),
            "atomic_items": metric(sum(success(row, "atomic_items") for row in rows), total),
            **common,
        }
    return {
        "no_list": metric(
            sum(row["inference_ok"] and not row["false_list"] for row in rows), total
        ),
        "false_list": metric(
            sum(row["inference_ok"] and row["false_list"] for row in rows), total
        ),
        **common,
    }


def damage_proxies(positive: list[dict[str, Any]], restraint: list[dict[str, Any]]) -> dict[str, Any]:
    def ids(rows: list[dict[str, Any]], predicate: Callable[[dict[str, Any]], bool]) -> list[str]:
        return [row["id"] for row in rows if row["inference_ok"] and predicate(row)]

    return {
        "positive_wrong_marker": ids(positive, lambda row: row["wrong_marker_count"] > 0),
        "positive_count_mismatch": ids(positive, lambda row: not row["intended_count"]),
        "positive_nonatomic_item": ids(positive, lambda row: not row["atomic_items"]),
        "positive_compound_split": ids(positive, lambda row: not row["compound_atomic"]),
        "item_loss": ids([*positive, *restraint], lambda row: not row["items_preserved"]),
        "scope_loss": ids([*positive, *restraint], lambda row: not row["scope_preserved"]),
        "forbidden_retention": ids([*positive, *restraint], lambda row: not row["forbidden_cleanup"]),
        "restraint_false_list": ids(restraint, lambda row: row["false_list"]),
    }


def breakdowns(
    positive_cases: dict[str, dict[str, Any]],
    restraint_cases: dict[str, dict[str, Any]],
    positive: list[dict[str, Any]],
    restraint: list[dict[str, Any]],
) -> dict[str, Any]:
    positive_by_id = {row["id"]: row for row in positive}
    restraint_by_id = {row["id"]: row for row in restraint}
    report: dict[str, Any] = {}
    for axis in AXES:
        values = sorted(
            {str(case[axis]) for case in [*positive_cases.values(), *restraint_cases.values()]}
        )
        report[axis] = {}
        for value in values:
            positive_slice = [
                positive_by_id[case_id]
                for case_id, case in positive_cases.items()
                if str(case[axis]) == value
            ]
            restraint_slice = [
                restraint_by_id[case_id]
                for case_id, case in restraint_cases.items()
                if str(case[axis]) == value
            ]
            report[axis][value] = {
                "positive": metric_set(positive_slice, "positive_list"),
                "restraint": metric_set(restraint_slice, "prose_restraint"),
            }
    return report


def exact_mcnemar_p(a_only: int, b_only: int) -> float:
    discordant = a_only + b_only
    if discordant == 0:
        return 1.0
    tail = sum(math.comb(discordant, index) for index in range(min(a_only, b_only) + 1))
    return min(1.0, 2.0 * tail / (2**discordant))


def paired_counts(
    left: dict[str, dict[str, Any]], right: dict[str, dict[str, Any]], ids: list[str]
) -> dict[str, Any]:
    both_pass = left_only = right_only = both_fail = 0
    for case_id in ids:
        left_pass = bool(left[case_id]["strict"])
        right_pass = bool(right[case_id]["strict"])
        if left_pass and right_pass:
            both_pass += 1
        elif left_pass:
            left_only += 1
        elif right_pass:
            right_only += 1
        else:
            both_fail += 1
    return {
        "both_pass": both_pass,
        "left_only": left_only,
        "right_only": right_only,
        "both_fail": both_fail,
        "discordant": left_only + right_only,
        "exact_mcnemar_p_two_sided": exact_mcnemar_p(left_only, right_only),
    }


def build_report(
    positive_path: Path, restraint_path: Path, candidate_paths: list[Path]
) -> dict[str, Any]:
    scorer_inventory = file_inventory(Path(__file__).resolve())
    positive_inventory = file_inventory(positive_path)
    restraint_inventory = file_inventory(restraint_path)
    candidate_inventories = [
        file_inventory(path) for path in sorted(candidate_paths, key=str)
    ]
    inventories_by_path = {
        inventory["path"]: inventory for inventory in candidate_inventories
    }
    positive_cases = load_corpus(positive_path, "positive_list")
    restraint_cases = load_corpus(restraint_path, "prose_restraint")
    overlap = sorted(set(positive_cases) & set(restraint_cases))
    if overlap:
        raise ValueError(f"corpus IDs overlap: {overlap}")
    expected_ids = set(positive_cases) | set(restraint_cases)
    grouped, sources = load_candidates(candidate_paths)
    scored: dict[str, dict[str, dict[str, Any]]] = {}
    models: dict[str, Any] = {}
    for model_id in sorted(grouped):
        actual_ids = set(grouped[model_id])
        missing = sorted(expected_ids - actual_ids)
        extra = sorted(actual_ids - expected_ids)
        if missing or extra:
            raise ValueError(f"{model_id}: missing={missing}, extra={extra}")
        positive = [
            score_candidate(case, grouped[model_id][case_id], score_positive)
            for case_id, case in positive_cases.items()
        ]
        restraint = [
            score_candidate(case, grouped[model_id][case_id], score_restraint)
            for case_id, case in restraint_cases.items()
        ]
        inference_failure_ids = [
            row["id"] for row in [*positive, *restraint] if not row["inference_ok"]
        ]
        candidate_error_ids = [
            row["id"] for row in [*positive, *restraint] if row["candidate_error"] is not None
        ]
        empty_output_ids = [
            row["id"] for row in [*positive, *restraint] if row["empty_output"]
        ]
        scored[model_id] = {row["id"]: row for row in [*positive, *restraint]}
        models[model_id] = {
            "candidate_paths": sources[model_id],
            "candidate_sources": [inventories_by_path[path] for path in sources[model_id]],
            "inference_failure_count": len(inference_failure_ids),
            "inference_failure_ids": inference_failure_ids,
            "candidate_error_count": len(candidate_error_ids),
            "candidate_error_ids": candidate_error_ids,
            "empty_output_count": len(empty_output_ids),
            "empty_output_ids": empty_output_ids,
            "positive": metric_set(positive, "positive_list"),
            "restraint": metric_set(restraint, "prose_restraint"),
            "damage_proxies": damage_proxies(positive, restraint),
            "breakdowns": breakdowns(
                positive_cases, restraint_cases, positive, restraint
            ),
            "case_results": [*positive, *restraint],
        }

    comparisons: list[dict[str, Any]] = []
    model_ids = sorted(models)
    positive_ids = list(positive_cases)
    restraint_ids = list(restraint_cases)
    for left_index, left_id in enumerate(model_ids):
        for right_id in model_ids[left_index + 1 :]:
            comparisons.append(
                {
                    "left_model": left_id,
                    "right_model": right_id,
                    "positive_strict": paired_counts(
                        scored[left_id], scored[right_id], positive_ids
                    ),
                    "restraint_strict": paired_counts(
                        scored[left_id], scored[right_id], restraint_ids
                    ),
                    "combined_strict_diagnostic_only": paired_counts(
                        scored[left_id], scored[right_id], [*positive_ids, *restraint_ids]
                    ),
                }
            )

    for inventory in [
        scorer_inventory,
        positive_inventory,
        restraint_inventory,
        *candidate_inventories,
    ]:
        verify_inventory(inventory)

    return {
        "status": "development_unreviewed_deterministic_only",
        "frozen": False,
        "native_reviewed": False,
        "semantic_proof": False,
        "release_quality_claim_allowed": False,
        "limitations": [
            "Visible list structure and exact audited spans only.",
            "No semantic, native-speaker, frozen-benchmark, or release-quality proof.",
            "Positive-list and restraint results are co-primary and must remain separate.",
            "Combined strict comparison is diagnostic-only and cannot be a headline percentage.",
        ],
        "reporting_contract": {
            "co_primary_endpoints": [
                "positive.strict",
                "restraint.false_list",
                "restraint.strict",
            ],
            "combined_percentage_allowed": False,
        },
        "scorer_source": scorer_inventory,
        "corpora": {
            "positive": positive_inventory,
            "restraint": restraint_inventory,
            "positive_cases": len(positive_cases),
            "restraint_cases": len(restraint_cases),
        },
        "candidate_sources": candidate_inventories,
        "models": models,
        "paired_comparisons": comparisons,
    }


def main() -> None:
    args = parse_args()
    if args.out.exists() or args.out.is_symlink():
        raise SystemExit("--out already exists; refusing to overwrite scoring evidence")
    report = build_report(args.positive_corpus, args.restraint_corpus, args.candidates)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    inventories = [
        report["scorer_source"],
        report["corpora"]["positive"],
        report["corpora"]["restraint"],
        *report["candidate_sources"],
    ]
    report_bytes = (
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    publish_exclusive(
        args.out,
        report_bytes,
        before_link=lambda: [verify_inventory(item) for item in inventories],
    )
    print(
        json.dumps(
            {
                model_id: {
                    "positive_strict": values["positive"]["strict"]["successes"],
                    "restraint_false_lists": values["restraint"]["false_list"]["successes"],
                }
                for model_id, values in report["models"].items()
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
