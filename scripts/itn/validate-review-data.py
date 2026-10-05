#!/usr/bin/env python3
"""Validate the German expectation rows and refusal data (#1677, PR 2 chunk 2).

Dependency-free. It checks WELL-FORMEDNESS and administrative consistency only: required fields and
types (a small JSON Schema subset read from review-data.schema.json), closed vocabularies, ids,
versions and content hashes, split membership, duplicate sentences, target-span versus full-sentence
consistency, preserve-row byte identity, provenance and evidence references, refusal references and
the exclusion of pending rows from the frozen set. A row that passes is not thereby linguistically
correct, and nothing here measures an engine.

  scripts/itn/validate-review-data.py                 # validate everything under scripts/itn
  scripts/itn/validate-review-data.py --frozen        # also require the full frozen membership
  scripts/itn/validate-review-data.py --root DIR      # test seam: another scripts/itn-shaped tree

Exit 0 only when no problem was found AND at least one row was read; a missing file, a parse error
or an empty corpus is a failure, never an empty successful set.
"""

import argparse
import hashlib
import itertools
import json
import re
import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent

CORPUS_FILES = {
    "development": "corpus/de-development.jsonl",
    "holdout": "corpus/de-holdout.jsonl",
    "control": "corpus/de-controls.jsonl",
}
REFUSAL_FILE = "refusals/de.json"
SCHEMA_FILE = "review-data.schema.json"

# Frozen membership per category (chunk 2 target): conversions and controls.
FROZEN_TARGETS = {"development": 20, "holdout": 59, "control_lexical": 30, "control_formatted": 29}
ID_CATEGORY = {"phone": "phone_country_prefix", "ordinal": "ordinal", "clock": "clock_idiom"}
ID_SPLIT = {"dev": "development", "hold": "holdout", "ctl": "control"}
HASHED_FIELDS = [
    "category", "split", "spoken_input", "input_kind", "expected_action",
    "accepted_written_variants", "target_spans", "must_preserve", "refusal_reason", "region_limit",
]


class Problems(list):
    def add(self, where, message):
        self.append(f"{where}: {message}")


# --------------------------------------------------------------------------------------------
# JSON Schema subset


def resolve(schema, root):
    while "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        schema = node
    return schema


def type_ok(value, expected):
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "null": value is None,
        "boolean": isinstance(value, bool),
    }[expected]


def check_schema(value, schema, root, where, problems):
    schema = resolve(schema, root)
    if "anyOf" in schema:
        trial = [Problems() for _ in schema["anyOf"]]
        for sub, sink in zip(schema["anyOf"], trial):
            check_schema(value, sub, root, where, sink)
        if all(sink for sink in trial):
            problems.add(where, f"matches none of the allowed shapes ({trial[0][0] if trial[0] else ''})")
        return
    expected = schema.get("type")
    if expected and not type_ok(value, expected):
        problems.add(where, f"expected {expected}, got {type(value).__name__}")
        return
    if "enum" in schema and value not in schema["enum"]:
        problems.add(where, f"{value!r} not in {schema['enum']}")
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            problems.add(where, "string too short")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            problems.add(where, f"{value!r} does not match {schema['pattern']}")
    if isinstance(value, int) and not isinstance(value, bool) and value < schema.get("minimum", value):
        problems.add(where, f"{value} below minimum {schema['minimum']}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            problems.add(where, f"needs at least {schema['minItems']} items")
        for index, item in enumerate(value):
            if "items" in schema:
                check_schema(item, schema["items"], root, f"{where}[{index}]", problems)
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                problems.add(where, f"missing required field {key}")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    problems.add(where, f"unexpected field {key}")
        for key, sub in props.items():
            if key in value:
                check_schema(value[key], sub, root, f"{where}.{key}", problems)


# --------------------------------------------------------------------------------------------
# Loading


def read_json(path, problems):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        problems.add(str(path), f"cannot read or parse: {exc}")
        return None


def read_rows(path, problems):
    rows = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        problems.add(str(path), f"cannot read: {exc}")
        return rows
    for number, line in enumerate(lines, 1):
        if not line.strip():
            problems.add(f"{path.name}:{number}", "blank line in a JSON Lines file")
            continue
        try:
            row = json.loads(line)
        except ValueError as exc:
            problems.add(f"{path.name}:{number}", f"parse error: {exc}")
            continue
        rows.append((number, row))
    return rows


REFUSAL_HASHED_FIELDS = ["category", "reason_code", "match", "required_context", "region_limit", "evidence_ids"]


def refusal_hash(entry):
    """Hash of the fields the panel judged. Same byte-sensitive serialization as content_hash."""
    body = {key: entry.get(key) for key in REFUSAL_HASHED_FIELDS}
    text = json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def content_hash(row):
    body = {key: row.get(key) for key in HASHED_FIELDS}
    text = json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    # Byte-sensitive on purpose: no Unicode normalization, so a changed byte can never keep a review hash.
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------------------------
# Row checks


def apply_spans(sentence, spans, choice):
    """Replace each span's FIRST occurrence in order with the chosen written form."""
    out, cursor = [], 0
    for span, form in zip(spans, choice):
        at = sentence.find(span["spoken_span"], cursor)
        if at < 0:
            return None
        out.append(sentence[cursor:at])
        out.append(form)
        cursor = at + len(span["spoken_span"])
    out.append(sentence[cursor:])
    return "".join(out)


def check_row(row, file_split, vocab, problems):
    where = row.get("id", "<no id>")
    match = re.fullmatch(r"de-(phone|ordinal|clock)-(dev|hold|ctl)-[0-9]{3}", where)
    if match:
        if row.get("category") != ID_CATEGORY[match.group(1)]:
            problems.add(where, "id category does not match the category field")
        if row.get("split") != ID_SPLIT[match.group(2)]:
            problems.add(where, "id split does not match the split field")
    category, split = row.get("category"), row.get("split")
    if category not in vocab["category"]:
        problems.add(where, f"category {category!r} outside the closed vocabulary")
    if split not in vocab["split"]:
        problems.add(where, f"split {split!r} outside the closed vocabulary")
    if split != file_split:
        problems.add(where, f"split {split!r} found in the {file_split} file")
    for field, key in (("input_kind", "input_kind"), ("expected_action", "expected_action"),
                       ("panel_status", "panel_status")):
        if row.get(field) not in vocab[key]:
            problems.add(where, f"{field} {row.get(field)!r} outside the closed vocabulary")
    if row.get("content_sha256") != content_hash(row):
        problems.add(where, "content_sha256 does not match the row content")
    status, ref = row.get("panel_status"), row.get("review_ref")
    if status == "panel-reviewed" and not ref:
        problems.add(where, "a panel-reviewed row needs a review_ref")
    if status == "panel-reviewed" and isinstance(ref, str) and f":{row.get('version')}:" not in f":{ref}:" \
            and not ref.endswith(f":v{row.get('version')}"):
        problems.add(where, "review_ref must name this row version (…:v<version>)")
    spoken, variants = row.get("spoken_input"), row.get("accepted_written_variants")
    spans, action = row.get("target_spans") or [], row.get("expected_action")
    reasons = vocab["refusal_reason_by_category"].get(category, [])
    if not isinstance(spoken, str) or not isinstance(variants, list):
        return
    if action == "convert":
        if row.get("refusal_reason") is not None:
            problems.add(where, "a convert row must have refusal_reason null")
        if row.get("input_kind") != "spoken_sentence":
            problems.add(where, "a convert row must be a spoken_sentence")
        if not spans:
            problems.add(where, "a convert row needs target_spans")
        if split == "control":
            problems.add(where, "a control row cannot be a convert row")
        for span in spans:
            if span["spoken_span"] not in spoken:
                problems.add(where, f"span {span['spoken_span']!r} is not in spoken_input")
        forms = [span["written_forms"] for span in spans]
        reachable = set()
        if all(isinstance(f, list) for f in forms) and forms:
            for choice in itertools.islice(itertools.product(*forms), 5000):
                built = apply_spans(spoken, spans, choice)
                if built is not None:
                    reachable.add(built)
        for variant in variants:
            if variant not in reachable:
                problems.add(where, f"variant {variant!r} is not spoken_input with the spans replaced")
        if variants and spoken in variants:
            problems.add(where, "the unconverted sentence cannot be an accepted variant")
        if reachable and set(variants) != reachable:
            problems.add(where, "accepted_written_variants must list every span-form combination "
                                "or the spans must narrow written_forms to the accepted ones")
        for needle in row.get("must_preserve") or []:
            if needle not in spoken:
                problems.add(where, f"must_preserve {needle!r} is not in spoken_input")
            for variant in variants:
                if needle not in variant:
                    problems.add(where, f"must_preserve {needle!r} missing from variant {variant!r}")
    elif action == "preserve":
        if row.get("refusal_reason") not in reasons:
            problems.add(where, f"refusal_reason {row.get('refusal_reason')!r} not allowed for {category}")
        if spans:
            problems.add(where, "a preserve row has no target_spans")
        if variants != [spoken]:
            problems.add(where, "a preserve row accepts exactly its own byte-identical sentence")
        if split != "control":
            problems.add(where, "a preserve row must be in the control split")
        if (row.get("refusal_reason") == "already_formatted") != (row.get("input_kind") == "already_formatted_synthetic"):
            problems.add(where, "already_formatted reason and already_formatted_synthetic kind go together")
    prov = row.get("provenance") or {}
    for evidence in prov.get("evidence_ids", []):
        if evidence not in vocab["evidence_ids"]:
            problems.add(where, f"unknown evidence id {evidence}")


# --------------------------------------------------------------------------------------------
# Whole-corpus and refusal checks


def control_kind(row):
    return "control_formatted" if row.get("refusal_reason") == "already_formatted" else "control_lexical"


def frozen_counts(rows):
    counts = {}
    for row in rows:
        if row.get("panel_status") != "panel-reviewed":
            continue
        key = row["category"], row["split"] if row["split"] != "control" else control_kind(row)
        counts[key] = counts.get(key, 0) + 1
    return counts


def check_refusals(data, rows_by_id, vocab, problems):
    seen = set()
    for bucket, status_ok in (("reviewed_entries", {"panel-reviewed"}), ("pending_entries", {"pending", "draft"})):
        for entry in data.get(bucket, []):
            where = entry.get("id", "<no id>")
            if where in seen:
                problems.add(where, "duplicate refusal id")
            seen.add(where)
            if entry.get("panel_status") not in status_ok:
                problems.add(where, f"{bucket} cannot hold status {entry.get('panel_status')!r}")
            if bucket == "reviewed_entries" and not entry.get("review_ref"):
                problems.add(where, "a reviewed refusal needs a review_ref")
            if bucket == "reviewed_entries":
                ref = entry.get("review_ref") or ""
                if not ref.endswith(f":v{entry.get('version')}"):
                    problems.add(where, "a reviewed refusal needs a version that its review_ref names (…:v<version>)")
                if entry.get("content_sha256") != refusal_hash(entry):
                    problems.add(where, "content_sha256 does not match the reviewed fields; a changed entry needs a new version and a fresh review")
            category = entry.get("category")
            if category not in vocab["category"]:
                problems.add(where, f"category {category!r} outside the closed vocabulary")
            if entry.get("reason_code") not in vocab["refusal_reason_by_category"].get(category, []) \
                    or entry.get("reason_code") == "already_formatted":
                problems.add(where, f"reason_code {entry.get('reason_code')!r} not allowed for {category}")
            if entry.get("required_context") not in vocab["required_context"]:
                problems.add(where, "required_context outside the closed vocabulary")
            match = entry.get("match") or {}
            if match.get("kind") not in vocab["match_kind"]:
                problems.add(where, "match.kind outside the closed vocabulary")
            if match.get("kind") == "literal_phrase":
                if not match.get("tokens") or match.get("context_shape") is not None:
                    problems.add(where, "a literal_phrase needs tokens and a null context_shape")
            if match.get("kind") == "context_shape":
                if match.get("context_shape") not in vocab["context_shape"]:
                    problems.add(where, "context_shape outside the closed vocabulary")
            for token in match.get("tokens", []):
                if re.search(r"[\\\[\]()*+?{}|^$]", token):
                    problems.add(where, f"token {token!r} looks like a pattern; tokens are literal words")
            for evidence in entry.get("evidence_ids", []):
                if evidence not in vocab["evidence_ids"]:
                    problems.add(where, f"unknown evidence id {evidence}")
            for ref in entry.get("supporting_row_ids", []):
                row = rows_by_id.get(ref)
                if row is None:
                    problems.add(where, f"supporting row {ref} does not exist")
                elif row["split"] == "holdout":
                    problems.add(where, f"supporting row {ref} is a holdout row; refusal logic uses development and control rows only")
                elif bucket == "reviewed_entries" and row.get("panel_status") != "panel-reviewed":
                    problems.add(where, f"reviewed refusal rests on {ref}, which is {row.get('panel_status')}")
                elif row.get("category") != category:
                    problems.add(where, f"supporting row {ref} belongs to another category")


def validate(root, frozen):
    problems = Problems()
    schema = read_json(root / SCHEMA_FILE, problems)
    if schema is None:
        return problems, {}
    vocab = schema["x-closed-vocabulary"]
    rows_all, rows_by_id, hashes_seen = [], {}, {}
    for split, rel in CORPUS_FILES.items():
        for number, row in read_rows(root / rel, problems):
            where = f"{Path(rel).name}:{number}"
            check_schema(row, {"$ref": "#/$defs/row"}, schema, where, problems)
            if isinstance(row, dict):
                check_row(row, split, vocab, problems)
                rid = row.get("id")
                if rid in rows_by_id:
                    problems.add(where, f"duplicate id {rid}")
                rows_by_id[rid] = row
                rows_all.append(row)
                key = unicodedata.normalize("NFC", str(row.get("spoken_input"))).casefold()
                if key in hashes_seen:
                    problems.add(where, f"duplicate sentence (also {hashes_seen[key]})")
                hashes_seen[key] = rid
    if not rows_all:
        problems.add("corpus", "no rows were read; an empty corpus is a failure")
    data = read_json(root / REFUSAL_FILE, problems)
    if data is not None:
        check_schema(data, {"$ref": "#/$defs/refusalFile"}, schema, REFUSAL_FILE, problems)
        if isinstance(data, dict):
            check_refusals(data, rows_by_id, vocab, problems)
    counts = frozen_counts(rows_all)
    if frozen:
        for category in vocab["category"]:
            for key, target in FROZEN_TARGETS.items():
                got = counts.get((category, key), 0)
                if got != target:
                    problems.add(f"frozen:{category}:{key}", f"{got} panel-reviewed rows, need {target}")
    summary = {"rows": len(rows_all), "panel_reviewed": sum(counts.values()),
               "pending_or_draft": len(rows_all) - sum(counts.values()), "counts": counts}
    return problems, summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=str(HERE))
    parser.add_argument("--frozen", action="store_true")
    args = parser.parse_args(argv)
    problems, summary = validate(Path(args.root), args.frozen)
    for problem in problems:
        print(f"validate-review-data: {problem}", file=sys.stderr)
    if problems:
        print(f"FAILED: {len(problems)} problem(s)", file=sys.stderr)
        return 1
    print(f"OK: {summary['rows']} rows, {summary['panel_reviewed']} panel-reviewed, "
          f"{summary['pending_or_draft']} pending or draft")
    return 0


if __name__ == "__main__":
    sys.exit(main())
