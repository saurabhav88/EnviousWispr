#!/usr/bin/env python3
"""Recompute aggregate-only Qwen3/EG-1 language evidence without leaking cases.

This audit deliberately refuses to produce a five-language ranking. Existing
artifacts mix prompts, runtimes, judges, task families, and development sets.
The JSON output contains only receipts, counts, rates, and evidence limits.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path
from typing import Any

from eg1_replay_normalizer_v1 import NORMALIZER_VERSION, normalize_text


SCRIPT_PATH = Path(__file__).resolve()
DEFAULT_REPO_ROOT = SCRIPT_PATH.parents[2]
DEFAULT_CONTRACT = SCRIPT_PATH.with_name("contracts") / "qwen3_language_evidence_v1.json"

FORBIDDEN_REPORT_KEYS = {
    "asr_input",
    "candidate_output",
    "changed_or_missing_content",
    "clean_output",
    "context",
    "expected_behavior",
    "expected_notes",
    "expected_output",
    "input",
    "morphology_note",
    "note",
    "notes",
    "output",
    "rationale",
    "raw_transcript",
    "reference_output",
    "required",
    "forbidden",
}


class AuditError(RuntimeError):
    """Raised when pinned evidence changes or is not safely auditable."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_bytes(path: Path, role: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as exc:
        raise AuditError(f"{role}: source unavailable") from exc


def load_contract(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AuditError("contract: invalid or unavailable") from exc
    if not isinstance(value, dict) or value.get("schema_version") != "qwen3-language-evidence-v1":
        raise AuditError("contract: unsupported schema")
    return value


def resolve_source(root: Path, relative: str, role: str) -> Path:
    path = (root / relative).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError as exc:
        raise AuditError(f"{role}: source escapes its evidence root") from exc
    return path


def load_source(root: Path, role: str, spec: dict[str, Any]) -> Any:
    path = resolve_source(root, str(spec.get("path", "")), role)
    data = read_bytes(path, role)
    if sha256_bytes(data) != spec.get("sha256"):
        raise AuditError(f"{role}: SHA-256 mismatch")

    if spec.get("format") == "text":
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise AuditError(f"{role}: invalid UTF-8 text") from exc

    if spec.get("format", "jsonl") == "json":
        try:
            value = json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise AuditError(f"{role}: invalid JSON") from exc
        if not isinstance(value, dict):
            raise AuditError(f"{role}: expected JSON object")
        return value

    rows: list[dict[str, Any]] = []
    try:
        for line in data.splitlines():
            if line.strip():
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise AuditError(f"{role}: expected JSONL objects")
                rows.append(value)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AuditError(f"{role}: invalid JSONL") from exc
    if len(rows) != spec.get("rows"):
        raise AuditError(f"{role}: row-count mismatch")
    return rows


def source_receipt(role: str, spec: dict[str, Any]) -> dict[str, Any]:
    receipt = {
        "role": role,
        "path": spec["path"],
        "sha256": spec["sha256"],
        "format": spec.get("format", "jsonl"),
    }
    if "rows" in spec:
        receipt["rows"] = spec["rows"]
    for key in (
        "source_path",
        "source_commit",
        "source_git_blob_oid",
        "source_sha256",
        "source_section_payload_sha256",
        "variant",
        "model_id",
        "prompt_sha256",
        "prompt_variant",
        "runtime",
        "identity_evidence",
    ):
        if key in spec:
            receipt[key] = spec[key]
    return receipt


def require_string(row: dict[str, Any], key: str, role: str) -> str:
    value = row.get(key)
    if not isinstance(value, str) or not value:
        raise AuditError(f"{role}: invalid {key} field")
    return value


def require_bool(row: dict[str, Any], key: str, role: str) -> bool:
    value = row.get(key)
    if type(value) is not bool:
        raise AuditError(f"{role}: invalid {key} field")
    return value


def simple_normalize(value: str) -> str:
    return " ".join(value.casefold().split())


def case_signature(rows: list[dict[str, Any]], role: str) -> dict[str, str]:
    signatures: dict[str, str] = {}
    for row in rows:
        case_id = require_string(row, "id", role)
        if case_id in signatures:
            raise AuditError(f"{role}: duplicate case ID")
        field = "input" if isinstance(row.get("input"), str) else "asr_input"
        text = require_string(row, field, role)
        signatures[case_id] = sha256_bytes(normalize_text(text).encode("utf-8"))
    return signatures


def assert_same_cases(
    left: list[dict[str, Any]],
    left_role: str,
    right: list[dict[str, Any]],
    right_role: str,
) -> None:
    if case_signature(left, left_role) != case_signature(right, right_role):
        raise AuditError(f"{left_role}/{right_role}: case-set mismatch")


def wilson_95(count: int, total: int) -> list[float]:
    if total <= 0 or not 0 <= count <= total:
        raise AuditError("metric: invalid binomial count")
    z = 1.959963984540054
    p = count / total
    denominator = 1 + z * z / total
    center = (p + z * z / (2 * total)) / denominator
    radius = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total)) / denominator
    return [round(max(0.0, center - radius), 6), round(min(1.0, center + radius), 6)]


def metric(count: int, total: int) -> dict[str, Any]:
    return {
        "count": count,
        "total": total,
        "rate": round(count / total, 6),
        "wilson_95": wilson_95(count, total),
    }


def aggregate_legacy(
    rows: list[dict[str, Any]], role: str
) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, int]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        language = require_string(row, "lang", role)
        judge = row.get("judge")
        if not isinstance(judge, dict):
            raise AuditError(f"{role}: invalid judge field")
        for key in ("language_kept", "meaning_ok", "polish_ok"):
            require_bool(judge, key, role)
        grouped.setdefault(language, []).append(judge)

    report: dict[str, dict[str, Any]] = {}
    raw: dict[str, dict[str, int]] = {}
    for language, judges in sorted(grouped.items()):
        total = len(judges)
        counts = {
            "language_kept": sum(judge["language_kept"] for judge in judges),
            "meaning_ok": sum(judge["meaning_ok"] for judge in judges),
            "polish_ok": sum(judge["polish_ok"] for judge in judges),
            "strict_conjunction": sum(
                judge["language_kept"] and judge["meaning_ok"] and judge["polish_ok"]
                for judge in judges
            ),
        }
        raw[language] = {"total": total, **counts}
        report[language] = {name: metric(count, total) for name, count in counts.items()}
    return report, raw


def replace_language_slice(
    rows: list[dict[str, Any]],
    replacements: list[dict[str, Any]],
    language: str,
    role: str,
) -> list[dict[str, Any]]:
    replacement_map = {
        require_string(row, "id", role): row for row in replacements
    }
    target_ids = {
        require_string(row, "id", role)
        for row in rows
        if row.get("lang") == language
    }
    if target_ids != set(replacement_map):
        raise AuditError(f"{role}: replacement slice mismatch")
    return [replacement_map[row["id"]] if row.get("lang") == language else row for row in rows]


def aggregate_ru(
    rows: list[dict[str, Any]], role: str, spec: dict[str, Any]
) -> tuple[dict[str, Any], int]:
    strict = 0
    list_rows = 0
    list_structure = 0
    list_strict = 0
    for row in rows:
        if row.get("model_id") != spec.get("model_id"):
            raise AuditError(f"{role}: embedded model identity mismatch")
        if row.get("prompt_sha256") != spec.get("prompt_sha256"):
            raise AuditError(f"{role}: embedded prompt identity mismatch")
        score = row.get("deterministic_score")
        if not isinstance(score, dict):
            raise AuditError(f"{role}: missing deterministic score")
        strict_pass = require_bool(score, "strict_deterministic_pass", role)
        strict += strict_pass
        categories = row.get("categories")
        if not isinstance(categories, list) or not all(isinstance(item, str) for item in categories):
            raise AuditError(f"{role}: invalid categories field")
        if any(item.startswith("list_") for item in categories):
            list_rows += 1
            list_structure += require_bool(score, "structure_ok", role)
            list_strict += strict_pass
    total = len(rows)
    return {
        "variant": spec["variant"],
        "prompt_variant": spec["prompt_variant"],
        "strict_deterministic_pass": metric(strict, total),
        "list_case_count": list_rows,
        "list_structure_ok": metric(list_structure, list_rows),
        "list_strict_deterministic_pass": metric(list_strict, list_rows),
        "semantic_quality": "not_recomputable_case_level_scores_missing",
    }, strict


def type_b_counts(rows: list[dict[str, Any]], role: str) -> dict[str, int]:
    ids: set[str] = set()
    for row in rows:
        case_id = require_string(row, "id", role)
        if case_id in ids:
            raise AuditError(f"{role}: duplicate case ID")
        ids.add(case_id)
        for key in ("behavior_correct", "meaning_preserved", "clean_output"):
            require_bool(row, key, role)
        if row.get("severity") not in {"S0", "S1", "S2", "S3", "S4"}:
            raise AuditError(f"{role}: invalid severity")
        if row.get("verdict") not in {
            "pass",
            "minor",
            "soft_fail",
            "major_fail",
            "critical_fail",
        }:
            raise AuditError(f"{role}: invalid verdict")

    def strict(row: dict[str, Any]) -> bool:
        return bool(row["behavior_correct"] and row["meaning_preserved"] and row["clean_output"])

    list_rows = [row for row in rows if row.get("behavior") == "list_format"]
    list_s3_s4 = [row for row in list_rows if row["severity"] in {"S3", "S4"}]
    return {
        "total": len(rows),
        "judge_pass_like": sum(row["verdict"] in {"pass", "minor"} for row in rows),
        "strict_three_green": sum(strict(row) for row in rows),
        "meaning_preserved": sum(row["meaning_preserved"] for row in rows),
        "s3_s4_judge_severity": sum(row["severity"] in {"S3", "S4"} for row in rows),
        "s4_damage": sum(row["severity"] == "S4" for row in rows),
        "list_total": len(list_rows),
        "list_strict_three_green": sum(strict(row) for row in list_rows),
        "list_behavior_correct": sum(row["behavior_correct"] for row in list_rows),
        "list_meaning_preserved": sum(row["meaning_preserved"] for row in list_rows),
        "list_s3_s4_judge_severity": len(list_s3_s4),
        "list_s3_s4_with_meaning_preserved": sum(
            row["meaning_preserved"] for row in list_s3_s4
        ),
        "list_s3_s4_with_behavior_incorrect": sum(
            not row["behavior_correct"] for row in list_s3_s4
        ),
        "list_s3_s4_with_clean_output_false": sum(
            not row["clean_output"] for row in list_s3_s4
        ),
    }


def type_b_report(counts: dict[str, int]) -> dict[str, Any]:
    total = counts["total"]
    list_total = counts["list_total"]
    report: dict[str, Any] = {"total": total, "list_total": list_total}
    for key, count in counts.items():
        if key in {"total", "list_total"}:
            continue
        if key.startswith("list_s3_s4_with_"):
            denominator = counts["list_s3_s4_judge_severity"]
        else:
            denominator = list_total if key.startswith("list_") else total
        report[key] = metric(count, denominator)
    report["metric_definition"] = {
        "judge_pass_like": "verdict is pass or minor",
        "strict_three_green": "behavior_correct AND meaning_preserved AND clean_output",
        "s3_s4_judge_severity": "judge severity is S3 or S4; this can be caused by a required-behavior failure even when the separate meaning_preserved flag is true",
    }
    return report


def parse_base_run_005_receipt(
    receipt: dict[str, Any], spec: dict[str, Any]
) -> dict[str, Any]:
    if receipt.get("schema_version") != "qwen3-base-run-005-aggregate-v1":
        raise AuditError("base_run_005_receipt: unsupported schema")
    source = receipt.get("source")
    expected_source = {
        "path": spec.get("source_path"),
        "producing_commit": spec.get("source_commit"),
        "git_blob_oid": spec.get("source_git_blob_oid"),
        "sha256": spec.get("source_sha256"),
        "section_start": spec.get("source_section_start"),
        "section_end": spec.get("source_section_end"),
        "section_payload_sha256": spec.get("source_section_payload_sha256"),
    }
    if source != expected_source:
        raise AuditError("base_run_005_receipt: source provenance mismatch")
    if re.fullmatch(r"[0-9a-f]{40}", str(source["producing_commit"])) is None:
        raise AuditError("base_run_005_receipt: invalid source commit")
    if re.fullmatch(r"[0-9a-f]{40,64}", str(source["git_blob_oid"])) is None:
        raise AuditError("base_run_005_receipt: invalid source blob OID")
    for key in ("sha256", "section_payload_sha256"):
        if re.fullmatch(r"[0-9a-f]{64}", str(source[key])) is None:
            raise AuditError(f"base_run_005_receipt: invalid {key}")

    aggregate = receipt.get("aggregate")
    if not isinstance(aggregate, dict):
        raise AuditError("base_run_005_receipt: aggregate missing")
    overall = aggregate.get("overall")
    strict_by_language = aggregate.get("strict_by_language")
    english_twoitem = aggregate.get("english_twoitem")
    expected_overall_keys = {
        "total",
        "same_language",
        "meaning_safe",
        "cleanup",
        "grammar",
        "damaging",
        "strict",
    }
    if not isinstance(overall, dict) or set(overall) != expected_overall_keys:
        raise AuditError("base_run_005_receipt: invalid overall aggregate")
    if (
        not isinstance(strict_by_language, dict)
        or set(strict_by_language) != {"de", "es", "fr", "pt", "hi", "ja", "zh"}
    ):
        raise AuditError("base_run_005_receipt: invalid language aggregate")
    if (
        not isinstance(english_twoitem, dict)
        or set(english_twoitem) != {"total", "meaning_safe", "damaging", "strict"}
    ):
        raise AuditError("base_run_005_receipt: invalid English aggregate")
    if overall.get("total") != 56 or english_twoitem.get("total") != 20:
        raise AuditError("base_run_005_receipt: invalid denominators")
    if any(type(value) is not int or not 0 <= value <= 56 for value in overall.values()):
        raise AuditError("base_run_005_receipt: invalid overall count")
    if any(
        type(value) is not int or not 0 <= value <= 8
        for value in strict_by_language.values()
    ):
        raise AuditError("base_run_005_receipt: invalid language count")
    if any(
        type(value) is not int or not 0 <= value <= 20
        for value in english_twoitem.values()
    ):
        raise AuditError("base_run_005_receipt: invalid English count")
    return aggregate


def leakage_counts(
    corpus: list[dict[str, Any]], training: list[dict[str, Any]]
) -> dict[str, int]:
    training_ids = {require_string(row, "id", "eg1_training_v2") for row in training}
    if len(training_ids) != len(training):
        raise AuditError("eg1_training_v2: duplicate ID")
    training_simple = {
        simple_normalize(require_string(row, "input", "eg1_training_v2")) for row in training
    }
    training_conservative = {
        normalize_text(require_string(row, "input", "eg1_training_v2")) for row in training
    }

    graph: dict[str, set[str]] = {}
    exact_id = 0
    simple_overlap = 0
    conservative_overlap = 0
    conservative_match_nodes: set[str] = set()
    for row in corpus:
        case_id = require_string(row, "id", "type_b_corpus")
        origin = require_string(row, "origin", "type_b_corpus")
        graph.setdefault(case_id, set()).add(origin)
        graph.setdefault(origin, set()).add(case_id)
        text = require_string(row, "asr_input", "type_b_corpus")
        exact_id += case_id in training_ids
        simple_overlap += simple_normalize(text) in training_simple
        conservative_match = normalize_text(text) in training_conservative
        conservative_overlap += conservative_match
        if conservative_match:
            conservative_match_nodes.update((case_id, origin))

    def transitive_exposure(seeds: set[str]) -> int:
        exposed_nodes = set(seeds)
        frontier = list(seeds)
        while frontier:
            node = frontier.pop()
            for neighbor in graph.get(node, ()):
                if neighbor not in exposed_nodes:
                    exposed_nodes.add(neighbor)
                    frontier.append(neighbor)
        return sum(
            row["id"] in exposed_nodes or row["origin"] in exposed_nodes
            for row in corpus
        )

    return {
        "exact_id_overlap": exact_id,
        "simple_normalized_input_overlap": simple_overlap,
        "conservative_normalized_input_overlap": conservative_overlap,
        "id_origin_family_exposed": transitive_exposure(training_ids),
        "normalized_seeded_family_exposed": transitive_exposure(
            training_ids | conservative_match_nodes
        ),
    }


TWOITEM_BULLET_RE = re.compile(r"^\s*[-*•]\s+\S")
OVERFLOW_LIST_LINE_RE = re.compile(r"^\s*(?:[-*•]|\d+[.)])\s+\S")


def phrase_normalize(text: str) -> str:
    value = unicodedata.normalize("NFKC", text).casefold()
    value = value.replace("’", "'").replace("–", "-").replace("—", "-")
    value = re.sub(r"[-_/]", " ", value)
    value = re.sub(r"[^\w$%.']+", " ", value)
    return " ".join(value.split())


def contains_phrase(text: str, phrase: str) -> bool:
    needle = phrase_normalize(phrase)
    return bool(needle) and f" {needle} " in f" {phrase_normalize(text)} "


def twoitem_structure_ok(output: str) -> bool:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    bullets = [line for line in lines if TWOITEM_BULLET_RE.match(line)]
    bare_list = len(lines) == 2 and len(bullets) == 2
    headed_list = (
        len(lines) == 3
        and not TWOITEM_BULLET_RE.match(lines[0])
        and (lines[0].endswith(":") or lines[0].endswith("—"))
        and all(TWOITEM_BULLET_RE.match(line) for line in lines[1:])
    )
    return bare_list or headed_list


def recompute_twoitem_counts(
    shards: list[list[dict[str, Any]]], role: str, spec: dict[str, Any]
) -> dict[str, int]:
    rows = [row for shard in shards for row in shard]
    signatures = case_signature(rows, role)
    if len(signatures) != len(rows):
        raise AuditError(f"{role}: duplicate ID across candidate shards")
    counts = Counter(total=len(rows))
    for row in rows:
        if row.get("model_id") != spec.get("model_id"):
            raise AuditError(f"{role}: embedded model identity mismatch")
        if row.get("prompt_sha256") != spec.get("prompt_sha256"):
            raise AuditError(f"{role}: embedded prompt identity mismatch")
        output = require_string(row, "output", role).strip()
        required = row.get("required")
        forbidden = row.get("forbidden")
        if not isinstance(required, list) or not all(isinstance(v, str) for v in required):
            raise AuditError(f"{role}: required phrases missing")
        if not isinstance(forbidden, list) or not all(isinstance(v, str) for v in forbidden):
            raise AuditError(f"{role}: forbidden phrases missing")
        structure_ok = twoitem_structure_ok(output)
        required_ok = all(contains_phrase(output, phrase) for phrase in required)
        forbidden_ok = not any(contains_phrase(output, phrase) for phrase in forbidden)
        counts["structure_ok"] += structure_ok
        counts["required_ok"] += required_ok
        counts["forbidden_ok"] += forbidden_ok
        counts["strict"] += structure_ok and required_ok and forbidden_ok
    return {
        key: counts[key]
        for key in ("total", "strict", "structure_ok", "required_ok", "forbidden_ok")
    }


def recompute_overflow_counts(
    positive: list[dict[str, Any]],
    traps: list[dict[str, Any]],
    role: str,
    spec: dict[str, Any],
) -> dict[str, int]:
    if len(case_signature(positive, role)) != len(positive):
        raise AuditError(f"{role}: duplicate positive ID")
    if len(case_signature(traps, role)) != len(traps):
        raise AuditError(f"{role}: duplicate trap ID")
    for row in positive + traps:
        if row.get("model_id") != spec.get("model_id"):
            raise AuditError(f"{role}: embedded model identity mismatch")
        if row.get("prompt_sha256") != spec.get("prompt_sha256"):
            raise AuditError(f"{role}: embedded prompt identity mismatch")

    def list_lines(row: dict[str, Any]) -> int:
        output = require_string(row, "output", role).strip()
        return sum(bool(OVERFLOW_LIST_LINE_RE.match(line)) for line in output.splitlines())

    activated = 0
    intended_count = 0
    for row in positive:
        count = list_lines(row)
        intended = row.get("item_count")
        if not isinstance(intended, int):
            raise AuditError(f"{role}: item_count missing")
        activated += count >= 2
        intended_count += count == intended
    false_lists = sum(list_lines(row) >= 2 for row in traps)
    return {
        "positive_total": len(positive),
        "activated": activated,
        "intended_count": intended_count,
        "trap_total": len(traps),
        "false_lists": false_lists,
    }


def assert_expected(actual: Any, expected: Any, label: str) -> None:
    if actual != expected:
        raise AuditError(f"{label}: aggregate mismatch")


def assert_private_safe(value: Any, path: tuple[str, ...] = ()) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key in FORBIDDEN_REPORT_KEYS:
                raise AuditError(f"report privacy: forbidden key at {'.'.join(path + (key,))}")
            assert_private_safe(item, path + (str(key),))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            assert_private_safe(item, path + (str(index),))


def build_report(
    contract: dict[str, Any], repo_root: Path, private_root: Path
) -> dict[str, Any]:
    tracked_specs = contract.get("tracked_sources")
    private_specs = contract.get("private_sources")
    if not isinstance(tracked_specs, dict) or not isinstance(private_specs, dict):
        raise AuditError("contract: invalid source registry")

    tracked = {
        role: load_source(repo_root, role, spec) for role, spec in tracked_specs.items()
    }
    private = {
        role: load_source(private_root, role, spec) for role, spec in private_specs.items()
    }
    expected = contract.get("expected_aggregates")
    if not isinstance(expected, dict):
        raise AuditError("contract: expected aggregates missing")

    base_run_005 = parse_base_run_005_receipt(
        tracked["base_run_005_receipt"], tracked_specs["base_run_005_receipt"]
    )
    assert_expected(
        base_run_005,
        expected["qwen_base_run_005_reported"],
        "Qwen base BASE-RUN-005 reported aggregate",
    )

    legacy_cases = private["legacy_ml_cases"]
    legacy_base = private["legacy_base_judged"]
    legacy_eg1 = replace_language_slice(
        private["legacy_eg1_judged"],
        private["legacy_eg1_hi_rejudge"],
        "hi",
        "legacy_eg1_hi_rejudge",
    )
    assert_same_cases(legacy_cases, "legacy_ml_cases", legacy_base, "legacy_base_judged")
    assert_same_cases(legacy_cases, "legacy_ml_cases", legacy_eg1, "legacy_eg1_judged")
    assert_same_cases(
        legacy_cases,
        "legacy_ml_cases",
        tracked["qwen_base_ml56_output"],
        "qwen_base_ml56_output",
    )
    assert_same_cases(
        legacy_cases,
        "legacy_ml_cases",
        tracked["eg1_current_listv2_ml56_output"],
        "eg1_current_listv2_ml56_output",
    )
    for role in ("qwen_base_ml56_output", "eg1_current_listv2_ml56_output"):
        spec = tracked_specs[role]
        for row in tracked[role]:
            if row.get("model_id") != spec.get("model_id"):
                raise AuditError(f"{role}: embedded model identity mismatch")
            if row.get("prompt_sha256") != spec.get("prompt_sha256"):
                raise AuditError(f"{role}: embedded prompt identity mismatch")
    base_legacy_report, base_legacy_raw = aggregate_legacy(legacy_base, "legacy_base_judged")
    eg1_legacy_report, eg1_legacy_raw = aggregate_legacy(legacy_eg1, "legacy_eg1_judged")
    assert_expected(
        {lang: values["strict_conjunction"] for lang, values in base_legacy_raw.items()},
        expected["legacy_base_strict"],
        "legacy_base_strict",
    )
    assert_expected(
        {lang: values["polish_ok"] for lang, values in eg1_legacy_raw.items()},
        expected["legacy_eg1_polish_ok"],
        "legacy_eg1_polish_ok",
    )
    assert_expected(
        {lang: values["strict_conjunction"] for lang, values in eg1_legacy_raw.items()},
        expected["legacy_eg1_strict"],
        "legacy_eg1_strict",
    )
    base_run_005_report = {
        "evidence_level": "aggregate_only_case_level_semantic_scores_not_retained",
        "review_mode": "independent_model_assisted_development_review",
        "overall": {
            name: metric(count, base_run_005["overall"]["total"])
            for name, count in base_run_005["overall"].items()
            if name != "total"
        },
        "strict_by_language": {
            language: metric(count, 8)
            for language, count in base_run_005["strict_by_language"].items()
        },
        "english_twoitem": {
            name: metric(count, base_run_005["english_twoitem"]["total"])
            for name, count in base_run_005["english_twoitem"].items()
            if name != "total"
        },
        "reproducibility_limit": "counts come from the hash-pinned aggregate receipt with producing-commit provenance and rates are recomputed; semantic row judgments cannot be independently recomputed",
    }

    ru_roles = [role for role in tracked_specs if role.startswith("ru_")]
    ru_reference = tracked[ru_roles[0]]
    ru_report: dict[str, Any] = {}
    ru_strict: dict[str, int] = {}
    for role in ru_roles:
        assert_same_cases(ru_reference, ru_roles[0], tracked[role], role)
        ru_report[role], ru_strict[role] = aggregate_ru(
            tracked[role], role, tracked_specs[role]
        )
    assert_expected(ru_strict, expected["ru_deterministic_strict"], "ru strict")

    candidate_roles = (
        "qwen_base_twoitem_v1a",
        "qwen_base_twoitem_v1b",
        "qwen_base_listpos_overflow100",
        "qwen_base_listtrap_overflow100",
    )
    candidate_identity = {
        (tracked_specs[role].get("model_id"), tracked_specs[role].get("prompt_sha256"))
        for role in candidate_roles
    }
    if len(candidate_identity) != 1 or None in next(iter(candidate_identity)):
        raise AuditError("mechanical candidates: contract identity mismatch")

    twoitem = tracked["qwen_base_twoitem_scores"].get("models", {}).get("qwen3_4b_base")
    structure = tracked["qwen_base_overflow_structure_scores"].get("models", {}).get(
        "qwen3_4b_base"
    )
    if not isinstance(twoitem, dict) or not isinstance(structure, dict):
        raise AuditError("mechanical scores: qwen3 base aggregate missing")
    reported_twoitem_counts = {
        key: twoitem.get(key)
        for key in ("total", "strict", "structure_ok", "required_ok", "forbidden_ok")
    }
    reported_overflow_counts = {
        key: structure.get(key)
        for key in ("positive_total", "activated", "intended_count", "trap_total", "false_lists")
    }
    twoitem_counts = recompute_twoitem_counts(
        [tracked["qwen_base_twoitem_v1a"], tracked["qwen_base_twoitem_v1b"]],
        "qwen_base_twoitem_candidates",
        tracked_specs["qwen_base_twoitem_v1a"],
    )
    overflow_counts = recompute_overflow_counts(
        tracked["qwen_base_listpos_overflow100"],
        tracked["qwen_base_listtrap_overflow100"],
        "qwen_base_overflow_candidates",
        tracked_specs["qwen_base_listpos_overflow100"],
    )
    assert_expected(
        twoitem_counts,
        reported_twoitem_counts,
        "two-item candidate-to-score provenance",
    )
    assert_expected(
        overflow_counts,
        reported_overflow_counts,
        "overflow candidate-to-score provenance",
    )
    assert_expected(twoitem_counts, expected["qwen_base_twoitem"], "two-item mechanical")
    assert_expected(overflow_counts, expected["qwen_base_overflow"], "overflow mechanical")

    leakage = leakage_counts(private["type_b_corpus"], private["eg1_training_v2"])
    assert_expected(leakage, expected["type_b_leakage"], "Type B leakage")

    type_b_reports: dict[str, Any] = {}
    type_b_case_sets: dict[str, Any] = {}
    corpus_ids = set(case_signature(private["type_b_corpus"], "type_b_corpus"))
    for role, expected_counts in expected["type_b_metrics"].items():
        counts = type_b_counts(private[role], role)
        assert_expected(counts, expected_counts, f"{role} metrics")
        scored_ids = {require_string(row, "id", role) for row in private[role]}
        if not scored_ids <= corpus_ids:
            raise AuditError(f"{role}: scores escape pinned Type B corpus")
        type_b_case_sets[role] = {
            "scored": len(scored_ids),
            "missing_from_1890": len(corpus_ids - scored_ids),
            "same_family_as_old_type_b": True,
        }
        type_b_reports[role] = {
            "variant": private_specs[role]["variant"],
            "runtime": private_specs[role]["runtime"],
            "identity_evidence": private_specs[role]["identity_evidence"],
            "metrics": type_b_report(counts),
            "ranking_admissibility": "excluded_old_type_b_training_and_family_exposure",
        }

    ml56_languages = Counter(
        require_string(row, "lang", "qwen_base_ml56_output")
        for row in tracked["qwen_base_ml56_output"]
    )
    if ml56_languages != Counter({lang: 8 for lang in ("de", "es", "fr", "hi", "ja", "pt", "zh")}):
        raise AuditError("qwen_base_ml56_output: language balance mismatch")

    report = {
        "schema_version": contract["schema_version"],
        "audit_status": "pass",
        "privacy": "aggregate_only_no_case_text",
        "normalizer": NORMALIZER_VERSION,
        "priority_languages": contract["priority_languages"],
        "source_receipts": {
            "tracked": [source_receipt(role, spec) for role, spec in tracked_specs.items()],
            "private": [source_receipt(role, spec) for role, spec in private_specs.items()],
        },
        "case_family_accounting": {
            "legacy_ml56": {
                "unique_cases": 56,
                "artifact_arms": 4,
                "independent_case_count": 56,
                "explanation": "legacy base, legacy EG-1, later Qwen base, and current list-v2 outputs reuse the same cases",
            },
            "russian_dev16": {
                "unique_cases": 16,
                "artifact_arms": len(ru_roles),
                "independent_case_count": 16,
                "explanation": "prompt and model arms are paired, not independent samples",
            },
            "old_type_b": type_b_case_sets,
        },
        "strata": {
            "legacy_multilingual_untouched_base": {
                "identity_evidence": private_specs["legacy_base_judged"]["identity_evidence"],
                "runtime_and_prompt": "not_embedded_in_artifact",
                "metrics": base_legacy_report,
                "damage_metric": "unavailable",
            },
            "legacy_multilingual_current_eg1": {
                "identity_evidence": private_specs["legacy_eg1_judged"]["identity_evidence"],
                "runtime_and_prompt": "not_embedded_in_artifact",
                "metrics": eg1_legacy_report,
                "interpretation": "polish_ok is diagnostic and is not pooled with untouched-base strict or meaning metrics",
                "damage_metric": "unavailable",
            },
            "newer_universal_bakeoff_untouched_qwen_base": base_run_005_report,
            "russian_dev16_deterministic": ru_report,
            "untouched_qwen_base_english_list_mechanical": {
                "two_item": {
                    "strict": metric(twoitem_counts["strict"], twoitem_counts["total"]),
                    "structure_ok": metric(twoitem_counts["structure_ok"], twoitem_counts["total"]),
                    "required_ok": metric(twoitem_counts["required_ok"], twoitem_counts["total"]),
                    "forbidden_ok": metric(twoitem_counts["forbidden_ok"], twoitem_counts["total"]),
                },
                "overflow_positive": {
                    "activated": metric(overflow_counts["activated"], overflow_counts["positive_total"]),
                    "intended_count": metric(
                        overflow_counts["intended_count"], overflow_counts["positive_total"]
                    ),
                },
                "overflow_restraint": {
                    "false_lists": metric(
                        overflow_counts["false_lists"], overflow_counts["trap_total"]
                    )
                },
                "semantic_quality": "not_recomputable_case_level_scores_missing",
            },
            "old_english_type_b_development_only": type_b_reports,
        },
        "leakage": {
            "old_type_b_total": len(private["type_b_corpus"]),
            **leakage,
            "english_93_7_quality_ranking": "disqualified",
            "reason": "old Type B is training-exposed and therefore only a development/litmus gate",
        },
        "ranking": {
            "status": "insufficient_evidence",
            "five_language_ranking": None,
            "diagnostic_only": {
                "current_eg1_de_fr_es": "German strongest, French next, Spanish weakest on the shared legacy 8-case slices",
                "russian": "prompt-sensitive and not comparable to the 8-case legacy slices",
                "english": "broad old Type B is disqualified; list-specific exact-Mac evidence remains separate",
            },
            "cross_stratum_disagreement": {
                language: {
                    "legacy_strict": base_legacy_raw[language]["strict_conjunction"],
                    "newer_bakeoff_strict": base_run_005["strict_by_language"][language],
                }
                for language in ("de", "fr", "es")
            },
            "blocking_reasons": [
                "no single balanced suite covers English, German, French, Spanish, and Russian",
                "prompt and runtime variants are mixed",
                "semantic judges and metric definitions are mixed",
                "several semantic aggregates lack retained case-level score artifacts",
                "legacy non-English slices have only eight cases per language",
                "old English Type B is training- and family-exposed",
                "no native-reviewed frozen release evidence exists in these artifacts",
            ],
        },
        "evidence_gaps": [
            "Qwen base ml56 later semantic case scores were not retained",
            "Russian semantic case scores were not retained",
            "current EG-1 later ml56 rescore case scores were not retained",
            "legacy and English judge artifacts do not embed full model, prompt, and runtime identity",
        ],
    }
    assert_private_safe(report)
    return report


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=DEFAULT_REPO_ROOT)
    parser.add_argument(
        "--private-root",
        type=Path,
        default=None,
        help="Root containing ignored historical score artifacts; defaults to --repo-root.",
    )
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--output", type=Path)
    return parser.parse_args(argv)


def write_report_atomic(output_path: Path, payload: str) -> None:
    temporary = output_path.with_name(f".{output_path.name}.tmp-{os.getpid()}")
    try:
        temporary.unlink(missing_ok=True)
        with temporary.open("x", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(output_path)
    except OSError as exc:
        raise AuditError("output: atomic write failed") from exc
    finally:
        temporary.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    output_path = args.output.resolve() if args.output else None
    try:
        if output_path:
            output_path.unlink(missing_ok=True)
        contract = load_contract(args.contract.resolve())
        report = build_report(
            contract,
            args.repo_root.resolve(),
            (args.private_root or args.repo_root).resolve(),
        )
        payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if output_path:
            write_report_atomic(output_path, payload)
        else:
            sys.stdout.write(payload)
    except (AuditError, OSError) as exc:
        if output_path:
            try:
                output_path.unlink(missing_ok=True)
            except OSError:
                sys.stderr.write("audit failed: output cleanup failed\n")
                return 2
        sys.stderr.write(f"audit failed: {exc}\n")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
