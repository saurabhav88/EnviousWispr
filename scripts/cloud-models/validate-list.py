#!/usr/bin/env python3
"""Validate the cloud model list (#4353 D6) before it is published. Standard library only.

  validate-list.py [FILE ...]      validate each file (default: website/public/cloud-models.json)
  validate-list.py --self-test     run the shared fixtures in scripts/cloud-models/fixtures/
  validate-list.py --same A B      also require two files to be byte-identical

The contract is the Swift one, `Sources/EnviousWisprLLM/CloudModelList.swift`
(`CloudModelList.validated(from:)`), which the app runs on every fetched copy. The two must
agree on every fixture: `fixtures/valid/*.json` are accepted by both, `fixtures/invalid/*.json`
are refused by both, and `CloudModelListTests` runs the same files through the Swift parser.
A whole document is accepted or refused; nothing is admitted in part.

Exit 0 when every file is valid (or every self-test passes), 1 otherwise.
"""

import datetime
import json
import re
import sys
import unicodedata
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FILE = REPO_ROOT / "website/public/cloud-models.json"
FIXTURES = Path(__file__).resolve().parent / "fixtures"

SUPPORTED_SCHEMA = 1
MAX_DOCUMENT_BYTES = 262_144
MAX_ROWS = 500
MAX_ID = 100
MAX_DISPLAY_NAME = 80
MAX_HIDDEN_REASON = 200
GEMINI_BUDGET = (0, 32_768)
MEDIAN_POLISH_MS = (1, 60_000)
GEMINI_LEVELS = {"minimal", "low", "medium", "high"}
TOP_KEYS = {"schema", "updated", "models"}
ROW_KEYS = {
    "provider", "id", "released", "recommended", "hidden", "hiddenReason", "displayName",
    "request", "supportsChatCompletions", "allowsFileBatch", "medianPolishMs",
}
REQUIRED_ROW_KEYS = {
    "provider", "id", "recommended", "hidden", "request", "supportsChatCompletions",
    "allowsFileBatch",
}
PROVIDERS = {"openAI", "gemini", "claude"}
OPENAI_EFFORTS = {"none", "low", "minimal", "omit"}
CLAUDE_SHAPES = {"thinkingDisabled", "thinkingBetweenTools", "effortLow"}
# Always used with fullmatch: `$` alone would accept a final newline.
ID_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,99}")
DATE_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")


class Invalid(Exception):
    pass


def _reject_constant(name):
    raise Invalid(f"not JSON ({name})")


def closed_keys(obj, allowed, required, path):
    unknown = sorted(set(obj) - allowed)
    if unknown:
        raise Invalid(f"{path} has unknown key {unknown[0]}")
    missing = sorted(required - set(obj))
    if missing:
        raise Invalid(f"{path} is missing {missing[0]}")


def boolean(value, path):
    if not isinstance(value, bool):
        raise Invalid(f"{path} is not a boolean")
    return value


def integer(value, path):
    if isinstance(value, bool) or not isinstance(value, int):
        raise Invalid(f"{path} is not an integer")
    return value


def text(value, path, max_len):
    """Printable text, counted in code points, with no Cc, Cf, Zl or Zp characters (as Swift
    counts Unicode scalars and refuses the control, format and line-break categories)."""
    if not isinstance(value, str) or value == "":
        raise Invalid(f"{path} is not text")
    if len(value) > max_len:
        raise Invalid(f"{path} is longer than {max_len}")
    # Cs: an escaped unpaired surrogate, which Swift's parser refuses outright.
    if any(unicodedata.category(ch) in ("Cc", "Cf", "Cs", "Zl", "Zp") for ch in value):
        raise Invalid(f"{path} has a control character or line break")
    return value


def calendar_date(value, path):
    if not isinstance(value, str) or not DATE_RE.fullmatch(value):
        raise Invalid(f"{path} is not YYYY-MM-DD")
    year, month, day = (int(part) for part in value.split("-"))
    if not 2000 <= year <= 2099:
        raise Invalid(f"{path} is not a date from 2000 to 2099")
    try:
        datetime.date(year, month, day)
    except ValueError:
        raise Invalid(f"{path} is not a real date")
    return value


def gemini_thinking(value, path):
    if isinstance(value, str):
        if value != "none":
            raise Invalid(f"{path} string is not none")
        return
    if not isinstance(value, dict) or len(value) != 1:
        raise Invalid(f'{path} is not none, {{"budget": n}} or {{"level": name}}')
    if "budget" in value:
        budget = integer(value["budget"], f"{path}.budget")
        if not GEMINI_BUDGET[0] <= budget <= GEMINI_BUDGET[1]:
            raise Invalid(f"{path}.budget {budget} is out of range")
        return
    if "level" in value:
        if not isinstance(value["level"], str) or value["level"] not in GEMINI_LEVELS:
            raise Invalid(f"{path}.level is not minimal, low, medium or high")
        return
    raise Invalid(f"{path} has an unknown key")


def validate_request(request, provider, path):
    if not isinstance(request, dict):
        raise Invalid(f"{path} is not an object")
    if provider == "openAI":
        closed_keys(request, {"openAIEffort", "temperature"}, {"openAIEffort", "temperature"}, path)
        effort = request["openAIEffort"]
        if not isinstance(effort, str) or effort not in OPENAI_EFFORTS:
            raise Invalid(f"{path}.openAIEffort is not none, low, minimal or omit")
        temperature = request["temperature"]
        if not isinstance(temperature, str) or temperature not in ("include", "omit"):
            raise Invalid(f"{path}.temperature is not include or omit")
    elif provider == "gemini":
        closed_keys(request, {"geminiThinking"}, {"geminiThinking"}, path)
        gemini_thinking(request["geminiThinking"], f"{path}.geminiThinking")
    else:
        closed_keys(request, {"claudeShape"}, {"claudeShape"}, path)
        shape = request["claudeShape"]
        if not isinstance(shape, str) or shape not in CLAUDE_SHAPES:
            raise Invalid(f"{path}.claudeShape is not thinkingDisabled, thinkingBetweenTools or effortLow")


def validate_row(row, path):
    if not isinstance(row, dict):
        raise Invalid(f"{path} is not an object")
    closed_keys(row, ROW_KEYS, REQUIRED_ROW_KEYS, path)
    provider = row["provider"]
    if not isinstance(provider, str) or provider not in PROVIDERS:
        raise Invalid(f"{path}.provider is not openAI, gemini or claude")
    model_id = text(row["id"], f"{path}.id", MAX_ID)
    if not ID_RE.fullmatch(model_id):
        raise Invalid(f"{path}.id {model_id} is not a lowercase model id")
    if "released" in row:
        calendar_date(row["released"], f"{path}.released")
    boolean(row["recommended"], f"{path}.recommended")
    boolean(row["hidden"], f"{path}.hidden")
    if "hiddenReason" in row:
        text(row["hiddenReason"], f"{path}.hiddenReason", MAX_HIDDEN_REASON)
    if "displayName" in row:
        text(row["displayName"], f"{path}.displayName", MAX_DISPLAY_NAME)
    supports_chat = boolean(row["supportsChatCompletions"], f"{path}.supportsChatCompletions")
    boolean(row["allowsFileBatch"], f"{path}.allowsFileBatch")
    if "medianPolishMs" in row:
        median = integer(row["medianPolishMs"], f"{path}.medianPolishMs")
        if not MEDIAN_POLISH_MS[0] <= median <= MEDIAN_POLISH_MS[1]:
            raise Invalid(f"{path}.medianPolishMs {median} is out of range")
    validate_request(row["request"], provider, f"{path}.request")
    if provider != "openAI" and supports_chat:
        raise Invalid(f"{path}.supportsChatCompletions must be false for {provider}")
    return f"{provider}/{model_id}"


def validate_bytes(data):
    """The whole document, or Invalid with the first reason. Returns the row count."""
    if len(data) > MAX_DOCUMENT_BYTES:
        raise Invalid(f"document is {len(data)} bytes, over {MAX_DOCUMENT_BYTES}")
    # One encoding, as in Swift: UTF-8 with no byte-order mark and no raw NUL.
    if data.startswith(b"\xef\xbb\xbf") or b"\x00" in data:
        raise Invalid("document is not UTF-8 without a byte-order mark")
    try:
        document = json.loads(data.decode("utf-8"), parse_constant=_reject_constant)
    except Invalid:
        raise
    except (UnicodeDecodeError, ValueError):
        raise Invalid("not JSON")
    if not isinstance(document, dict):
        raise Invalid("top level is not an object")
    closed_keys(document, TOP_KEYS, TOP_KEYS, "document")
    schema = integer(document["schema"], "schema")
    if schema != SUPPORTED_SCHEMA:
        raise Invalid(f"unsupported schema {schema}")
    calendar_date(document["updated"], "updated")
    models = document["models"]
    if not isinstance(models, list):
        raise Invalid("models is not an array")
    if len(models) > MAX_ROWS:
        raise Invalid(f"{len(models)} rows, over {MAX_ROWS}")
    seen = set()
    for index, row in enumerate(models):
        identity = validate_row(row, f"models[{index}]")
        if identity in seen:
            raise Invalid(f"duplicate row {identity}")
        seen.add(identity)
    return len(models)


def self_test():
    failures = []
    valid = sorted((FIXTURES / "valid").glob("*.json"))
    invalid = sorted((FIXTURES / "invalid").glob("*.json"))
    if not valid or not invalid:
        print("self-test: fixtures missing", file=sys.stderr)
        return 1
    for path in valid:
        try:
            validate_bytes(path.read_bytes())
        except Invalid as error:
            failures.append(f"{path.name}: should pass, refused: {error}")
    for path in invalid:
        try:
            validate_bytes(path.read_bytes())
            failures.append(f"{path.name}: should be refused, passed")
        except Invalid:
            pass
    # Generated cases too large to keep as files.
    oversized = b'{"schema":1,"updated":"2026-11-04","models":[]}' + b" " * MAX_DOCUMENT_BYTES
    row = {"provider": "claude", "recommended": False, "hidden": False,
           "request": {"claudeShape": "thinkingDisabled"}, "supportsChatCompletions": False,
           "allowsFileBatch": True}
    too_many = json.dumps({"schema": 1, "updated": "2026-11-04", "models": [
        dict(row, id=f"claude-row-{n}") for n in range(MAX_ROWS + 1)]}).encode()
    at_limit = json.dumps({"schema": 1, "updated": "2026-11-04", "models": [
        dict(row, id=f"claude-row-{n}") for n in range(MAX_ROWS)]}).encode()
    for name, data, ok in [("oversized", oversized, False), ("too-many-rows", too_many, False),
                           ("rows-at-limit", at_limit, True)]:
        try:
            validate_bytes(data)
            if not ok:
                failures.append(f"{name}: should be refused, passed")
        except Invalid as error:
            if ok:
                failures.append(f"{name}: should pass, refused: {error}")
    total = len(valid) + len(invalid) + 3
    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    print(f"self-test: {total - len(failures)} of {total} passed")
    return 1 if failures else 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    same = None
    if argv[:1] == ["--same"]:
        if len(argv) != 3:
            print("usage: validate-list.py --same A B", file=sys.stderr)
            return 1
        same = argv[1:]
        argv = argv[1:]
    files = [Path(arg) for arg in argv] or [DEFAULT_FILE]
    status = 0
    for path in files:
        try:
            rows = validate_bytes(path.read_bytes())
            print(f"ok {path} ({rows} rows)")
        except OSError as error:
            print(f"FAIL {path}: cannot read: {error}", file=sys.stderr)
            status = 1
        except Invalid as error:
            print(f"FAIL {path}: {error}", file=sys.stderr)
            status = 1
    if same and status == 0:
        if Path(same[0]).read_bytes() != Path(same[1]).read_bytes():
            print(f"FAIL {same[0]} and {same[1]} differ", file=sys.stderr)
            status = 1
        else:
            print(f"ok {same[0]} and {same[1]} are byte-identical")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
