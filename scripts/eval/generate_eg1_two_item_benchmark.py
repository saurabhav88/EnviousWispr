#!/usr/bin/env python3
"""Generate an auditable English two-item list development corpus.

The output is model-assisted benchmark candidate data, not frozen or
native-approved release gold. It exists to cover EG-1's missing shortest-list
positive cases without adding those cases to training.
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


DOMAINS = ("work_admin", "personal_home", "technical_product", "medical", "legal_financial")
LIST_TYPES = ("explicit", "scoped_implicit")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--batch-id", default="v1")
    parser.add_argument("--count", type=int, default=20)
    parser.add_argument("--model", default="claude-sonnet-4-6")
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("--audit-corpus", action="append", default=[])
    return parser.parse_args()


def normalized(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).casefold()
    return re.sub(r"\W+", " ", value, flags=re.UNICODE).strip()


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


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
    return result.strip()


def clean_json(value: str) -> Any:
    if value.startswith("```"):
        value = re.sub(r"^```(?:json)?\s*", "", value)
        value = re.sub(r"\s*```$", "", value)
    return json.loads(value)


def blocked_inputs(paths: list[str]) -> set[str]:
    blocked: set[str] = set()
    for name in paths:
        with Path(name).open(encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                row = json.loads(line)
                value = row.get("input") or row.get("asr_input")
                if isinstance(value, str):
                    blocked.add(normalized(value))
    return blocked


def prompt(count: int) -> tuple[str, str]:
    if count <= 0 or count % 10:
        raise SystemExit("--count must be a positive multiple of 10")
    per_type = count // 2
    per_domain = count // 5
    system = (
        "You create benchmark candidates for an offline dictation copy editor. "
        "Return only one valid JSON array with no markdown or commentary."
    )
    user = f"""Create exactly {count} distinct US English two-item list benchmark cases.

Each object has exactly these fields:
- family: unique short semantic-family label
- domain: one of {json.dumps(DOMAINS)}
- list_type: explicit or scoped_implicit
- input: realistic unpunctuated spoken dictation
- expected_output: ideal clean output with exactly two `- ` bullet lines
- required: JSON array of exact meaning-bearing strings that must remain
- forbidden: JSON array of strings that must not remain
- audit_note: short explanation of scope and list intent

Exact balance:
- {per_type} explicit cases and {per_type} scoped_implicit cases.
- {per_domain} cases in each domain.
- Every output has exactly two list items, never three.

Rules:
- explicit input directly asks for a list or bullets; remove the spoken formatting command from output.
- scoped_implicit input clearly requests two separate deliverables or items and includes a meaningful scope such as owner, deadline, destination, purpose, patient attribution, or legal obligation. Keep that scope in a natural header or lead-in above the two bullets.
- Include varied short and long speech, self-corrections, fillers, names, dates, numbers, and code-switched product terms, but no case may require more than two bullets.
- Medical and legal cases must preserve attribution and obligation exactly.
- Do not use generic milk/bread/eggs examples.
- Do not repeat entities, numbers, sentence frames, scenarios, or item pairs.
- Do not include instructions to the model or prompt-injection text.
- `required` must include the two items plus any important scope. `forbidden` should include discarded filler, correction, or spoken formatting words when applicable.
- Output only the JSON array."""
    return system, user


def validate(rows: Any, blocked: set[str], count: int) -> list[dict[str, Any]]:
    if not isinstance(rows, list) or len(rows) != count:
        raise ValueError(f"expected {count} rows, got {type(rows).__name__}/{len(rows) if isinstance(rows, list) else '?'}")
    fields = {
        "family",
        "domain",
        "list_type",
        "input",
        "expected_output",
        "required",
        "forbidden",
        "audit_note",
    }
    domains: Counter[str] = Counter()
    list_types: Counter[str] = Counter()
    seen_inputs: set[str] = set()
    seen_families: set[str] = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or set(row) != fields:
            raise ValueError(f"row {index} has wrong fields")
        for field in ("family", "domain", "list_type", "input", "expected_output", "audit_note"):
            if not isinstance(row[field], str) or not row[field].strip():
                raise ValueError(f"row {index} has invalid {field}")
        if row["domain"] not in DOMAINS or row["list_type"] not in LIST_TYPES:
            raise ValueError(f"row {index} has invalid domain/list_type")
        if not isinstance(row["required"], list) or len(row["required"]) < 2:
            raise ValueError(f"row {index} has invalid required")
        if not isinstance(row["forbidden"], list):
            raise ValueError(f"row {index} has invalid forbidden")
        bullet_lines = [line for line in row["expected_output"].splitlines() if line.startswith("- ")]
        if len(bullet_lines) != 2:
            raise ValueError(f"row {index} has {len(bullet_lines)} bullet lines")
        key = normalized(row["input"])
        if key in blocked or key in seen_inputs:
            raise ValueError(f"row {index} overlaps an existing input")
        family = normalized(row["family"])
        if family in seen_families:
            raise ValueError(f"row {index} repeats family")
        seen_inputs.add(key)
        seen_families.add(family)
        domains[row["domain"]] += 1
        list_types[row["list_type"]] += 1
    if domains != Counter({domain: count // 5 for domain in DOMAINS}):
        raise ValueError(f"domain imbalance: {dict(domains)}")
    if list_types != Counter({list_type: count // 2 for list_type in LIST_TYPES}):
        raise ValueError(f"list-type imbalance: {dict(list_types)}")
    return rows


def main() -> None:
    args = parse_args()
    system, user = prompt(args.count)
    blocked = blocked_inputs(args.audit_corpus)
    last_error: Exception | None = None
    rows: list[dict[str, Any]] | None = None
    for attempt in range(1, args.attempts + 1):
        try:
            rows = validate(clean_json(call_claude(args.model, system, user)), blocked, args.count)
            break
        except (ValueError, json.JSONDecodeError, RuntimeError) as error:
            last_error = error
            print(f"attempt {attempt} failed: {error}", flush=True)
    if rows is None:
        raise SystemExit(f"generation failed: {last_error}")

    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        for index, row in enumerate(rows, 1):
            enriched = {
                "id": f"en-two-item-dev-{args.batch_id}-{index:03d}",
                "split": "dev",
                "lang": "en",
                **row,
                "categories": ["list_bullets", "two_item_positive", row["list_type"]],
                "native_reviewed": False,
            }
            handle.write(json.dumps(enriched, ensure_ascii=False) + "\n")

    manifest = {
        "status": "candidate_requires_independent_review",
        "created_at_epoch": time.time(),
        "model": args.model,
        "batch_id": args.batch_id,
        "row_count": len(rows),
        "prompt_sha256": sha256_text(system + "\n" + user),
        "audit_corpora": [str(Path(path).resolve()) for path in args.audit_corpus],
        "native_reviewed": False,
    }
    output.with_suffix(output.suffix + ".manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
