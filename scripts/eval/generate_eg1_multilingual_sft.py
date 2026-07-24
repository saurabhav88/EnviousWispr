#!/usr/bin/env python3
"""Generate a small, auditable multilingual SFT smoke corpus via Claude subscription.

Generated rows are experimental teacher data, not native-approved gold. The
script enforces quotas, uniqueness, and exact-overlap checks, then writes a
manifest so the provenance survives handoffs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
import unicodedata
from collections import Counter
from pathlib import Path
from typing import Any


LANGUAGE_GUIDANCE = {
    "de": (
        "German",
        "case and article agreement, verb placement, separable verbs, formality, and compound nouns",
    ),
    "en": ("English", "natural US English dictation and list intent"),
    "es": (
        "Spanish",
        "gender and number agreement, clitic pronouns, accents, and formal versus informal address",
    ),
    "fr": (
        "French",
        "gender and number agreement, elision, accents, and formal versus informal address",
    ),
    "ru": (
        "Russian",
        "case endings, gender, number, tense agreement, aspect, and inflected personal names",
    ),
}

MULTILINGUAL_QUOTAS = {
    "explicit_list": 5,
    "ordinal_list": 5,
    "implicit_list": 5,
    "list_trap": 5,
    "morphology_repair": 4,
    "morphology_preserve": 4,
    "correction_filler": 5,
    "punctuation": 3,
    "preservation": 4,
}

ENGLISH_QUOTAS = {
    "explicit_list": 15,
    "ordinal_list": 15,
    "implicit_list": 15,
    "list_trap": 15,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--language", choices=sorted(LANGUAGE_GUIDANCE), required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--audit-corpus", action="append", default=[])
    parser.add_argument("--model", default="claude-sonnet-4-6")
    parser.add_argument("--batch-id", required=True)
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument(
        "--quota",
        action="append",
        default=[],
        metavar="CATEGORY=COUNT",
        help="Override the default quota map; repeat for each category in this batch",
    )
    return parser.parse_args()


def normalized(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).casefold()
    return re.sub(r"\W+", " ", value, flags=re.UNICODE).strip()


def prompt_hash(system: str, user: str) -> str:
    return hashlib.sha256((system + "\n" + user).encode()).hexdigest()


def clean_json(text: str) -> Any:
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    return json.loads(text)


def subscription_env() -> dict[str, str]:
    return {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("ANTHROPIC_")
        and key not in ("CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX")
    }


def call_claude(model: str, system: str, user: str) -> str:
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
            timeout=180,
            cwd=tempfile.gettempdir(),
            env=subscription_env(),
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("Claude generation timed out after 180 seconds") from error
    if process.returncode:
        raise RuntimeError(process.stderr.strip()[:500])
    envelope = json.loads(process.stdout)
    if envelope.get("is_error") or envelope.get("subtype") != "success":
        raise RuntimeError(str(envelope)[:500])
    result = envelope.get("result")
    if not isinstance(result, str) or not result.strip():
        raise RuntimeError("Claude returned an empty result")
    return result


def parse_quotas(language: str, values: list[str]) -> dict[str, int]:
    if not values:
        return ENGLISH_QUOTAS if language == "en" else MULTILINGUAL_QUOTAS
    allowed = set(ENGLISH_QUOTAS if language == "en" else MULTILINGUAL_QUOTAS)
    quotas: dict[str, int] = {}
    for value in values:
        try:
            category, raw_count = value.split("=", 1)
            count = int(raw_count)
        except ValueError as error:
            raise SystemExit(f"invalid --quota {value!r}; expected CATEGORY=COUNT") from error
        if category not in allowed or count <= 0 or category in quotas:
            raise SystemExit(f"invalid --quota {value!r}")
        quotas[category] = count
    return quotas


def build_prompt(language: str, quotas: dict[str, int]) -> tuple[str, str]:
    language_name, morphology = LANGUAGE_GUIDANCE[language]
    system = (
        "You create supervised fine-tuning pairs for a privacy-first dictation copy editor. "
        "Return only one valid JSON array. Do not use markdown or commentary."
    )
    user = f"""Create exactly {sum(quotas.values())} distinct training pairs in {language_name}.

Required primary_category counts: {json.dumps(quotas, sort_keys=True)}

Each object must have exactly these fields:
- primary_category: one key from the quota map
- family: a short unique semantic-family label
- input: realistic raw spoken dictation with little or no punctuation
- output: the ideal cleaned text
- rationale: one short English audit note

Rules:
- Input and output stay in {language_name}; never translate to English.
- Use diverse personal, home, business, medical, technical, travel, and school contexts.
- Vary wording and item count. At least half of list examples are short three-item speech.
- explicit_list asks for a list and output removes the spoken formatting command.
- ordinal_list uses spoken first/second/third equivalents and outputs consecutive numbered lines.
- implicit_list clearly enumerates items without a formatting command and outputs bullet lines.
- list_trap contains an enumeration or list-related words that must remain ordinary prose.
- morphology_repair contains one plausible agreement or inflection error and fixes it.
- morphology_preserve begins grammatically correct and the output must preserve its inflections.
- correction_filler removes genuine fillers and keeps only the speaker's final correction.
- preservation protects names, numbers, quoted text, code-switched product names, formality, and meaning.
- For this language, emphasize {morphology}.
- Do not use generic translations of 'milk, bread, and eggs'.
- Do not reuse the same entities, numbers, scenario, or sentence frame.
- Output only the JSON array."""
    return system, user


def existing_inputs(paths: list[str]) -> set[str]:
    values: set[str] = set()
    for name in paths:
        with Path(name).open(encoding="utf-8") as handle:
            for line in handle:
                if line.strip():
                    row = json.loads(line)
                    values.add(normalized(row["input"]))
    return values


def validate(rows: Any, quotas: dict[str, int], blocked: set[str]) -> list[dict[str, str]]:
    if not isinstance(rows, list) or len(rows) != sum(quotas.values()):
        raise ValueError(f"expected {sum(quotas.values())} rows, got {type(rows).__name__}/{len(rows) if isinstance(rows, list) else '?'}")
    required_fields = {"primary_category", "family", "input", "output", "rationale"}
    counts: Counter[str] = Counter()
    seen: set[str] = set()
    validated: list[dict[str, str]] = []
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or set(row) != required_fields:
            raise ValueError(f"row {index} has wrong fields")
        if not all(isinstance(row[field], str) and row[field].strip() for field in required_fields):
            raise ValueError(f"row {index} has an empty/non-string field")
        if row["primary_category"] not in quotas:
            raise ValueError(f"row {index} has unknown category")
        key = normalized(row["input"])
        if key in seen:
            raise ValueError(f"duplicate generated input at row {index}")
        if key in blocked:
            raise ValueError(f"benchmark overlap at row {index}")
        seen.add(key)
        counts[row["primary_category"]] += 1
        validated.append(row)
    if dict(counts) != quotas:
        raise ValueError(f"quota mismatch: {dict(counts)}")
    return validated


def main() -> None:
    args = parse_args()
    quotas = parse_quotas(args.language, args.quota)
    system, user = build_prompt(args.language, quotas)
    blocked = existing_inputs(args.audit_corpus)
    last_error: Exception | None = None
    rows: list[dict[str, str]] | None = None
    for attempt in range(1, args.attempts + 1):
        try:
            rows = validate(clean_json(call_claude(args.model, system, user)), quotas, blocked)
            break
        except (ValueError, json.JSONDecodeError, RuntimeError) as error:
            last_error = error
            print(f"attempt {attempt} failed: {error}", flush=True)
    if rows is None:
        raise SystemExit(f"generation failed: {last_error}")

    output_path = Path(args.output).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as handle:
        for index, row in enumerate(rows, start=1):
            enriched = {
                "id": f"{args.language}-train-{args.batch_id}-{index:03d}",
                "split": "train",
                "lang": args.language,
                "source": args.model,
                "native_reviewed": False,
                **row,
            }
            handle.write(json.dumps(enriched, ensure_ascii=False) + "\n")
    manifest = {
        "batch_id": args.batch_id,
        "language": args.language,
        "model": args.model,
        "generated_at_epoch": time.time(),
        "row_count": len(rows),
        "quotas": quotas,
        "prompt_sha256": prompt_hash(system, user),
        "audit_corpora": [str(Path(name).resolve()) for name in args.audit_corpus],
        "warning": "Experimental teacher data; not native-reviewed and not release gold.",
    }
    output_path.with_suffix(output_path.suffix + ".manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
