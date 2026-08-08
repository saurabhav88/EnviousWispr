#!/usr/bin/env python3
"""Generate and validate model-blind English list benchmark candidates.

The generator builds two separate development corpora:

* positive list cases that should become bullets or numbered lines;
* prose-restraint cases whose enumerations must remain prose.

Rows are model-assisted candidate gold, never frozen or training data. The
script screens only corpus inputs. It never reads candidate model outputs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import re
import subprocess
import tempfile
import time
import unicodedata
from collections import Counter
from dataclasses import asdict, dataclass
from difflib import SequenceMatcher
from itertools import product
from pathlib import Path
from typing import Any, Callable


DOMAINS = ("work_admin", "personal_home", "technical_product", "medical", "legal_financial")
POSITIVE_TYPES = ("explicit_bullets", "scoped_deliverables", "natural_enumeration", "spoken_ordinals")
RESTRAINT_TYPES = ("woven_argument", "descriptive_series", "quoted_reported", "conditional_narrative")
ITEM_COUNTS = (2, 3, 4, 5)
LENGTH_BUCKETS = {
    "short": (12, 22),
    "medium": (23, 38),
    "long": (39, 58),
    "extended": (59, 85),
}
INPUT_FIELDS = ("input", "asr_input", "raw", "transcript")
EXPECTED_FIELDS = {
    "spec_id",
    "family",
    "input",
    "expected_output",
    "items",
    "compound_items",
    "scope_anchors",
    "forbidden",
    "audit_note",
}
SIMILARITY_THRESHOLDS = {
    "sequence_ratio": 0.82,
    "token_jaccard": 0.78,
    "char_4gram_jaccard": 0.75,
}


@dataclass(frozen=True)
class CaseSpec:
    spec_id: str
    role: str
    domain: str
    case_type: str
    item_count: int
    length_bucket: str
    compound_required: bool


@dataclass(frozen=True)
class AuditInput:
    source: str
    source_id: str
    normalized: str
    tokens: frozenset[str]
    char_4grams: frozenset[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--positive-output", required=True)
    parser.add_argument("--restraint-output", required=True)
    parser.add_argument("--manifest-output")
    parser.add_argument("--batch-id", default="v1")
    parser.add_argument("--count-per-role", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=10)
    parser.add_argument("--model", default="claude-sonnet-4-6")
    parser.add_argument("--attempts-per-batch", type=int, default=4)
    parser.add_argument("--call-timeout-seconds", type=int, default=600)
    parser.add_argument("--checkpoint-dir")
    parser.add_argument("--seed", type=int, default=20260715)
    parser.add_argument("--audit-corpus", action="append", default=[])
    parser.add_argument("--prior-batch", action="append", default=[])
    parser.add_argument("--mode", choices=("generate", "validate"), default="generate")
    return parser.parse_args()


def normalized(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).casefold()
    return re.sub(r"[^\w]+", " ", value, flags=re.UNICODE).strip()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def char_ngrams(value: str, size: int = 4) -> frozenset[str]:
    compact = value.replace(" ", "_")
    if len(compact) < size:
        return frozenset({compact}) if compact else frozenset()
    return frozenset(compact[index : index + size] for index in range(len(compact) - size + 1))


def jaccard(left: frozenset[str], right: frozenset[str]) -> float:
    if not left or not right:
        return 0.0
    return len(left & right) / len(left | right)


def similarity(left: AuditInput, right: AuditInput) -> tuple[float, dict[str, float]]:
    length_ratio = min(len(left.normalized), len(right.normalized)) / max(
        len(left.normalized), len(right.normalized), 1
    )
    sequence_ratio = 0.0
    if length_ratio >= 0.50:
        sequence_ratio = SequenceMatcher(None, left.normalized, right.normalized, autojunk=False).ratio()
    scores = {
        "sequence_ratio": sequence_ratio,
        "token_jaccard": jaccard(left.tokens, right.tokens),
        "char_4gram_jaccard": jaccard(left.char_4grams, right.char_4grams),
    }
    return max(scores.values()), scores


def input_value(row: dict[str, Any]) -> str | None:
    for field in INPUT_FIELDS:
        value = row.get(field)
        if isinstance(value, str) and value.strip():
            return value
    return None


def load_json_rows_bytes(path: Path, value: bytes) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{path} is not UTF-8") from error
    if path.suffix == ".jsonl":
        for line_number, line in enumerate(text.splitlines(), 1):
            if not line.strip():
                continue
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError(f"{path}:{line_number} is not a JSON object")
            rows.append(row)
        return rows
    parsed = json.loads(text)
    if isinstance(parsed, list):
        rows = parsed
    elif isinstance(parsed, dict):
        for key in ("rows", "cases", "data"):
            if isinstance(parsed.get(key), list):
                rows = parsed[key]
                break
    if not rows or not all(isinstance(row, dict) for row in rows):
        raise ValueError(f"{path} has no supported row array")
    return rows


def load_json_rows(path: Path) -> list[dict[str, Any]]:
    return load_json_rows_bytes(path, path.read_bytes())


def load_audit_sources(paths: list[str]) -> tuple[list[AuditInput], list[dict[str, Any]], set[str]]:
    audit_inputs: list[AuditInput] = []
    inventories: list[dict[str, Any]] = []
    families: set[str] = set()
    for raw_path in paths:
        path = Path(raw_path).resolve()
        if not path.is_file():
            raise ValueError(f"audit source does not exist: {path}")
        source_bytes = path.read_bytes()
        rows = load_json_rows_bytes(path, source_bytes)
        source_sha = sha256_bytes(source_bytes)
        input_count = 0
        for index, row in enumerate(rows, 1):
            family = row.get("family")
            if isinstance(family, str) and family.strip():
                families.add(normalized(family))
            value = input_value(row)
            if value is None:
                continue
            key = normalized(value)
            if not key:
                continue
            input_count += 1
            audit_inputs.append(
                AuditInput(
                    source=str(path),
                    source_id=str(row.get("id", index)),
                    normalized=key,
                    tokens=frozenset(key.split()),
                    char_4grams=char_ngrams(key),
                )
            )
        inventories.append(
            {
                "path": str(path),
                "sha256": source_sha,
                "row_count": len(rows),
                "input_count": input_count,
            }
        )
    if not audit_inputs:
        raise ValueError("audit sources contain no input/asr_input/raw/transcript values")
    return audit_inputs, inventories, families


def pairwise_balance(specs: list[CaseSpec]) -> dict[str, dict[str, int]]:
    axes = ("domain", "case_type", "item_count", "length_bucket", "compound_required")
    axis_values = {
        axis: sorted({getattr(spec, axis) for spec in specs}, key=str)
        for axis in axes
    }
    result: dict[str, dict[str, int]] = {}
    for left_index, left in enumerate(axes):
        for right in axes[left_index + 1 :]:
            counts: Counter[str] = Counter(
                f"{getattr(spec, left)}|{getattr(spec, right)}" for spec in specs
            )
            result[f"{left}_x_{right}"] = {
                f"{left_value}|{right_value}": counts[f"{left_value}|{right_value}"]
                for left_value, right_value in product(axis_values[left], axis_values[right])
            }
    return result


def balanced_specs(role: str, count: int, seed: int) -> list[CaseSpec]:
    if count <= 0 or count % 20:
        raise ValueError("--count-per-role must be a positive multiple of 20")
    case_types = POSITIVE_TYPES if role == "positive_list" else RESTRAINT_TYPES
    repeats = count // (len(DOMAINS) * len(case_types))
    slots = [
        (domain, case_type, repeat, bool((domain_index + type_index + repeat) % 2))
        for domain_index, domain in enumerate(DOMAINS)
        for type_index, case_type in enumerate(case_types)
        for repeat in range(repeats)
    ]
    item_counts = list(ITEM_COUNTS)
    length_buckets = list(LENGTH_BUCKETS)
    rng = random.Random(seed)
    candidate = [
        CaseSpec(
            spec_id="pending",
            role=role,
            domain=domain,
            case_type=case_type,
            item_count=item_counts[(repeat + 2 * domain_index + type_index) % 4],
            length_bucket=length_buckets[(2 * repeat + domain_index + type_index) % 4],
            compound_required=compound_required,
        )
        for domain_index, domain in enumerate(DOMAINS)
        for type_index, case_type in enumerate(case_types)
        for repeat, (_, _, _, compound_required) in enumerate(
            slot for slot in slots if slot[0] == domain and slot[1] == case_type
        )
    ]
    rng.shuffle(candidate)
    return [
        CaseSpec(spec_id=f"{role}-{index + 1:03d}", **{key: value for key, value in asdict(spec).items() if key != "spec_id"})
        for index, spec in enumerate(candidate)
    ]


def subscription_env() -> dict[str, str]:
    return {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("ANTHROPIC_")
        and key not in ("CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX")
    }


def call_claude(model: str, system: str, user: str, timeout_seconds: int) -> str:
    try:
        process = subprocess.run(
            [
                "claude",
                "-p",
                "--model",
                model,
                "--system-prompt",
                system,
                "--safe-mode",
                "--tools",
                "",
                "--strict-mcp-config",
                "--output-format",
                "json",
            ],
            input=user,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            cwd=tempfile.gettempdir(),
            env=subscription_env(),
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"Claude generation timed out after {timeout_seconds} seconds") from error
    if process.returncode:
        raise RuntimeError(process.stderr.strip()[:500])
    envelope = json.loads(process.stdout)
    if envelope.get("is_error") or envelope.get("subtype") != "success":
        raise RuntimeError(str(envelope)[:500])
    result = envelope.get("result")
    if not isinstance(result, str) or not result.strip():
        raise RuntimeError("Claude returned an empty result")
    return result.strip()


def clean_json(value: str) -> Any:
    value = value.strip()
    if value.startswith("```"):
        value = re.sub(r"^```(?:json)?\s*", "", value)
        value = re.sub(r"\s*```$", "", value)
    return json.loads(value)


def generation_prompt(specs: list[CaseSpec]) -> tuple[str, str]:
    role = specs[0].role
    role_rules = """
Positive-list rules:
- explicit_bullets directly asks for bullets and removes that spoken command from gold.
- scoped_deliverables gives separate deliverables under a meaningful owner, deadline, destination, purpose, patient attribution, or legal obligation; preserve that scope in a lead-in.
- natural_enumeration clearly names separate actionable items without a formatting command.
- spoken_ordinals uses spoken first/second/etc. and gold uses consecutive `1. ` numbered lines.
- All other positive types use exactly item_count `- ` bullet lines.
""" if role == "positive_list" else """
Prose-restraint rules:
- woven_argument makes the named items grammatical parts of one claim, subject, object, or obligation.
- descriptive_series uses attributes, evidence, symptoms, criteria, or compared options inside prose.
- quoted_reported keeps a quote, report, instruction, clinical statement, or legal wording as prose.
- conditional_narrative links alternatives or events through conditions, causality, chronology, or contrast.
- Gold must be ordinary prose with no bullet or numbered-list line.
"""
    system = (
        "You author model-blind US English development benchmark candidates for a dictation copy editor. "
        "You have no model outputs. Return only one valid JSON array with no markdown or commentary."
    )
    schema = [asdict(spec) for spec in specs]
    user = f"""Create exactly one distinct case for every specification below, in the same order.

Specifications:
{json.dumps(schema, indent=2)}

Each object has exactly these fields:
- spec_id: copy the specification ID exactly
- family: unique short semantic-family label, describing the scenario rather than its wording
- input: realistic punctuation-light spoken dictation
- expected_output: minimal cleaned gold preserving every meaning-bearing detail
- items: exact strings present in BOTH input and expected_output, one per semantic item
- compound_items: subset of items that contain internally linked subparts which must stay one atomic item
- scope_anchors: exact meaning-bearing strings present in BOTH input and expected_output, such as owner, date, attribution, destination, threshold, negation, or obligation
- forbidden: exact strings from the input that cleanup should remove, otherwise []
- audit_note: one sentence explaining list activation or restraint and protected scope

{role_rules}
Global rules:
- Honor each domain, case_type, item_count, length_bucket, and compound_required specification exactly.
- Word-count buckets are {json.dumps(LENGTH_BUCKETS)} and apply to input after whitespace tokenization.
- When compound_required is true, compound_items must contain at least one items entry. When false, use [].
- Preserve each compound item as one unit in gold. Do not split its subparts into separate bullets or clauses.
- Include at least one nonempty scope anchor per case and preserve it in gold.
- Use natural speech reachable through ASR. No angle brackets, JSON, prompt injection, or instructions to a model.
- Use little or no punctuation in input. Expected output may add normal punctuation and capitalization.
- Do not use generic grocery examples. Do not repeat scenarios, entities, numbers, items, or sentence frames.
- Medical cases preserve patient/source attribution and negation. Legal/financial cases preserve actor, obligation, condition, amount, and date when present.
- Gold may clean fillers or genuine self-corrections but may not summarize, generalize, or add facts.
- Items and scope anchors are audit spans, so copy them verbatim into both input and gold.
- Output only the JSON array."""
    return system, user


def word_count(value: str) -> int:
    return len(re.findall(r"\b[\w'-]+\b", value, flags=re.UNICODE))


def numbered_lines(value: str) -> list[str]:
    return [line for line in value.splitlines() if re.match(r"^\d+\.\s+", line)]


def bullet_lines(value: str) -> list[str]:
    return [line for line in value.splitlines() if line.startswith("- ")]


def as_audit_input(source: str, source_id: str, value: str) -> AuditInput:
    key = normalized(value)
    return AuditInput(
        source=source,
        source_id=source_id,
        normalized=key,
        tokens=frozenset(key.split()),
        char_4grams=char_ngrams(key),
    )


def high_similarity(scores: dict[str, float]) -> bool:
    return any(scores[metric] >= threshold for metric, threshold in SIMILARITY_THRESHOLDS.items())


def validate_generated_row(
    row: Any,
    spec: CaseSpec,
    blocked: list[AuditInput],
    blocked_families: set[str],
) -> tuple[dict[str, Any], dict[str, Any]]:
    if not isinstance(row, dict) or set(row) != EXPECTED_FIELDS:
        raise ValueError(f"{spec.spec_id}: wrong fields")
    if row["spec_id"] != spec.spec_id:
        raise ValueError(f"{spec.spec_id}: returned spec_id {row['spec_id']!r}")
    for field in ("family", "input", "expected_output", "audit_note"):
        if not isinstance(row[field], str) or not row[field].strip():
            raise ValueError(f"{spec.spec_id}: invalid {field}")
    for field in ("items", "compound_items", "scope_anchors", "forbidden"):
        if not isinstance(row[field], list) or not all(isinstance(item, str) and item.strip() for item in row[field]):
            raise ValueError(f"{spec.spec_id}: invalid {field}")
    if len(row["items"]) != spec.item_count or len(set(map(normalized, row["items"]))) != spec.item_count:
        raise ValueError(f"{spec.spec_id}: item count/uniqueness mismatch")
    if not row["scope_anchors"]:
        raise ValueError(f"{spec.spec_id}: scope_anchors is empty")
    if spec.compound_required != bool(row["compound_items"]):
        raise ValueError(f"{spec.spec_id}: compound_items does not match compound_required")
    if not set(map(normalized, row["compound_items"])).issubset(set(map(normalized, row["items"]))):
        raise ValueError(f"{spec.spec_id}: compound_items is not a subset of items")

    input_key = normalized(row["input"])
    output_key = normalized(row["expected_output"])
    if not input_key or any(marker in row["input"] for marker in ("<", ">", "{", "}")):
        raise ValueError(f"{spec.spec_id}: input is not speech-reachable")
    low, high = LENGTH_BUCKETS[spec.length_bucket]
    count = word_count(row["input"])
    if not low <= count <= high:
        raise ValueError(f"{spec.spec_id}: word_count {count} outside {spec.length_bucket} {low}-{high}")
    for field in ("items", "scope_anchors"):
        for value in row[field]:
            key = normalized(value)
            if key not in input_key or key not in output_key:
                raise ValueError(f"{spec.spec_id}: {field} span missing from input or gold")
    for value in row["forbidden"]:
        key = normalized(value)
        if key not in input_key or key in output_key:
            raise ValueError(f"{spec.spec_id}: forbidden span is missing from input or remains in gold")

    bullets = bullet_lines(row["expected_output"])
    numbers = numbered_lines(row["expected_output"])
    if spec.role == "positive_list":
        expected_lines = numbers if spec.case_type == "spoken_ordinals" else bullets
        wrong_lines = bullets if spec.case_type == "spoken_ordinals" else numbers
        if len(expected_lines) != spec.item_count or wrong_lines:
            raise ValueError(f"{spec.spec_id}: positive list structure mismatch")
        for item in row["items"]:
            containing = sum(normalized(item) in normalized(line) for line in expected_lines)
            if containing != 1:
                raise ValueError(f"{spec.spec_id}: item is not atomic on exactly one list line")
        for item in row["compound_items"]:
            containing = sum(normalized(item) in normalized(line) for line in expected_lines)
            if containing != 1:
                raise ValueError(f"{spec.spec_id}: compound item was split")
    elif bullets or numbers:
        raise ValueError(f"{spec.spec_id}: restraint gold contains a list")

    family_key = normalized(row["family"])
    if family_key in blocked_families:
        raise ValueError(f"{spec.spec_id}: duplicate semantic-family label")
    candidate = as_audit_input("generated", spec.spec_id, row["input"])
    exact_hit: AuditInput | None = None
    nearest: AuditInput | None = None
    nearest_score = -1.0
    nearest_axes: dict[str, float] = {}
    for prior in blocked:
        if candidate.normalized == prior.normalized:
            exact_hit = prior
            break
        score, axes = similarity(candidate, prior)
        if high_similarity(axes):
            triggered = {
                key: round(value, 4)
                for key, value in axes.items()
                if value >= SIMILARITY_THRESHOLDS[key]
            }
            raise ValueError(
                f"{spec.spec_id}: high-similarity overlap with {prior.source}:{prior.source_id} {triggered}"
            )
        if score > nearest_score:
            nearest = prior
            nearest_score = score
            nearest_axes = axes
    if exact_hit is not None:
        raise ValueError(f"{spec.spec_id}: exact overlap with {exact_hit.source}:{exact_hit.source_id}")
    similarity_audit = {
        "nearest_source": nearest.source if nearest else None,
        "nearest_source_id": nearest.source_id if nearest else None,
        "max_score": round(max(nearest_axes.values()), 6) if nearest_axes else 0.0,
        "scores": {key: round(value, 6) for key, value in nearest_axes.items()},
    }
    return row, similarity_audit


def validate_batch(
    value: Any,
    specs: list[CaseSpec],
    blocked: list[AuditInput],
    blocked_families: set[str],
) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    if not isinstance(value, list) or len(value) != len(specs):
        raise ValueError(f"expected {len(specs)} rows, got {type(value).__name__}/{len(value) if isinstance(value, list) else '?'}")
    by_spec = {row.get("spec_id"): row for row in value if isinstance(row, dict)}
    if len(by_spec) != len(specs):
        raise ValueError("duplicate or missing spec_id")
    validated: list[tuple[dict[str, Any], dict[str, Any]]] = []
    local_blocked = list(blocked)
    local_families = set(blocked_families)
    for spec in specs:
        row, similarity_audit = validate_generated_row(
            by_spec[spec.spec_id], spec, local_blocked, local_families
        )
        validated.append((row, similarity_audit))
        local_blocked.append(as_audit_input("generated_in_batch", spec.spec_id, row["input"]))
        local_families.add(normalized(row["family"]))
    return validated


def distributions(rows: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    axes = ("domain", "case_type", "item_count", "length_bucket", "compound_required")
    return {axis: dict(sorted(Counter(str(row[axis]) for row in rows).items())) for axis in axes}


def enrich(row: dict[str, Any], spec: CaseSpec, batch_id: str, similarity_audit: dict[str, Any]) -> dict[str, Any]:
    role_slug = "positive" if spec.role == "positive_list" else "restraint"
    formatting = "numbered" if spec.case_type == "spoken_ordinals" else "bullets" if spec.role == "positive_list" else "prose"
    return {
        "id": f"en-list-{role_slug}-{batch_id}-{spec.spec_id.rsplit('-', 1)[-1]}",
        "split": "dev",
        "lang": "en",
        "benchmark_role": spec.role,
        "domain": spec.domain,
        "case_type": spec.case_type,
        "item_count": spec.item_count,
        "length_bucket": spec.length_bucket,
        "word_count": word_count(row["input"]),
        "compound_required": spec.compound_required,
        "family": row["family"],
        "input": row["input"],
        "expected_output": row["expected_output"],
        "items": row["items"],
        "compound_items": row["compound_items"],
        "scope_anchors": row["scope_anchors"],
        "forbidden": row["forbidden"],
        "expected_formatting": formatting,
        "audit_note": row["audit_note"],
        "similarity_audit": similarity_audit,
        "gold_status": "candidate_unreviewed",
        "native_reviewed": False,
        "training_eligible": False,
    }


def publish_bytes_exclusive(
    path: Path, value: bytes, before_link: Callable[[], None] | None = None
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
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


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    value = b"".join(
        (json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
        for row in rows
    )
    publish_bytes_exclusive(path, value)


def validate_complete_corpus(
    path: Path,
    role: str,
    count: int,
    audit_inputs: list[AuditInput],
    audit_families: set[str],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    corpus_bytes = path.read_bytes()
    rows = load_json_rows_bytes(path, corpus_bytes)
    corpus_sha = sha256_bytes(corpus_bytes)
    if len(rows) != count:
        raise ValueError(f"{path}: expected {count} rows, found {len(rows)}")
    seen_ids: set[str] = set()
    blocked = list(audit_inputs)
    families = set(audit_families)
    maximum_similarity = 0.0
    for index, row in enumerate(rows, 1):
        required = {
            "id", "split", "lang", "benchmark_role", "domain", "case_type", "item_count",
            "length_bucket", "word_count", "compound_required", "family", "input", "expected_output",
            "items", "compound_items", "scope_anchors", "forbidden", "expected_formatting", "audit_note",
            "similarity_audit", "gold_status", "native_reviewed", "training_eligible",
        }
        if set(row) != required:
            raise ValueError(f"{path}:{index}: wrong enriched fields")
        if row["id"] in seen_ids or row["benchmark_role"] != role:
            raise ValueError(f"{path}:{index}: duplicate ID or wrong role")
        spec = CaseSpec(
            spec_id=row["id"],
            role=role,
            domain=row["domain"],
            case_type=row["case_type"],
            item_count=row["item_count"],
            length_bucket=row["length_bucket"],
            compound_required=row["compound_required"],
        )
        source = {field: row[field] for field in EXPECTED_FIELDS if field != "spec_id"}
        source["spec_id"] = spec.spec_id
        _, similarity_audit = validate_generated_row(source, spec, blocked, families)
        if row["word_count"] != word_count(row["input"]):
            raise ValueError(f"{path}:{index}: stale word_count")
        if row["native_reviewed"] is not False or row["training_eligible"] is not False:
            raise ValueError(f"{path}:{index}: candidate was marked reviewed or training eligible")
        maximum_similarity = max(maximum_similarity, similarity_audit["max_score"])
        seen_ids.add(row["id"])
        families.add(normalized(row["family"]))
        blocked.append(as_audit_input(str(path), row["id"], row["input"]))

    expected_domain = count // len(DOMAINS)
    expected_axis = count // 4
    dist = distributions(rows)
    if dist["domain"] != {domain: expected_domain for domain in DOMAINS}:
        raise ValueError(f"{path}: domain imbalance {dist['domain']}")
    case_types = POSITIVE_TYPES if role == "positive_list" else RESTRAINT_TYPES
    if dist["case_type"] != {case_type: expected_axis for case_type in case_types}:
        raise ValueError(f"{path}: type imbalance {dist['case_type']}")
    if dist["item_count"] != {str(item_count): expected_axis for item_count in ITEM_COUNTS}:
        raise ValueError(f"{path}: item-count imbalance {dist['item_count']}")
    if dist["length_bucket"] != {bucket: expected_axis for bucket in LENGTH_BUCKETS}:
        raise ValueError(f"{path}: length imbalance {dist['length_bucket']}")
    return rows, {
        "path": str(path),
        "sha256": corpus_sha,
        "row_count": len(rows),
        "distributions": dist,
        "pairwise_balance": pairwise_balance([
            CaseSpec(
                spec_id=row["id"], role=role, domain=row["domain"], case_type=row["case_type"],
                item_count=row["item_count"], length_bucket=row["length_bucket"],
                compound_required=row["compound_required"],
            )
            for row in rows
        ]),
        "maximum_similarity_to_earlier_input": round(maximum_similarity, 6),
    }


def generate_role(
    role: str,
    specs: list[CaseSpec],
    args: argparse.Namespace,
    audit_inputs: list[AuditInput],
    audit_families: set[str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, str]], list[AuditInput], set[str]]:
    rows: list[dict[str, Any]] = []
    prompt_records: list[dict[str, Any]] = []
    failures: list[dict[str, str]] = []
    blocked = list(audit_inputs)
    families = set(audit_families)
    checkpoint_dir = Path(args.checkpoint_dir).resolve() if args.checkpoint_dir else None
    if checkpoint_dir:
        checkpoint_dir.mkdir(parents=True, exist_ok=True)
    for batch_index, start in enumerate(range(0, len(specs), args.batch_size), 1):
        batch = specs[start : start + args.batch_size]
        system, user = generation_prompt(batch)
        prompt_sha = sha256_bytes((system + "\n" + user).encode())
        prompt_record = {
            "role": role,
            "batch": batch_index,
            "spec_ids": [spec.spec_id for spec in batch],
            "prompt_sha256": prompt_sha,
            "reused_checkpoint": False,
        }
        prompt_records.append(prompt_record)
        accepted: list[tuple[dict[str, Any], dict[str, Any]]] | None = None
        last_error: Exception | None = None
        checkpoint = checkpoint_dir / f"{role}-batch-{batch_index:03d}.json" if checkpoint_dir else None
        if checkpoint and checkpoint.is_file():
            cached = json.loads(checkpoint.read_text(encoding="utf-8"))
            if (
                cached.get("prompt_sha256") != prompt_sha
                or cached.get("specs") != [asdict(spec) for spec in batch]
                or not isinstance(cached.get("rows"), list)
            ):
                raise RuntimeError(f"checkpoint does not match current prompt/specs: {checkpoint}")
            accepted = validate_batch(cached["rows"], batch, blocked, families)
            prompt_record["reused_checkpoint"] = True
        else:
            for attempt in range(1, args.attempts_per_batch + 1):
                try:
                    raw_rows = clean_json(
                        call_claude(args.model, system, user, args.call_timeout_seconds)
                    )
                    accepted = validate_batch(raw_rows, batch, blocked, families)
                    if checkpoint:
                        publish_bytes_exclusive(
                            checkpoint,
                            (
                                json.dumps(
                                    {
                                        "prompt_sha256": prompt_sha,
                                        "specs": [asdict(spec) for spec in batch],
                                        "rows": raw_rows,
                                    },
                                    ensure_ascii=False,
                                    indent=2,
                                    sort_keys=True,
                                )
                                + "\n"
                            ).encode("utf-8"),
                        )
                    break
                except (ValueError, json.JSONDecodeError, RuntimeError) as error:
                    last_error = error
                    failures.append({
                        "role": role,
                        "batch": str(batch_index),
                        "attempt": str(attempt),
                        "reason": str(error)[:500],
                    })
                    print(f"{role} batch {batch_index} attempt {attempt} failed: {error}", flush=True)
        if accepted is None:
            raise RuntimeError(f"{role} batch {batch_index} failed after {args.attempts_per_batch} attempts: {last_error}")
        for spec, (row, similarity_audit) in zip(batch, accepted):
            enriched = enrich(row, spec, args.batch_id, similarity_audit)
            rows.append(enriched)
            families.add(normalized(row["family"]))
            blocked.append(as_audit_input("generated", enriched["id"], row["input"]))
        print(f"accepted {role} batch {batch_index}: {len(accepted)} rows", flush=True)
    return rows, prompt_records, failures, blocked, families


def ensure_source_snapshots_unchanged(inventories: list[dict[str, Any]]) -> None:
    for inventory in inventories:
        path = Path(inventory["path"])
        if file_sha256(path) != inventory["sha256"]:
            raise RuntimeError(f"audit source changed during generation: {path}")


def manifest_path(args: argparse.Namespace) -> Path:
    if args.manifest_output:
        return Path(args.manifest_output).resolve()
    positive = Path(args.positive_output).resolve()
    return positive.with_name(f"{positive.stem}.benchmark-manifest.json")


def main() -> None:
    args = parse_args()
    if args.batch_size <= 0 or args.count_per_role % args.batch_size:
        raise SystemExit("--batch-size must be positive and divide --count-per-role")
    if args.call_timeout_seconds <= 0:
        raise SystemExit("--call-timeout-seconds must be positive")
    source_paths = [*args.audit_corpus, *args.prior_batch]
    if not source_paths:
        raise SystemExit("supply at least one --audit-corpus or --prior-batch")
    if len({str(Path(path).resolve()) for path in source_paths}) != len(source_paths):
        raise SystemExit("duplicate audit/prior source path")

    audit_inputs, inventories, audit_families = load_audit_sources(source_paths)
    positive_path = Path(args.positive_output).resolve()
    restraint_path = Path(args.restraint_output).resolve()
    started = time.time()
    prompt_records: list[dict[str, Any]] = []
    failures: list[dict[str, str]] = []

    if args.mode == "generate":
        positive_specs = balanced_specs("positive_list", args.count_per_role, args.seed)
        restraint_specs = balanced_specs("prose_restraint", args.count_per_role, args.seed + 1)
        positive_rows, records, failed, generated_inputs, generated_families = generate_role(
            "positive_list", positive_specs, args, audit_inputs, audit_families
        )
        prompt_records.extend(records)
        failures.extend(failed)
        restraint_rows, records, failed, _, _ = generate_role(
            "prose_restraint", restraint_specs, args, generated_inputs, generated_families
        )
        prompt_records.extend(records)
        failures.extend(failed)
        ensure_source_snapshots_unchanged(inventories)
        write_jsonl(positive_path, positive_rows)
        write_jsonl(restraint_path, restraint_rows)
    elif not positive_path.is_file() or not restraint_path.is_file():
        raise SystemExit("--mode validate requires existing positive and restraint outputs")

    positive_rows, positive_report = validate_complete_corpus(
        positive_path, "positive_list", args.count_per_role, audit_inputs, audit_families
    )
    positive_as_audit = [
        as_audit_input(str(positive_path), row["id"], row["input"]) for row in positive_rows
    ]
    positive_families = audit_families | {normalized(row["family"]) for row in positive_rows}
    _, restraint_report = validate_complete_corpus(
        restraint_path,
        "prose_restraint",
        args.count_per_role,
        [*audit_inputs, *positive_as_audit],
        positive_families,
    )
    ensure_source_snapshots_unchanged(inventories)

    generator_path = Path(__file__).resolve()
    generator_sha = file_sha256(generator_path)
    manifest = {
        "status": "candidate_requires_independent_native_review",
        "model_blind": True,
        "frozen": False,
        "training_eligible": False,
        "native_reviewed": False,
        "created_at_epoch": started,
        "elapsed_seconds": round(time.time() - started, 3),
        "mode": args.mode,
        "generator": str(generator_path),
        "generator_sha256": generator_sha,
        "model": args.model if args.mode == "generate" else None,
        "batch_id": args.batch_id,
        "seed": args.seed,
        "count_per_role": args.count_per_role,
        "batch_size": args.batch_size,
        "call_timeout_seconds": args.call_timeout_seconds,
        "similarity_thresholds": SIMILARITY_THRESHOLDS,
        "audit_sources": inventories,
        "audit_source_roles": {
            "training_and_eval": [str(Path(path).resolve()) for path in args.audit_corpus],
            "prior_generated_batches": [str(Path(path).resolve()) for path in args.prior_batch],
        },
        "prompt_batches": prompt_records,
        "rejected_attempts": failures,
        "outputs": {
            "positive_list": positive_report,
            "prose_restraint": restraint_report,
        },
    }
    output_manifest = manifest_path(args)

    def verify_before_manifest_link() -> None:
        ensure_source_snapshots_unchanged(inventories)
        for report, label in (
            (positive_report, "positive corpus"),
            (restraint_report, "restraint corpus"),
        ):
            if file_sha256(Path(report["path"])) != report["sha256"]:
                raise RuntimeError(f"{label} changed before manifest publication")
        if file_sha256(generator_path) != generator_sha:
            raise RuntimeError("generator changed before manifest publication")

    publish_bytes_exclusive(
        output_manifest,
        (
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        ).encode("utf-8"),
        before_link=verify_before_manifest_link,
    )
    print(json.dumps({
        "manifest": str(output_manifest),
        "manifest_sha256": file_sha256(output_manifest),
        "positive": positive_report,
        "restraint": restraint_report,
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
