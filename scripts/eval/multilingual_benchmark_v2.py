#!/usr/bin/env python3
"""Fail-closed corpus validator and manifest builder for EG-1 multilingual V2.

This tool validates benchmark inputs only. It does not run or inspect models.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any, Iterable, Sequence


SCHEMA_VERSION = "eg1-multilingual-benchmark-v2"
RATING_SCHEMA_VERSION = "eg1-multilingual-benchmark-v2-rating"
VALIDATOR_VERSION = "1.2.0"
LANGUAGES = ("en", "de", "fr", "es", "ru")
SPLITS = ("development", "frozen")
DOMAINS = (
    "work_admin",
    "personal_home",
    "technical_product",
    "medical",
    "legal_financial",
)
BEHAVIORS = (
    "filler_removal",
    "self_correction",
    "native_morphology",
    "punctuation_capitalization",
    "entities_numbers_dates",
    "names_code_switching",
    "topic_shift_long_dictation",
    "mixed_two_to_three_edits",
    "explicit_two_item_list",
    "scoped_two_item_list",
    "natural_three_to_five_item_bullet_list",
    "spoken_ordinals_numbered_list",
    "two_item_prose_restraint",
    "three_plus_item_prose_restraint",
    "quoted_high_risk_instruction_restraint",
    "clean_minimal_edit_restraint",
)
DIFFICULTIES = ("routine", "challenging", "adversarial")
SAFETY_RISKS = ("standard", "medical", "legal", "financial")
LIST_CONTRACTS = (
    "no_list_requirement",
    "activate_bullets",
    "activate_numbered",
    "restrain_prose",
)
SOURCE_TYPES = ("native_original", "shared_concept_local_rewrite")
LEAKAGE_ROLES = ("training", "prior_eval", "blocked_family_registry")
REQUIRED_FROZEN_LEAKAGE_ROLES = frozenset(LEAKAGE_ROLES)
REQUIRED_SCREEN_METHODS = (
    "exact_normalized",
    "token_ngram_jaccard",
    "character_ngram_jaccard",
    "embedding_cosine",
)
RATING_AXES = (
    "same_language",
    "meaning_preserved",
    "requested_cleanup_completed",
    "native_grammar_morphology",
    "entities_preserved",
    "numbers_preserved",
    "timing_preserved",
    "attribution_preserved",
    "list_contract_satisfied",
    "no_damaging_extra_edits",
)
DAMAGE_SEVERITIES = ("S0", "S1", "S2", "S3", "S4")

POSITIVE_LIST_BEHAVIORS = frozenset(BEHAVIORS[8:12])
RESTRAINT_BEHAVIORS = frozenset(BEHAVIORS[12:16])

EXPECTED_LIST_CONTRACT = {
    **{behavior: "no_list_requirement" for behavior in BEHAVIORS[:8]},
    "explicit_two_item_list": "activate_bullets",
    "scoped_two_item_list": "activate_bullets",
    "natural_three_to_five_item_bullet_list": "activate_bullets",
    "spoken_ordinals_numbered_list": "activate_numbered",
    **{behavior: "restrain_prose" for behavior in BEHAVIORS[12:]},
}

RELEASE_COUNTS = {
    "development": {"per_language": 160, "per_behavior": 10, "per_domain": 32},
    "frozen": {"per_language": 320, "per_behavior": 20, "per_domain": 64},
}

IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class BenchmarkValidationError(ValueError):
    """Raised only after all discoverable validation errors are collected."""

    def __init__(self, errors: Sequence[str]):
        self.errors = list(errors)
        super().__init__("\n".join(self.errors))


@dataclass(frozen=True)
class LeakageSource:
    role: str
    name: str
    path: Path
    sha256: str


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_text(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    normalized = "".join(
        character
        if unicodedata.category(character)[0] in {"L", "M", "N"}
        else " "
        for character in normalized
    )
    return " ".join(normalized.split())


def _read_json_or_jsonl(path: Path) -> list[Any]:
    if not path.is_file():
        raise BenchmarkValidationError([f"missing input file: {path}"])
    text = path.read_text(encoding="utf-8")
    stripped = text.lstrip()
    if not stripped:
        raise BenchmarkValidationError([f"empty input file: {path}"])
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        value = None
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return [value]
    rows: list[Any] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise BenchmarkValidationError(
                [f"{path}:{line_number}: invalid JSON: {exc.msg}"]
            ) from exc
    if not rows:
        raise BenchmarkValidationError([f"no JSONL rows: {path}"])
    return rows


def read_benchmark(path: Path) -> list[dict[str, Any]]:
    values = _read_json_or_jsonl(path)
    errors = [
        f"{path}: row {index} must be a JSON object"
        for index, value in enumerate(values, start=1)
        if not isinstance(value, dict)
    ]
    if errors:
        raise BenchmarkValidationError(errors)
    return values  # type: ignore[return-value]


def _nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _validate_string_list(
    value: Any, *, case_id: str, field: str, errors: list[str]
) -> None:
    if not isinstance(value, list):
        errors.append(f"{case_id}: {field} must be an array")
        return
    all_strings = all(_nonempty_string(item) for item in value)
    if not all_strings:
        errors.append(f"{case_id}: {field} must contain only non-empty strings")
    if all_strings and len(value) != len(set(value)):
        errors.append(f"{case_id}: {field} contains duplicates")


def _validate_review_record(
    record: Any,
    *,
    case_id: str,
    language: str,
    kind: str,
    errors: list[str],
) -> None:
    required = {"reviewer_id", "locale", "native_attested", "status", "reviewed_on"}
    if kind == "validator":
        required.add("independent_of_author")
    if not isinstance(record, dict):
        errors.append(f"{case_id}: provenance.{kind} must be an object")
        return
    missing = sorted(required - set(record))
    unknown = sorted(set(record) - required)
    if missing:
        errors.append(f"{case_id}: provenance.{kind} missing {missing}")
    if unknown:
        errors.append(f"{case_id}: provenance.{kind} has unknown fields {unknown}")
    reviewer_id = record.get("reviewer_id")
    if not _nonempty_string(reviewer_id) or not IDENTIFIER_RE.fullmatch(reviewer_id):
        errors.append(f"{case_id}: provenance.{kind}.reviewer_id must be a stable identifier")
    locale = record.get("locale")
    if not _nonempty_string(locale) or locale.split("-", 1)[0].lower() != language:
        errors.append(f"{case_id}: provenance.{kind}.locale must match {language}")
    if record.get("native_attested") is not True:
        errors.append(f"{case_id}: provenance.{kind}.native_attested must be true")
    if record.get("status") not in ({"complete"} if kind == "native_author" else {"approved"}):
        errors.append(f"{case_id}: provenance.{kind}.status is not release-valid")
    reviewed_on = record.get("reviewed_on")
    if not isinstance(reviewed_on, str) or not DATE_RE.fullmatch(reviewed_on):
        errors.append(f"{case_id}: provenance.{kind}.reviewed_on must be YYYY-MM-DD")
    else:
        try:
            date.fromisoformat(reviewed_on)
        except ValueError:
            errors.append(f"{case_id}: provenance.{kind}.reviewed_on is not a real date")
    if kind == "validator" and record.get("independent_of_author") is not True:
        errors.append(
            f"{case_id}: provenance.validator.independent_of_author must be true"
        )


def validate_rows(rows: Sequence[dict[str, Any]], *, release_profile: bool = False) -> None:
    errors: list[str] = []
    seen_case_ids: set[str] = set()
    family_splits: dict[str, set[str]] = defaultdict(set)
    family_signatures: dict[str, tuple[Any, ...]] = {}
    contrast_sets: dict[str, list[dict[str, Any]]] = defaultdict(list)
    normalized_inputs: dict[str, str] = {}
    normalized_outputs: dict[str, str] = {}

    top_fields = {
        "schema_version",
        "case_id",
        "semantic_family_id",
        "split",
        "language",
        "domain",
        "behavior",
        "contrast_set_id",
        "difficulty",
        "safety_risk",
        "asr_input",
        "gold_output",
        "requirements",
        "provenance",
    }
    requirement_fields = {
        "meaning",
        "entities",
        "numbers",
        "timing",
        "attribution",
        "formatting",
    }
    formatting_fields = {"list_contract", "expected_item_count", "shared_scope"}
    provenance_fields = {
        "source_type",
        "source_ref",
        "native_author",
        "independent_native_validator",
    }

    for row_number, row in enumerate(rows, start=1):
        case_id = row.get("case_id") if _nonempty_string(row.get("case_id")) else f"row-{row_number}"
        missing = sorted(top_fields - set(row))
        unknown = sorted(set(row) - top_fields)
        if missing:
            errors.append(f"{case_id}: missing fields {missing}")
        if unknown:
            errors.append(f"{case_id}: unknown fields {unknown}")
        if row.get("schema_version") != SCHEMA_VERSION:
            errors.append(f"{case_id}: schema_version must be {SCHEMA_VERSION}")

        for field in ("case_id", "semantic_family_id"):
            value = row.get(field)
            if not _nonempty_string(value) or not IDENTIFIER_RE.fullmatch(value):
                errors.append(f"{case_id}: {field} must be a stable identifier")
        if case_id in seen_case_ids:
            errors.append(f"{case_id}: duplicate case_id")
        seen_case_ids.add(case_id)

        split = row.get("split")
        language = row.get("language")
        domain = row.get("domain")
        behavior = row.get("behavior")
        contrast_set_id = row.get("contrast_set_id")
        difficulty = row.get("difficulty")
        safety = row.get("safety_risk")
        for field, value, allowed in (
            ("split", split, SPLITS),
            ("language", language, LANGUAGES),
            ("domain", domain, DOMAINS),
            ("behavior", behavior, BEHAVIORS),
            ("difficulty", difficulty, DIFFICULTIES),
            ("safety_risk", safety, SAFETY_RISKS),
        ):
            if value not in allowed:
                errors.append(f"{case_id}: {field} must be one of {list(allowed)}")

        for field in ("asr_input", "gold_output"):
            if not _nonempty_string(row.get(field)):
                errors.append(f"{case_id}: {field} must be non-empty")

        if domain == "medical" and safety != "medical":
            errors.append(f"{case_id}: medical domain requires medical safety_risk")
        if domain == "legal_financial" and safety not in {"legal", "financial"}:
            errors.append(
                f"{case_id}: legal_financial domain requires legal or financial safety_risk"
            )
        if domain in {"work_admin", "personal_home", "technical_product"} and safety != "standard":
            errors.append(f"{case_id}: {domain} domain requires standard safety_risk")

        requirements = row.get("requirements")
        if not isinstance(requirements, dict):
            errors.append(f"{case_id}: requirements must be an object")
            requirements = {}
        else:
            missing = sorted(requirement_fields - set(requirements))
            unknown = sorted(set(requirements) - requirement_fields)
            if missing:
                errors.append(f"{case_id}: requirements missing {missing}")
            if unknown:
                errors.append(f"{case_id}: requirements has unknown fields {unknown}")
        if not _nonempty_string(requirements.get("meaning")):
            errors.append(f"{case_id}: requirements.meaning must be non-empty")
        for field in ("entities", "numbers", "timing", "attribution"):
            _validate_string_list(
                requirements.get(field), case_id=case_id, field=f"requirements.{field}", errors=errors
            )

        formatting = requirements.get("formatting")
        if not isinstance(formatting, dict):
            errors.append(f"{case_id}: requirements.formatting must be an object")
            formatting = {}
        else:
            missing = sorted(formatting_fields - set(formatting))
            unknown = sorted(set(formatting) - formatting_fields)
            if missing:
                errors.append(f"{case_id}: requirements.formatting missing {missing}")
            if unknown:
                errors.append(f"{case_id}: requirements.formatting has unknown fields {unknown}")
        list_contract = formatting.get("list_contract")
        if list_contract not in LIST_CONTRACTS:
            errors.append(
                f"{case_id}: requirements.formatting.list_contract must be one of {list(LIST_CONTRACTS)}"
            )
        expected_contract = EXPECTED_LIST_CONTRACT.get(behavior)
        if expected_contract and list_contract != expected_contract:
            errors.append(
                f"{case_id}: behavior {behavior} requires list_contract {expected_contract}"
            )
        item_count = formatting.get("expected_item_count")
        if list_contract in {"activate_bullets", "activate_numbered"}:
            if not isinstance(item_count, int) or isinstance(item_count, bool) or item_count < 2:
                errors.append(f"{case_id}: active list requires expected_item_count >= 2")
        elif item_count is not None:
            errors.append(f"{case_id}: non-list contract requires expected_item_count null")
        if behavior in {"explicit_two_item_list", "scoped_two_item_list"} and item_count != 2:
            errors.append(f"{case_id}: two-item behavior requires expected_item_count 2")
        if behavior == "natural_three_to_five_item_bullet_list" and item_count not in {3, 4, 5}:
            errors.append(f"{case_id}: natural list item count must be 3, 4, or 5")
        if not isinstance(formatting.get("shared_scope"), str):
            errors.append(f"{case_id}: requirements.formatting.shared_scope must be a string")

        if behavior in POSITIVE_LIST_BEHAVIORS | RESTRAINT_BEHAVIORS:
            if not _nonempty_string(contrast_set_id) or not IDENTIFIER_RE.fullmatch(
                contrast_set_id
            ):
                errors.append(f"{case_id}: list behavior requires a stable contrast_set_id")
            else:
                contrast_sets[contrast_set_id].append(row)
        elif contrast_set_id is not None:
            errors.append(f"{case_id}: core behavior requires contrast_set_id null")

        provenance = row.get("provenance")
        if not isinstance(provenance, dict):
            errors.append(f"{case_id}: provenance must be an object")
            provenance = {}
        else:
            missing = sorted(provenance_fields - set(provenance))
            unknown = sorted(set(provenance) - provenance_fields)
            if missing:
                errors.append(f"{case_id}: provenance missing {missing}")
            if unknown:
                errors.append(f"{case_id}: provenance has unknown fields {unknown}")
        if provenance.get("source_type") not in SOURCE_TYPES:
            errors.append(f"{case_id}: provenance.source_type must be one of {list(SOURCE_TYPES)}")
        if not _nonempty_string(provenance.get("source_ref")):
            errors.append(f"{case_id}: provenance.source_ref must be non-empty")

        author = provenance.get("native_author")
        _validate_review_record(
            author,
            case_id=case_id,
            language=language if language in LANGUAGES else "",
            kind="native_author",
            errors=errors,
        )
        validator = provenance.get("independent_native_validator")
        if validator is None:
            if split == "frozen":
                errors.append(
                    f"{case_id}: frozen row missing independent native validation"
                )
        else:
            _validate_review_record(
                validator,
                case_id=case_id,
                language=language if language in LANGUAGES else "",
                kind="validator",
                errors=errors,
            )
            if isinstance(author, dict) and isinstance(validator, dict):
                if author.get("reviewer_id") == validator.get("reviewer_id"):
                    errors.append(
                        f"{case_id}: native author and validator must be different people"
                    )

        family_id = row.get("semantic_family_id")
        if _nonempty_string(family_id) and split in SPLITS:
            family_splits[family_id].add(split)
            signature = (domain, behavior, difficulty, safety, list_contract)
            old_signature = family_signatures.setdefault(family_id, signature)
            if old_signature != signature:
                errors.append(
                    f"{case_id}: semantic family {family_id} changes its stratum signature"
                )

        for field, value, seen in (
            ("asr_input", row.get("asr_input"), normalized_inputs),
            ("gold_output", row.get("gold_output"), normalized_outputs),
        ):
            if _nonempty_string(value):
                normalized = normalize_text(value)
                prior = seen.get(normalized)
                if prior is not None and prior != case_id:
                    errors.append(f"{case_id}: normalized {field} duplicates {prior}")
                else:
                    seen[normalized] = case_id

    for family_id, splits in sorted(family_splits.items()):
        if len(splits) > 1:
            errors.append(
                f"semantic family {family_id} crosses splits {sorted(splits)}; allocate whole families"
            )

    for contrast_set_id, members in sorted(contrast_sets.items()):
        if len(members) != 2:
            errors.append(
                f"contrast set {contrast_set_id} has {len(members)} rows, expected one activation and one restraint"
            )
            continue
        positive = [row for row in members if row.get("behavior") in POSITIVE_LIST_BEHAVIORS]
        restraint = [row for row in members if row.get("behavior") in RESTRAINT_BEHAVIORS]
        if len(positive) != 1 or len(restraint) != 1:
            errors.append(
                f"contrast set {contrast_set_id} must contain one activation and one restraint row"
            )
            continue
        if positive[0].get("semantic_family_id") == restraint[0].get("semantic_family_id"):
            errors.append(
                f"contrast set {contrast_set_id} must use separately authored semantic families"
            )
        match_fields = ("split", "language", "domain", "difficulty", "safety_risk")
        mismatches = [
            field for field in match_fields if positive[0].get(field) != restraint[0].get(field)
        ]
        if mismatches:
            errors.append(
                f"contrast set {contrast_set_id} is not matched on {mismatches}"
            )

    if release_profile:
        errors.extend(_release_profile_errors(rows))
    if errors:
        raise BenchmarkValidationError(errors)


def _release_profile_errors(rows: Sequence[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    counts = Counter((row.get("split"), row.get("language")) for row in rows)
    behavior_counts = Counter(
        (row.get("split"), row.get("language"), row.get("behavior")) for row in rows
    )
    domain_counts = Counter(
        (row.get("split"), row.get("language"), row.get("domain")) for row in rows
    )
    behavior_domain_counts = Counter(
        (
            row.get("split"),
            row.get("language"),
            row.get("behavior"),
            row.get("domain"),
        )
        for row in rows
    )
    source_counts: Counter[tuple[Any, Any, Any]] = Counter()
    for row in rows:
        provenance = row.get("provenance")
        source_type = provenance.get("source_type") if isinstance(provenance, dict) else None
        source_counts[(row.get("split"), row.get("language"), source_type)] += 1
    difficulty_seen: dict[tuple[str, str], set[str]] = defaultdict(set)
    safety_seen: dict[tuple[str, str], set[str]] = defaultdict(set)
    for row in rows:
        key = (row.get("split"), row.get("language"))
        difficulty_seen[key].add(row.get("difficulty"))
        safety_seen[key].add(row.get("safety_risk"))

    for split in SPLITS:
        target = RELEASE_COUNTS[split]
        for language in LANGUAGES:
            key = (split, language)
            if counts[key] != target["per_language"]:
                errors.append(
                    f"release profile: {split}/{language} has {counts[key]} rows, expected {target['per_language']}"
                )
            for behavior in BEHAVIORS:
                actual = behavior_counts[(split, language, behavior)]
                if actual != target["per_behavior"]:
                    errors.append(
                        f"release profile: {split}/{language}/{behavior} has {actual}, expected {target['per_behavior']}"
                    )
            for domain in DOMAINS:
                actual = domain_counts[(split, language, domain)]
                if actual != target["per_domain"]:
                    errors.append(
                        f"release profile: {split}/{language}/{domain} has {actual}, expected {target['per_domain']}"
                    )
            expected_behavior_domain = target["per_behavior"] // len(DOMAINS)
            for behavior in BEHAVIORS:
                for domain in DOMAINS:
                    actual = behavior_domain_counts[
                        (split, language, behavior, domain)
                    ]
                    if actual != expected_behavior_domain:
                        errors.append(
                            f"release profile: {split}/{language}/{behavior}/{domain} has {actual}, expected {expected_behavior_domain}"
                        )
            native_original = source_counts[(split, language, "native_original")]
            native_minimum = math.ceil(target["per_language"] * 0.8)
            if native_original < native_minimum:
                errors.append(
                    f"release profile: {split}/{language} has {native_original} native-original rows, minimum {native_minimum}"
                )
            missing_difficulties = sorted(set(DIFFICULTIES) - difficulty_seen[key])
            missing_safety = sorted(set(SAFETY_RISKS) - safety_seen[key])
            if missing_difficulties:
                errors.append(
                    f"release profile: {split}/{language} missing difficulty strata {missing_difficulties}"
                )
            if missing_safety:
                errors.append(
                    f"release profile: {split}/{language} missing safety strata {missing_safety}"
                )
    expected_total = sum(
        RELEASE_COUNTS[split]["per_language"] * len(LANGUAGES) for split in SPLITS
    )
    if len(rows) != expected_total:
        errors.append(f"release profile: corpus has {len(rows)} rows, expected {expected_total}")
    return errors


def benchmark_content_sha256(rows: Sequence[dict[str, Any]]) -> str:
    ordered = sorted(rows, key=lambda row: row["case_id"])
    payload = "\n".join(canonical_json(row) for row in ordered) + "\n"
    return sha256_bytes(payload.encode("utf-8"))


def rating_content_sha256(rows: Sequence[dict[str, Any]]) -> str:
    ordered = sorted(rows, key=lambda row: row["rating_id"])
    payload = "\n".join(canonical_json(row) for row in ordered) + "\n"
    return sha256_bytes(payload.encode("utf-8"))


def read_ratings(path: Path) -> list[dict[str, Any]]:
    values = _read_json_or_jsonl(path)
    errors = [
        f"{path}: rating row {index} must be a JSON object"
        for index, value in enumerate(values, start=1)
        if not isinstance(value, dict)
    ]
    if errors:
        raise BenchmarkValidationError(errors)
    return values  # type: ignore[return-value]


def _rating_signature(row: dict[str, Any]) -> tuple[Any, ...] | None:
    axes = row.get("axes")
    severity = row.get("damage_severity")
    if not isinstance(axes, dict) or set(axes) != set(RATING_AXES):
        return None
    if any(not isinstance(axes.get(axis), bool) for axis in RATING_AXES):
        return None
    if severity not in DAMAGE_SEVERITIES:
        return None
    return tuple(axes[axis] for axis in RATING_AXES) + (severity,)


def validate_rating_rows(
    ratings: Sequence[dict[str, Any]],
    *,
    corpus_rows: Sequence[dict[str, Any]],
    expected_model_labels: Sequence[str],
) -> dict[str, Any]:
    """Validate the complete blinded native-review workflow without candidate text."""

    validate_rows(corpus_rows)
    errors: list[str] = []
    frozen_cases = {
        row["case_id"]: row for row in corpus_rows if row.get("split") == "frozen"
    }
    if not frozen_cases:
        errors.append("rating workflow requires at least one frozen case")

    labels = list(expected_model_labels)
    if not labels:
        errors.append("at least one predeclared opaque model label is required")
    if len(labels) != len(set(labels)):
        errors.append("expected opaque model labels contain duplicates")
    for label in labels:
        if not _nonempty_string(label) or not IDENTIFIER_RE.fullmatch(label):
            errors.append(f"invalid expected opaque model label {label!r}")
    label_set = set(labels)

    top_fields = {
        "schema_version",
        "rating_id",
        "case_id",
        "opaque_model_label",
        "blind_assignment_id",
        "blinded",
        "reviewer_id",
        "reviewer_locale",
        "reviewer_native_attested",
        "review_round",
        "repeat_of_rating_id",
        "axes",
        "damage_severity",
        "reason",
    }
    seen_rating_ids: set[str] = set()
    seen_assignments: set[str] = set()
    initial_by_pair: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    adjudication_by_pair: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    repeats: list[dict[str, Any]] = []

    for row_number, rating in enumerate(ratings, start=1):
        rating_id = (
            rating.get("rating_id")
            if _nonempty_string(rating.get("rating_id"))
            else f"rating-row-{row_number}"
        )
        missing = sorted(top_fields - set(rating))
        unknown = sorted(set(rating) - top_fields)
        if missing:
            errors.append(f"{rating_id}: missing fields {missing}")
        if unknown:
            errors.append(f"{rating_id}: unknown fields {unknown}")
        if rating.get("schema_version") != RATING_SCHEMA_VERSION:
            errors.append(f"{rating_id}: schema_version must be {RATING_SCHEMA_VERSION}")

        for field in (
            "rating_id",
            "case_id",
            "opaque_model_label",
            "blind_assignment_id",
            "reviewer_id",
        ):
            value = rating.get(field)
            if not _nonempty_string(value) or not IDENTIFIER_RE.fullmatch(value):
                errors.append(f"{rating_id}: {field} must be a stable identifier")
        if rating_id in seen_rating_ids:
            errors.append(f"{rating_id}: duplicate rating_id")
        seen_rating_ids.add(rating_id)

        assignment_id = rating.get("blind_assignment_id")
        if assignment_id in seen_assignments:
            errors.append(f"{rating_id}: duplicate blind_assignment_id {assignment_id}")
        if _nonempty_string(assignment_id):
            seen_assignments.add(assignment_id)
        if rating.get("blinded") is not True:
            errors.append(f"{rating_id}: blinded must be true")
        if rating.get("reviewer_native_attested") is not True:
            errors.append(f"{rating_id}: reviewer_native_attested must be true")

        case_id = rating.get("case_id")
        case = frozen_cases.get(case_id)
        if case is None:
            errors.append(f"{rating_id}: case_id {case_id!r} is not a frozen benchmark case")
        else:
            locale = rating.get("reviewer_locale")
            if (
                not _nonempty_string(locale)
                or locale.split("-", 1)[0].lower() != case["language"]
            ):
                errors.append(
                    f"{rating_id}: reviewer_locale must match case language {case['language']}"
                )

        model_label = rating.get("opaque_model_label")
        if model_label not in label_set:
            errors.append(
                f"{rating_id}: opaque_model_label {model_label!r} was not predeclared"
            )
        review_round = rating.get("review_round")
        if review_round not in {"initial", "adjudication", "repeat"}:
            errors.append(f"{rating_id}: review_round is invalid")
        repeat_of = rating.get("repeat_of_rating_id")
        if review_round == "repeat":
            if not _nonempty_string(repeat_of) or not IDENTIFIER_RE.fullmatch(repeat_of):
                errors.append(f"{rating_id}: repeat rating requires repeat_of_rating_id")
            repeats.append(rating)
        elif repeat_of is not None:
            errors.append(f"{rating_id}: only repeat ratings may set repeat_of_rating_id")

        axes = rating.get("axes")
        if not isinstance(axes, dict):
            errors.append(f"{rating_id}: axes must be an object")
        else:
            missing_axes = sorted(set(RATING_AXES) - set(axes))
            unknown_axes = sorted(set(axes) - set(RATING_AXES))
            if missing_axes:
                errors.append(f"{rating_id}: axes missing {missing_axes}")
            if unknown_axes:
                errors.append(f"{rating_id}: axes has unknown fields {unknown_axes}")
            for axis in RATING_AXES:
                if axis in axes and not isinstance(axes[axis], bool):
                    errors.append(f"{rating_id}: axes.{axis} must be boolean")
        if rating.get("damage_severity") not in DAMAGE_SEVERITIES:
            errors.append(
                f"{rating_id}: damage_severity must be one of {list(DAMAGE_SEVERITIES)}"
            )
        if not _nonempty_string(rating.get("reason")):
            errors.append(f"{rating_id}: reason must be non-empty")

        if case_id in frozen_cases and model_label in label_set:
            pair = (case_id, model_label)
            if review_round == "initial":
                initial_by_pair[pair].append(rating)
            elif review_round == "adjudication":
                adjudication_by_pair[pair].append(rating)

    expected_pairs = {
        (case_id, label) for case_id in frozen_cases for label in label_set
    }
    all_initials: list[dict[str, Any]] = []
    for pair in sorted(expected_pairs):
        initials = initial_by_pair.get(pair, [])
        adjudications = adjudication_by_pair.get(pair, [])
        if len(initials) != 2:
            errors.append(
                f"rating pair {pair} has {len(initials)} initial ratings, expected exactly 2"
            )
            continue
        all_initials.extend(initials)
        initial_reviewers = {rating.get("reviewer_id") for rating in initials}
        if len(initial_reviewers) != 2:
            errors.append(f"rating pair {pair} requires two distinct native initial reviewers")

        signatures = [_rating_signature(rating) for rating in initials]
        disagreement = None not in signatures and signatures[0] != signatures[1]
        if disagreement and len(adjudications) != 1:
            errors.append(
                f"rating pair {pair} disagrees and requires exactly one third-reviewer adjudication"
            )
        if not disagreement and adjudications:
            errors.append(f"rating pair {pair} has adjudication without an initial disagreement")
        if len(adjudications) == 1:
            adjudicator = adjudications[0].get("reviewer_id")
            if adjudicator in initial_reviewers:
                errors.append(
                    f"rating pair {pair} adjudicator must be distinct from both initial reviewers"
                )

    unexpected_initial_pairs = sorted(set(initial_by_pair) - expected_pairs)
    unexpected_adjudication_pairs = sorted(set(adjudication_by_pair) - expected_pairs)
    if unexpected_initial_pairs:
        errors.append(f"unexpected initial rating pairs {unexpected_initial_pairs}")
    if unexpected_adjudication_pairs:
        errors.append(f"unexpected adjudication rating pairs {unexpected_adjudication_pairs}")

    initial_by_id = {
        rating["rating_id"]: rating
        for rating in all_initials
        if _nonempty_string(rating.get("rating_id"))
    }
    repeated_targets: Counter[str] = Counter()
    for repeat in repeats:
        repeat_id = repeat.get("rating_id")
        target_id = repeat.get("repeat_of_rating_id")
        target = initial_by_id.get(target_id)
        if target is None:
            errors.append(
                f"{repeat_id}: repeat_of_rating_id {target_id!r} is not a valid initial rating"
            )
            continue
        repeated_targets[target_id] += 1
        for field in ("case_id", "opaque_model_label", "reviewer_id"):
            if repeat.get(field) != target.get(field):
                errors.append(f"{repeat_id}: repeat must preserve initial {field}")
        if repeat.get("blind_assignment_id") == target.get("blind_assignment_id"):
            errors.append(f"{repeat_id}: repeat requires a new blind_assignment_id")
    duplicate_repeat_targets = sorted(
        target_id for target_id, count in repeated_targets.items() if count > 1
    )
    if duplicate_repeat_targets:
        errors.append(f"initial ratings repeated more than once {duplicate_repeat_targets}")

    required_repeat_count = math.ceil(len(all_initials) * 0.10)
    actual_repeat_count = len(repeated_targets)
    if actual_repeat_count < required_repeat_count:
        errors.append(
            f"repeat coverage is {actual_repeat_count}/{len(all_initials)}, minimum {required_repeat_count}/{len(all_initials)}"
        )

    initials_by_reviewer: Counter[str] = Counter()
    repeats_by_reviewer: Counter[str] = Counter()
    initials_by_language_model: Counter[tuple[str, str]] = Counter()
    repeats_by_language_model: Counter[tuple[str, str]] = Counter()
    for initial in all_initials:
        reviewer_id = initial.get("reviewer_id")
        case = frozen_cases.get(initial.get("case_id"))
        model_label = initial.get("opaque_model_label")
        if _nonempty_string(reviewer_id):
            initials_by_reviewer[reviewer_id] += 1
        if case is not None and model_label in label_set:
            initials_by_language_model[(case["language"], model_label)] += 1
    for target_id in repeated_targets:
        target = initial_by_id.get(target_id)
        if target is None:
            continue
        reviewer_id = target.get("reviewer_id")
        case = frozen_cases.get(target.get("case_id"))
        model_label = target.get("opaque_model_label")
        if _nonempty_string(reviewer_id):
            repeats_by_reviewer[reviewer_id] += 1
        if case is not None and model_label in label_set:
            repeats_by_language_model[(case["language"], model_label)] += 1

    reviewer_coverage: dict[str, dict[str, int]] = {}
    for reviewer_id, initial_count in sorted(initials_by_reviewer.items()):
        minimum = math.ceil(initial_count * 0.10)
        repeated = repeats_by_reviewer[reviewer_id]
        reviewer_coverage[reviewer_id] = {
            "initial": initial_count,
            "repeated": repeated,
            "minimum": minimum,
        }
        if repeated < minimum:
            errors.append(
                f"repeat coverage for reviewer {reviewer_id} is {repeated}/{initial_count}, minimum {minimum}/{initial_count}"
            )

    language_model_coverage: dict[str, dict[str, int]] = {}
    for key, initial_count in sorted(initials_by_language_model.items()):
        minimum = math.ceil(initial_count * 0.10)
        repeated = repeats_by_language_model[key]
        display_key = f"{key[0]}:{key[1]}"
        language_model_coverage[display_key] = {
            "initial": initial_count,
            "repeated": repeated,
            "minimum": minimum,
        }
        if repeated < minimum:
            errors.append(
                f"repeat coverage for language/model {display_key} is {repeated}/{initial_count}, minimum {minimum}/{initial_count}"
            )
    if errors:
        raise BenchmarkValidationError(errors)
    return {
        "initial_rating_count": len(all_initials),
        "adjudication_rating_count": sum(len(rows) for rows in adjudication_by_pair.values()),
        "repeat_rating_count": len(repeats),
        "distinct_repeated_initial_count": actual_repeat_count,
        "required_repeat_count": required_repeat_count,
        "repeat_coverage_by_reviewer": reviewer_coverage,
        "repeat_coverage_by_language_model": language_model_coverage,
    }


def _parse_source_spec(spec: str) -> tuple[str, str, Path]:
    try:
        left, raw_path = spec.split("=", 1)
        role, name = left.split(":", 1)
    except ValueError as exc:
        raise BenchmarkValidationError(
            [f"invalid leakage source {spec!r}; expected ROLE:NAME=PATH"]
        ) from exc
    if role not in LEAKAGE_ROLES:
        raise BenchmarkValidationError(
            [f"invalid leakage role {role!r}; expected one of {list(LEAKAGE_ROLES)}"]
        )
    if not IDENTIFIER_RE.fullmatch(name):
        raise BenchmarkValidationError([f"invalid leakage source name {name!r}"])
    path = Path(raw_path).expanduser().resolve()
    if not path.is_file():
        raise BenchmarkValidationError([f"missing leakage source: {path}"])
    return role, name, path


def parse_leakage_sources(specs: Sequence[str]) -> list[LeakageSource]:
    sources: list[LeakageSource] = []
    seen: set[tuple[str, str]] = set()
    for spec in specs:
        role, name, path = _parse_source_spec(spec)
        key = (role, name)
        if key in seen:
            raise BenchmarkValidationError([f"duplicate leakage source identity: {role}:{name}"])
        seen.add(key)
        sources.append(LeakageSource(role, name, path, sha256_file(path)))
    return sorted(sources, key=lambda source: (source.role, source.name))


def _walk_source_values(
    value: Any, *, allow_string_family: bool = False
) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for key in ("rows", "records", "families", "items"):
            nested = value.get(key)
            if isinstance(nested, (dict, list)):
                yield from _walk_source_values(
                    nested, allow_string_family=allow_string_family
                )
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, (dict, list)):
                yield from _walk_source_values(
                    item, allow_string_family=allow_string_family
                )
            elif isinstance(item, str) and allow_string_family:
                yield {"semantic_family_id": item}
    elif isinstance(value, str) and allow_string_family:
        yield {"semantic_family_id": value}


def exact_leakage_errors(
    rows: Sequence[dict[str, Any]], sources: Sequence[LeakageSource]
) -> list[str]:
    candidate_inputs = {normalize_text(row["asr_input"]): row["case_id"] for row in rows}
    candidate_outputs = {normalize_text(row["gold_output"]): row["case_id"] for row in rows}
    candidate_families = {row["semantic_family_id"]: row["case_id"] for row in rows}
    text_fields = ("asr_input", "input", "gold_output", "output", "expected_output")
    family_fields = ("semantic_family_id", "family_id", "origin_family_id")
    errors: list[str] = []
    for source in sources:
        values = _read_json_or_jsonl(source.path)
        extractable_values = 0
        for value in values:
            for record in _walk_source_values(
                value, allow_string_family=source.role == "blocked_family_registry"
            ):
                for field in text_fields:
                    text = record.get(field)
                    if not _nonempty_string(text):
                        continue
                    extractable_values += 1
                    normalized = normalize_text(text)
                    if normalized in candidate_inputs:
                        errors.append(
                            f"{candidate_inputs[normalized]}: input exact-leaks from {source.role}:{source.name} field {field}"
                        )
                    if normalized in candidate_outputs:
                        errors.append(
                            f"{candidate_outputs[normalized]}: gold exact-leaks from {source.role}:{source.name} field {field}"
                        )
                for field in family_fields:
                    family_id = record.get(field)
                    if _nonempty_string(family_id):
                        extractable_values += 1
                    if family_id in candidate_families:
                        errors.append(
                            f"{candidate_families[family_id]}: family {family_id} blocked by {source.role}:{source.name}"
                        )
        if extractable_values == 0:
            errors.append(
                f"leakage source {source.role}:{source.name} has no recognized text or family fields"
            )
    return sorted(set(errors))


def validate_leakage_receipt(
    receipt_path: Path,
    *,
    rows: Sequence[dict[str, Any]],
    sources: Sequence[LeakageSource],
) -> dict[str, Any]:
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    errors: list[str] = []
    if not isinstance(receipt, dict):
        raise BenchmarkValidationError([f"leakage receipt must be an object: {receipt_path}"])
    if receipt.get("schema_version") != "eg1-multilingual-leakage-receipt-v1":
        errors.append("leakage receipt schema_version is invalid")
    if receipt.get("benchmark_content_sha256") != benchmark_content_sha256(rows):
        errors.append("leakage receipt is not bound to this benchmark content hash")
    if not _nonempty_string(receipt.get("screening_policy_id")):
        errors.append("leakage receipt screening_policy_id is required")

    expected_sources = {
        (source.role, source.name): source.sha256 for source in sources
    }
    entries = receipt.get("sources")
    if not isinstance(entries, list):
        errors.append("leakage receipt sources must be an array")
        entries = []
    observed: dict[tuple[str, str], str] = {}
    for index, entry in enumerate(entries, start=1):
        if not isinstance(entry, dict):
            errors.append(f"leakage receipt source {index} must be an object")
            continue
        key = (entry.get("role"), entry.get("name"))
        if key in observed:
            errors.append(f"leakage receipt duplicates source {key}")
        observed[key] = entry.get("sha256")
        methods = entry.get("methods")
        if not isinstance(methods, dict):
            errors.append(f"leakage receipt source {key} missing methods")
            continue
        missing_methods = sorted(set(REQUIRED_SCREEN_METHODS) - set(methods))
        if missing_methods:
            errors.append(f"leakage receipt source {key} missing methods {missing_methods}")
        for method_name in REQUIRED_SCREEN_METHODS:
            result = methods.get(method_name)
            if not isinstance(result, dict):
                continue
            if result.get("status") != "pass" or result.get("violations") != 0:
                errors.append(f"leakage receipt source {key} method {method_name} did not pass")
            if method_name != "exact_normalized":
                threshold = result.get("threshold")
                maximum = result.get("max_observed")
                if (
                    not isinstance(threshold, (int, float))
                    or isinstance(threshold, bool)
                    or not 0 <= threshold <= 1
                ):
                    errors.append(
                        f"leakage receipt source {key} method {method_name} has invalid threshold"
                    )
                if (
                    not isinstance(maximum, (int, float))
                    or isinstance(maximum, bool)
                    or not 0 <= maximum <= 1
                ):
                    errors.append(
                        f"leakage receipt source {key} method {method_name} has invalid max_observed"
                    )
                elif isinstance(threshold, (int, float)) and maximum > threshold:
                    errors.append(
                        f"leakage receipt source {key} method {method_name} exceeds threshold"
                    )
    if observed != expected_sources:
        errors.append(
            f"leakage receipt source inventory/hash mismatch: expected {expected_sources}, observed {observed}"
        )
    if errors:
        raise BenchmarkValidationError(errors)
    return receipt


def _nested_counts(rows: Sequence[dict[str, Any]], fields: Sequence[str]) -> dict[str, Any]:
    root: dict[str, Any] = {}
    counter = Counter(tuple(row[field] for field in fields) for row in rows)
    for keys, count in sorted(counter.items()):
        cursor = root
        for key in keys[:-1]:
            cursor = cursor.setdefault(key, {})
        cursor[keys[-1]] = count
    return root


def build_manifest(
    *,
    rows: Sequence[dict[str, Any]],
    corpus_path: Path,
    sources: Sequence[LeakageSource],
    receipt_path: Path | None,
    release_profile: bool,
) -> dict[str, Any]:
    script_dir = Path(__file__).resolve().parent
    schema_path = script_dir / "multilingual_benchmark_v2.schema.json"
    rating_schema_path = script_dir / "multilingual_benchmark_v2_rating.schema.json"
    family_assignments = sorted(
        {row["semantic_family_id"]: row["split"] for row in rows}.items()
    )
    row_hashes = [
        {"case_id": row["case_id"], "sha256": sha256_bytes(canonical_json(row).encode("utf-8"))}
        for row in sorted(rows, key=lambda item: item["case_id"])
    ]
    list_counts = Counter(
        (
            row["split"],
            row["language"],
            row["requirements"]["formatting"]["list_contract"],
        )
        for row in rows
    )
    return {
        "schema_version": "eg1-multilingual-benchmark-manifest-v2",
        "validator_version": VALIDATOR_VERSION,
        "benchmark_schema_sha256": sha256_file(schema_path),
        "rating_schema_sha256": sha256_file(rating_schema_path),
        "corpus_source_sha256": sha256_file(corpus_path),
        "benchmark_content_sha256": benchmark_content_sha256(rows),
        "release_profile_enforced": release_profile,
        "row_count": len(rows),
        "family_count": len(family_assignments),
        "family_assignment_sha256": sha256_bytes(
            canonical_json(family_assignments).encode("utf-8")
        ),
        "row_hashes": row_hashes,
        "counts": {
            "split_language": _nested_counts(rows, ("split", "language")),
            "split_language_domain": _nested_counts(rows, ("split", "language", "domain")),
            "split_language_behavior": _nested_counts(rows, ("split", "language", "behavior")),
            "split_language_behavior_domain": _nested_counts(
                rows, ("split", "language", "behavior", "domain")
            ),
            "split_language_difficulty": _nested_counts(rows, ("split", "language", "difficulty")),
            "split_language_safety": _nested_counts(rows, ("split", "language", "safety_risk")),
            "split_language_list_contract": _counter_to_nested(list_counts),
        },
        "leakage_sources": [
            {"role": source.role, "name": source.name, "sha256": source.sha256}
            for source in sources
        ],
        "leakage_receipt_sha256": sha256_file(receipt_path) if receipt_path else None,
    }


def validate_benchmark_manifest_for_ratings(
    manifest_path: Path,
    *,
    rows: Sequence[dict[str, Any]],
    corpus_path: Path,
) -> dict[str, Any]:
    validate_rows(rows, release_profile=True)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise BenchmarkValidationError(["benchmark manifest must be an object"])
    errors: list[str] = []
    expected_manifest_fields = {
        "schema_version",
        "validator_version",
        "benchmark_schema_sha256",
        "rating_schema_sha256",
        "corpus_source_sha256",
        "benchmark_content_sha256",
        "release_profile_enforced",
        "row_count",
        "family_count",
        "family_assignment_sha256",
        "row_hashes",
        "counts",
        "leakage_sources",
        "leakage_receipt_sha256",
    }
    missing_fields = sorted(expected_manifest_fields - set(manifest))
    unknown_fields = sorted(set(manifest) - expected_manifest_fields)
    if missing_fields:
        errors.append(f"benchmark manifest missing fields {missing_fields}")
    if unknown_fields:
        errors.append(f"benchmark manifest has unknown fields {unknown_fields}")
    if manifest.get("schema_version") != "eg1-multilingual-benchmark-manifest-v2":
        errors.append("benchmark manifest schema_version is invalid")
    expected = build_manifest(
        rows=rows,
        corpus_path=corpus_path,
        sources=[],
        receipt_path=None,
        release_profile=True,
    )
    corpus_derived_fields = (
        "validator_version",
        "benchmark_schema_sha256",
        "rating_schema_sha256",
        "corpus_source_sha256",
        "benchmark_content_sha256",
        "release_profile_enforced",
        "row_count",
        "family_count",
        "family_assignment_sha256",
        "row_hashes",
        "counts",
    )
    for field in corpus_derived_fields:
        if manifest.get(field) != expected[field]:
            errors.append(f"benchmark manifest corpus-derived field {field} is invalid")
    receipt_sha = manifest.get("leakage_receipt_sha256")
    if not isinstance(receipt_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", receipt_sha):
        errors.append("rating workflow requires a benchmark with a leakage receipt")
    sources = manifest.get("leakage_sources")
    roles: set[str] = set()
    if not isinstance(sources, list):
        errors.append("benchmark manifest leakage_sources must be an array")
        sources = []
    for index, source in enumerate(sources, start=1):
        if not isinstance(source, dict) or set(source) != {"role", "name", "sha256"}:
            errors.append(f"benchmark manifest leakage source {index} is malformed")
            continue
        role = source.get("role")
        name = source.get("name")
        sha = source.get("sha256")
        if role not in LEAKAGE_ROLES:
            errors.append(f"benchmark manifest leakage source {index} has invalid role")
        else:
            roles.add(role)
        if not _nonempty_string(name) or not IDENTIFIER_RE.fullmatch(name):
            errors.append(f"benchmark manifest leakage source {index} has invalid name")
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
            errors.append(f"benchmark manifest leakage source {index} has invalid sha256")
    missing_roles = sorted(REQUIRED_FROZEN_LEAKAGE_ROLES - roles)
    if missing_roles:
        errors.append(f"benchmark manifest missing leakage source roles {missing_roles}")
    if errors:
        raise BenchmarkValidationError(errors)
    return manifest


def build_rating_manifest(
    *,
    ratings: Sequence[dict[str, Any]],
    ratings_path: Path,
    benchmark_manifest: dict[str, Any],
    benchmark_manifest_sha256: str,
    expected_model_labels: Sequence[str],
    workflow_stats: dict[str, Any],
) -> dict[str, Any]:
    rating_schema_path = (
        Path(__file__).resolve().parent / "multilingual_benchmark_v2_rating.schema.json"
    )
    row_hashes = [
        {
            "rating_id": row["rating_id"],
            "sha256": sha256_bytes(canonical_json(row).encode("utf-8")),
        }
        for row in sorted(ratings, key=lambda item: item["rating_id"])
    ]
    counts = Counter(
        (row["opaque_model_label"], row["review_round"]) for row in ratings
    )
    return {
        "schema_version": "eg1-multilingual-rating-manifest-v2",
        "validator_version": VALIDATOR_VERSION,
        "rating_schema_sha256": sha256_file(rating_schema_path),
        "benchmark_content_sha256": benchmark_manifest["benchmark_content_sha256"],
        "benchmark_manifest_sha256": benchmark_manifest_sha256,
        "rating_source_sha256": sha256_file(ratings_path),
        "rating_content_sha256": rating_content_sha256(ratings),
        "expected_model_labels": sorted(expected_model_labels),
        "rating_count": len(ratings),
        "workflow_stats": workflow_stats,
        "counts_by_model_and_round": _counter_to_nested(counts),
        "row_hashes": row_hashes,
    }


def _counter_to_nested(counter: Counter[tuple[str, ...]]) -> dict[str, Any]:
    root: dict[str, Any] = {}
    for keys, count in sorted(counter.items()):
        cursor = root
        for key in keys[:-1]:
            cursor = cursor.setdefault(key, {})
        cursor[keys[-1]] = count
    return root


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def validate_command(args: argparse.Namespace) -> int:
    corpus_path = args.corpus.expanduser().resolve()
    rows = read_benchmark(corpus_path)
    validate_rows(rows, release_profile=args.release_profile)
    sources = parse_leakage_sources(args.leakage_source)
    exact_errors = exact_leakage_errors(rows, sources)
    if exact_errors:
        raise BenchmarkValidationError(exact_errors)

    has_frozen = any(row["split"] == "frozen" for row in rows)
    receipt_path = args.leakage_receipt.expanduser().resolve() if args.leakage_receipt else None
    if has_frozen:
        roles = {source.role for source in sources}
        missing_roles = sorted(REQUIRED_FROZEN_LEAKAGE_ROLES - roles)
        errors: list[str] = []
        if missing_roles:
            errors.append(f"frozen corpus missing leakage source roles {missing_roles}")
        if receipt_path is None:
            errors.append("frozen corpus requires a leakage screening receipt")
        if errors:
            raise BenchmarkValidationError(errors)
    if receipt_path is not None:
        if not receipt_path.is_file():
            raise BenchmarkValidationError([f"missing leakage receipt: {receipt_path}"])
        validate_leakage_receipt(receipt_path, rows=rows, sources=sources)

    manifest = build_manifest(
        rows=rows,
        corpus_path=corpus_path,
        sources=sources,
        receipt_path=receipt_path,
        release_profile=args.release_profile,
    )
    if args.manifest_out:
        write_manifest(args.manifest_out.expanduser().resolve(), manifest)
    print(
        canonical_json(
            {
                "status": "valid",
                "row_count": len(rows),
                "family_count": manifest["family_count"],
                "benchmark_content_sha256": manifest["benchmark_content_sha256"],
            }
        )
    )
    return 0


def hash_command(args: argparse.Namespace) -> int:
    rows = read_benchmark(args.corpus.expanduser().resolve())
    validate_rows(rows, release_profile=args.release_profile)
    print(benchmark_content_sha256(rows))
    return 0


def validate_ratings_command(args: argparse.Namespace) -> int:
    corpus_path = args.corpus.expanduser().resolve()
    benchmark_manifest_path = args.benchmark_manifest.expanduser().resolve()
    ratings_path = args.ratings.expanduser().resolve()
    rows = read_benchmark(corpus_path)
    benchmark_manifest = validate_benchmark_manifest_for_ratings(
        benchmark_manifest_path, rows=rows, corpus_path=corpus_path
    )
    ratings = read_ratings(ratings_path)
    workflow_stats = validate_rating_rows(
        ratings,
        corpus_rows=rows,
        expected_model_labels=args.expected_model_label,
    )
    manifest = build_rating_manifest(
        ratings=ratings,
        ratings_path=ratings_path,
        benchmark_manifest=benchmark_manifest,
        benchmark_manifest_sha256=sha256_file(benchmark_manifest_path),
        expected_model_labels=args.expected_model_label,
        workflow_stats=workflow_stats,
    )
    if args.manifest_out:
        write_manifest(args.manifest_out.expanduser().resolve(), manifest)
    print(
        canonical_json(
            {
                "status": "valid",
                "rating_count": len(ratings),
                "rating_content_sha256": manifest["rating_content_sha256"],
                "workflow_stats": workflow_stats,
            }
        )
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser(
        "validate", help="validate a corpus and optionally write its deterministic manifest"
    )
    validate_parser.add_argument("--corpus", type=Path, required=True)
    validate_parser.add_argument(
        "--release-profile",
        action="store_true",
        help="enforce the 160-development/320-frozen per-language matrix",
    )
    validate_parser.add_argument(
        "--leakage-source",
        action="append",
        default=[],
        metavar="ROLE:NAME=PATH",
        help="screen against a pinned training, prior-eval, or blocked-family input",
    )
    validate_parser.add_argument("--leakage-receipt", type=Path)
    validate_parser.add_argument("--manifest-out", type=Path)
    validate_parser.set_defaults(func=validate_command)

    hash_parser = subparsers.add_parser(
        "content-hash", help="validate structure and print the order-independent content hash"
    )
    hash_parser.add_argument("--corpus", type=Path, required=True)
    hash_parser.add_argument("--release-profile", action="store_true")
    hash_parser.set_defaults(func=hash_command)

    ratings_parser = subparsers.add_parser(
        "validate-ratings",
        help="validate complete blinded native ratings for a sealed release-profile corpus",
    )
    ratings_parser.add_argument("--corpus", type=Path, required=True)
    ratings_parser.add_argument("--benchmark-manifest", type=Path, required=True)
    ratings_parser.add_argument("--ratings", type=Path, required=True)
    ratings_parser.add_argument(
        "--expected-model-label",
        action="append",
        required=True,
        help="predeclared opaque model label; repeat once per model arm",
    )
    ratings_parser.add_argument("--manifest-out", type=Path)
    ratings_parser.set_defaults(func=validate_ratings_command)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (BenchmarkValidationError, json.JSONDecodeError, OSError) as exc:
        if isinstance(exc, BenchmarkValidationError):
            for error in exc.errors:
                print(f"ERROR: {error}", file=sys.stderr)
        else:
            print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
