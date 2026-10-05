#!/usr/bin/env python3
"""Generate German number data for the inverse text normalizer from PINNED sources (#1677, PR 2).

Offline compilation of lexical data. Every input is a file under scripts/itn/sources/, listed in
scripts/itn/manifest.json with the upstream repository, tag, COMMIT, path and SHA-256. Normal
generation and --check read only those local bytes and need no network. Source tables establish
generation integrity, never sentence correctness: nothing here says a German sentence converts
correctly, and nothing generated is reachable from runtime normalization until a later PR
registers a vetted rule set.

Two source classes, each keeping its own meaning:

  NeMo text-processing r1.2.0, text_normalization/de/data/numbers (Apache-2.0). Column 1 is the
  SPOKEN form. Column 2 is a value whose meaning depends on the file (declared in the manifest):
  zero and ones carry the value itself; digit carries a unit digit 2..9; teen carries 10..19; ties
  carries the TENS DIGIT (zwanzig is 2, not 20), which this generator multiplies by ten. ones.tsv
  may carry a third column, an FST preference weight, which is ignored. quantities.tsv has ONE
  column (scale words with no stated value).

  CLDR release-48-2, common/rbnf/de.xml (Unicode License v3). Only the rulesets named in the
  manifest are read, from the canonical <rbnfRules> text block. A rule whose body is one literal
  word is an atom. Every other rule is kept as a structured instruction (tokens), never as a
  spoken word, and an unsupported construct in a selected ruleset fails the run: nothing is
  dropped silently. Parsed-rule count must equal atoms plus instructions.

A bounded ORDINAL extraction is declared per CLDR source in the manifest (`ordinal`): the base
  ordinal ruleset's irregular literal forms and its regular suffix rules below 100, plus the
  declared inflection rulesets (`-n`, `-r`). Every rule of every `%spellout-ordinal*` ruleset is
  accounted for: kept as an ordinal atom, suffix rule or inflection, or counted as deliberately
  excluded (negative, decimal, scale rules and the undeclared `-s` / `-m` inflections). A rule that
  fits none of those fails the run.

A second, separate output lowers the REVIEWED phone-prefix refusal entries (manifest `phonePrefix`):
  the reviewed entries of one category in refusals/de.json, checked against their semantic hashes,
  versions and the closed shape vocabulary of review-data.schema.json, emitted as typed rows with
  their ids, versions, hashes and review references. Pending entries and other categories are
  never read into the output; a missing, extra or malformed required entry fails the whole run.

Normalization operations (all recorded in the generated inventory): Unicode NFC; lower-casing of
spoken forms; removal of U+00AD SOFT HYPHEN from CLDR literals (a hyphenation hint, not a
spoken character); tens digit times ten; the ones.tsv weight column ignored.

Identical mappings from two sources merge into one entry that lists both sources. Conflicting
meanings in one semantic role (one spoken form, two values) fail the run.

Usage:
  scripts/itn/generate.py               # validate every input, then write the committed output
  scripts/itn/generate.py --check       # regenerate in an owned temp dir and byte-compare
  scripts/itn/generate.py --self-test   # run the generator's own tests (nonzero count required)
  scripts/itn/generate.py --refresh     # re-download the pinned URLs and verify their hashes
  scripts/itn/generate.py --inventory   # print the source-to-output inventory
Test seams: --manifest PATH and --out PATH point the same code at fixture inputs.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import unicodedata
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
DEFAULT_MANIFEST = HERE / "manifest.json"
DEFAULT_OUT = ROOT / "Sources/EnviousWisprPostProcessing/Generated/GermanNumberData.swift"
DEFAULT_PHONE_OUT = ROOT / "Sources/EnviousWisprPostProcessing/Generated/GermanPhonePrefixData.swift"

SOFT_HYPHEN = "­"
ROLE_ORDER = ["zero", "unit", "teen", "tens"]

# Per NeMo file: (role, accepted value range after normalization, columns, tens-digit factor).
NEMO_KINDS = {
    "zero": {"role": "zero", "lo": 0, "hi": 0, "factor": 1, "columns": (2, 2)},
    "digit": {"role": "unit", "lo": 2, "hi": 9, "factor": 1, "columns": (2, 2)},
    "ones": {"role": "unit", "lo": 1, "hi": 1, "factor": 1, "columns": (2, 3)},
    "teen": {"role": "teen", "lo": 10, "hi": 19, "factor": 1, "columns": (2, 2)},
    "ties": {"role": "tens", "lo": 20, "hi": 90, "factor": 10, "columns": (2, 2)},
}


class GenerationError(Exception):
    """A pinned input is missing, altered, malformed or in conflict. The run writes nothing."""


# --------------------------------------------------------------------------------------------
# Inputs


def sha256_of(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_manifest(manifest_path):
    try:
        manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise GenerationError(f"cannot read manifest {manifest_path}: {exc}")
    if manifest.get("schema") != 1 or not manifest.get("sources"):
        raise GenerationError("manifest must have schema 1 and a non-empty sources list")
    ids = [s.get("id") for s in manifest["sources"]]
    if len(set(ids)) != len(ids) or not all(ids):
        raise GenerationError("manifest source ids must be unique and non-empty")
    return manifest


def verify_sources(manifest, base):
    """Every listed file and licence exists and matches its pinned SHA-256. Nothing is parsed
    before all hashes pass."""
    for source in manifest["sources"]:
        for key, hash_key in (("file", "sha256"), ("licenseFile", "licenseSha256")):
            path = base / source[key]
            if not path.is_file():
                raise GenerationError(f"{source['id']}: missing {path}")
            actual = sha256_of(path)
            if actual != source[hash_key]:
                raise GenerationError(
                    f"{source['id']}: {source[key]} hash {actual} != pinned {source[hash_key]}"
                )
        for field in ("repo", "tag", "commit", "path", "license"):
            if not source.get(field):
                raise GenerationError(f"{source['id']}: manifest field {field} is empty")
        if not re.fullmatch(r"[0-9a-f]{40}", source["commit"]):
            raise GenerationError(f"{source['id']}: commit must be a 40-hex SHA, not a ref")


def normalize_spoken(text):
    return unicodedata.normalize("NFC", text).lower()


# --------------------------------------------------------------------------------------------
# NeMo TSV


def parse_nemo(source, base):
    kind = NEMO_KINDS.get(source.get("nemoKind"))
    path = base / source["file"]
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines:
        raise GenerationError(f"{source['id']}: empty file")
    atoms, words = [], []
    for number, line in enumerate(lines, 1):
        cells = line.split("\t")
        where = f"{source['id']}:{number}"
        if source.get("nemoKind") == "quantities":
            if len(cells) != 1 or not cells[0].strip():
                raise GenerationError(f"{where}: quantities rows have exactly one non-empty column")
            words.append(normalize_spoken(cells[0]))
            continue
        if kind is None:
            raise GenerationError(f"{source['id']}: unknown nemoKind {source.get('nemoKind')!r}")
        lo_cols, hi_cols = kind["columns"]
        if not lo_cols <= len(cells) <= hi_cols or not cells[0].strip():
            raise GenerationError(f"{where}: expected {lo_cols}..{hi_cols} columns, got {cells!r}")
        if not re.fullmatch(r"\d+", cells[1]):
            raise GenerationError(f"{where}: value {cells[1]!r} is not a non-negative integer")
        if len(cells) == 3:
            try:
                float(cells[2])
            except ValueError:
                raise GenerationError(f"{where}: weight {cells[2]!r} is not a number")
        value = int(cells[1]) * kind["factor"]
        if not kind["lo"] <= value <= kind["hi"]:
            raise GenerationError(f"{where}: value {value} outside {kind['lo']}..{kind['hi']}")
        atoms.append((kind["role"], value, normalize_spoken(cells[0]), source["id"]))
    return atoms, words


# --------------------------------------------------------------------------------------------
# CLDR RBNF

SELECTOR = re.compile(r"^(?:-x|x\.x|0\.x|\d+(?:/\d+)?)$")
SUPPORTED_PLAIN = re.compile(r"[^<>=\[\]$\{\}]")


def tokenize_body(body, where):
    """Split one RBNF rule body into tokens, or fail on a construct this generator does not
    support. Substitution syntax is never a spoken word."""
    tokens, literal, i = [], [], 0

    def flush():
        if literal:
            tokens.append(("literal", "".join(literal)))
            literal.clear()

    while i < len(body):
        ch = body[i]
        if ch == SOFT_HYPHEN:
            i += 1
            continue
        if body.startswith("$(", i):
            raise GenerationError(f"{where}: plural syntax $(...)$ is not supported")
        if ch in "[]":
            flush()
            tokens.append(("optionalOpen" if ch == "[" else "optionalClose", ""))
            i += 1
        elif body.startswith(">>>", i):
            flush()
            tokens.append(("remainderSkip", ""))
            i += 3
        elif body.startswith(">>", i):
            flush()
            tokens.append(("remainder", ""))
            i += 2
        elif body.startswith("<<", i):
            flush()
            tokens.append(("quotient", ""))
            i += 2
        elif ch in "<>":
            match = re.match(r"([<>])(%%?[A-Za-z0-9-]+)\1", body[i:])
            if not match:
                raise GenerationError(f"{where}: unsupported substitution near {body[i:i+20]!r}")
            flush()
            tokens.append(("quotientRule" if ch == "<" else "remainderRule", match.group(2)))
            i += match.end()
        elif ch == "=":
            match = re.match(r"=(%%?[A-Za-z0-9-]+)=", body[i:])
            if match:
                flush()
                tokens.append(("redirect", match.group(1)))
                i += match.end()
                continue
            match = re.match(r"=([#0,.]+)=", body[i:])
            if not match:
                raise GenerationError(f"{where}: unsupported redirect near {body[i:i+20]!r}")
            flush()
            tokens.append(("redirectFormat", match.group(1)))
            i += match.end()
        elif ch in "${}":
            raise GenerationError(f"{where}: unsupported character {ch!r}")
        else:
            literal.append(ch)
            i += 1
    flush()
    depth = 0
    for kind, _ in tokens:
        depth += (kind == "optionalOpen") - (kind == "optionalClose")
        if depth < 0 or depth > 1:
            raise GenerationError(f"{where}: unbalanced or nested optional brackets")
    if depth != 0:
        raise GenerationError(f"{where}: unbalanced optional brackets")
    if not tokens:
        raise GenerationError(f"{where}: empty rule body")
    return tokens


def read_rbnf_rules(source, base):
    path = base / source["file"]
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        raise GenerationError(f"{source['id']}: XML is malformed: {exc}")
    blocks = [
        el.text or ""
        for grouping in root.iter("rulesetGrouping")
        if grouping.get("type") == "SpelloutRules"
        for el in grouping.findall("rbnfRules")
    ]
    if len(blocks) != 1:
        raise GenerationError(f"{source['id']}: expected one SpelloutRules rbnfRules block")
    rulesets, current = {}, None
    for number, raw in enumerate(blocks[0].splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        where = f"{source['id']}:rbnf:{number}"
        header = re.fullmatch(r"(%%?[A-Za-z0-9-]+):", line)
        if header:
            current = header.group(1)
            if current in rulesets:
                raise GenerationError(f"{where}: duplicate ruleset {current}")
            rulesets[current] = []
            continue
        if current is None:
            raise GenerationError(f"{where}: rule before any ruleset header")
        match = re.fullmatch(r"([^:]+):\s*(.*);", line)
        if not match or not SELECTOR.fullmatch(match.group(1).strip()):
            raise GenerationError(f"{where}: unsupported rule {line!r}")
        rulesets[current].append((match.group(1).strip(), match.group(2), where))
    return rulesets


def parse_cldr(source, base):
    rulesets = read_rbnf_rules(source, base)
    selected = source.get("rulesets") or []
    if not selected:
        raise GenerationError(f"{source['id']}: manifest names no rulesets")
    atoms, rules, parsed_total, soft_hyphens = [], [], 0, 0
    for name in selected:
        if name not in rulesets:
            raise GenerationError(f"{source['id']}: ruleset {name} not found")
        for selector, body, where in rulesets[name]:
            parsed_total += 1
            soft_hyphens += body.count(SOFT_HYPHEN)
            tokens = tokenize_body(body, where)
            single = len(tokens) == 1 and tokens[0][0] == "literal"
            if single and re.fullmatch(r"\d+", selector) and not re.search(r"\s", tokens[0][1]):
                value = int(selector)
                if value < 20:
                    role = "zero" if value == 0 else "unit" if value < 10 else "teen"
                    atoms.append((role, value, normalize_spoken(tokens[0][1]),
                                  f"{source['id']}#{name}"))
                    continue
            rules.append({"ruleset": name, "selector": selector, "tokens": tokens})
    if parsed_total != len(atoms) + len(rules):
        raise GenerationError(f"{source['id']}: parsed {parsed_total} rules but kept "
                              f"{len(atoms)} atoms + {len(rules)} instructions")
    return atoms, rules, parsed_total, soft_hyphens


def parse_cldr_ordinals(source, base, cardinal_rulesets):
    """The bounded ordinal extraction declared in the manifest, or None when none is declared.

    Returns atoms, suffix rules, inflections and the count of deliberately excluded rules; the
    four counts must sum to the number of rules in every ordinal ruleset."""
    decl = source.get("ordinal")
    if not decl:
        return None
    rulesets = read_rbnf_rules(source, base)
    base_name = decl.get("base")
    inflection_names = decl.get("inflectionRulesets") or []
    excluded_names = decl.get("excludedRulesets") or []
    irregular_below = decl.get("irregularBelow")
    if not base_name or not isinstance(irregular_below, int) or irregular_below < 1:
        raise GenerationError(f"{source['id']}: ordinal declaration needs base and irregularBelow")
    declared = {base_name, *inflection_names, *excluded_names}
    for name in sorted(declared):
        if name not in rulesets:
            raise GenerationError(f"{source['id']}: ordinal ruleset {name} not found")
    for name in rulesets:
        if name.startswith("%spellout-ordinal") and name not in declared:
            raise GenerationError(f"{source['id']}: ordinal ruleset {name} is neither declared "
                                  f"nor excluded in the manifest")
    atoms, suffix_rules, inflections, excluded, parsed = [], [], [], [], 0
    for selector, body, where in rulesets[base_name]:
        parsed += 1
        tokens = tokenize_body(body, where)
        kinds = [kind for kind, _ in tokens]
        if re.fullmatch(r"\d+", selector) and int(selector) < irregular_below:
            if kinds != ["literal"] or re.search(r"\s", tokens[0][1]):
                raise GenerationError(f"{where}: irregular ordinal {selector} must be one literal word")
            atoms.append({"spoken": normalize_spoken(tokens[0][1]), "value": int(selector),
                          "sources": [f"{source['id']}#{base_name}"]})
        elif re.fullmatch(r"\d+", selector) and int(selector) < 100:
            if kinds != ["redirect", "literal"] or tokens[0][1] not in cardinal_rulesets:
                raise GenerationError(f"{where}: ordinal suffix rule {selector} must be a "
                                      f"selected cardinal ruleset followed by one literal")
            suffix_rules.append({"fromValue": int(selector), "cardinalRuleset": tokens[0][1],
                                 "suffix": normalize_spoken(tokens[1][1]),
                                 "source": f"{source['id']}#{base_name}"})
        elif selector in ("-x", "x.x") or (re.fullmatch(r"\d+", selector) and int(selector) >= 100):
            excluded.append((base_name, selector))
        else:
            raise GenerationError(f"{where}: ordinal rule {selector!r} fits no declared class")
    for name in inflection_names:
        for selector, body, where in rulesets[name]:
            parsed += 1
            tokens = tokenize_body(body, where)
            if selector in ("-x", "x.x"):
                excluded.append((name, selector))
            elif selector == "0" and [k for k, _ in tokens] == ["redirect", "literal"] \
                    and tokens[0][1] == base_name:
                inflections.append({"ruleset": name, "baseRuleset": base_name,
                                    "suffix": normalize_spoken(tokens[1][1]),
                                    "source": f"{source['id']}#{name}"})
            else:
                raise GenerationError(f"{where}: inflection rule {selector!r} fits no declared class")
    for name in excluded_names:
        for selector, _, _ in rulesets[name]:
            parsed += 1
            excluded.append((name, selector))
    if sorted(a["value"] for a in atoms) != list(range(irregular_below)):
        raise GenerationError(f"{source['id']}: irregular ordinals must cover 0..{irregular_below - 1}")
    if not suffix_rules or not inflections:
        raise GenerationError(f"{source['id']}: ordinal extraction found no suffix rule or inflection")
    if parsed != len(atoms) + len(suffix_rules) + len(inflections) + len(excluded):
        raise GenerationError(f"{source['id']}: ordinal rules parsed {parsed} but accounted for "
                              f"{len(atoms) + len(suffix_rules) + len(inflections) + len(excluded)}")
    suffix_rules.sort(key=lambda r: r["fromValue"])
    inflections.sort(key=lambda r: r["ruleset"])
    return {"atoms": atoms, "suffixRules": suffix_rules, "inflections": inflections,
            "excluded": len(excluded), "parsed": parsed,
            "excludedRulesets": list(excluded_names)}


# --------------------------------------------------------------------------------------------
# Merge and cross-checks


def merge_atoms(entries):
    """Merge identical (role, value, spoken) mappings; fail on one spoken form with two values
    in one role."""
    merged, meaning = {}, {}
    for role, value, spoken, source in entries:
        seen = meaning.setdefault((role, spoken), value)
        if seen != value:
            raise GenerationError(
                f"conflict in role {role}: {spoken!r} means {seen} and {value} ({source})")
        merged.setdefault((role, value, spoken), []).append(source)
    out = []
    for (role, value, spoken), sources in merged.items():
        out.append({"role": role, "value": value, "spoken": spoken,
                    "sources": sorted(set(sources))})
    out.sort(key=lambda a: (ROLE_ORDER.index(a["role"]), a["value"], a["spoken"]))
    return out


def cross_check(atoms, quantity_words, rules):
    """CLDR and NeMo describe the same language: the literal ending each CLDR tens rule must be
    the NeMo tens word, and every CLDR scale noun must be a NeMo quantity word."""
    tens = {a["value"]: a["spoken"] for a in atoms if a["role"] == "tens"}
    quantity = set(quantity_words)
    for rule in rules:
        if rule["ruleset"] != "%spellout-numbering":
            continue
        selector = rule["selector"]
        tokens = rule["tokens"]
        if selector.isdigit() and int(selector) in tens:
            last = tokens[-1]
            if last[0] != "literal" or normalize_spoken(last[1]) != tens[int(selector)]:
                raise GenerationError(
                    f"cross-check: CLDR rule {selector} ends {last!r}, NeMo tens word is "
                    f"{tens[int(selector)]!r}")
        if selector.isdigit() and int(selector) >= 1_000_000:
            for kind, text in tokens:
                if kind != "literal":
                    continue
                for word in re.findall(r"[^\W\d_]+", normalize_spoken(text)):
                    if word in ("eine", "eins"):
                        continue
                    if word not in quantity:
                        raise GenerationError(
                            f"cross-check: CLDR scale word {word!r} (rule {selector}) is not a "
                            f"NeMo quantity word")


# --------------------------------------------------------------------------------------------
# Build and emit


def build(manifest, base):
    verify_sources(manifest, base)
    entries, quantity_words, rules, rule_counts, soft_hyphens = [], [], [], {}, 0
    nemo_ids, cldr_ids, ordinals = [], [], None
    for source in manifest["sources"]:
        kind = source.get("kind")
        if kind == "nemo-tsv":
            atoms, words = parse_nemo(source, base)
            entries += atoms
            quantity_words += [(w, source["id"]) for w in words]
            nemo_ids.append(source["id"])
        elif kind == "cldr-rbnf":
            atoms, source_rules, parsed, soft = parse_cldr(source, base)
            entries += atoms
            rules += source_rules
            soft_hyphens += soft
            rule_counts[source["id"]] = (parsed, len(atoms), len(source_rules))
            cldr_ids.append(source["id"])
            found = parse_cldr_ordinals(source, base, source.get("rulesets") or [])
            if found is not None:
                if ordinals is not None:
                    raise GenerationError("only one CLDR source may declare an ordinal extraction")
                ordinals = found
        else:
            raise GenerationError(f"{source['id']}: unknown source kind {kind!r}")
    atoms = merge_atoms(entries)
    word_sources = {}
    for word, source_id in quantity_words:
        word_sources.setdefault(word, set()).add(source_id)
    words = [{"spoken": w, "sources": sorted(word_sources[w])} for w in sorted(word_sources)]
    cross_check(atoms, [w["spoken"] for w in words], rules)
    if not atoms or not words or not rules:
        raise GenerationError("an empty generated table is never published")
    return {
        "sources": manifest["sources"],
        "atoms": atoms,
        "words": words,
        "rules": rules,
        "rule_counts": rule_counts,
        "ordinals": ordinals,
        "raw_atom_entries": len(entries),
        "soft_hyphens_removed": soft_hyphens,
    }


def load_refusal_hash():
    """The refusal entry hash has ONE definition: the review-data validator's."""
    import importlib.util
    path = HERE / "validate-review-data.py"
    spec = importlib.util.spec_from_file_location("validate_review_data", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.refusal_hash


def build_phone(manifest, base):
    """The reviewed phone-prefix refusal entries as typed rows, or None when not declared."""
    decl = manifest.get("phonePrefix")
    if decl is None:
        return None
    for key in ("category", "refusalsFile", "schemaFile", "requiredEntries", "replacement"):
        if not decl.get(key):
            raise GenerationError(f"phonePrefix: manifest field {key} is empty")
    try:
        data = json.loads((base / decl["refusalsFile"]).read_text(encoding="utf-8"))
        schema = json.loads((base / decl["schemaFile"]).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise GenerationError(f"phonePrefix: cannot read refusal inputs: {exc}")
    shapes = schema.get("x-closed-vocabulary", {}).get("context_shape")
    reviewed = data.get("reviewed_entries")
    pending = data.get("pending_entries")
    if not shapes or not isinstance(reviewed, list) or not isinstance(pending, list):
        raise GenerationError("phonePrefix: refusal file or schema lacks the expected lists")
    refusal_hash = load_refusal_hash()
    category = decl["category"]
    required = list(decl["requiredEntries"])
    chosen = [e for e in reviewed if e.get("category") == category]
    ids = sorted(e.get("id", "") for e in chosen)
    if ids != sorted(required) or len(set(ids)) != len(ids):
        raise GenerationError(
            f"phonePrefix: reviewed {category} entries {ids} are not the required set "
            f"{sorted(required)}")
    rows, triggers = [], None
    for entry in sorted(chosen, key=lambda e: e["id"]):
        where = f"phonePrefix:{entry['id']}"
        match = entry.get("match") or {}
        if entry.get("panel_status") != "panel-reviewed":
            raise GenerationError(f"{where}: status {entry.get('panel_status')!r} is not reviewed")
        ref = entry.get("review_ref") or ""
        if ref != f"refusal-ledger:{entry['id']}:v{entry.get('version')}":
            raise GenerationError(f"{where}: review_ref {ref!r} does not name version "
                                  f"{entry.get('version')}")
        if entry.get("content_sha256") != refusal_hash(entry):
            raise GenerationError(f"{where}: content_sha256 does not match the reviewed fields")
        if match.get("kind") != "context_shape" or match.get("context_shape") not in shapes:
            raise GenerationError(f"{where}: unsupported shape {match.get('context_shape')!r}")
        tokens = [normalize_spoken(t) for t in match.get("tokens") or []]
        if not tokens or any(not t or re.search(r"\s", t) for t in tokens):
            raise GenerationError(f"{where}: trigger tokens must be non-empty single words")
        if triggers is None:
            triggers = tokens
        elif tokens != triggers:
            raise GenerationError(f"{where}: trigger tokens {tokens} differ from {triggers}")
        rows.append({"id": entry["id"], "version": entry["version"],
                     "contentSHA256": entry["content_sha256"], "reasonCode": entry["reason_code"],
                     "contextShape": match["context_shape"], "reviewRef": ref})
    shape_names = [r["contextShape"] for r in rows]
    if len(set(shape_names)) != len(shape_names):
        raise GenerationError("phonePrefix: two required entries share one context shape")
    return {
        "category": category,
        "replacement": decl["replacement"],
        "triggers": triggers,
        "rows": rows,
        "pending_excluded": sum(1 for e in pending if e.get("category") == category),
        "refusalsFile": decl["refusalsFile"],
    }


def phone_inventory_lines(result):
    return [
        "Source-to-output inventory (reviewed refusal lowering only, not telephone grammar):",
        f"  source {result['refusalsFile']}: reviewed entries of category {result['category']}",
        f"  emitted: {len(result['rows'])} reviewed entries, each checked against its semantic "
        "hash, its version and the closed shape vocabulary",
        f"  excluded: {result['pending_excluded']} pending entries of this category, every "
        "other category",
        f"  trigger tokens: {', '.join(result['triggers'])}; replacement {result['replacement']!r}",
    ]


def emit_phone(result):
    out = ["// GENERATED by scripts/itn/generate.py from scripts/itn/manifest.json. DO NOT EDIT.",
           "// Regenerate with scripts/itn/generate.py; scripts/itn/generate.py --check verifies it.",
           "//"]
    out += ["// " + line for line in phone_inventory_lines(result)]
    out += [
        "//",
        "// Reviewed refusal data only (#1677). It is not a telephone grammar and makes no claim",
        "// that a German sentence converts correctly.",
        "",
        "enum GermanPhonePrefixData {",
        "  /// One reviewed refusal entry, exactly as the panel approved it.",
        "  struct Refusal: Equatable {",
        "    let id: String",
        "    let version: Int",
        "    let contentSHA256: String",
        "    let reasonCode: String",
        "    let contextShape: String",
        "    let reviewRef: String",
        "  }",
        "",
        f"  static let replacement = {swift_string(result['replacement'])}",
        "",
        "  static let triggerTokens: [String] = [",
    ]
    out += [f"    {swift_string(t)}," for t in result["triggers"]]
    out += ["  ]", "", "  static let refusals: [Refusal] = ["]
    for r in result["rows"]:
        out.append(
            f"    Refusal(id: {swift_string(r['id'])}, version: {r['version']}, "
            f"contentSHA256: {swift_string(r['contentSHA256'])}, "
            f"reasonCode: {swift_string(r['reasonCode'])}, "
            f"contextShape: {swift_string(r['contextShape'])}, "
            f"reviewRef: {swift_string(r['reviewRef'])}),")
    out += ["  ]", "}", ""]
    return "\n".join(out)


def swift_string(text):
    out = []
    for ch in text:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ord(ch) < 0x20 or ord(ch) == 0x7F or unicodedata.category(ch) in ("Cf", "Zl", "Zp"):
            out.append("\\u{%X}" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


TOKEN_CASE = {
    "literal": "literal", "optionalOpen": "optionalOpen", "optionalClose": "optionalClose",
    "quotient": "quotient", "remainder": "remainder", "remainderSkip": "remainderSkip",
    "quotientRule": "quotientRule", "remainderRule": "remainderRule",
    "redirect": "redirect", "redirectFormat": "redirectFormat",
}
WITH_TEXT = {"literal", "quotientRule", "remainderRule", "redirect", "redirectFormat"}


def swift_token(kind, text):
    case = TOKEN_CASE[kind]
    return f".{case}({swift_string(text)})" if kind in WITH_TEXT else f".{case}"


def inventory_lines(result):
    atoms = result["atoms"]
    by_role = {r: sum(1 for a in atoms if a["role"] == r) for r in ROLE_ORDER}
    merged = sum(1 for a in atoms if len(a["sources"]) > 1)
    lines = ["Source-to-output inventory (generation integrity only, not German number grammar):"]
    for source in result["sources"]:
        lines.append(f"  source {source['id']}: {source['repo']} {source['tag']} "
                     f"{source['commit'][:12]} {source['path']} sha256 {source['sha256'][:12]} "
                     f"({source['license']})")
    lines += [
        f"  included: NeMo zero, digit, ones, teen, ties, quantities; CLDR rulesets "
        f"{', '.join(next(s for s in result['sources'] if s['kind'] == 'cldr-rbnf')['rulesets'])}",
        "  excluded: CLDR cardinal-neuter/-n/-r/-s/-m, spellout-numbering-year, the ordinal "
        "rules outside the declared extraction (negative, decimal and scale rules, the -s and -m "
        "inflections), the NeMo fraction, money, measure, time, date and electronic data",
        "  normalization: NFC; lower-case spoken forms; U+00AD removed from CLDR literals "
        f"({result['soft_hyphens_removed']} in the selected rules); NeMo tens digit times ten; "
        "ones.tsv weight column ignored",
        f"  atom entries read: {result['raw_atom_entries']}; merged atoms: {len(atoms)} "
        f"({merged} backed by two sources); by role "
        + ", ".join(f"{r} {by_role[r]}" for r in ROLE_ORDER),
        f"  quantity words (NeMo, no stated value): {len(result['words'])}",
    ]
    for source_id, (parsed, atom_count, rule_count) in sorted(result["rule_counts"].items()):
        lines.append(f"  CLDR rules parsed: {parsed} = {atom_count} atoms + {rule_count} "
                     "instructions (every selected rule accounted for)")
    ordinals = result.get("ordinals")
    if ordinals:
        lines.append(
            f"  CLDR ordinal rules parsed: {ordinals['parsed']} = {len(ordinals['atoms'])} atoms + "
            f"{len(ordinals['suffixRules'])} suffix rules + {len(ordinals['inflections'])} "
            f"inflections + {ordinals['excluded']} excluded (every ordinal rule accounted for)")
    lines.append("  collisions: identical mappings merged with provenance; any one-spoken-form, "
                 "two-value conflict in a role fails the run")
    return lines


def emit(result):
    out = ["// GENERATED by scripts/itn/generate.py from scripts/itn/manifest.json. DO NOT EDIT.",
           "// Regenerate with scripts/itn/generate.py; scripts/itn/generate.py --check verifies it.",
           "//"]
    out += ["// " + line for line in inventory_lines(result)]
    out += [
        "//",
        "// Candidate lexical data only (#1677). It is not a vetted rule set, nothing in runtime",
        "// normalization reads it, and it makes no claim that a German sentence converts correctly.",
        "",
        "enum GermanNumberData {",
        "  /// What a spoken atom is, by source semantics (not by spelling).",
        "  enum Role: String, CaseIterable { case zero, unit, teen, tens }",
        "",
        "  /// One RBNF construct. Substitution tokens are instructions and never spoken words.",
        "  enum Token: Equatable {",
        "    case literal(String)",
        "    case optionalOpen",
        "    case optionalClose",
        "    case quotient",
        "    case remainder",
        "    case remainderSkip",
        "    case quotientRule(String)",
        "    case remainderRule(String)",
        "    case redirect(String)",
        "    case redirectFormat(String)",
        "  }",
        "",
        "  struct Atom: Equatable {",
        "    let spoken: String",
        "    let value: Int",
        "    let role: Role",
        "    let sources: [String]",
        "  }",
        "",
        "  struct QuantityWord: Equatable {",
        "    let spoken: String",
        "    let sources: [String]",
        "  }",
        "",
        "  /// A CLDR rule that is not a single-word atom, kept as instructions.",
        "  struct Rule: Equatable {",
        "    let ruleset: String",
        "    let selector: String",
        "    let tokens: [Token]",
        "  }",
        "",
    ]
    if result.get("ordinals"):
        out += [
            "  /// An irregular ordinal form read from the base ordinal ruleset (spoken word, value).",
            "  struct OrdinalAtom: Equatable {",
            "    let spoken: String",
            "    let value: Int",
            "    let sources: [String]",
            "  }",
            "",
            "  /// A regular ordinal: the cardinal of `cardinalRuleset` followed by `suffix`, for every",
            "  /// value from `fromValue` up to the next rule's `fromValue` (or the end of the range).",
            "  struct OrdinalSuffixRule: Equatable {",
            "    let fromValue: Int",
            "    let cardinalRuleset: String",
            "    let suffix: String",
            "    let source: String",
            "  }",
            "",
            "  /// A declared inflection of the base ordinal: the base form followed by `suffix`.",
            "  struct OrdinalInflection: Equatable {",
            "    let ruleset: String",
            "    let baseRuleset: String",
            "    let suffix: String",
            "    let source: String",
            "  }",
            "",
        ]
    out += [
        "  static let sourceIDs: [String] = [",
    ]
    out += [f"    {swift_string(s['id'])}," for s in result["sources"]]
    out += ["  ]", "", "  static let atoms: [Atom] = ["]
    for a in result["atoms"]:
        sources = ", ".join(swift_string(s) for s in a["sources"])
        out.append(f"    Atom(spoken: {swift_string(a['spoken'])}, value: {a['value']}, "
                   f"role: .{a['role']}, sources: [{sources}]),")
    out += ["  ]", "", "  static let quantityWords: [QuantityWord] = ["]
    for w in result["words"]:
        sources = ", ".join(swift_string(s) for s in w["sources"])
        out.append(f"    QuantityWord(spoken: {swift_string(w['spoken'])}, sources: [{sources}]),")
    out += ["  ]", "", "  static let rules: [Rule] = ["]
    for r in result["rules"]:
        tokens = ", ".join(swift_token(k, t) for k, t in r["tokens"])
        out.append(f"    Rule(ruleset: {swift_string(r['ruleset'])}, "
                   f"selector: {swift_string(r['selector'])}, tokens: [{tokens}]),")
    out += ["  ]"]
    ordinals = result.get("ordinals")
    if ordinals:
        out += ["", "  static let ordinalAtoms: [OrdinalAtom] = ["]
        for a in sorted(ordinals["atoms"], key=lambda a: a["value"]):
            sources = ", ".join(swift_string(s) for s in a["sources"])
            out.append(f"    OrdinalAtom(spoken: {swift_string(a['spoken'])}, value: {a['value']}, "
                       f"sources: [{sources}]),")
        out += ["  ]", "", "  static let ordinalSuffixRules: [OrdinalSuffixRule] = ["]
        for r in ordinals["suffixRules"]:
            out.append(f"    OrdinalSuffixRule(fromValue: {r['fromValue']}, "
                       f"cardinalRuleset: {swift_string(r['cardinalRuleset'])}, "
                       f"suffix: {swift_string(r['suffix'])}, source: {swift_string(r['source'])}),")
        out += ["  ]", "", "  static let ordinalInflections: [OrdinalInflection] = ["]
        for r in ordinals["inflections"]:
            out.append(f"    OrdinalInflection(ruleset: {swift_string(r['ruleset'])}, "
                       f"baseRuleset: {swift_string(r['baseRuleset'])}, "
                       f"suffix: {swift_string(r['suffix'])}, source: {swift_string(r['source'])}),")
        out += ["  ]"]
    out += ["}", ""]
    return "\n".join(out)


def generate_bytes(manifest_path):
    manifest_path = Path(manifest_path)
    manifest = load_manifest(manifest_path)
    return emit(build(manifest, manifest_path.parent)).encode("utf-8")


def generate_phone_bytes(manifest_path):
    """The phone-prefix output, or None when the manifest declares none."""
    manifest_path = Path(manifest_path)
    manifest = load_manifest(manifest_path)
    result = build_phone(manifest, manifest_path.parent)
    return None if result is None else emit_phone(result).encode("utf-8")


def write_atomically(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".generate-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# --------------------------------------------------------------------------------------------
# Modes


def run_check(manifest_path, out_path, phone_out_path):
    """Verifies BOTH generated files without rewriting either."""
    with tempfile.TemporaryDirectory(prefix="itn-check-") as tmp:
        pairs = [(generate_bytes(manifest_path), out_path)]
        phone = generate_phone_bytes(manifest_path)
        if phone is not None:
            pairs.append((phone, phone_out_path))
        for index, (fresh, committed) in enumerate(pairs):
            regenerated = Path(tmp) / f"fresh-{index}.swift"
            write_atomically(regenerated, fresh)
            if not Path(committed).is_file():
                raise GenerationError(f"committed output {committed} is missing")
            if regenerated.read_bytes() != Path(committed).read_bytes():
                raise GenerationError(f"{committed} differs from a fresh regeneration; run generate.py")
    for _, committed in pairs:
        print(f"check ok: {committed} matches a fresh regeneration")


def run_refresh(manifest_path):
    manifest = load_manifest(manifest_path)
    verified = 0
    for source in manifest["sources"]:
        for url_key, hash_key, label in (("url", "sha256", "file"),
                                         ("licenseUrl", "licenseSha256", "license")):
            url = source[url_key]
            if source["commit"] not in url:
                raise GenerationError(f"{source['id']}: {url_key} must contain the pinned commit")
            with urllib.request.urlopen(url, timeout=60) as response:
                blob = response.read()
            digest = hashlib.sha256(blob).hexdigest()
            if digest != source[hash_key]:
                raise GenerationError(f"{source['id']}: upstream {label} hash {digest} != "
                                      f"pinned {source[hash_key]}")
            verified += 1
    print(f"refresh ok: {verified} pinned upstream files match their SHA-256")


def run_self_test():
    import unittest
    suite = unittest.defaultTestLoader.discover(str(HERE / "tests"), pattern="test_*.py")
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    if result.testsRun == 0:
        raise GenerationError("self-test ran zero tests")
    print(f"self-test: {result.testsRun} tests, {len(result.failures)} failures, "
          f"{len(result.errors)} errors")
    return result.wasSuccessful()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--out", default=str(DEFAULT_OUT))
    parser.add_argument("--phone-out", default=str(DEFAULT_PHONE_OUT))
    mode = parser.add_mutually_exclusive_group()
    for flag in ("--check", "--self-test", "--refresh", "--inventory"):
        mode.add_argument(flag, action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.self_test:
            return 0 if run_self_test() else 1
        if args.refresh:
            run_refresh(args.manifest)
        elif args.check:
            run_check(args.manifest, args.out, args.phone_out)
        elif args.inventory:
            manifest = load_manifest(args.manifest)
            print("\n".join(inventory_lines(build(manifest, Path(args.manifest).parent))))
            phone = build_phone(manifest, Path(args.manifest).parent)
            if phone is not None:
                print("\n".join(phone_inventory_lines(phone)))
        else:
            # Build and validate BOTH outputs before publishing either, so a failure writes nothing.
            data = generate_bytes(args.manifest)
            phone = generate_phone_bytes(args.manifest)
            write_atomically(args.out, data)
            print(f"wrote {args.out} ({len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()})")
            if phone is not None:
                write_atomically(args.phone_out, phone)
                print(f"wrote {args.phone_out} ({len(phone)} bytes, sha256 "
                      f"{hashlib.sha256(phone).hexdigest()})")
    except GenerationError as exc:
        print(f"generate.py: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
