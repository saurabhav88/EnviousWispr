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
