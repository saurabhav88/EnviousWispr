#!/usr/bin/env python3
"""Plan and gate EG-1 D1 multilingual training data.

This tool does not author examples or start training. It creates deterministic
family slots, validates authored rows, and exports a trainable JSONL only after
the contract, blocked-family registry, leakage receipt, and native reviews all
pass. Release export has a separate explicit approval gate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


CONTRACT_SCHEMA = "eg1-multilingual-d1-contract-v1"
REGISTRY_SCHEMA = "eg1-d1-blocked-family-registry-v1"
LEAKAGE_SCHEMA = "eg1-d1-leakage-receipt-v1"
BULLET_LINE = re.compile(r"^\s*[-*\u2022]\s+\S", re.MULTILINE)
NUMBERED_LINE = re.compile(r"^\s*\d+[.)]\s+\S", re.MULTILINE)
REQUIRED_ROW_FIELDS = {
    "family_id",
    "semantic_origin_id",
    "language",
    "split",
    "stratum",
    "pair_id",
    "behavior",
    "domain",
    "length_bucket",
    "difficulty",
    "safety_risk",
    "item_count",
    "list_type",
    "restraint_type",
    "origin_mode",
    "cross_language_concept_id",
    "semantic_scenario_id",
    "authoring_template_id",
    "source_provenance",
    "input",
    "output",
    "checks",
    "native_reviewed",
    "native_review",
}
REQUIRED_CHECK_FIELDS = {
    "meaning",
    "entities",
    "numbers",
    "timing",
    "attribution",
    "formatting",
    "compound_scope",
}
SLOT_FIELDS = (
    "language",
    "split",
    "stratum",
    "pair_id",
    "behavior",
    "domain",
    "length_bucket",
    "difficulty",
    "safety_risk",
    "item_count",
    "list_type",
    "restraint_type",
    "origin_mode",
    "cross_language_concept_id",
)


class ValidationFailure(Exception):
    """Raised for malformed input that cannot produce a trustworthy report."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold()
    return " ".join(re.findall(r"\w+", text, flags=re.UNICODE))


def normalized_sha256(text: str) -> str:
    return hashlib.sha256(normalized(text).encode("utf-8")).hexdigest()


def token_jaccard(left: str, right: str) -> float:
    left_tokens = set(normalized(left).split())
    right_tokens = set(normalized(right).split())
    if not left_tokens and not right_tokens:
        return 1.0
    return len(left_tokens & right_tokens) / len(left_tokens | right_tokens)


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationFailure(f"{path}: cannot read valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ValidationFailure(f"{path}: expected a JSON object")
    return value


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        handle = path.open(encoding="utf-8")
    except OSError as error:
        raise ValidationFailure(f"{path}: cannot open: {error}") from error
    with handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValidationFailure(
                    f"{path}:{line_number}: invalid JSON: {error}"
                ) from error
            if not isinstance(row, dict):
                raise ValidationFailure(f"{path}:{line_number}: expected an object")
            rows.append(row)
    return rows


def write_json_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def write_jsonl_atomic(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def deterministic_values(
    totals: dict[str, int], *, seed: int, namespace: str
) -> list[str]:
    expanded: list[tuple[str, int]] = []
    for value, count in sorted(totals.items()):
        if not isinstance(count, int) or count < 0:
            raise ValidationFailure(f"{namespace}: invalid count for {value!r}")
        expanded.extend((value, occurrence) for occurrence in range(count))

    def sort_key(item: tuple[str, int]) -> str:
        value, occurrence = item
        material = f"{seed}|{namespace}|{value}|{occurrence}".encode("utf-8")
        return hashlib.sha256(material).hexdigest()

    expanded.sort(key=sort_key)
    return [value for value, _ in expanded]


def risk_for_domain(domain: str, legal_financial_occurrence: int) -> str:
    if domain == "medical":
        return "medical"
    if domain == "legal_financial":
        return "legal" if legal_financial_occurrence % 2 == 0 else "financial"
    return "standard"


def build_abstract_slots(contract: dict[str, Any]) -> list[dict[str, Any]]:
    seed = contract["seed"]
    strata = contract["strata"]
    domains = contract["domains"]
    lengths = contract["length_buckets"]
    difficulties = contract["difficulty_levels"]
    abstract: list[dict[str, Any]] = []

    core = strata["core"]
    behaviors = core["behaviors"]
    rows_per_behavior = core["rows_per_behavior"]
    if rows_per_behavior * len(behaviors) != core["rows"]:
        raise ValidationFailure("core behavior counts do not sum to core rows")
    if rows_per_behavior != 12 or len(domains) != 5:
        raise ValidationFailure("D1 core allocation requires 12 rows and 5 domains")

    core_number = 0
    for behavior_index, behavior in enumerate(behaviors):
        domain_totals = {domain: 2 for domain in domains}
        domain_totals[domains[behavior_index % len(domains)]] += 1
        domain_totals[domains[(behavior_index + 2) % len(domains)]] += 1
        behavior_domains = deterministic_values(
            domain_totals, seed=seed, namespace=f"core:{behavior}:domain"
        )
        behavior_lengths = deterministic_values(
            {value: 3 for value in lengths},
            seed=seed,
            namespace=f"core:{behavior}:length",
        )
        behavior_difficulties = deterministic_values(
            {value: 4 for value in difficulties},
            seed=seed,
            namespace=f"core:{behavior}:difficulty",
        )
        legal_financial_seen = 0
        for local_index in range(rows_per_behavior):
            core_number += 1
            domain = behavior_domains[local_index]
            risk = risk_for_domain(domain, legal_financial_seen)
            if domain == "legal_financial":
                legal_financial_seen += 1
            abstract.append(
                {
                    "abstract_id": f"CORE-{core_number:03d}",
                    "stratum": "core",
                    "pair_number": None,
                    "behavior": behavior,
                    "domain": domain,
                    "length_bucket": behavior_lengths[local_index],
                    "difficulty": behavior_difficulties[local_index],
                    "safety_risk": risk,
                    "item_count": None,
                    "list_type": None,
                    "restraint_type": None,
                }
            )

    positive = strata["positive_list"]
    positive_count = positive["rows"]
    item_counts = [int(value) for value in positive["item_count_totals"]]
    list_types = list(positive["list_type_totals"])
    if len(item_counts) != 4 or len(list_types) != 5:
        raise ValidationFailure("D1 positive allocation requires 4 item counts and 5 list types")
    cell_count = len(item_counts) * len(list_types)
    if positive_count % cell_count:
        raise ValidationFailure("positive rows must divide evenly across item-count/list-type cells")
    repetitions = positive_count // cell_count
    combinations: list[dict[str, Any]] = []
    for repetition in range(repetitions):
        for item_index, item_count in enumerate(item_counts):
            for list_index, list_type in enumerate(list_types):
                domain = domains[(item_index + list_index + repetition + seed) % len(domains)]
                length = lengths[
                    (item_index + 2 * list_index + 3 * repetition + seed) % len(lengths)
                ]
                combinations.append(
                    {
                        "item_count": item_count,
                        "list_type": list_type,
                        "domain": domain,
                        "length_bucket": length,
                        "repetition": repetition,
                    }
                )
    combinations.sort(
        key=lambda row: hashlib.sha256(
            (
                f"{seed}|positive:combination|{row['item_count']}|{row['list_type']}|"
                f"{row['domain']}|{row['length_bucket']}|{row['repetition']}"
            ).encode("utf-8")
        ).hexdigest()
    )
    difficulties_for_positive = deterministic_values(
        positive["difficulty_totals"], seed=seed, namespace="positive:difficulty"
    )
    if len(combinations) != positive_count or len(difficulties_for_positive) != positive_count:
        raise ValidationFailure("positive-list axis totals do not match positive rows")
    computed_totals = {
        "item_count_totals": Counter(str(row["item_count"]) for row in combinations),
        "list_type_totals": Counter(row["list_type"] for row in combinations),
        "domain_totals": Counter(row["domain"] for row in combinations),
        "length_totals": Counter(row["length_bucket"] for row in combinations),
        "difficulty_totals": Counter(difficulties_for_positive),
    }
    for contract_key, actual in computed_totals.items():
        if actual != Counter(positive[contract_key]):
            raise ValidationFailure(f"computed positive {contract_key} does not match contract")

    positive_slots: list[dict[str, Any]] = []
    legal_financial_seen = 0
    for index in range(positive_count):
        combination = combinations[index]
        domain = combination["domain"]
        risk = risk_for_domain(domain, legal_financial_seen)
        if domain == "legal_financial":
            legal_financial_seen += 1
        slot = {
            "abstract_id": f"POS-{index + 1:03d}",
            "stratum": "positive_list",
            "pair_number": index + 1,
            "behavior": "list_activation",
            "domain": domain,
            "length_bucket": combination["length_bucket"],
            "difficulty": difficulties_for_positive[index],
            "safety_risk": risk,
            "item_count": combination["item_count"],
            "list_type": combination["list_type"],
            "restraint_type": None,
        }
        abstract.append(slot)
        positive_slots.append(slot)

    restraint = strata["matched_restraint"]
    restraint_types = deterministic_values(
        restraint["restraint_type_totals"],
        seed=seed,
        namespace="restraint:type",
    )
    if len(restraint_types) != positive_count or restraint["rows"] != positive_count:
        raise ValidationFailure("restraint totals must match positive-list rows")
    for index, paired in enumerate(positive_slots):
        abstract.append(
            {
                "abstract_id": f"RST-{index + 1:03d}",
                "stratum": "matched_restraint",
                "pair_number": index + 1,
                "behavior": "list_restraint",
                "domain": paired["domain"],
                "length_bucket": paired["length_bucket"],
                "difficulty": paired["difficulty"],
                "safety_risk": paired["safety_risk"],
                "item_count": paired["item_count"],
                "list_type": None,
                "restraint_type": restraint_types[index],
            }
        )

    expected_abstract = contract["language_rows"]
    if len(abstract) != expected_abstract:
        raise ValidationFailure(
            f"expected {expected_abstract} abstract slots, built {len(abstract)}"
        )

    origin_values = deterministic_values(
        contract["origin_modes"], seed=seed, namespace="origin_mode"
    )
    if len(origin_values) != len(abstract):
        raise ValidationFailure("origin-mode totals do not match language rows")
    shared_number = 0
    for slot, origin_mode in zip(abstract, origin_values):
        slot["origin_mode"] = origin_mode
        if origin_mode == "shared_concept_independent_rewrite":
            shared_number += 1
            slot["cross_language_concept_id"] = f"D1-XCON-{shared_number:03d}"
        else:
            slot["cross_language_concept_id"] = None
    return abstract


def build_slots(contract: dict[str, Any]) -> list[dict[str, Any]]:
    if contract.get("schema_version") != CONTRACT_SCHEMA:
        raise ValidationFailure("unsupported D1 contract schema")
    abstract = build_abstract_slots(contract)
    slots: list[dict[str, Any]] = []
    stratum_codes = {"core": "CORE", "positive_list": "POS", "matched_restraint": "RST"}
    for language in contract["languages"]:
        counters: Counter[str] = Counter()
        for source in abstract:
            stratum = source["stratum"]
            counters[stratum] += 1
            code = stratum_codes[stratum]
            family_id = f"D1-{language.upper()}-{code}-{counters[stratum]:03d}"
            pair_number = source["pair_number"]
            slots.append(
                {
                    "family_id": family_id,
                    "language": language,
                    "split": "train",
                    "stratum": stratum,
                    "pair_id": (
                        f"D1-{language.upper()}-PAIR-{pair_number:03d}"
                        if pair_number is not None
                        else None
                    ),
                    "behavior": source["behavior"],
                    "domain": source["domain"],
                    "length_bucket": source["length_bucket"],
                    "difficulty": source["difficulty"],
                    "safety_risk": source["safety_risk"],
                    "item_count": source["item_count"],
                    "list_type": source["list_type"],
                    "restraint_type": source["restraint_type"],
                    "origin_mode": source["origin_mode"],
                    "cross_language_concept_id": source["cross_language_concept_id"],
                }
            )
    if len(slots) != contract["total_rows"]:
        raise ValidationFailure(
            f"contract says {contract['total_rows']} rows, built {len(slots)}"
        )
    return slots


def verify_plan(contract: dict[str, Any], slots: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    for language in contract["languages"]:
        language_slots = [slot for slot in slots if slot["language"] == language]
        if len(language_slots) != contract["language_rows"]:
            errors.append(f"{language}: wrong language-row count")
        for stratum, definition in contract["strata"].items():
            actual = sum(slot["stratum"] == stratum for slot in language_slots)
            if actual != definition["rows"]:
                errors.append(f"{language}:{stratum}: expected {definition['rows']}, got {actual}")
        core_slots = [slot for slot in language_slots if slot["stratum"] == "core"]
        for behavior in contract["strata"]["core"]["behaviors"]:
            behavior_slots = [slot for slot in core_slots if slot["behavior"] == behavior]
            if len(behavior_slots) != contract["strata"]["core"]["rows_per_behavior"]:
                errors.append(f"{language}:{behavior}: wrong core behavior count")
            if not {"medical", "legal_financial"}.issubset(
                {slot["domain"] for slot in behavior_slots}
            ):
                errors.append(f"{language}:{behavior}: missing high-risk domains")
        pair_groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for slot in language_slots:
            if slot["pair_id"]:
                pair_groups[slot["pair_id"]].append(slot)
        for pair_id, pair in pair_groups.items():
            if len(pair) != 2:
                errors.append(f"{pair_id}: expected exactly two slots")
                continue
            by_stratum = {slot["stratum"]: slot for slot in pair}
            if set(by_stratum) != {"positive_list", "matched_restraint"}:
                errors.append(f"{pair_id}: wrong pair strata")
                continue
            for field in ("domain", "length_bucket", "difficulty", "safety_risk", "item_count"):
                if by_stratum["positive_list"][field] != by_stratum["matched_restraint"][field]:
                    errors.append(f"{pair_id}: paired {field} does not match")
    return errors


def registry_state(
    contract: dict[str, Any], registry: dict[str, Any]
) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    blockers: list[str] = []
    if registry.get("schema_version") != REGISTRY_SCHEMA:
        errors.append("blocked registry has unsupported schema")
        return errors, blockers
    required_groups = registry.get("required_groups")
    if not isinstance(required_groups, dict):
        errors.append("blocked registry required_groups must be an object")
        return errors, blockers
    selector_fields = (
        "exact_family_ids",
        "family_prefixes",
        "semantic_origin_ids",
        "normalized_input_sha256",
        "normalized_output_sha256",
    )
    for field in selector_fields:
        value = registry.get(field)
        if not isinstance(value, list) or any(
            not isinstance(item, str) or not item for item in value
        ):
            errors.append(f"blocked registry {field} must be a list of nonempty strings")
    for group in contract["blocked_registry_required_groups"]:
        value = required_groups.get(group)
        if not isinstance(value, dict):
            blockers.append(f"blocked registry group {group} is missing")
            continue
        source_digest = value.get("source_artifact_sha256")
        digest_is_sealed = isinstance(source_digest, str) and bool(
            re.fullmatch(r"[0-9a-f]{64}", source_digest)
        )
        if value.get("status") != "complete" or not digest_is_sealed:
            blockers.append(f"blocked registry group {group} is not complete and sealed")
    if registry.get("status") != "sealed":
        blockers.append("blocked registry status is not sealed")
    if not isinstance(registry.get("registry_id"), str) or registry["registry_id"].startswith(
        "REPLACE_"
    ):
        blockers.append("blocked registry ID is not finalized")
    return errors, blockers


def prompt_state(contract_path: Path, contract: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    prompt = contract.get("prompt")
    if not isinstance(prompt, dict):
        return {}, ["contract prompt section is missing"]
    raw_path = prompt.get("path")
    if not isinstance(raw_path, str) or not raw_path:
        return {}, ["contract prompt path is missing"]
    prompt_path = Path(raw_path)
    if not prompt_path.is_absolute():
        repository_root = Path(__file__).resolve().parents[2]
        prompt_path = repository_root / prompt_path
    if not prompt_path.is_file():
        return {}, [f"pinned prompt is missing: {prompt_path}"]
    actual_hash = sha256_file(prompt_path)
    expected_hash = prompt.get("sha256")
    if actual_hash != expected_hash:
        return {}, ["pinned prompt hash does not match the D1 contract"]
    return {
        "path": str(prompt_path.resolve()),
        "template_id": prompt.get("template_id"),
        "sha256": actual_hash,
        "development_only": bool(prompt.get("development_only")),
    }, []


def validate_candidate_rows(
    contract: dict[str, Any],
    slots: list[dict[str, Any]],
    rows: list[dict[str, Any]],
    registry: dict[str, Any],
) -> tuple[list[str], list[str], dict[str, Any]]:
    errors: list[str] = []
    blockers: list[str] = []
    expected = {slot["family_id"]: slot for slot in slots}
    actual_by_id: dict[str, dict[str, Any]] = {}
    input_counts: Counter[str] = Counter()
    output_counts: Counter[str] = Counter()
    reviewed_count = 0
    language_counts: Counter[str] = Counter()
    stratum_counts: Counter[tuple[str, str]] = Counter()

    exact_blocked_ids = set(registry.get("exact_family_ids", []))
    blocked_prefixes = tuple(registry.get("family_prefixes", []))
    blocked_origins = set(registry.get("semantic_origin_ids", []))
    blocked_inputs = set(registry.get("normalized_input_sha256", []))
    blocked_outputs = set(registry.get("normalized_output_sha256", []))

    for row_number, row in enumerate(rows, 1):
        missing = REQUIRED_ROW_FIELDS - set(row)
        if missing:
            errors.append(f"row {row_number}: missing fields {sorted(missing)}")
            continue
        family_id = row["family_id"]
        if not isinstance(family_id, str) or not family_id:
            errors.append(f"row {row_number}: family_id must be a nonempty string")
            continue
        if family_id in actual_by_id:
            errors.append(f"{family_id}: duplicate family_id")
            continue
        actual_by_id[family_id] = row
        slot = expected.get(family_id)
        if slot is None:
            errors.append(f"{family_id}: not allocated by the D1 contract")
            continue
        for field in SLOT_FIELDS:
            if row.get(field) != slot[field]:
                errors.append(
                    f"{family_id}: {field} must be {slot[field]!r}, got {row.get(field)!r}"
                )

        semantic_origin_id = row["semantic_origin_id"]
        if not isinstance(semantic_origin_id, str) or not semantic_origin_id:
            errors.append(f"{family_id}: semantic_origin_id must be nonempty")
        if family_id in exact_blocked_ids or semantic_origin_id in exact_blocked_ids or (
            blocked_prefixes and family_id.startswith(blocked_prefixes)
        ):
            errors.append(f"{family_id}: family is blocked")
        if semantic_origin_id in blocked_origins or (
            blocked_prefixes and semantic_origin_id.startswith(blocked_prefixes)
        ):
            errors.append(f"{family_id}: semantic origin is blocked")

        input_text = row["input"]
        output_text = row["output"]
        if not isinstance(input_text, str) or not input_text.strip():
            errors.append(f"{family_id}: input must be nonempty text")
            continue
        if not isinstance(output_text, str) or not output_text.strip():
            errors.append(f"{family_id}: output must be nonempty text")
            continue
        input_key = normalized(input_text)
        output_key = normalized(output_text)
        input_counts[input_key] += 1
        output_counts[output_key] += 1
        if normalized_sha256(input_text) in blocked_inputs:
            errors.append(f"{family_id}: normalized input is blocked")
        if normalized_sha256(output_text) in blocked_outputs:
            errors.append(f"{family_id}: normalized output is blocked")

        checks = row["checks"]
        if not isinstance(checks, dict) or not REQUIRED_CHECK_FIELDS.issubset(checks):
            errors.append(f"{family_id}: checks are incomplete")
        elif row["safety_risk"] in {"medical", "legal", "financial"}:
            if not checks.get("timing") or not checks.get("attribution"):
                errors.append(f"{family_id}: high-risk row needs timing and attribution checks")

        bullet_lines = BULLET_LINE.findall(output_text)
        numbered_lines = NUMBERED_LINE.findall(output_text)
        list_line_count = len(bullet_lines) + len(numbered_lines)
        if row["stratum"] == "positive_list":
            if list_line_count != row["item_count"]:
                errors.append(
                    f"{family_id}: expected {row['item_count']} list lines, got {list_line_count}"
                )
            formatting = checks.get("formatting") if isinstance(checks, dict) else None
            expected_format = (
                "numbered" if row["list_type"] == "explicit_numbering" else "bullets"
            )
            if formatting != expected_format:
                errors.append(f"{family_id}: formatting check must be {expected_format}")
            if row["list_type"] == "explicit_numbering":
                if len(numbered_lines) != row["item_count"] or bullet_lines:
                    errors.append(
                        f"{family_id}: explicit_numbering output must use exactly "
                        f"{row['item_count']} numbered markers"
                    )
            elif len(bullet_lines) != row["item_count"] or numbered_lines:
                errors.append(
                    f"{family_id}: {row['list_type']} output must use exactly "
                    f"{row['item_count']} bullet markers"
                )
        elif row["stratum"] == "matched_restraint" and list_line_count:
            errors.append(f"{family_id}: restraint output contains list lines")

        provenance = row["source_provenance"]
        required_provenance = {
            "source_id",
            "author_id",
            "author_type",
            "author_language",
            "origin_mode",
        }
        if not isinstance(provenance, dict) or not required_provenance.issubset(provenance):
            errors.append(f"{family_id}: source provenance is incomplete")
        else:
            if provenance["origin_mode"] != row["origin_mode"]:
                errors.append(f"{family_id}: provenance origin_mode does not match slot")
            if provenance["author_language"] != row["language"]:
                errors.append(f"{family_id}: author language must match row language")
            author_type = provenance["author_type"]
            if author_type not in {"human_native", "synthetic_native"}:
                blockers.append(f"{family_id}: author is not native-language qualified")
            elif author_type == "synthetic_native":
                synthetic_fields = (
                    "author_model_id",
                    "author_configuration_id",
                    "critic_model_id",
                    "critic_configuration_id",
                )
                if any(not provenance.get(field) for field in synthetic_fields):
                    errors.append(f"{family_id}: synthetic provenance is incomplete")
                elif (
                    provenance["author_model_id"],
                    provenance["author_configuration_id"],
                ) == (
                    provenance["critic_model_id"],
                    provenance["critic_configuration_id"],
                ):
                    errors.append(f"{family_id}: synthetic author and critic are identical")

        native_review = row["native_review"]
        if not isinstance(row["native_reviewed"], bool) or not isinstance(native_review, dict):
            errors.append(f"{family_id}: native-review fields are malformed")
        else:
            status = native_review.get("status")
            if row["native_reviewed"]:
                if status != "approved":
                    errors.append(f"{family_id}: native_reviewed conflicts with review status")
                required_review = (
                    "reviewer_id",
                    "reviewer_type",
                    "reviewer_language",
                    "reviewed_at",
                )
                if any(not native_review.get(field) for field in required_review):
                    errors.append(f"{family_id}: approved native review lacks identity/time")
                elif native_review["reviewer_type"] != "human_native":
                    errors.append(f"{family_id}: native reviewer must be human_native")
                elif native_review["reviewer_language"] != row["language"]:
                    errors.append(f"{family_id}: reviewer language does not match row language")
                elif isinstance(provenance, dict) and native_review["reviewer_id"] == provenance.get(
                    "author_id"
                ):
                    errors.append(f"{family_id}: author cannot approve their own native review")
                else:
                    reviewed_count += 1
            else:
                if status not in {"pending", "not_selected"}:
                    errors.append(f"{family_id}: unreviewed row has invalid review status")
                blockers.append(f"{family_id}: native review is not approved")

        language_counts[row["language"]] += 1
        stratum_counts[(row["language"], row["stratum"])] += 1

    missing_ids = sorted(set(expected) - set(actual_by_id))
    if missing_ids:
        errors.append(f"missing {len(missing_ids)} allocated families; first={missing_ids[0]}")
    if len(rows) != len(slots):
        errors.append(f"expected {len(slots)} rows, got {len(rows)}")
    for text, count in input_counts.items():
        if text and count > 1:
            errors.append(f"normalized input appears {count} times: {text[:80]!r}")
    for text, count in output_counts.items():
        if text and count > 1:
            errors.append(f"normalized output appears {count} times: {text[:80]!r}")

    pair_rows: dict[str, list[dict[str, Any]]] = defaultdict(list)
    shared_rows: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in actual_by_id.values():
        if row.get("pair_id"):
            pair_rows[row["pair_id"]].append(row)
        if row.get("cross_language_concept_id"):
            shared_rows[row["cross_language_concept_id"]].append(row)
    for pair_id, pair in pair_rows.items():
        if len(pair) != 2:
            continue
        positive = next((row for row in pair if row["stratum"] == "positive_list"), None)
        restraint = next((row for row in pair if row["stratum"] == "matched_restraint"), None)
        if not positive or not restraint:
            continue
        if positive["authoring_template_id"] == restraint["authoring_template_id"]:
            errors.append(f"{pair_id}: positive and restraint reuse an authoring template")
        if positive["semantic_scenario_id"] == restraint["semantic_scenario_id"]:
            errors.append(f"{pair_id}: positive and restraint reuse a semantic scenario")
        if token_jaccard(positive["input"], restraint["input"]) >= 0.80:
            errors.append(f"{pair_id}: positive/restraint wording is too similar")

    expected_languages = set(contract["languages"])
    for concept_id, concept_rows in shared_rows.items():
        if {row["language"] for row in concept_rows} != expected_languages:
            errors.append(f"{concept_id}: shared concept does not cover all five languages")
        if len({row["authoring_template_id"] for row in concept_rows}) != len(concept_rows):
            errors.append(f"{concept_id}: shared concept reuses an authoring template")
        comparison_fields = (
            "stratum",
            "behavior",
            "domain",
            "length_bucket",
            "difficulty",
            "item_count",
            "list_type",
            "restraint_type",
        )
        for field in comparison_fields:
            if len({row[field] for row in concept_rows}) != 1:
                errors.append(f"{concept_id}: cross-language {field} allocation differs")

    metrics = {
        "row_count": len(rows),
        "native_reviewed_count": reviewed_count,
        "language_counts": dict(sorted(language_counts.items())),
        "stratum_counts": {
            f"{language}:{stratum}": count
            for (language, stratum), count in sorted(stratum_counts.items())
        },
        "shared_concept_count": len(shared_rows),
    }
    return errors, sorted(set(blockers)), metrics


def leakage_state(
    contract: dict[str, Any],
    receipt: dict[str, Any] | None,
    *,
    candidate_sha256: str,
    registry_sha256: str,
    prompt_sha256: str,
) -> list[str]:
    blockers: list[str] = []
    if receipt is None:
        return ["sealed leakage receipt is missing"]
    if receipt.get("schema_version") != LEAKAGE_SCHEMA:
        return ["leakage receipt has unsupported schema"]
    if receipt.get("status") != "pass":
        blockers.append("leakage receipt status is not pass")
    expected_hashes = {
        "candidate_rows_sha256": candidate_sha256,
        "blocked_registry_sha256": registry_sha256,
        "prompt_sha256": prompt_sha256,
    }
    for field, expected in expected_hashes.items():
        if receipt.get(field) != expected:
            blockers.append(f"leakage receipt {field} does not match current artifacts")
    checks = receipt.get("checks")
    if not isinstance(checks, dict):
        return blockers + ["leakage receipt checks are missing"]
    for check_name in contract["leakage_receipt_required_checks"]:
        check = checks.get(check_name)
        if not isinstance(check, dict) or check.get("status") != "pass":
            blockers.append(f"leakage check {check_name} is not pass")
        elif check.get("matches") != 0:
            blockers.append(f"leakage check {check_name} reports matches")
    return blockers


def evaluate(
    *,
    contract_path: Path,
    rows_path: Path,
    registry_path: Path,
    purpose: str,
    leakage_receipt_path: Path | None,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    contract = read_json(contract_path)
    rows = read_jsonl(rows_path)
    registry = read_json(registry_path)
    receipt = read_json(leakage_receipt_path) if leakage_receipt_path else None
    slots = build_slots(contract)
    errors = verify_plan(contract, slots)
    registry_errors, registry_blockers = registry_state(contract, registry)
    errors.extend(registry_errors)
    row_errors, row_blockers, metrics = validate_candidate_rows(
        contract, slots, rows, registry
    )
    errors.extend(row_errors)
    prompt, prompt_blockers = prompt_state(contract_path, contract)
    blockers = registry_blockers + row_blockers + prompt_blockers

    candidate_sha = sha256_file(rows_path)
    registry_sha = sha256_file(registry_path)
    if purpose in {"training", "release"}:
        if not contract.get("approval", {}).get("training_export_allowed"):
            blockers.append("D1 contract has no training-export approval")
        blockers.extend(
            leakage_state(
                contract,
                receipt,
                candidate_sha256=candidate_sha,
                registry_sha256=registry_sha,
                prompt_sha256=prompt.get("sha256", ""),
            )
        )
    if purpose == "release":
        if contract.get("prompt", {}).get("development_only"):
            blockers.append("development-only prompt cannot produce release data")
        if not contract.get("approval", {}).get("release_export_allowed"):
            blockers.append("D1 contract has no release-export approval")

    errors = sorted(set(errors))
    blockers = sorted(set(blockers))
    passed = not errors and (purpose == "draft" or not blockers)
    ordered_rows: list[dict[str, Any]] = []
    if not errors:
        by_id = {row["family_id"]: row for row in rows}
        ordered_rows = [by_id[slot["family_id"]] for slot in slots]
    report = {
        "schema_version": "eg1-d1-validation-report-v1",
        "status": "pass" if passed else "fail",
        "purpose": purpose,
        "eligible_for_training_export": (
            passed and purpose in {"training", "release"}
        ),
        "eligible_for_release_export": (
            passed and purpose == "release"
        ),
        "contract": {
            "path": str(contract_path.resolve()),
            "sha256": sha256_file(contract_path),
            "seed": contract.get("seed"),
        },
        "candidate_rows": {
            "path": str(rows_path.resolve()),
            "sha256": candidate_sha,
        },
        "blocked_registry": {
            "path": str(registry_path.resolve()),
            "sha256": registry_sha,
            "status": registry.get("status"),
        },
        "prompt": prompt,
        "metrics": metrics,
        "errors": errors,
        "promotion_blockers": blockers,
    }
    return report, ordered_rows


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    slots_parser = subparsers.add_parser(
        "slots", help="write deterministic allocation slots without example text"
    )
    slots_parser.add_argument("--contract", required=True)
    slots_parser.add_argument("--output", required=True)

    validate_parser = subparsers.add_parser(
        "validate", help="validate draft rows or export approved training/release rows"
    )
    validate_parser.add_argument("--contract", required=True)
    validate_parser.add_argument("--rows", required=True)
    validate_parser.add_argument("--blocked-registry", required=True)
    validate_parser.add_argument("--purpose", choices=("draft", "training", "release"), required=True)
    validate_parser.add_argument("--leakage-receipt")
    validate_parser.add_argument("--report", required=True)
    validate_parser.add_argument("--output")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        if args.command == "slots":
            output_path = Path(args.output).resolve()
            if output_path.exists():
                raise ValidationFailure(f"refusing to overwrite existing output: {output_path}")
            contract_path = Path(args.contract).resolve()
            contract = read_json(contract_path)
            slots = build_slots(contract)
            plan_errors = verify_plan(contract, slots)
            if plan_errors:
                raise ValidationFailure("; ".join(plan_errors))
            write_jsonl_atomic(output_path, slots)
            print(f"wrote {len(slots)} allocation slots to {output_path}")
            return

        report_path = Path(args.report).resolve()
        output_path = Path(args.output).resolve() if args.output else None
        if args.purpose == "draft" and output_path is not None:
            raise ValidationFailure("draft validation cannot write a trainable output")
        if args.purpose in {"training", "release"} and output_path is None:
            raise ValidationFailure(f"{args.purpose} purpose requires --output")
        if output_path is not None and output_path.exists():
            raise ValidationFailure(f"refusing to overwrite existing output: {output_path}")

        report, ordered_rows = evaluate(
            contract_path=Path(args.contract).resolve(),
            rows_path=Path(args.rows).resolve(),
            registry_path=Path(args.blocked_registry).resolve(),
            purpose=args.purpose,
            leakage_receipt_path=(
                Path(args.leakage_receipt).resolve() if args.leakage_receipt else None
            ),
        )
        write_json_atomic(report_path, report)
        if report["status"] != "pass":
            raise ValidationFailure(
                f"validation failed: {len(report['errors'])} errors, "
                f"{len(report['promotion_blockers'])} promotion blockers; see {report_path}"
            )
        if output_path is not None:
            write_jsonl_atomic(output_path, ordered_rows)
            manifest = {
                "schema_version": "eg1-d1-export-manifest-v1",
                "purpose": args.purpose,
                "row_count": len(ordered_rows),
                "dataset_path": str(output_path),
                "dataset_sha256": sha256_file(output_path),
                "validation_report_path": str(report_path),
                "validation_report_sha256": sha256_file(report_path),
                "native_reviewed_count": report["metrics"]["native_reviewed_count"],
                "prompt_sha256": report["prompt"]["sha256"],
                "contract_sha256": report["contract"]["sha256"],
                "blocked_registry_sha256": report["blocked_registry"]["sha256"],
            }
            manifest_path = output_path.with_suffix(output_path.suffix + ".manifest.json")
            write_json_atomic(manifest_path, manifest)
            print(f"exported {len(ordered_rows)} approved rows to {output_path}")
        else:
            print(f"draft validation passed; report: {report_path}")
    except ValidationFailure as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2) from error


if __name__ == "__main__":
    main()
