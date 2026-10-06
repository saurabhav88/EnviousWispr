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

A fourth, separate output (manifest `clockIdiom`) carries the clock-idiom SYNTAX data (templates,
  anchors, trailing marker, separator: implementation admission data grounded in the approved scope,
  never derived from corpus sentences and not a reviewed refusal) and the reviewed clock refusal
  entries, which are all complete literal phrases.

A third, separate output (manifest `ordinalRefusals`) lowers the reviewed ORDINAL refusal entries the
  same way, keeping context-shape entries and literal-phrase entries distinct. No output carries a
  context lexicon: the reviewed entries supply tokens and shapes, not complete phrases.

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
DEFAULT_ORDINAL_OUT = ROOT / "Sources/EnviousWisprPostProcessing/Generated/GermanOrdinalData.swift"
DEFAULT_CLOCK_OUT = ROOT / "Sources/EnviousWisprPostProcessing/Generated/GermanClockIdiomData.swift"
DEFAULT_STYLE_OUT = ROOT / "Sources/EnviousWisprPostProcessing/Generated/GermanNumberStyleData.swift"
DEFAULT_TRIGGERS_OUT = ROOT / "Sources/EnviousWisprPostProcessing/Generated/PhoneTriggerData.swift"
DEFAULT_HOUR_CLOCK_OUT = ROOT / "Sources/EnviousWisprPostProcessing/Generated/HourFirstClockData.swift"

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


def refusal_inputs(manifest, base, key, required_keys):
    """The declaration, the reviewed entries of its category and the closed shape vocabulary, with
    the required set checked. Shared by every reviewed-refusal lowering."""
    decl = manifest.get(key)
    if decl is None:
        return None
    for field in required_keys:
        if not decl.get(field):
            raise GenerationError(f"{key}: manifest field {field} is empty")
    try:
        data = json.loads((base / decl["refusalsFile"]).read_text(encoding="utf-8"))
        schema = json.loads((base / decl["schemaFile"]).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise GenerationError(f"{key}: cannot read refusal inputs: {exc}")
    shapes = schema.get("x-closed-vocabulary", {}).get("context_shape")
    reviewed = data.get("reviewed_entries")
    pending = data.get("pending_entries")
    if not shapes or not isinstance(reviewed, list) or not isinstance(pending, list):
        raise GenerationError(f"{key}: refusal file or schema lacks the expected lists")
    category = decl["category"]
    required = list(decl["requiredEntries"])
    chosen = [e for e in reviewed if e.get("category") == category]
    ids = sorted(e.get("id", "") for e in chosen)
    if ids != sorted(required) or len(set(ids)) != len(ids):
        raise GenerationError(
            f"{key}: reviewed {category} entries {ids} are not the required set {sorted(required)}")
    return decl, chosen, shapes, sum(1 for e in pending if e.get("category") == category)


def check_reviewed(entry, key, refusal_hash):
    where = f"{key}:{entry['id']}"
    if entry.get("panel_status") != "panel-reviewed":
        raise GenerationError(f"{where}: status {entry.get('panel_status')!r} is not reviewed")
    ref = entry.get("review_ref") or ""
    if ref != f"refusal-ledger:{entry['id']}:v{entry.get('version')}":
        raise GenerationError(f"{where}: review_ref {ref!r} does not name version "
                              f"{entry.get('version')}")
    if entry.get("content_sha256") != refusal_hash(entry):
        raise GenerationError(f"{where}: content_sha256 does not match the reviewed fields")
    return where, ref


def build_phone(manifest, base):
    """The reviewed phone-prefix refusal entries as typed rows, or None when not declared."""
    loaded = refusal_inputs(manifest, base, "phonePrefix",
                            ("category", "refusalsFile", "schemaFile", "requiredEntries",
                             "replacement", "unsignedContext"))
    if loaded is None:
        return None
    decl, chosen, shapes, pending_excluded = loaded
    refusal_hash = load_refusal_hash()
    category = decl["category"]
    rows, triggers = [], None
    for entry in sorted(chosen, key=lambda e: e["id"]):
        where, ref = check_reviewed(entry, "phonePrefix", refusal_hash)
        match = entry.get("match") or {}
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
        "unsigned": build_unsigned_context(decl["unsignedContext"]),
        "rows": rows,
        "pending_excluded": pending_excluded,
        "refusalsFile": decl["refusalsFile"],
    }


UNSIGNED_WORD_ROLES = ("linkersBefore", "phoneWords", "nonNounWords", "valueVerbs",
                       "possessorArticles", "fieldSuffixes", "localQualifiers")


def build_unsigned_context(decl):
    """The word classes the phone pass's unsigned-number gates read (#1677 evolution): admission
    data for a shared algorithm, NOT a reviewed refusal and not a phone grammar. Every role must be
    a non-empty list of distinct lower-case single words; the possessive suffix is one short
    lower-case ending; the provenance says where the lists come from."""
    if not isinstance(decl, dict):
        raise GenerationError("phonePrefix: unsignedContext must be an object")
    known = set(UNSIGNED_WORD_ROLES) | {"possessiveSuffix", "provenance"}
    unknown = sorted(set(decl) - known)
    if unknown:
        raise GenerationError(f"phonePrefix: unsignedContext has unknown roles {unknown}")
    out = {}
    for role in UNSIGNED_WORD_ROLES:
        words = decl.get(role)
        if not isinstance(words, list) or not words:
            raise GenerationError(f"phonePrefix: unsignedContext.{role} must be a non-empty list")
        folded = [normalize_spoken(w) for w in words]
        if any(not w or re.search(r"\s", w) or w != w.lower() for w in folded):
            raise GenerationError(f"phonePrefix: unsignedContext.{role} needs lower-case single words")
        if len(set(folded)) != len(folded):
            raise GenerationError(f"phonePrefix: unsignedContext.{role} lists a word twice")
        out[role] = folded
    suffix = decl.get("possessiveSuffix")
    if not isinstance(suffix, str) or not re.fullmatch(r"[a-zäöüß]{1,3}", suffix):
        raise GenerationError("phonePrefix: unsignedContext.possessiveSuffix must be 1-3 lower-case letters")
    out["possessiveSuffix"] = suffix
    provenance = decl.get("provenance")
    if not isinstance(provenance, str) or not provenance.strip():
        raise GenerationError("phonePrefix: unsignedContext.provenance is empty")
    out["provenance"] = provenance
    return out


def build_ordinal(manifest, base):
    """The reviewed ordinal refusal entries (context shapes and literal phrases) as typed rows,
    or None when not declared."""
    loaded = refusal_inputs(manifest, base, "ordinalRefusals",
                            ("category", "refusalsFile", "schemaFile", "requiredEntries",
                             "allowedShapes", "writtenSuffix"))
    if loaded is None:
        return None
    decl, chosen, shapes, pending_excluded = loaded
    allowed = list(decl["allowedShapes"])
    unknown = [a for a in allowed if a not in shapes]
    if unknown:
        raise GenerationError(f"ordinalRefusals: allowedShapes {unknown} are outside the closed "
                              "vocabulary")
    refusal_hash = load_refusal_hash()
    rows, seen_shapes, seen_phrases = [], set(), set()
    for entry in sorted(chosen, key=lambda e: e["id"]):
        where, ref = check_reviewed(entry, "ordinalRefusals", refusal_hash)
        match = entry.get("match") or {}
        kind = match.get("kind")
        tokens = [normalize_spoken(t) for t in match.get("tokens") or []]
        if kind == "context_shape":
            shape = match.get("context_shape")
            if shape not in allowed:
                raise GenerationError(f"{where}: unsupported shape {shape!r}")
            if shape in seen_shapes:
                raise GenerationError(f"{where}: two required entries share shape {shape!r}")
            seen_shapes.add(shape)
            if not tokens or any(not t or re.search(r"\s", t) for t in tokens):
                raise GenerationError(f"{where}: tokens must be non-empty single words")
            swift_kind = "contextShape"
        elif kind == "literal_phrase":
            shape = None
            if match.get("context_shape") is not None:
                raise GenerationError(f"{where}: a literal phrase carries no context shape")
            if not tokens or any(not re.fullmatch(r"\S+( \S+)*", t) for t in tokens):
                raise GenerationError(f"{where}: phrases must be non-empty words joined by "
                                      "single spaces")
            for phrase in tokens:
                if phrase in seen_phrases:
                    raise GenerationError(f"{where}: phrase {phrase!r} appears twice")
                seen_phrases.add(phrase)
            swift_kind = "literalPhrase"
        else:
            raise GenerationError(f"{where}: unsupported match kind {kind!r}")
        rows.append({"id": entry["id"], "version": entry["version"],
                     "contentSHA256": entry["content_sha256"], "reasonCode": entry["reason_code"],
                     "kind": swift_kind, "contextShape": shape, "tokens": tokens,
                     "reviewRef": ref})
    return {
        "category": decl["category"],
        "writtenSuffix": decl["writtenSuffix"],
        "rows": rows,
        "pending_excluded": pending_excluded,
        "refusalsFile": decl["refusalsFile"],
    }


def ordinal_inventory_lines(result):
    shapes = sum(1 for r in result["rows"] if r["kind"] == "contextShape")
    phrases = len(result["rows"]) - shapes
    return [
        "Source-to-output inventory (reviewed refusal lowering only, not ordinal grammar):",
        f"  source {result['refusalsFile']}: reviewed entries of category {result['category']}",
        f"  emitted: {len(result['rows'])} reviewed entries ({shapes} context shapes, {phrases} "
        "literal phrase entries), each checked against its semantic hash, its version and the "
        "allowed shapes",
        f"  excluded: {result['pending_excluded']} pending entries of this category, every "
        "other category",
        f"  written suffix: {result['writtenSuffix']!r}",
    ]


def emit_ordinal(result):
    out = ["// GENERATED by scripts/itn/generate.py from scripts/itn/manifest.json. DO NOT EDIT.",
           "// Regenerate with scripts/itn/generate.py; scripts/itn/generate.py --check verifies it.",
           "//"]
    out += ["// " + line for line in ordinal_inventory_lines(result)]
    out += [
        "//",
        "// Reviewed refusal data only (#1677). It is not an ordinal grammar, and it carries no",
        "// context lexicon: the reviewed entries supply tokens and shapes, not complete phrases.",
        "",
        "enum GermanOrdinalData {",
        "  /// One reviewed refusal entry, exactly as the panel approved it.",
        "  struct Refusal: Equatable {",
        "    enum Kind: String, Equatable { case contextShape, literalPhrase }",
        "    let id: String",
        "    let version: Int",
        "    let contentSHA256: String",
        "    let reasonCode: String",
        "    let kind: Kind",
        "    /// The reviewed context shape; nil for a literal-phrase entry.",
        "    let contextShape: String?",
        "    /// Folded single words for a context shape; folded word sequences for a phrase entry.",
        "    let tokens: [String]",
        "    let reviewRef: String",
        "  }",
        "",
        f"  static let writtenSuffix = {swift_string(result['writtenSuffix'])}",
        "",
        "  static let refusals: [Refusal] = [",
    ]
    for r in result["rows"]:
        shape = "nil" if r["contextShape"] is None else swift_string(r["contextShape"])
        tokens = ", ".join(swift_string(t) for t in r["tokens"])
        out.append(
            f"    Refusal(id: {swift_string(r['id'])}, version: {r['version']}, "
            f"contentSHA256: {swift_string(r['contentSHA256'])}, "
            f"reasonCode: {swift_string(r['reasonCode'])}, kind: .{r['kind']}, "
            f"contextShape: {shape}, tokens: [{tokens}], "
            f"reviewRef: {swift_string(r['reviewRef'])}),")
    out += ["  ]", "}", ""]
    return "\n".join(out)


def build_clock(manifest, base):
    """The clock-idiom syntax data and the reviewed clock refusal entries (all literal phrases), or
    None when not declared. The syntax data (templates, anchors, marker, separator) is
    implementation admission data grounded in the approved scope; it is NOT a reviewed refusal and
    nothing is derived from corpus sentences."""
    loaded = refusal_inputs(manifest, base, "clockIdiom",
                            ("category", "refusalsFile", "schemaFile", "requiredEntries",
                             "templates", "anchors", "trailingMarker", "outputSeparator",
                             "syntaxProvenance"))
    if loaded is None:
        return None
    decl, chosen, shapes, pending_excluded = loaded
    templates, seen_ids = [], set()
    for template in decl["templates"]:
        where = f"clockIdiom:template:{template.get('id')}"
        tokens = [normalize_spoken(t) for t in template.get("tokens") or []]
        low_high = template.get("inputHours")
        offset, minute = template.get("hourOffset"), template.get("minute")
        if not template.get("id") or template["id"] in seen_ids:
            raise GenerationError(f"{where}: a template needs a unique id")
        seen_ids.add(template["id"])
        if not tokens or any(not t or re.search(r"\s", t) for t in tokens):
            raise GenerationError(f"{where}: tokens must be non-empty single words")
        if not (isinstance(low_high, list) and len(low_high) == 2
                and all(isinstance(v, int) for v in low_high) and 1 <= low_high[0] <= low_high[1] <= 12):
            raise GenerationError(f"{where}: inputHours must be two ints inside 1..12")
        if not isinstance(offset, int) or not isinstance(minute, int) or not 0 <= minute <= 59:
            raise GenerationError(f"{where}: hourOffset must be an int and minute 0..59")
        if not (1 <= low_high[0] + offset and low_high[1] + offset <= 12):
            raise GenerationError(f"{where}: the output hour would leave 1..12; the template "
                                  "must exclude the hours that need a clock-face choice")
        templates.append({"id": template["id"], "tokens": tokens, "hourOffset": offset,
                          "minute": minute, "low": low_high[0], "high": low_high[1]})
    anchors = [normalize_spoken(a) for a in decl["anchors"]]
    if len(set(anchors)) != len(anchors) or any(not a or re.search(r"\s", a) for a in anchors):
        raise GenerationError("clockIdiom: anchors must be distinct non-empty single words")
    marker = normalize_spoken(decl["trailingMarker"])
    if not marker or re.search(r"\s", marker):
        raise GenerationError("clockIdiom: trailingMarker must be one non-empty word")
    separator = decl["outputSeparator"]
    if len(separator) != 1 or separator.isalnum():
        raise GenerationError("clockIdiom: outputSeparator must be one punctuation character")
    refusal_hash = load_refusal_hash()
    rows, seen_phrases = [], set()
    for entry in sorted(chosen, key=lambda e: e["id"]):
        where, ref = check_reviewed(entry, "clockIdiom", refusal_hash)
        match = entry.get("match") or {}
        if match.get("kind") != "literal_phrase" or match.get("context_shape") is not None:
            raise GenerationError(f"{where}: clock refusals are literal phrases without a shape")
        phrases = [normalize_spoken(t) for t in match.get("tokens") or []]
        if not phrases or any(not re.fullmatch(r"\S+( \S+)*", t) for t in phrases):
            raise GenerationError(f"{where}: phrases must be non-empty words joined by single spaces")
        for phrase in phrases:
            if phrase in seen_phrases:
                raise GenerationError(f"{where}: phrase {phrase!r} appears twice")
            seen_phrases.add(phrase)
        rows.append({"id": entry["id"], "version": entry["version"],
                     "contentSHA256": entry["content_sha256"], "reasonCode": entry["reason_code"],
                     "phrases": phrases, "reviewRef": ref})
    return {
        "category": decl["category"], "templates": templates, "anchors": anchors,
        "trailingMarker": marker, "outputSeparator": separator,
        "syntaxProvenance": decl["syntaxProvenance"], "rows": rows,
        "pending_excluded": pending_excluded, "refusalsFile": decl["refusalsFile"],
    }


def clock_inventory_lines(result):
    return [
        "Source-to-output inventory (clock syntax data plus reviewed literal refusals, not a clock parser):",
        f"  source {result['refusalsFile']}: reviewed entries of category {result['category']}",
        f"  emitted: {len(result['rows'])} reviewed literal-phrase entries, each checked against its "
        "semantic hash and version; syntax data is separate and is NOT a reviewed refusal",
        f"  syntax data: {len(result['templates'])} templates, {len(result['anchors'])} anchors, "
        f"marker {result['trailingMarker']!r}, separator {result['outputSeparator']!r}",
        f"  excluded: {result['pending_excluded']} pending entries of this category, every other "
        "category",
    ]


def emit_clock(result):
    out = ["// GENERATED by scripts/itn/generate.py from scripts/itn/manifest.json. DO NOT EDIT.",
           "// Regenerate with scripts/itn/generate.py; scripts/itn/generate.py --check verifies it.",
           "//"]
    out += ["// " + line for line in clock_inventory_lines(result)]
    out += [
        "//",
        "// Implementation syntax data and reviewed refusal data only (#1677). The syntax data is not a",
        "// reviewed refusal and not a general German clock grammar; the refusals are complete literal",
        "// phrases. Nothing here is derived from corpus sentences.",
        "",
        "enum GermanClockIdiomData {",
        "  /// One idiom template: the spoken tokens before an hour word, the hour offset and the minutes",
        "  /// written, and the input hours it admits (the others need a clock-face choice).",
        "  struct Template: Equatable {",
        "    let id: String",
        "    let tokens: [String]",
        "    let hourOffset: Int",
        "    let minute: Int",
        "    let inputHourLow: Int",
        "    let inputHourHigh: Int",
        "  }",
        "",
        "  /// One reviewed refusal entry (a set of complete literal phrases), exactly as approved.",
        "  struct Refusal: Equatable {",
        "    let id: String",
        "    let version: Int",
        "    let contentSHA256: String",
        "    let reasonCode: String",
        "    let phrases: [String]",
        "    let reviewRef: String",
        "  }",
        "",
        f"  static let syntaxProvenance = {swift_string(result['syntaxProvenance'])}",
        f"  static let trailingMarker = {swift_string(result['trailingMarker'])}",
        f"  static let outputSeparator = {swift_string(result['outputSeparator'])}",
        "",
        "  static let anchors: [String] = [",
    ]
    out += [f"    {swift_string(a)}," for a in result["anchors"]]
    out += ["  ]", "", "  static let templates: [Template] = ["]
    for t in result["templates"]:
        tokens = ", ".join(swift_string(x) for x in t["tokens"])
        out.append(f"    Template(id: {swift_string(t['id'])}, tokens: [{tokens}], "
                   f"hourOffset: {t['hourOffset']}, minute: {t['minute']}, "
                   f"inputHourLow: {t['low']}, inputHourHigh: {t['high']}),")
    out += ["  ]", "", "  static let refusals: [Refusal] = ["]
    for r in result["rows"]:
        phrases = ", ".join(swift_string(x) for x in r["phrases"])
        out.append(
            f"    Refusal(id: {swift_string(r['id'])}, version: {r['version']}, "
            f"contentSHA256: {swift_string(r['contentSHA256'])}, "
            f"reasonCode: {swift_string(r['reasonCode'])}, phrases: [{phrases}], "
            f"reviewRef: {swift_string(r['reviewRef'])}),")
    out += ["  ]", "}", ""]
    return "\n".join(out)


def phone_inventory_lines(result):
    return [
        "Source-to-output inventory (reviewed refusal lowering only, not telephone grammar):",
        f"  source {result['refusalsFile']}: reviewed entries of category {result['category']}",
        f"  emitted: {len(result['rows'])} reviewed entries, each checked against its semantic "
        "hash, its version and the closed shape vocabulary",
        f"  excluded: {result['pending_excluded']} pending entries of this category, every "
        "other category",
        f"  trigger tokens: {', '.join(result['triggers'])}; replacement {result['replacement']!r}",
        "  unsigned-number word classes: " + ", ".join(
            f"{role} {len(result['unsigned'][role])}" for role in UNSIGNED_WORD_ROLES)
        + " (admission data, not reviewed refusals)",
    ]


def emit_phone(result):
    out = ["// GENERATED by scripts/itn/generate.py from scripts/itn/manifest.json. DO NOT EDIT.",
           "// Regenerate with scripts/itn/generate.py; scripts/itn/generate.py --check verifies it.",
           "//"]
    out += ["// " + line for line in phone_inventory_lines(result)]
    out += [
        "//",
        "// Reviewed refusal data plus the unsigned-number word classes (admission data, not reviewed",
        "// refusals) (#1677). It is not a telephone grammar and makes no claim that a German",
        "// sentence converts correctly.",
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
    out += ["  ]", ""]
    unsigned = result["unsigned"]
    out += ["  /// Word classes for numbers written without a sign (admission data, not reviewed",
            "  /// refusals). Provenance: " + unsigned["provenance"].replace("\n", " "),
            "  enum Unsigned {"]
    for role in UNSIGNED_WORD_ROLES:
        out.append(f"    static let {role}: [String] = [")
        out += [f"      {swift_string(w)}," for w in unsigned[role]]
        out.append("    ]")
    out += [f"    static let possessiveSuffix = {swift_string(unsigned['possessiveSuffix'])}",
            "  }", "", "  static let refusals: [Refusal] = ["]
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


def generate_ordinal_bytes(manifest_path):
    """The ordinal-refusal output, or None when the manifest declares none."""
    manifest_path = Path(manifest_path)
    manifest = load_manifest(manifest_path)
    result = build_ordinal(manifest, manifest_path.parent)
    return None if result is None else emit_ordinal(result).encode("utf-8")


def generate_clock_bytes(manifest_path):
    """The clock-idiom output, or None when the manifest declares none."""
    manifest_path = Path(manifest_path)
    manifest = load_manifest(manifest_path)
    result = build_clock(manifest, manifest_path.parent)
    return None if result is None else emit_clock(result).encode("utf-8")


def build_number_style(manifest):
    """The number-style word data (#1677 evolution): unit words written as a symbol after a
    number, postcode labels, street-name endings and the postcode length. Admission data for a
    shared pass, not a reviewed refusal. None when not declared."""
    decl = manifest.get("numberStyle")
    if decl is None:
        return None
    known = {"unitSymbols", "postcodeLabels", "streetSuffixes", "postcodeDigits", "provenance"}
    unknown = sorted(set(decl) - known)
    if unknown:
        raise GenerationError(f"numberStyle: unknown fields {unknown}")
    symbols = decl.get("unitSymbols")
    if not isinstance(symbols, dict) or not symbols:
        raise GenerationError("numberStyle: unitSymbols must be a non-empty object")
    pairs = []
    for word, symbol in sorted(symbols.items()):
        folded = normalize_spoken(word)
        if not folded or re.search(r"\s", folded) or folded != folded.lower():
            raise GenerationError(f"numberStyle: unit word {word!r} must be one lower-case word")
        if not isinstance(symbol, str) or not symbol or any(ch.isalnum() or ch.isspace() for ch in symbol):
            raise GenerationError(f"numberStyle: symbol for {word!r} must be non-empty punctuation")
        pairs.append((folded, symbol))
    lists = {}
    for role in ("postcodeLabels", "streetSuffixes"):
        words = decl.get(role)
        if not isinstance(words, list) or not words:
            raise GenerationError(f"numberStyle: {role} must be a non-empty list")
        folded = [normalize_spoken(w) for w in words]
        if any(not w or re.search(r"\s", w) or w != w.lower() for w in folded) or len(set(folded)) != len(folded):
            raise GenerationError(f"numberStyle: {role} needs distinct lower-case single words")
        lists[role] = folded
    digits = decl.get("postcodeDigits")
    if not isinstance(digits, int) or not 4 <= digits <= 6:
        raise GenerationError("numberStyle: postcodeDigits must be an int in 4...6")
    provenance = decl.get("provenance")
    if not isinstance(provenance, str) or not provenance.strip():
        raise GenerationError("numberStyle: provenance is empty")
    return {"unitSymbols": pairs, "postcodeDigits": digits, "provenance": provenance, **lists}


def emit_number_style(result):
    out = ["// GENERATED by scripts/itn/generate.py from scripts/itn/manifest.json. DO NOT EDIT.",
           "// Regenerate with scripts/itn/generate.py; scripts/itn/generate.py --check verifies it.",
           "//",
           f"// Number-style admission data (#1677): {len(result['unitSymbols'])} unit symbols, "
           f"{len(result['postcodeLabels'])} postcode labels, {len(result['streetSuffixes'])} street "
           f"endings, postcodes of {result['postcodeDigits']} digits. Not a reviewed refusal.",
           "// Provenance: " + result["provenance"].replace("\n", " "),
           "",
           "enum GermanNumberStyleData {",
           "  /// Unit word (folded) to the symbol written after a number.",
           "  static let unitSymbols: [(word: String, symbol: String)] = ["]
    out += [f"    ({swift_string(w)}, {swift_string(sym)})," for w, sym in result["unitSymbols"]]
    out += ["  ]", "", "  static let postcodeLabels: [String] = ["]
    out += [f"    {swift_string(w)}," for w in result["postcodeLabels"]]
    out += ["  ]", "", "  static let streetSuffixes: [String] = ["]
    out += [f"    {swift_string(w)}," for w in result["streetSuffixes"]]
    out += ["  ]", "", f"  static let postcodeDigits = {result['postcodeDigits']}", "}", ""]
    return "\n".join(out)


def build_phone_triggers(manifest):
    """The spoken plus words of languages whose phone pass runs the signed path only (#1677
    multilingual phase 1): admission data, not reviewed refusals. None when not declared."""
    decl = manifest.get("phoneTriggers")
    if decl is None:
        return None
    if not isinstance(decl, dict) or not decl:
        raise GenerationError("phoneTriggers: must be a non-empty object of language codes")
    out = []
    for code in sorted(decl):
        entry = decl[code]
        if not re.fullmatch(r"[a-z]{2}", code):
            raise GenerationError(f"phoneTriggers: {code!r} is not a two-letter language code")
        if code == "de":
            raise GenerationError("phoneTriggers: German owns its reviewed phonePrefix section")
        if not isinstance(entry, dict) or set(entry) - {"triggerTokens", "replacement", "provenance"}:
            raise GenerationError(f"phoneTriggers.{code}: fields are triggerTokens, replacement, provenance")
        tokens = entry.get("triggerTokens")
        if not isinstance(tokens, list) or not all(isinstance(w, str) for w in tokens):
            raise GenerationError(f"phoneTriggers.{code}: triggerTokens must be a list of words")
        words = [normalize_spoken(w) for w in tokens]
        if not words or any(not w or re.search(r"\s", w) or w != w.lower() for w in words) \
                or len(set(words)) != len(words):
            raise GenerationError(f"phoneTriggers.{code}: triggerTokens need distinct lower-case single words")
        if entry.get("replacement") != "+":
            raise GenerationError(f"phoneTriggers.{code}: replacement must be '+'")
        if not isinstance(entry.get("provenance"), str) or not entry["provenance"].strip():
            raise GenerationError(f"phoneTriggers.{code}: provenance is empty")
        out.append((code, words, entry["provenance"]))
    return out


def emit_phone_triggers(rows):
    out = ["// GENERATED by scripts/itn/generate.py from scripts/itn/manifest.json. DO NOT EDIT.",
           "// Regenerate with scripts/itn/generate.py; scripts/itn/generate.py --check verifies it.",
           "//",
           f"// Spoken plus words for {len(rows)} languages whose phone pass runs the signed path only",
           "// (#1677). Admission data, not reviewed refusals.",
           "",
           "enum PhoneTriggerData {",
           "  /// Language base code to its spoken plus words (folded).",
           "  static let triggerTokens: [String: [String]] = ["]
    for code, words, _ in rows:
        out.append(f"    {swift_string(code)}: [" + ", ".join(swift_string(w) for w in words) + "],")
    out += ["  ]", ""]
    for code, _, provenance in rows:
        out.append(f"  // {code}: " + provenance.replace("\n", " "))
    out += ["}", ""]
    return "\n".join(out)


def generate_triggers_bytes(manifest_path):
    rows = build_phone_triggers(load_manifest(Path(manifest_path)))
    return None if rows is None else emit_phone_triggers(rows).encode("utf-8")


HOUR_CLOCK_FIELDS = {
    "style", "hourAnchors", "gluedAnchors", "hours", "hourMarkers", "noon", "midnight",
    "noonAnchors", "connector", "fractions", "minus", "minusFractions", "before",
    "minuteFirstAnchors", "provenance",
}


def build_hour_first_clock(manifest):
    """Validates `hourFirstClock` (#1677): the hour-first clock idioms of the languages that are
    not German. Returns None when the manifest declares none. Never coerces a malformed value."""
    decl = manifest.get("hourFirstClock")
    if decl is None:
        return None
    if not isinstance(decl, dict) or not decl:
        raise GenerationError("hourFirstClock: must be a non-empty object of language codes")

    def word(value, where):
        if not isinstance(value, str):
            raise GenerationError(f"{where}: {value!r} is not a word")
        folded = normalize_spoken(value)
        if not folded or folded != value or re.search(r"\s", folded):
            raise GenerationError(f"{where}: {value!r} must be one lower-case NFC word")
        return folded

    def phrase(value, where):
        if not isinstance(value, str) or not value.strip():
            raise GenerationError(f"{where}: {value!r} is not a phrase")
        tokens = value.split(" ")
        return [word(t, where) for t in tokens]

    def phrases(value, where, allow_empty):
        if not isinstance(value, list) or (not value and not allow_empty):
            raise GenerationError(f"{where}: must be a {'' if allow_empty else 'non-empty '}list")
        out = [phrase(v, where) for v in value]
        if len({tuple(p) for p in out}) != len(out):
            raise GenerationError(f"{where}: duplicate phrase")
        return out

    def valued(value, where, allowed):
        if not isinstance(value, dict) or not value:
            raise GenerationError(f"{where}: must be a non-empty object")
        out = []
        for key, minutes in value.items():
            if minutes not in allowed or isinstance(minutes, bool):
                raise GenerationError(f"{where}.{key}: minutes must be one of {sorted(allowed)}")
            out.append((phrase(key, where), minutes))
        return out

    out = []
    for code in sorted(decl):
        entry = decl[code]
        where = f"hourFirstClock.{code}"
        if not re.fullmatch(r"[a-z]{2}", code):
            raise GenerationError(f"hourFirstClock: {code!r} is not a two-letter language code")
        if code == "de":
            raise GenerationError("hourFirstClock: German owns its reviewed clockIdiom section")
        if not isinstance(entry, dict) or set(entry) != HOUR_CLOCK_FIELDS:
            raise GenerationError(f"{where}: fields are {', '.join(sorted(HOUR_CLOCK_FIELDS))}")
        if entry["style"] not in ("h", "colon"):
            raise GenerationError(f"{where}.style: must be 'h' or 'colon'")
        hours = entry["hours"]
        if not isinstance(hours, dict) or sorted(hours.values()) != list(range(1, 13)) \
                or any(isinstance(v, bool) for v in hours.values()):
            raise GenerationError(f"{where}.hours: must spell each hour 1 to 12 exactly once")
        spelled = sorted((word(k, f"{where}.hours"), v) for k, v in hours.items())
        glued = entry["gluedAnchors"]
        if not isinstance(glued, list) or any(
                not isinstance(g, str) or not g.endswith("'") or len(g) < 2 for g in glued):
            raise GenerationError(f"{where}.gluedAnchors: each must end with an apostrophe")
        glued = [word(g, f"{where}.gluedAnchors") for g in glued]
        noon = [word(w, f"{where}.noon") for w in entry["noon"]] if isinstance(entry["noon"], list) \
            else None
        midnight = [word(w, f"{where}.midnight") for w in entry["midnight"]] \
            if isinstance(entry["midnight"], list) else None
        if noon is None or midnight is None:
            raise GenerationError(f"{where}: noon and midnight must be lists")
        noon_anchors = phrases(entry["noonAnchors"], f"{where}.noonAnchors", True)
        if bool(noon or midnight) != bool(noon_anchors):
            raise GenerationError(f"{where}: noonAnchors are required exactly when noon or midnight")
        markers = entry["hourMarkers"]
        if not isinstance(markers, list):
            raise GenerationError(f"{where}.hourMarkers: must be a list")
        markers = [word(w, f"{where}.hourMarkers") for w in markers]
        before = entry["before"]
        first_anchors = phrases(entry["minuteFirstAnchors"], f"{where}.minuteFirstAnchors", True)
        if before is None:
            if first_anchors:
                raise GenerationError(f"{where}: minuteFirstAnchors need a 'before' word")
            before_word, before_articles, article_before_time = None, [], False
        else:
            if not isinstance(before, dict) \
                    or set(before) != {"word", "articles", "articleBeforeTime"} or not first_anchors:
                raise GenerationError(f"{where}.before: needs word, articles, articleBeforeTime "
                                      "and minuteFirstAnchors")
            if not isinstance(before["articleBeforeTime"], bool):
                raise GenerationError(f"{where}.before.articleBeforeTime: must be true or false")
            before_word = word(before["word"], f"{where}.before.word")
            if not isinstance(before["articles"], list) or not before["articles"]:
                raise GenerationError(f"{where}.before.articles: must be a non-empty list")
            before_articles = [word(a, f"{where}.before.articles") for a in before["articles"]]
            article_before_time = before["articleBeforeTime"]
        if not isinstance(entry["provenance"], str) or not entry["provenance"].strip():
            raise GenerationError(f"{where}.provenance: is empty")
        out.append({
            "code": code,
            "style": entry["style"],
            "hourAnchors": phrases(entry["hourAnchors"], f"{where}.hourAnchors", False),
            "gluedAnchors": glued,
            "hours": spelled,
            "hourMarkers": markers,
            "noon": noon,
            "midnight": midnight,
            "noonAnchors": noon_anchors,
            "connector": word(entry["connector"], f"{where}.connector"),
            "fractions": valued(entry["fractions"], f"{where}.fractions", {15, 30, 45}),
            "minus": word(entry["minus"], f"{where}.minus"),
            "minusFractions": valued(entry["minusFractions"], f"{where}.minusFractions", {15}),
            "beforeWord": before_word,
            "beforeArticles": before_articles,
            "articleBeforeTime": article_before_time,
            "minuteFirstAnchors": first_anchors,
            "provenance": entry["provenance"],
        })
    return out


def emit_hour_first_clock(rows):
    def tokens(p):
        return "[" + ", ".join(swift_string(t) for t in p) + "]"

    def tokens_list(ps):
        return "[" + ", ".join(tokens(p) for p in ps) + "]"

    def strings(ws):
        return "[" + ", ".join(swift_string(w) for w in ws) + "]"

    def valued(vs):
        return "[" + ", ".join(f"({tokens(p)}, {m})" for p, m in vs) + "]"

    out = ["// GENERATED by scripts/itn/generate.py from scripts/itn/manifest.json. DO NOT EDIT.",
           "// Regenerate with scripts/itn/generate.py; scripts/itn/generate.py --check verifies it.",
           "//",
           f"// Hour-first clock idioms for {len(rows)} languages (#1677). Admission data, not reviewed",
           "// refusals. Words are folded (lower case, NFC); a phrase is its words in order.",
           "",
           "enum HourFirstClockData {",
           "  struct Language: Sendable {",
           "    let style: String",
           "    let hourAnchors: [[String]]",
           "    let gluedAnchors: [String]",
           "    let hours: [(word: String, value: Int)]",
           "    let hourMarkers: [String]",
           "    let noon: [String]",
           "    let midnight: [String]",
           "    let noonAnchors: [[String]]",
           "    let connector: String",
           "    let fractions: [(words: [String], minutes: Int)]",
           "    let minus: String",
           "    let minusFractions: [(words: [String], minutes: Int)]",
           "    let beforeWord: String?",
           "    let beforeArticles: [String]",
           "    /// The minute-first form writes the article before the time (`a las 7:45`).",
           "    let articleBeforeTime: Bool",
           "    let minuteFirstAnchors: [[String]]",
           "  }",
           "",
           "  static let languages: [String: Language] = ["]
    for r in rows:
        before = "nil" if r["beforeWord"] is None else swift_string(r["beforeWord"])
        out += [
            f"    {swift_string(r['code'])}: Language(",
            f"      style: {swift_string(r['style'])},",
            f"      hourAnchors: {tokens_list(r['hourAnchors'])},",
            f"      gluedAnchors: {strings(r['gluedAnchors'])},",
            "      hours: [" + ", ".join(f"({swift_string(w)}, {v})" for w, v in r["hours"]) + "],",
            f"      hourMarkers: {strings(r['hourMarkers'])},",
            f"      noon: {strings(r['noon'])},",
            f"      midnight: {strings(r['midnight'])},",
            f"      noonAnchors: {tokens_list(r['noonAnchors'])},",
            f"      connector: {swift_string(r['connector'])},",
            f"      fractions: {valued(r['fractions'])},",
            f"      minus: {swift_string(r['minus'])},",
            f"      minusFractions: {valued(r['minusFractions'])},",
            f"      beforeWord: {before},",
            f"      beforeArticles: {strings(r['beforeArticles'])},",
            f"      articleBeforeTime: {'true' if r['articleBeforeTime'] else 'false'},",
            f"      minuteFirstAnchors: {tokens_list(r['minuteFirstAnchors'])}),",
        ]
    out += ["  ]", ""]
    for r in rows:
        out.append(f"  // {r['code']}: " + r["provenance"].replace("\n", " "))
    out += ["}", ""]
    return "\n".join(out)


def generate_hour_clock_bytes(manifest_path):
    rows = build_hour_first_clock(load_manifest(Path(manifest_path)))
    return None if rows is None else emit_hour_first_clock(rows).encode("utf-8")


def generate_style_bytes(manifest_path):
    """The number-style output, or None when the manifest declares none."""
    manifest = load_manifest(Path(manifest_path))
    result = build_number_style(manifest)
    return None if result is None else emit_number_style(result).encode("utf-8")


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


def run_check(manifest_path, out_path, phone_out_path, ordinal_out_path, clock_out_path,
              style_out_path=DEFAULT_STYLE_OUT, triggers_out_path=DEFAULT_TRIGGERS_OUT,
              hour_clock_out_path=DEFAULT_HOUR_CLOCK_OUT):
    """Verifies EVERY declared generated file without rewriting any of them."""
    with tempfile.TemporaryDirectory(prefix="itn-check-") as tmp:
        pairs = [(generate_bytes(manifest_path), out_path)]
        phone = generate_phone_bytes(manifest_path)
        if phone is not None:
            pairs.append((phone, phone_out_path))
        ordinal = generate_ordinal_bytes(manifest_path)
        if ordinal is not None:
            pairs.append((ordinal, ordinal_out_path))
        clock = generate_clock_bytes(manifest_path)
        if clock is not None:
            pairs.append((clock, clock_out_path))
        style = generate_style_bytes(manifest_path)
        if style is not None:
            pairs.append((style, style_out_path))
        triggers = generate_triggers_bytes(manifest_path)
        if triggers is not None:
            pairs.append((triggers, triggers_out_path))
        hour_clock = generate_hour_clock_bytes(manifest_path)
        if hour_clock is not None:
            pairs.append((hour_clock, hour_clock_out_path))
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
    parser.add_argument("--ordinal-out", default=str(DEFAULT_ORDINAL_OUT))
    parser.add_argument("--clock-out", default=str(DEFAULT_CLOCK_OUT))
    parser.add_argument("--style-out", default=str(DEFAULT_STYLE_OUT))
    parser.add_argument("--triggers-out", default=str(DEFAULT_TRIGGERS_OUT))
    parser.add_argument("--hour-clock-out", default=str(DEFAULT_HOUR_CLOCK_OUT))
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
            run_check(args.manifest, args.out, args.phone_out, args.ordinal_out, args.clock_out,
                      args.style_out, args.triggers_out, args.hour_clock_out)
        elif args.inventory:
            manifest = load_manifest(args.manifest)
            print("\n".join(inventory_lines(build(manifest, Path(args.manifest).parent))))
            phone = build_phone(manifest, Path(args.manifest).parent)
            if phone is not None:
                print("\n".join(phone_inventory_lines(phone)))
            ordinal = build_ordinal(manifest, Path(args.manifest).parent)
            if ordinal is not None:
                print("\n".join(ordinal_inventory_lines(ordinal)))
            clock = build_clock(manifest, Path(args.manifest).parent)
            if clock is not None:
                print("\n".join(clock_inventory_lines(clock)))
        else:
            # Build and validate EVERY output before publishing any, so a failure writes nothing.
            data = generate_bytes(args.manifest)
            phone = generate_phone_bytes(args.manifest)
            ordinal = generate_ordinal_bytes(args.manifest)
            clock = generate_clock_bytes(args.manifest)
            style = generate_style_bytes(args.manifest)
            triggers = generate_triggers_bytes(args.manifest)
            hour_clock = generate_hour_clock_bytes(args.manifest)
            write_atomically(args.out, data)
            print(f"wrote {args.out} ({len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()})")
            if phone is not None:
                write_atomically(args.phone_out, phone)
                print(f"wrote {args.phone_out} ({len(phone)} bytes, sha256 "
                      f"{hashlib.sha256(phone).hexdigest()})")
            if ordinal is not None:
                write_atomically(args.ordinal_out, ordinal)
                print(f"wrote {args.ordinal_out} ({len(ordinal)} bytes, sha256 "
                      f"{hashlib.sha256(ordinal).hexdigest()})")
            if clock is not None:
                write_atomically(args.clock_out, clock)
                print(f"wrote {args.clock_out} ({len(clock)} bytes, sha256 "
                      f"{hashlib.sha256(clock).hexdigest()})")
            if triggers is not None:
                write_atomically(args.triggers_out, triggers)
                print(f"wrote {args.triggers_out} ({len(triggers)} bytes, sha256 "
                      f"{hashlib.sha256(triggers).hexdigest()})")
            if hour_clock is not None:
                write_atomically(args.hour_clock_out, hour_clock)
                print(f"wrote {args.hour_clock_out} ({len(hour_clock)} bytes, sha256 "
                      f"{hashlib.sha256(hour_clock).hexdigest()})")
            if style is not None:
                write_atomically(args.style_out, style)
                print(f"wrote {args.style_out} ({len(style)} bytes, sha256 "
                      f"{hashlib.sha256(style).hexdigest()})")
    except GenerationError as exc:
        print(f"generate.py: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
