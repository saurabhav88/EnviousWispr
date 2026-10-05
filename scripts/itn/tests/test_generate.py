"""Contract tests for scripts/itn/generate.py (#1677, PR 2 chunk 1).

They drive the REAL command line against small synthetic fixture inputs with independent literal
expectations, and against the committed German sources. Fixtures prove the generator's behaviour
(hashes, malformed rows, conflicts, escaping, determinism); they say nothing about whether any
German sentence converts correctly.
"""

import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
GENERATOR = HERE.parent / "generate.py"
REAL_MANIFEST = HERE.parent / "manifest.json"
REAL_OUTPUT = (HERE.parent.parent.parent
               / "Sources/EnviousWisprPostProcessing/Generated/GermanNumberData.swift")
REAL_PHONE_OUTPUT = (HERE.parent.parent.parent
                     / "Sources/EnviousWisprPostProcessing/Generated/GermanPhonePrefixData.swift")
REAL_ORDINAL_OUTPUT = (HERE.parent.parent.parent
                       / "Sources/EnviousWisprPostProcessing/Generated/GermanOrdinalData.swift")

COMMIT = "0123456789abcdef0123456789abcdef01234567"

NEMO_FILES = {
    "zero": "null\t0",
    "digit": "zwei\t2",
    "ones": "eins\t1\t-0.0001",
    "teen": "zehn\t10",
    "ties": "zwanzig\t2",
    "quantities": "million\nmillionen",
}

CLDR_RULES = """%spellout-numbering:
-x: minus >>;
0: null;
1: eins;
2: zwei;
10: zehn;
20: [>%spellout-numbering>­und­]zwanzig;
1000000: eine Million[ >>];
2000000: <%spellout-numbering< Millionen[ >>];
"""


ORDINAL_RULES = """%spellout-ordinal:
-x: minus >>;
x.x: =#,##0.#=;
0: nullte;
1: erste;
2: zweite;
3: dritte;
9: =%spellout-numbering=te;
20: =%spellout-numbering=ste;
100: <%spellout-numbering<­hundert>>;
%spellout-ordinal-n:
-x: minus >>;
x.x: =#,##0.#=;
0: =%spellout-ordinal=n;
"""

ORDINAL_DECLARATION = {"base": "%spellout-ordinal", "irregularBelow": 4,
                       "inflectionRulesets": ["%spellout-ordinal-n"], "excludedRulesets": []}


def cldr_xml(rules):
    return ("<?xml version='1.0' encoding='UTF-8' ?>\n<ldml><rbnf>"
            "<rulesetGrouping type='SpelloutRules'><rbnfRules><![CDATA[\n"
            + rules + "]]></rbnfRules></rulesetGrouping></rbnf></ldml>\n")


def run(*args):
    return subprocess.run([sys.executable, str(GENERATOR), *args],
                          capture_output=True, text=True)


class Fixture:
    """A throwaway manifest plus pinned source files; every mutation re-hashes honestly unless
    a test deliberately corrupts a hash."""

    def __init__(self, test, nemo=None, cldr=None, extra_nemo=None, ordinal=None):
        self.dir = Path(tempfile.mkdtemp(prefix="itn-fixture-"))
        test.addCleanup(shutil.rmtree, self.dir, True)
        (self.dir / "sources").mkdir()
        nemo = dict(NEMO_FILES, **(nemo or {}))
        self.sources = []
        self.write("sources/LICENSE", "Apache License fixture\n")
        for kind, body in nemo.items():
            self.write(f"sources/{kind}.tsv", body)
            self.sources.append(self.entry(f"nemo-{kind}", "nemo-tsv", f"sources/{kind}.tsv",
                                           nemoKind=kind))
        for kind, body in (extra_nemo or {}).items():
            self.write(f"sources/{kind}.tsv", body)
            self.sources.append(self.entry(f"nemo-{kind}", "nemo-tsv", f"sources/{kind}.tsv",
                                           nemoKind=kind.split("-")[0]))
        base_rules = cldr if cldr is not None else CLDR_RULES
        if ordinal is not None:
            base_rules += ordinal[0]
        self.write("sources/de.xml", cldr_xml(base_rules))
        extra = {"ordinal": ordinal[1]} if ordinal is not None and ordinal[1] is not None else {}
        self.sources.append(self.entry("cldr-de", "cldr-rbnf", "sources/de.xml",
                                       rulesets=["%spellout-numbering"], **extra))
        self.out = self.dir / "out" / "GermanNumberData.swift"

    def write(self, rel, text):
        (self.dir / rel).write_text(text, encoding="utf-8")

    def entry(self, source_id, kind, rel, **extra):
        data = (self.dir / rel).read_bytes()
        entry = {"id": source_id, "kind": kind, "repo": "fixture/repo", "tag": "t1",
                 "commit": COMMIT, "path": rel, "url": f"https://example.invalid/{COMMIT}/{rel}",
                 "file": rel, "sha256": hashlib.sha256(data).hexdigest(),
                 "license": "Apache-2.0", "licenseFile": "sources/LICENSE",
                 "licenseSha256": hashlib.sha256((self.dir / "sources/LICENSE").read_bytes())
                 .hexdigest(),
                 "licenseUrl": f"https://example.invalid/{COMMIT}/LICENSE"}
        entry.update(extra)
        return entry

    def manifest(self, **overrides):
        data = {"schema": 1, "sources": self.sources}
        data.update(overrides)
        path = self.dir / "manifest.json"
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        return path

    def generate(self, *extra):
        return run("--manifest", str(self.manifest()), "--out", str(self.out), *extra)


class RealSourcesTests(unittest.TestCase):
    def test_committed_output_matches_a_fresh_regeneration(self):
        result = run("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("check ok", result.stdout)

    def test_two_generations_from_the_pinned_sources_are_byte_identical(self):
        with tempfile.TemporaryDirectory() as tmp:
            first, second = Path(tmp) / "a.swift", Path(tmp) / "b.swift"
            self.assertEqual(run("--out", str(first)).returncode, 0)
            self.assertEqual(run("--out", str(second)).returncode, 0)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(first.read_bytes(), REAL_OUTPUT.read_bytes())

    def test_output_carries_no_timestamp_or_checkout_path(self):
        text = REAL_OUTPUT.read_text(encoding="utf-8")
        self.assertNotIn("/Users/", text)
        self.assertNotIn(str(HERE.parent.parent.parent), text)
        self.assertIsNone(re.search(r"\b20\d\d-\d\d-\d\d\b", text))
        self.assertNotIn("­", text, "soft hyphens must not reach the generated literals")

    def test_every_manifest_source_is_pinned_to_a_commit_with_a_licence(self):
        manifest = json.loads(REAL_MANIFEST.read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(manifest["sources"]), 7)
        for source in manifest["sources"]:
            self.assertRegex(source["commit"], r"^[0-9a-f]{40}$", source["id"])
            self.assertIn(source["commit"], source["url"], source["id"])
            self.assertNotRegex(source["url"], r"/(main|master|latest)/", source["id"])
            self.assertIn(source["license"], ("Apache-2.0", "Unicode-3.0"))

    def test_real_inventory_accounts_for_every_cldr_rule(self):
        result = run("--inventory")
        self.assertEqual(result.returncode, 0, result.stderr)
        match = re.search(r"CLDR rules parsed: (\d+) = (\d+) atoms \+ (\d+) instructions",
                          result.stdout)
        self.assertIsNotNone(match)
        parsed, atoms, rules = map(int, match.groups())
        self.assertGreater(parsed, 0)
        self.assertEqual(parsed, atoms + rules)


PHONE_SHAPES = ["plus_between_operands", "plus_joining_nouns", "plus_before_temperature_or_percent",
                "plus_not_followed_by_digit", "ordinal_adverb"]
PHONE_IDS = ["ref-phone-001", "ref-phone-002", "ref-phone-003", "ref-phone-004"]


def phone_stamp(entry):
    """An independent oracle for the reviewed-field hash: the same recipe written out here."""
    keys = ["category", "reason_code", "match", "required_context", "region_limit", "evidence_ids"]
    text = json.dumps({k: entry[k] for k in keys}, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def phone_entry(entry_id, shape, version=1, tokens=("plus",), category="phone_country_prefix", **over):
    entry = {"id": entry_id, "category": category, "reason_code": "reason_" + shape,
             "match": {"kind": "context_shape", "tokens": list(tokens), "context_shape": shape},
             "required_context": "none", "region_limit": "fixture limit",
             "evidence_ids": ["E-FIXTURE"], "supporting_row_ids": ["de-phone-ctl-001"],
             "panel_status": "panel-reviewed", "review_ref": f"refusal-ledger:{entry_id}:v{version}",
             "version": version}
    entry.update(over)
    entry["content_sha256"] = over.get("content_sha256") or phone_stamp(entry)
    return entry


def default_phone_entries():
    return [phone_entry(PHONE_IDS[0], PHONE_SHAPES[0], version=2),
            phone_entry(PHONE_IDS[1], PHONE_SHAPES[1]),
            phone_entry(PHONE_IDS[2], PHONE_SHAPES[2], version=2),
            phone_entry(PHONE_IDS[3], PHONE_SHAPES[3])]


class PhoneFixture(Fixture):
    """A Fixture that also declares the phone-prefix lowering over a throwaway refusal file."""

    def __init__(self, test, entries=None, pending=None, other=None, declaration=None, raw=None):
        super().__init__(test)
        (self.dir / "refusals").mkdir()
        data = {"schema_version": 1, "language": "de",
                "reviewed_entries": (entries if entries is not None else default_phone_entries())
                + (other or []),
                "pending_entries": pending or []}
        self.write("refusals/de.json", raw if raw is not None else json.dumps(data, ensure_ascii=False))
        self.write("review-data.schema.json", json.dumps(
            {"x-closed-vocabulary": {"context_shape": PHONE_SHAPES}}))
        self.declaration = {"category": "phone_country_prefix", "refusalsFile": "refusals/de.json",
                            "schemaFile": "review-data.schema.json", "requiredEntries": PHONE_IDS,
                            "replacement": "+"}
        self.declaration.update(declaration or {})
        self.phone_out = self.dir / "out" / "GermanPhonePrefixData.swift"

    def generate(self, *extra):
        manifest = self.manifest(phonePrefix=self.declaration)
        return run("--manifest", str(manifest), "--out", str(self.out), "--phone-out",
                   str(self.phone_out), *extra)


class RealPhoneTests(unittest.TestCase):
    def test_real_phone_output_carries_the_four_reviewed_entries_exactly(self):
        text = REAL_PHONE_OUTPUT.read_text(encoding="utf-8")
        refusals = text.split("static let refusals")[1]
        self.assertEqual(refusals.count("    Refusal(id:"), 4)
        for expected in (
            'id: "ref-phone-001", version: 2,', 'contextShape: "plus_between_operands"',
            'id: "ref-phone-002", version: 1,', 'contextShape: "plus_joining_nouns"',
            'id: "ref-phone-003", version: 2,', 'contextShape: "plus_before_temperature_or_percent"',
            'id: "ref-phone-004", version: 1,', 'contextShape: "plus_not_followed_by_digit"',
            'reviewRef: "refusal-ledger:ref-phone-003:v2"',
        ):
            self.assertIn(expected, refusals)
        self.assertIn('static let replacement = "+"', text)
        self.assertIn('    "plus",', text)
        for other in ("ref-clock", "ref-ordinal"):
            self.assertNotIn(other, text)

    def test_two_generations_write_both_files_byte_identically(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = [Path(tmp) / "a.swift", Path(tmp) / "pa.swift"]
            second = [Path(tmp) / "b.swift", Path(tmp) / "pb.swift"]
            for out, phone in (first, second):
                self.assertEqual(run("--out", str(out), "--phone-out", str(phone)).returncode, 0)
            self.assertEqual(first[0].read_bytes(), second[0].read_bytes())
            self.assertEqual(first[1].read_bytes(), second[1].read_bytes())
            self.assertEqual(first[1].read_bytes(), REAL_PHONE_OUTPUT.read_bytes())

    def test_phone_output_carries_no_timestamp_or_checkout_path(self):
        text = REAL_PHONE_OUTPUT.read_text(encoding="utf-8")
        self.assertNotIn("/Users/", text)
        self.assertIsNone(re.search(r"\b20\d\d-\d\d-\d\d\b", text))

    def test_the_real_inventory_names_the_phone_lowering(self):
        result = run("--inventory")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("emitted: 4 reviewed entries", result.stdout)

    def test_the_manifest_declares_the_four_required_entries(self):
        manifest = json.loads(REAL_MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual(manifest["phonePrefix"]["requiredEntries"], PHONE_IDS)
        self.assertEqual(manifest["phonePrefix"]["replacement"], "+")


class PhoneFixtureTests(unittest.TestCase):
    def test_canonical_entries_produce_the_independent_literal_output(self):
        fixture = PhoneFixture(self)
        result = fixture.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = fixture.phone_out.read_text(encoding="utf-8")
        expected = default_phone_entries()
        for entry in expected:
            line = (f'    Refusal(id: "{entry["id"]}", version: {entry["version"]}, '
                    f'contentSHA256: "{entry["content_sha256"]}", '
                    f'reasonCode: "{entry["reason_code"]}", '
                    f'contextShape: "{entry["match"]["context_shape"]}", '
                    f'reviewRef: "{entry["review_ref"]}"),')
            self.assertIn(line, text)
        self.assertIn('static let replacement = "+"', text)
        self.assertIn("emitted: 4 reviewed entries", text)

    def test_pending_entries_and_other_categories_are_never_emitted(self):
        pending = [phone_entry("ref-phone-009", "ordinal_adverb", panel_status="pending",
                               review_ref=None)]
        other = [phone_entry("ref-ordinal-001", "ordinal_adverb", category="ordinal")]
        fixture = PhoneFixture(self, pending=pending, other=other)
        self.assertEqual(fixture.generate().returncode, 0)
        text = fixture.phone_out.read_text(encoding="utf-8")
        self.assertNotIn("ref-phone-009", text)
        self.assertNotIn("ref-ordinal-001", text)
        self.assertIn("excluded: 1 pending entries of this category", text)

    def test_a_declaration_makes_no_difference_to_the_number_data_output(self):
        plain = Fixture(self)
        plain.generate()
        with_phone = PhoneFixture(self)
        with_phone.generate()
        self.assertEqual(plain.out.read_bytes(), with_phone.out.read_bytes())

    def test_two_generations_with_phone_output_are_identical(self):
        fixture = PhoneFixture(self)
        fixture.generate()
        first = (fixture.out.read_bytes(), fixture.phone_out.read_bytes())
        fixture.generate()
        self.assertEqual((fixture.out.read_bytes(), fixture.phone_out.read_bytes()), first)

    def test_check_verifies_both_files_and_never_rewrites_either(self):
        fixture = PhoneFixture(self)
        fixture.generate()
        before = [(f.stat().st_mtime_ns, f.read_bytes()) for f in (fixture.out, fixture.phone_out)]
        result = fixture.generate("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("check ok"), 2)
        self.assertEqual(before, [(f.stat().st_mtime_ns, f.read_bytes())
                                  for f in (fixture.out, fixture.phone_out)])

    def test_check_fails_on_drift_in_the_phone_file_alone(self):
        fixture = PhoneFixture(self)
        fixture.generate()
        fixture.phone_out.write_text(
            fixture.phone_out.read_text(encoding="utf-8") + "// drift\n", encoding="utf-8")
        drifted = fixture.phone_out.read_bytes()
        number = fixture.out.read_bytes()
        result = fixture.generate("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GermanPhonePrefixData.swift", result.stderr)
        self.assertIn("differs", result.stderr)
        self.assertEqual((fixture.phone_out.read_bytes(), fixture.out.read_bytes()), (drifted, number))

    def test_check_fails_when_the_phone_file_is_missing(self):
        fixture = PhoneFixture(self)
        fixture.generate()
        fixture.phone_out.unlink()
        result = fixture.generate("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr)


class PhoneFailureTests(unittest.TestCase):
    def assert_fails_and_writes_nothing(self, fixture, needle):
        result = fixture.generate()
        self.assertNotEqual(result.returncode, 0, "must fail nonzero")
        self.assertIn(needle, result.stderr)
        self.assertFalse(fixture.out.exists(), "a failed run must not create the number output")
        self.assertFalse(fixture.phone_out.exists(), "a failed run must not create the phone output")

    def entries_with(self, index, **over):
        entries = default_phone_entries()
        base = entries[index]
        entries[index] = phone_entry(base["id"], base["match"]["context_shape"],
                                     version=base["version"], **over)
        return entries

    def test_a_changed_reviewed_field_with_the_old_hash_fails(self):
        entries = default_phone_entries()
        entries[0]["region_limit"] = "changed after review"
        self.assert_fails_and_writes_nothing(PhoneFixture(self, entries=entries), "content_sha256")

    def test_a_review_ref_that_names_another_version_fails(self):
        entries = self.entries_with(0, review_ref="refusal-ledger:ref-phone-001:v1")
        self.assert_fails_and_writes_nothing(PhoneFixture(self, entries=entries), "review_ref")

    def test_an_entry_that_is_not_reviewed_fails(self):
        entries = self.entries_with(1, panel_status="pending")
        self.assert_fails_and_writes_nothing(PhoneFixture(self, entries=entries), "not reviewed")

    def test_a_shape_outside_the_closed_vocabulary_fails(self):
        entries = default_phone_entries()
        entries[3] = phone_entry("ref-phone-004", "plus_anything_goes")
        self.assert_fails_and_writes_nothing(PhoneFixture(self, entries=entries), "unsupported shape")

    def test_a_literal_phrase_entry_fails(self):
        entries = self.entries_with(
            2, match={"kind": "literal_phrase", "tokens": ["plus"], "context_shape": None})
        self.assert_fails_and_writes_nothing(PhoneFixture(self, entries=entries), "unsupported shape")

    def test_a_missing_required_entry_fails(self):
        self.assert_fails_and_writes_nothing(
            PhoneFixture(self, entries=default_phone_entries()[:3]), "required set")

    def test_an_extra_reviewed_entry_of_the_category_fails(self):
        entries = default_phone_entries() + [phone_entry("ref-phone-005", "ordinal_adverb")]
        self.assert_fails_and_writes_nothing(PhoneFixture(self, entries=entries), "required set")

    def test_trigger_tokens_that_disagree_fail(self):
        entries = default_phone_entries()
        entries[1] = phone_entry("ref-phone-002", "plus_joining_nouns", tokens=("plus", "und"))
        self.assert_fails_and_writes_nothing(PhoneFixture(self, entries=entries), "differ")

    def test_an_empty_or_multi_word_trigger_fails(self):
        for tokens in ((), ("",), ("plus und",)):
            with self.subTest(tokens=tokens):
                entries = [phone_entry(i, s, tokens=tokens) for i, s in zip(PHONE_IDS, PHONE_SHAPES)]
                self.assert_fails_and_writes_nothing(
                    PhoneFixture(self, entries=entries), "single words")

    def test_two_entries_with_one_shape_fail(self):
        entries = [phone_entry(i, PHONE_SHAPES[0]) for i in PHONE_IDS]
        self.assert_fails_and_writes_nothing(PhoneFixture(self, entries=entries), "share one context shape")

    def test_malformed_refusal_json_fails(self):
        self.assert_fails_and_writes_nothing(PhoneFixture(self, raw="{not json"), "cannot read")

    def test_a_missing_refusal_file_fails(self):
        fixture = PhoneFixture(self, declaration={"refusalsFile": "refusals/nope.json"})
        self.assert_fails_and_writes_nothing(fixture, "cannot read")

    def test_a_declaration_without_a_required_key_fails(self):
        fixture = PhoneFixture(self, declaration={"replacement": ""})
        self.assert_fails_and_writes_nothing(fixture, "replacement is empty")


ORDINAL_IDS = ["ref-ordinal-001", "ref-ordinal-002", "ref-ordinal-003"]
ORDINAL_SHAPES = ["ordinal_adverb", "ordinal_word_in_date_phrase", "ordinal_word_without_following_noun"]


def ordinal_entry(entry_id, version=1, kind="context_shape", shape="ordinal_adverb",
                  tokens=("erstens", "zweitens"), category="ordinal", **over):
    entry = {"id": entry_id, "category": category, "reason_code": "reason_" + entry_id[-3:],
             "match": {"kind": kind, "tokens": list(tokens),
                       "context_shape": shape if kind == "context_shape" else None},
             "required_context": "none", "region_limit": "fixture limit",
             "evidence_ids": ["E-FIXTURE"], "supporting_row_ids": ["de-ordinal-ctl-001"],
             "panel_status": "panel-reviewed", "review_ref": f"refusal-ledger:{entry_id}:v{version}",
             "version": version}
    entry.update(over)
    entry["content_sha256"] = over.get("content_sha256") or phone_stamp(entry)
    return entry


def default_ordinal_entries():
    return [
        ordinal_entry("ref-ordinal-001", shape="ordinal_adverb", tokens=("Erstens", "zweitens")),
        ordinal_entry("ref-ordinal-002", version=2, kind="literal_phrase", tokens=("Ein Drittel", "ein viertel")),
        ordinal_entry("ref-ordinal-003", shape="ordinal_word_without_following_noun",
                      tokens=("erste", "zweite")),
    ]


class OrdinalRefusalFixture(Fixture):
    """A Fixture that declares the ordinal-refusal lowering over a throwaway refusal file."""

    def __init__(self, test, entries=None, pending=None, other=None, declaration=None, phone=False):
        super().__init__(test)
        (self.dir / "refusals").mkdir()
        data = {"schema_version": 1, "language": "de",
                "reviewed_entries": (entries if entries is not None else default_ordinal_entries())
                + (other or []) + (default_phone_entries() if phone else []),
                "pending_entries": pending or []}
        self.write("refusals/de.json", json.dumps(data, ensure_ascii=False))
        self.write("review-data.schema.json", json.dumps(
            {"x-closed-vocabulary": {"context_shape": PHONE_SHAPES + ORDINAL_SHAPES
                                     + ["ordinal_word_before_fraction_noun"]}}))
        self.declaration = {"category": "ordinal", "refusalsFile": "refusals/de.json",
                            "schemaFile": "review-data.schema.json", "requiredEntries": ORDINAL_IDS,
                            "allowedShapes": ORDINAL_SHAPES + ["ordinal_word_before_fraction_noun"],
                            "writtenSuffix": "."}
        self.declaration.update(declaration or {})
        self.phone = phone
        self.phone_out = self.dir / "out" / "GermanPhonePrefixData.swift"
        self.ordinal_out = self.dir / "out" / "GermanOrdinalData.swift"

    def generate(self, *extra):
        overrides = {"ordinalRefusals": self.declaration}
        if self.phone:
            overrides["phonePrefix"] = {"category": "phone_country_prefix",
                                        "refusalsFile": "refusals/de.json",
                                        "schemaFile": "review-data.schema.json",
                                        "requiredEntries": PHONE_IDS, "replacement": "+"}
        manifest = self.manifest(**overrides)
        return run("--manifest", str(manifest), "--out", str(self.out), "--phone-out",
                   str(self.phone_out), "--ordinal-out", str(self.ordinal_out), *extra)


class RealOrdinalRefusalTests(unittest.TestCase):
    def test_real_output_carries_the_six_reviewed_entries_with_distinct_kinds(self):
        text = REAL_ORDINAL_OUTPUT.read_text(encoding="utf-8")
        rows = text.split("static let refusals")[1]
        self.assertEqual(rows.count("    Refusal(id:"), 6)
        self.assertEqual(rows.count("kind: .contextShape"), 5)
        self.assertEqual(rows.count("kind: .literalPhrase"), 1)
        for expected in (
            'id: "ref-ordinal-004", version: 2,',
            'tokens: ["ein drittel", "ein viertel", "ein fünftel", "ein zehntel", "ein achtel"]',
            'contextShape: "ordinal_word_in_date_phrase"',
            'contextShape: "ordinal_word_in_proper_name"',
            'contextShape: "ordinal_word_in_fixed_phrase"',
            'contextShape: "ordinal_word_without_following_noun"',
            'contextShape: "ordinal_adverb"',
            'reviewRef: "refusal-ledger:ref-ordinal-006:v2"',
        ):
            self.assertIn(expected, rows)
        self.assertIn('static let writtenSuffix = "."', text)
        # The vocabulary shape without a reviewed entry is never manufactured.
        self.assertNotIn("ordinal_word_before_fraction_noun", rows)
        for other in ("ref-clock", "ref-phone"):
            self.assertNotIn(other, text)

    def test_three_outputs_are_reproducible_and_leave_the_others_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            outs = [[Path(tmp) / f"{name}{i}.swift" for name in ("n", "p", "o")] for i in (1, 2)]
            for number, phone, ordinal in outs:
                self.assertEqual(run("--out", str(number), "--phone-out", str(phone),
                                     "--ordinal-out", str(ordinal)).returncode, 0)
            for a, b in zip(*outs):
                self.assertEqual(a.read_bytes(), b.read_bytes())
            self.assertEqual(outs[0][0].read_bytes(), REAL_OUTPUT.read_bytes())
            self.assertEqual(outs[0][1].read_bytes(), REAL_PHONE_OUTPUT.read_bytes())
            self.assertEqual(outs[0][2].read_bytes(), REAL_ORDINAL_OUTPUT.read_bytes())

    def test_the_real_check_verifies_all_three_files(self):
        result = run("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("check ok"), 3)

    def test_the_manifest_declares_the_six_required_entries(self):
        manifest = json.loads(REAL_MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual(
            manifest["ordinalRefusals"]["requiredEntries"],
            ["ref-ordinal-001", "ref-ordinal-002", "ref-ordinal-003", "ref-ordinal-004",
             "ref-ordinal-005", "ref-ordinal-006"])
        self.assertEqual(manifest["ordinalRefusals"]["writtenSuffix"], ".")


class OrdinalRefusalFixtureTests(unittest.TestCase):
    def test_canonical_entries_produce_the_independent_literal_output(self):
        fixture = OrdinalRefusalFixture(self)
        result = fixture.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = fixture.ordinal_out.read_text(encoding="utf-8")
        for entry in default_ordinal_entries():
            match = entry["match"]
            kind = "contextShape" if match["kind"] == "context_shape" else "literalPhrase"
            shape = "nil" if match["context_shape"] is None else f'"{match["context_shape"]}"'
            tokens = ", ".join(f'"{t.lower()}"' for t in match["tokens"])
            line = (f'    Refusal(id: "{entry["id"]}", version: {entry["version"]}, '
                    f'contentSHA256: "{entry["content_sha256"]}", '
                    f'reasonCode: "{entry["reason_code"]}", kind: .{kind}, '
                    f'contextShape: {shape}, tokens: [{tokens}], reviewRef: "{entry["review_ref"]}"),')
            self.assertIn(line, text)
        self.assertIn("emitted: 3 reviewed entries (2 context shapes, 1 literal phrase entries)", text)

    def test_pending_and_other_category_entries_are_never_emitted(self):
        pending = [ordinal_entry("ref-ordinal-009", panel_status="pending", review_ref=None)]
        other = [phone_entry("ref-phone-001", "plus_between_operands")]
        fixture = OrdinalRefusalFixture(self, pending=pending, other=other)
        self.assertEqual(fixture.generate().returncode, 0)
        text = fixture.ordinal_out.read_text(encoding="utf-8")
        self.assertNotIn("ref-ordinal-009", text)
        self.assertNotIn("ref-phone-001", text)
        self.assertIn("excluded: 1 pending entries of this category", text)

    def test_check_covers_three_files_and_fails_on_drift_in_the_ordinal_file_alone(self):
        fixture = OrdinalRefusalFixture(self, phone=True)
        self.assertEqual(fixture.generate().returncode, 0)
        ok = fixture.generate("--check")
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertEqual(ok.stdout.count("check ok"), 3)
        fixture.ordinal_out.write_text(
            fixture.ordinal_out.read_text(encoding="utf-8") + "// drift\n", encoding="utf-8")
        drifted = fixture.ordinal_out.read_bytes()
        bad = fixture.generate("--check")
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("GermanOrdinalData.swift", bad.stderr)
        self.assertEqual(fixture.ordinal_out.read_bytes(), drifted)

    def test_a_declaration_adds_nothing_to_the_other_outputs(self):
        plain = Fixture(self)
        plain.generate()
        with_ordinal = OrdinalRefusalFixture(self)
        with_ordinal.generate()
        self.assertEqual(plain.out.read_bytes(), with_ordinal.out.read_bytes())
        self.assertFalse(with_ordinal.phone_out.exists())


class OrdinalRefusalFailureTests(unittest.TestCase):
    def assert_fails_and_writes_nothing(self, fixture, needle):
        result = fixture.generate()
        self.assertNotEqual(result.returncode, 0, "must fail nonzero")
        self.assertIn(needle, result.stderr)
        for path in (fixture.out, fixture.phone_out, fixture.ordinal_out):
            self.assertFalse(path.exists(), f"a failed run must not create {path.name}")

    def replace(self, index, entry):
        entries = default_ordinal_entries()
        entries[index] = entry
        return entries

    def test_a_changed_reviewed_field_with_the_old_hash_fails(self):
        entries = default_ordinal_entries()
        entries[0]["region_limit"] = "changed after review"
        self.assert_fails_and_writes_nothing(OrdinalRefusalFixture(self, entries=entries), "content_sha256")

    def test_a_review_ref_naming_another_version_fails(self):
        entries = self.replace(1, ordinal_entry("ref-ordinal-002", version=2, kind="literal_phrase",
                                                tokens=("ein drittel",),
                                                review_ref="refusal-ledger:ref-ordinal-002:v1"))
        self.assert_fails_and_writes_nothing(OrdinalRefusalFixture(self, entries=entries), "review_ref")

    def test_an_entry_that_is_not_reviewed_fails(self):
        entries = self.replace(0, ordinal_entry("ref-ordinal-001", panel_status="pending"))
        self.assert_fails_and_writes_nothing(OrdinalRefusalFixture(self, entries=entries), "not reviewed")

    def test_a_shape_outside_the_allowed_list_fails(self):
        entries = self.replace(0, ordinal_entry("ref-ordinal-001", shape="plus_between_operands"))
        self.assert_fails_and_writes_nothing(OrdinalRefusalFixture(self, entries=entries), "unsupported shape")

    def test_a_literal_phrase_carrying_a_shape_fails(self):
        entry = ordinal_entry("ref-ordinal-002", kind="literal_phrase", tokens=("ein drittel",))
        entry["match"]["context_shape"] = "ordinal_adverb"
        entry["content_sha256"] = phone_stamp(entry)
        self.assert_fails_and_writes_nothing(
            OrdinalRefusalFixture(self, entries=self.replace(1, entry)), "carries no context shape")

    def test_malformed_phrases_and_tokens_fail(self):
        for index, kind, tokens, needle in (
            (1, "literal_phrase", ("ein  drittel",), "single spaces"),
            (1, "literal_phrase", (), "single spaces"),
            (1, "literal_phrase", ("",), "single spaces"),
            (0, "context_shape", ("zwei worte",), "single words"),
            (0, "context_shape", (), "single words"),
        ):
            with self.subTest(index=index, tokens=tokens):
                entry = ordinal_entry(f"ref-ordinal-00{index + 1}", kind=kind, tokens=tokens)
                self.assert_fails_and_writes_nothing(
                    OrdinalRefusalFixture(self, entries=self.replace(index, entry)), needle)

    def test_two_entries_sharing_a_shape_or_a_phrase_fail(self):
        entries = self.replace(2, ordinal_entry("ref-ordinal-003", shape="ordinal_adverb"))
        self.assert_fails_and_writes_nothing(OrdinalRefusalFixture(self, entries=entries), "share shape")
        entries = default_ordinal_entries() + [
            ordinal_entry("ref-ordinal-004", kind="literal_phrase", tokens=("ein drittel",))]
        fixture = OrdinalRefusalFixture(
            self, entries=entries, declaration={"requiredEntries": ORDINAL_IDS + ["ref-ordinal-004"]})
        self.assert_fails_and_writes_nothing(fixture, "appears twice")

    def test_an_unsupported_match_kind_fails(self):
        entry = ordinal_entry("ref-ordinal-001")
        entry["match"]["kind"] = "regex"
        entry["content_sha256"] = phone_stamp(entry)
        self.assert_fails_and_writes_nothing(
            OrdinalRefusalFixture(self, entries=self.replace(0, entry)), "unsupported match kind")

    def test_a_missing_or_extra_required_entry_fails(self):
        self.assert_fails_and_writes_nothing(
            OrdinalRefusalFixture(self, entries=default_ordinal_entries()[:2]), "required set")
        extra = default_ordinal_entries() + [ordinal_entry("ref-ordinal-007", shape="ordinal_adverb")]
        self.assert_fails_and_writes_nothing(OrdinalRefusalFixture(self, entries=extra), "required set")

    def test_allowed_shapes_outside_the_vocabulary_or_missing_fail(self):
        self.assert_fails_and_writes_nothing(
            OrdinalRefusalFixture(self, declaration={"allowedShapes": ["ordinal_anything"]}),
            "outside the closed vocabulary")
        self.assert_fails_and_writes_nothing(
            OrdinalRefusalFixture(self, declaration={"allowedShapes": []}), "allowedShapes is empty")

    def test_a_failing_phone_declaration_blocks_the_ordinal_output_too(self):
        entries = default_ordinal_entries()
        fixture = OrdinalRefusalFixture(self, entries=entries, phone=True)
        # Break only the phone side: change a reviewed phone field without restamping its hash.
        data = json.loads((fixture.dir / "refusals/de.json").read_text(encoding="utf-8"))
        for entry in data["reviewed_entries"]:
            if entry["id"] == "ref-phone-001":
                entry["region_limit"] = "changed"
        fixture.write("refusals/de.json", json.dumps(data, ensure_ascii=False))
        self.assert_fails_and_writes_nothing(fixture, "content_sha256")


class RealOrdinalTests(unittest.TestCase):
    def test_every_real_ordinal_rule_is_accounted_for(self):
        result = run("--inventory")
        self.assertEqual(result.returncode, 0, result.stderr)
        match = re.search(r"CLDR ordinal rules parsed: (\d+) = (\d+) atoms \+ (\d+) suffix rules "
                          r"\+ (\d+) inflections \+ (\d+) excluded", result.stdout)
        self.assertIsNotNone(match, result.stdout)
        parsed, atoms, suffix, inflections, excluded = map(int, match.groups())
        self.assertEqual((atoms, suffix, inflections), (9, 2, 2))
        self.assertGreater(excluded, 0)
        self.assertEqual(parsed, atoms + suffix + inflections + excluded)

    def test_real_output_carries_the_independently_known_ordinal_forms(self):
        text = REAL_OUTPUT.read_text(encoding="utf-8")
        for line in (
            '    OrdinalAtom(spoken: "erste", value: 1, sources: ["cldr-de-rbnf#%spellout-ordinal"]),',
            '    OrdinalAtom(spoken: "dritte", value: 3, sources: ["cldr-de-rbnf#%spellout-ordinal"]),',
            '    OrdinalAtom(spoken: "siebte", value: 7, sources: ["cldr-de-rbnf#%spellout-ordinal"]),',
            '    OrdinalAtom(spoken: "achte", value: 8, sources: ["cldr-de-rbnf#%spellout-ordinal"]),',
            '    OrdinalSuffixRule(fromValue: 9, cardinalRuleset: "%spellout-numbering", suffix: "te", source: "cldr-de-rbnf#%spellout-ordinal"),',
            '    OrdinalSuffixRule(fromValue: 20, cardinalRuleset: "%spellout-numbering", suffix: "ste", source: "cldr-de-rbnf#%spellout-ordinal"),',
            '    OrdinalInflection(ruleset: "%spellout-ordinal-n", baseRuleset: "%spellout-ordinal", suffix: "n", source: "cldr-de-rbnf#%spellout-ordinal-n"),',
            '    OrdinalInflection(ruleset: "%spellout-ordinal-r", baseRuleset: "%spellout-ordinal", suffix: "r", source: "cldr-de-rbnf#%spellout-ordinal-r"),',
        ):
            self.assertIn(line, text)
        self.assertNotIn("%spellout-ordinal-s", text.split("static let ordinalAtoms")[1])
        self.assertNotIn("%spellout-ordinal-m", text.split("static let ordinalAtoms")[1])

    def test_the_manifest_declares_the_bounded_extraction(self):
        manifest = json.loads(REAL_MANIFEST.read_text(encoding="utf-8"))
        cldr = [s for s in manifest["sources"] if s["kind"] == "cldr-rbnf"]
        self.assertEqual(len(cldr), 1)
        self.assertEqual(cldr[0]["ordinal"]["inflectionRulesets"],
                         ["%spellout-ordinal-n", "%spellout-ordinal-r"])
        self.assertEqual(cldr[0]["ordinal"]["excludedRulesets"],
                         ["%spellout-ordinal-s", "%spellout-ordinal-m"])


class FixtureOrdinalTests(unittest.TestCase):
    def test_a_declared_extraction_produces_the_independent_literal_output(self):
        fixture = Fixture(self, ordinal=(ORDINAL_RULES, ORDINAL_DECLARATION))
        result = fixture.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = fixture.out.read_text(encoding="utf-8")
        for line in (
            '    OrdinalAtom(spoken: "nullte", value: 0, sources: ["cldr-de#%spellout-ordinal"]),',
            '    OrdinalAtom(spoken: "dritte", value: 3, sources: ["cldr-de#%spellout-ordinal"]),',
            '    OrdinalSuffixRule(fromValue: 9, cardinalRuleset: "%spellout-numbering", suffix: "te", source: "cldr-de#%spellout-ordinal"),',
            '    OrdinalSuffixRule(fromValue: 20, cardinalRuleset: "%spellout-numbering", suffix: "ste", source: "cldr-de#%spellout-ordinal"),',
            '    OrdinalInflection(ruleset: "%spellout-ordinal-n", baseRuleset: "%spellout-ordinal", suffix: "n", source: "cldr-de#%spellout-ordinal-n"),',
        ):
            self.assertIn(line, text)
        self.assertIn("CLDR ordinal rules parsed: 12 = 4 atoms + 2 suffix rules + 1 inflections "
                      "+ 5 excluded", text)

    def test_no_declaration_emits_no_ordinal_tables(self):
        fixture = Fixture(self)
        self.assertEqual(fixture.generate().returncode, 0)
        text = fixture.out.read_text(encoding="utf-8")
        self.assertNotIn("ordinalAtoms", text)
        self.assertNotIn("OrdinalAtom", text)

    def test_two_generations_with_an_ordinal_declaration_are_identical(self):
        fixture = Fixture(self, ordinal=(ORDINAL_RULES, ORDINAL_DECLARATION))
        fixture.generate()
        first = fixture.out.read_bytes()
        fixture.generate()
        self.assertEqual(fixture.out.read_bytes(), first)


class FixtureGenerationTests(unittest.TestCase):
    def test_canonical_small_inputs_produce_the_independent_literal_output(self):
        fixture = Fixture(self)
        result = fixture.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = fixture.out.read_text(encoding="utf-8")
        for line in (
            '    Atom(spoken: "null", value: 0, role: .zero, sources: ["cldr-de#%spellout-numbering", "nemo-zero"]),',
            '    Atom(spoken: "eins", value: 1, role: .unit, sources: ["cldr-de#%spellout-numbering", "nemo-ones"]),',
            '    Atom(spoken: "zwei", value: 2, role: .unit, sources: ["cldr-de#%spellout-numbering", "nemo-digit"]),',
            '    Atom(spoken: "zehn", value: 10, role: .teen, sources: ["cldr-de#%spellout-numbering", "nemo-teen"]),',
            '    Atom(spoken: "zwanzig", value: 20, role: .tens, sources: ["nemo-ties"]),',
            '    QuantityWord(spoken: "million", sources: ["nemo-quantities"]),',
            '    QuantityWord(spoken: "millionen", sources: ["nemo-quantities"]),',
            '    Rule(ruleset: "%spellout-numbering", selector: "-x", tokens: [.literal("minus "), .remainder]),',
            '    Rule(ruleset: "%spellout-numbering", selector: "20", tokens: [.optionalOpen, .remainderRule("%spellout-numbering"), .literal("und"), .optionalClose, .literal("zwanzig")]),',
            '    Rule(ruleset: "%spellout-numbering", selector: "2000000", tokens: [.quotientRule("%spellout-numbering"), .literal(" Millionen"), .optionalOpen, .literal(" "), .remainder, .optionalClose]),',
        ):
            self.assertIn(line, text)
        self.assertIn("CLDR rules parsed: 8 = 4 atoms + 4 instructions", text)

    def test_tens_digit_is_multiplied_and_weight_column_is_ignored(self):
        fixture = Fixture(self, nemo={"ties": "dreißig\t3", "ones": "eins\t1\t-0.5"},
                          cldr=CLDR_RULES.replace("zwanzig", "dreißig").replace("20:", "30:"))
        self.assertEqual(fixture.generate().returncode, 0)
        text = fixture.out.read_text(encoding="utf-8")
        self.assertIn('Atom(spoken: "dreißig", value: 30, role: .tens', text)
        self.assertNotIn("-0.5", text)

    def test_identical_mappings_merge_and_keep_both_sources(self):
        fixture = Fixture(self)
        fixture.generate()
        text = fixture.out.read_text(encoding="utf-8")
        self.assertEqual(text.count('Atom(spoken: "eins"'), 1)
        self.assertIn('sources: ["cldr-de#%spellout-numbering", "nemo-ones"]', text)

    def test_unicode_is_normalized_and_escaped_deterministically(self):
        decomposed = "zwölf"  # o + combining diaeresis
        fixture = Fixture(self, nemo={"teen": f"zehn\t10\n{decomposed}\t12"},
                          cldr=CLDR_RULES.replace("2: zwei;", "2: zwei;\n12: zwölf;"))
        self.assertEqual(fixture.generate().returncode, 0)
        text = fixture.out.read_text(encoding="utf-8")
        self.assertIn('Atom(spoken: "zwölf", value: 12, role: .teen', text)
        self.assertNotIn("ö", text)

    def test_quote_and_backslash_in_a_source_literal_are_escaped_for_swift(self):
        fixture = Fixture(self, cldr=CLDR_RULES + '3: ein "Wort\\" Ende[ >>];\n')
        result = fixture.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = fixture.out.read_text(encoding="utf-8")
        self.assertIn('.literal("ein \\"Wort\\\\\\" Ende")', text)

    def test_second_generation_does_not_change_the_output(self):
        fixture = Fixture(self)
        fixture.generate()
        first = fixture.out.read_bytes()
        fixture.generate()
        self.assertEqual(fixture.out.read_bytes(), first)


class FailureAssertions:
    def assert_fails_and_writes_nothing(self, fixture, needle):
        before = fixture.out.read_bytes() if fixture.out.exists() else None
        result = fixture.generate()
        self.assertNotEqual(result.returncode, 0, "must fail nonzero")
        self.assertIn(needle, result.stderr)
        after = fixture.out.read_bytes() if fixture.out.exists() else None
        self.assertEqual(before, after, "a failed run must not change or create the output")


class FailureTests(FailureAssertions, unittest.TestCase):

    def test_a_pinned_hash_mismatch_fails_before_any_output(self):
        fixture = Fixture(self)
        fixture.sources[1]["sha256"] = "0" * 64
        self.assert_fails_and_writes_nothing(fixture, "hash")

    def test_a_changed_source_file_fails_the_hash_check(self):
        fixture = Fixture(self)
        fixture.manifest()
        fixture.write("sources/digit.tsv", "zwei\t2\ndrei\t3")
        self.assert_fails_and_writes_nothing(fixture, "hash")

    def test_a_missing_source_file_fails(self):
        fixture = Fixture(self)
        fixture.manifest()
        (fixture.dir / "sources/teen.tsv").unlink()
        self.assert_fails_and_writes_nothing(fixture, "missing")

    def test_a_floating_ref_instead_of_a_commit_fails(self):
        fixture = Fixture(self)
        fixture.sources[0]["commit"] = "main"
        self.assert_fails_and_writes_nothing(fixture, "40-hex")

    def test_a_malformed_tsv_row_fails(self):
        for body, needle in (
            ("zwei", "columns"),
            ("zwei\ttwo", "integer"),
            ("zwei\t2\t-0.1\textra", "columns"),
            ("zwei\t2\nzwei\t3", "conflict"),
            ("zwei\t11", "outside"),
            ("zwei\t2\n\ndrei\t3", "columns"),
        ):
            with self.subTest(body=body):
                fixture = Fixture(self, nemo={"digit": body})
                self.assert_fails_and_writes_nothing(fixture, needle)

    def test_a_non_numeric_weight_fails(self):
        fixture = Fixture(self, nemo={"ones": "eins\t1\theavy"})
        self.assert_fails_and_writes_nothing(fixture, "weight")

    def test_quantities_rows_must_have_exactly_one_column(self):
        fixture = Fixture(self, nemo={"quantities": "million\t1000000"})
        self.assert_fails_and_writes_nothing(fixture, "exactly one")

    def test_one_spoken_form_with_two_values_in_one_role_is_a_conflict(self):
        fixture = Fixture(self, nemo={"digit": "zwei\t2", "ones": "zwei\t1"})
        self.assert_fails_and_writes_nothing(fixture, "conflict")

    def test_unsupported_rbnf_syntax_in_a_selected_ruleset_fails(self):
        for rule, needle in (
            ("3: $(cardinal,one{ein}other{viele})$;", "plural"),
            ("3: [eins;", "bracket"),
            ("3: eins];", "bracket"),
            ("3: <x;", "substitution"),
            ("3: =%;", "redirect"),
            ("fnord: drei;", "unsupported rule"),
        ):
            with self.subTest(rule=rule):
                fixture = Fixture(self, cldr=CLDR_RULES + rule + "\n")
                self.assert_fails_and_writes_nothing(fixture, needle)

    def test_a_missing_selected_ruleset_fails(self):
        fixture = Fixture(self)
        fixture.sources[-1]["rulesets"] = ["%spellout-numbering", "%spellout-nope"]
        self.assert_fails_and_writes_nothing(fixture, "not found")

    def test_malformed_xml_fails(self):
        fixture = Fixture(self)
        fixture.manifest()
        fixture.write("sources/de.xml", "<ldml><rbnf>")
        fixture.sources[-1] = fixture.entry("cldr-de", "cldr-rbnf", "sources/de.xml",
                                            rulesets=["%spellout-numbering"])
        self.assert_fails_and_writes_nothing(fixture, "malformed")

    def test_a_cldr_tens_word_that_disagrees_with_nemo_fails(self):
        fixture = Fixture(self, cldr=CLDR_RULES.replace("]zwanzig;", "]zwonzig;"))
        self.assert_fails_and_writes_nothing(fixture, "cross-check")

    def test_a_cldr_scale_word_missing_from_the_nemo_quantities_fails(self):
        fixture = Fixture(self, nemo={"quantities": "million"})
        self.assert_fails_and_writes_nothing(fixture, "cross-check")

    def test_an_empty_table_is_never_published(self):
        fixture = Fixture(self, nemo={"quantities": ""})
        self.assert_fails_and_writes_nothing(fixture, "empty")


class OrdinalFailureTests(FailureAssertions, unittest.TestCase):

    def declared(self, rules=ORDINAL_RULES, declaration=None):
        return Fixture(self, ordinal=(rules, declaration or dict(ORDINAL_DECLARATION)))

    def test_an_ordinal_ruleset_that_is_not_declared_fails(self):
        extra = ORDINAL_RULES + "%spellout-ordinal-s:\n0: =%spellout-ordinal=s;\n"
        self.assert_fails_and_writes_nothing(self.declared(extra), "neither declared")

    def test_declaring_a_missing_ordinal_ruleset_fails(self):
        declaration = dict(ORDINAL_DECLARATION, excludedRulesets=["%spellout-ordinal-nope"])
        self.assert_fails_and_writes_nothing(self.declared(declaration=declaration), "not found")

    def test_an_ordinal_rule_that_fits_no_class_fails(self):
        rules = ORDINAL_RULES.replace("100: <%spellout-numbering<­hundert>>;\n",
                                      "100: <%spellout-numbering<­hundert>>;\n50/2: nope;\n")
        self.assert_fails_and_writes_nothing(self.declared(rules), "fits no declared class")

    def test_an_irregular_ordinal_with_substitution_syntax_fails(self):
        rules = ORDINAL_RULES.replace("3: dritte;", "3: =%spellout-numbering=te;")
        self.assert_fails_and_writes_nothing(self.declared(rules), "one literal word")

    def test_a_gap_in_the_irregular_forms_fails(self):
        rules = ORDINAL_RULES.replace("2: zweite;\n", "")
        self.assert_fails_and_writes_nothing(self.declared(rules), "must cover")

    def test_a_suffix_rule_pointing_at_an_unselected_cardinal_ruleset_fails(self):
        rules = ORDINAL_RULES.replace("9: =%spellout-numbering=te;", "9: =%spellout-other=te;")
        self.assert_fails_and_writes_nothing(self.declared(rules), "selected cardinal ruleset")

    def test_an_inflection_that_does_not_redirect_the_base_fails(self):
        rules = ORDINAL_RULES.replace("0: =%spellout-ordinal=n;", "0: =%spellout-numbering=n;")
        self.assert_fails_and_writes_nothing(self.declared(rules), "fits no declared class")

    def test_a_declaration_without_a_base_fails(self):
        declaration = dict(ORDINAL_DECLARATION)
        del declaration["base"]
        self.assert_fails_and_writes_nothing(self.declared(declaration=declaration), "needs base")

    def test_an_excluded_ruleset_is_counted_not_dropped(self):
        extra = ORDINAL_RULES + "%spellout-ordinal-s:\n-x: minus >>;\n0: =%spellout-ordinal=s;\n"
        declaration = dict(ORDINAL_DECLARATION, excludedRulesets=["%spellout-ordinal-s"])
        fixture = self.declared(extra, declaration)
        self.assertEqual(fixture.generate().returncode, 0)
        text = fixture.out.read_text(encoding="utf-8")
        self.assertIn("CLDR ordinal rules parsed: 14 = 4 atoms + 2 suffix rules + 1 inflections "
                      "+ 7 excluded", text)


class ModeTests(unittest.TestCase):
    def test_check_passes_on_matching_output_and_never_rewrites_it(self):
        fixture = Fixture(self)
        fixture.generate()
        before = fixture.out.stat().st_mtime_ns, fixture.out.read_bytes()
        result = fixture.generate("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((fixture.out.stat().st_mtime_ns, fixture.out.read_bytes()), before)

    def test_check_fails_on_drift_and_leaves_the_drifted_file_alone(self):
        fixture = Fixture(self)
        fixture.generate()
        fixture.out.write_text(fixture.out.read_text(encoding="utf-8") + "// drift\n",
                               encoding="utf-8")
        drifted = fixture.out.read_bytes()
        result = fixture.generate("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs", result.stderr)
        self.assertEqual(fixture.out.read_bytes(), drifted)

    def test_check_fails_when_the_committed_output_is_missing(self):
        fixture = Fixture(self)
        result = fixture.generate("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr)

    def test_refresh_refuses_a_url_that_is_not_pinned_to_the_commit(self):
        fixture = Fixture(self)
        fixture.sources[0]["url"] = "https://example.invalid/main/sources/zero.tsv"
        result = fixture.generate("--refresh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pinned commit", result.stderr)

    def test_a_missing_manifest_fails(self):
        result = run("--manifest", "/nonexistent/manifest.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot read manifest", result.stderr)


if __name__ == "__main__":
    unittest.main()
