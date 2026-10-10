"""Contract tests for scripts/itn/validate-review-data.py (#1677, PR 2 chunk 2).

They drive the REAL command line against small synthetic trees with independent literal expectations.
They prove the validator's well-formedness and administrative checks; they say nothing about whether
any German expectation is linguistically right.
"""

import copy
import json
import unicodedata
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ITN = HERE.parent
VALIDATOR = ITN / "validate-review-data.py"
SCHEMA = ITN / "review-data.schema.json"

PROVENANCE = {
    "drafting_model": "test-model", "drafting_run": "fixture", "phase0_anchor_ids": [],
    "evidence_ids": ["E-ITU-E123"], "retrieval": "fixture",
}


def row(rid, category, split, spoken, action, variants, spans=None, reason=None, kind="spoken_sentence",
        preserve=None, status="panel-reviewed", review="ledger:fixture:v1"):
    body = {
        "id": rid, "version": 1, "content_sha256": "", "language": "de", "category": category, "split": split,
        "spoken_input": spoken, "input_kind": kind, "expected_action": action,
        "accepted_written_variants": variants, "target_spans": spans or [], "must_preserve": preserve or [],
        "refusal_reason": reason, "region_limit": "none", "provenance": copy.deepcopy(PROVENANCE),
        "panel_status": status, "review_ref": review if status == "panel-reviewed" else None,
    }
    body["content_sha256"] = stamp(body)
    return body


def stamp(body):
    import hashlib
    keys = ["category", "split", "spoken_input", "input_kind", "expected_action", "accepted_written_variants",
            "target_spans", "must_preserve", "refusal_reason", "region_limit"]
    text = json.dumps({k: body[k] for k in keys}, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def refusal_stamp(entry):
    import hashlib
    keys = ["category", "reason_code", "match", "required_context", "region_limit", "evidence_ids"]
    text = json.dumps({k: entry[k] for k in keys}, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def phone_dev():
    return row("de-phone-dev-001", "phone_country_prefix", "development",
               "Meine Nummer ist plus 49 171 2345678.", "convert",
               ["Meine Nummer ist +49 171 2345678."],
               spans=[{"spoken_span": "plus 49", "value": "German country code", "written_forms": ["+49"]}],
               preserve=["171 2345678"])


def phone_hold():
    return row("de-phone-hold-001", "phone_country_prefix", "holdout",
               "Ruf mich unter plus 43 664 1234567 an.", "convert",
               ["Ruf mich unter +43 664 1234567 an."],
               spans=[{"spoken_span": "plus 43", "value": "Austrian country code", "written_forms": ["+43"]}])


def phone_lexical():
    return row("de-phone-ctl-001", "phone_country_prefix", "control", "Drei plus vier ist sieben.", "preserve",
               ["Drei plus vier ist sieben."], reason="plus_arithmetic")


def phone_formatted():
    return row("de-phone-ctl-002", "phone_country_prefix", "control", "Meine Nummer ist +49 171 2345678.",
               "preserve", ["Meine Nummer ist +49 171 2345678."], reason="already_formatted",
               kind="already_formatted_synthetic")


def refusal(rid="ref-phone-001", supporting=("de-phone-ctl-001",), **over):
    entry = {
        "id": rid, "category": "phone_country_prefix", "reason_code": "plus_arithmetic",
        "match": {"kind": "context_shape", "tokens": ["plus"], "context_shape": "plus_between_operands"},
        "required_context": "none", "region_limit": "none", "evidence_ids": ["E-DUDEN-DAF-P78"],
        "supporting_row_ids": list(supporting), "panel_status": "panel-reviewed", "review_ref": "ledger:fixture:v1",
    }
    entry["version"] = 1
    entry.update(over)
    entry["content_sha256"] = over.get("content_sha256") or refusal_stamp(entry)
    return entry


class Tree:
    def __init__(self, test, dev=None, hold=None, ctl=None, refusals=None, raw=None):
        self.root = Path(tempfile.mkdtemp(prefix="itn-review-"))
        test.addCleanup(shutil.rmtree, self.root, True)
        (self.root / "corpus").mkdir()
        (self.root / "refusals").mkdir()
        shutil.copy(SCHEMA, self.root / "review-data.schema.json")
        files = {
            "corpus/de-development.jsonl": dev if dev is not None else [phone_dev()],
            "corpus/de-holdout.jsonl": hold if hold is not None else [phone_hold()],
            "corpus/de-controls.jsonl": ctl if ctl is not None else [phone_lexical(), phone_formatted()],
        }
        for rel, rows in files.items():
            self.write_rows(rel, rows)
        data = refusals if refusals is not None else {
            "schema_version": 1, "language": "de", "reviewed_entries": [refusal()], "pending_entries": []}
        (self.root / "refusals/de.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        for rel, text in (raw or {}).items():
            (self.root / rel).write_text(text, encoding="utf-8")

    def write_rows(self, rel, rows):
        (self.root / rel).write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n",
                                     encoding="utf-8")

    def run(self, *extra):
        return subprocess.run([sys.executable, str(VALIDATOR), "--root", str(self.root), *extra],
                              capture_output=True, text=True)


class CanonicalTests(unittest.TestCase):
    def test_a_small_well_formed_tree_passes_with_the_independent_counts(self):
        result = Tree(self).run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK: 4 rows, 4 panel-reviewed, 0 pending or draft", result.stdout)

    def test_the_content_hash_covers_the_content_and_ignores_panel_state(self):
        body = phone_dev()
        self.assertRegex(body["content_sha256"], r"^[0-9a-f]{64}$")
        # A one-character change in a hashed field changes the stamp; an unhashed field does not.
        other = copy.deepcopy(body)
        other["spoken_input"] += " "
        self.assertNotEqual(stamp(other), body["content_sha256"])
        other = copy.deepcopy(body)
        other["panel_status"] = "pending"
        self.assertEqual(stamp(other), body["content_sha256"])

    def test_the_real_corpus_files_when_present_validate(self):
        if not (ITN / "corpus/de-development.jsonl").exists():
            self.skipTest("the frozen corpus has not been committed yet")
        result = subprocess.run([sys.executable, str(VALIDATOR)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


class EmptyOrBrokenInputTests(unittest.TestCase):
    def fails(self, tree, needle):
        result = tree.run()
        self.assertNotEqual(result.returncode, 0, "must fail nonzero")
        self.assertIn(needle, result.stderr)

    def test_zero_rows_is_a_failure_never_an_empty_success(self):
        self.fails(Tree(self, dev=[], hold=[], ctl=[], refusals={
            "schema_version": 1, "language": "de", "reviewed_entries": [], "pending_entries": []}),
            "no rows were read")

    def test_a_missing_corpus_file_fails(self):
        tree = Tree(self)
        (tree.root / "corpus/de-holdout.jsonl").unlink()
        self.fails(tree, "cannot read")

    def test_a_missing_refusal_file_fails(self):
        tree = Tree(self)
        (tree.root / "refusals/de.json").unlink()
        self.fails(tree, "cannot read or parse")

    def test_a_parse_error_fails(self):
        tree = Tree(self, raw={"corpus/de-holdout.jsonl": "{not json}\n"})
        self.fails(tree, "parse error")

    def test_a_blank_line_fails(self):
        tree = Tree(self)
        text = (tree.root / "corpus/de-development.jsonl").read_text(encoding="utf-8")
        (tree.root / "corpus/de-development.jsonl").write_text(text + "\n", encoding="utf-8")
        self.fails(tree, "blank line")

    def test_a_missing_schema_fails(self):
        tree = Tree(self)
        (tree.root / "review-data.schema.json").unlink()
        self.fails(tree, "cannot read or parse")


class RowRuleTests(unittest.TestCase):
    def mutated(self, base, **changes):
        out = copy.deepcopy(base)
        out.update(changes)
        return out

    def check(self, dev=None, hold=None, ctl=None, needle="", refusals=None):
        result = Tree(self, dev=dev, hold=hold, ctl=ctl, refusals=refusals).run()
        self.assertNotEqual(result.returncode, 0, "must fail nonzero")
        self.assertIn(needle, result.stderr)

    def test_a_stale_hash_fails(self):
        self.check(dev=[self.mutated(phone_dev(), spoken_input="Meine Nummer ist plus 49 171 2345678!")],
                   needle="content_sha256")

    def test_an_unknown_category_fails(self):
        row_ = phone_dev()
        row_["category"] = "cardinal"
        row_["content_sha256"] = stamp(row_)
        self.check(dev=[row_], needle="closed vocabulary")

    def test_a_row_in_the_wrong_split_file_fails(self):
        self.check(dev=[phone_hold()], needle="found in the development file")

    def test_a_duplicate_id_fails(self):
        self.check(ctl=[phone_lexical(), phone_lexical()], needle="duplicate id")

    def test_a_duplicate_sentence_fails_even_when_case_or_unicode_form_differs(self):
        twin = row("de-phone-ctl-003", "phone_country_prefix", "control", "DREI PLUS VIER IST SIEBEN.", "preserve",
                   ["DREI PLUS VIER IST SIEBEN."], reason="plus_arithmetic")
        self.check(ctl=[phone_lexical(), twin], needle="duplicate sentence")

    def test_a_variant_that_is_not_the_spans_replaced_fails(self):
        bad = phone_dev()
        bad["accepted_written_variants"] = ["Meine Nummer ist +48 171 2345678."]
        bad["content_sha256"] = stamp(bad)
        self.check(dev=[bad], needle="is not spoken_input with the spans replaced")

    def test_the_unconverted_sentence_cannot_be_an_accepted_variant(self):
        bad = phone_dev()
        bad["accepted_written_variants"] = ["Meine Nummer ist +49 171 2345678.", bad["spoken_input"]]
        bad["content_sha256"] = stamp(bad)
        self.check(dev=[bad], needle="unconverted sentence")

    def test_a_span_not_in_the_sentence_fails(self):
        bad = phone_dev()
        bad["target_spans"][0]["spoken_span"] = "plus 50"
        bad["content_sha256"] = stamp(bad)
        self.check(dev=[bad], needle="is not in spoken_input")

    def test_a_must_preserve_text_missing_from_the_sentence_fails(self):
        bad = phone_dev()
        bad["must_preserve"] = ["Hotline"]
        bad["content_sha256"] = stamp(bad)
        self.check(dev=[bad], needle="must_preserve")

    def test_a_preserve_row_must_accept_exactly_its_own_sentence(self):
        bad = phone_lexical()
        bad["accepted_written_variants"] = ["Drei + vier ist sieben."]
        bad["content_sha256"] = stamp(bad)
        self.check(ctl=[bad, phone_formatted()], needle="byte-identical")

    def test_a_reason_from_another_category_fails(self):
        bad = phone_lexical()
        bad["refusal_reason"] = "fraction_word"
        bad["content_sha256"] = stamp(bad)
        self.check(ctl=[bad, phone_formatted()], needle="not allowed for phone_country_prefix")

    def test_already_formatted_reason_and_kind_go_together(self):
        bad = phone_formatted()
        bad["input_kind"] = "spoken_sentence"
        bad["content_sha256"] = stamp(bad)
        self.check(ctl=[phone_lexical(), bad], needle="go together")

    def test_a_panel_reviewed_row_needs_a_review_ref(self):
        bad = phone_dev()
        bad["review_ref"] = None
        self.check(dev=[bad], needle="needs a review_ref")

    def test_a_convert_row_cannot_sit_in_the_controls(self):
        bad = row("de-phone-ctl-009", "phone_country_prefix", "control", "Ruf plus 49 171 123 an.", "convert",
                  ["Ruf +49 171 123 an."],
                  spans=[{"spoken_span": "plus 49", "value": "x", "written_forms": ["+49"]}])
        self.check(ctl=[phone_lexical(), bad], needle="cannot be a convert row")

    def test_an_unknown_evidence_id_fails(self):
        bad = phone_dev()
        bad["provenance"]["evidence_ids"] = ["E-NOPE"]
        self.check(dev=[bad], needle="unknown evidence id")

    def test_unicode_byte_change_cannot_keep_a_review_hash(self):
        sentence = "Für die Aufgabe gilt: 3 plus 4 ist 7."
        original = row("de-phone-ctl-003", "phone_country_prefix", "control", sentence, "preserve", [sentence],
                       reason="plus_arithmetic")
        changed = copy.deepcopy(original)
        changed["spoken_input"] = unicodedata.normalize("NFD", sentence)
        changed["accepted_written_variants"] = [changed["spoken_input"]]
        self.assertNotEqual(changed["spoken_input"], sentence.encode().decode("utf-8") + "x")
        self.check(ctl=[changed, phone_formatted()], needle="content_sha256")

    def test_an_unexpected_field_and_a_wrong_type_fail(self):
        extra = phone_dev()
        extra["score"] = 1
        self.check(dev=[extra], needle="unexpected field score")
        wrong = phone_dev()
        wrong["version"] = "1"
        self.check(dev=[wrong], needle="expected integer")


class RefusalRuleTests(unittest.TestCase):
    def check(self, entry, needle, pending=None, **tree_args):
        data = {"schema_version": 1, "language": "de", "reviewed_entries": [entry] if entry else [],
                "pending_entries": pending or []}
        result = Tree(self, refusals=data, **tree_args).run()
        self.assertNotEqual(result.returncode, 0, "must fail nonzero")
        self.assertIn(needle, result.stderr)

    def test_a_holdout_row_cannot_support_a_refusal(self):
        self.check(refusal(supporting=("de-phone-hold-001",)), "holdout row")

    def test_a_missing_supporting_row_fails(self):
        self.check(refusal(supporting=("de-phone-ctl-099",)), "does not exist")

    def test_a_reviewed_refusal_cannot_rest_on_a_pending_row(self):
        pending = row("de-phone-ctl-001", "phone_country_prefix", "control", "Drei plus vier ist sieben.",
                      "preserve", ["Drei plus vier ist sieben."], reason="plus_arithmetic", status="pending")
        self.check(refusal(), "which is pending", ctl=[pending, phone_formatted()])

    def test_a_token_that_looks_like_a_pattern_fails(self):
        entry = refusal()
        entry["match"] = {"kind": "literal_phrase", "tokens": ["plu.*"], "context_shape": None}
        self.check(entry, "looks like a pattern")

    def test_a_context_shape_outside_the_vocabulary_fails(self):
        entry = refusal()
        entry["match"]["context_shape"] = "anything_goes"
        self.check(entry, "context_shape outside")

    def test_a_literal_phrase_must_not_carry_a_context_shape(self):
        entry = refusal()
        entry["match"] = {"kind": "literal_phrase", "tokens": ["plus"], "context_shape": "plus_between_operands"}
        self.check(entry, "literal_phrase needs tokens")

    def test_pending_status_in_the_reviewed_bucket_fails(self):
        self.check(refusal(panel_status="pending"), "cannot hold status")

    def test_an_unreviewed_refusal_needs_a_review_ref_when_reviewed(self):
        self.check(refusal(review_ref=None), "review_ref")

    def test_a_changed_reviewed_entry_cannot_keep_its_review_hash(self):
        entry = refusal()
        entry["region_limit"] = "A different sentence than the one the panel judged."
        self.check(entry, "content_sha256 does not match")

    def test_a_reviewed_entry_needs_the_version_its_review_ref_names(self):
        self.check(refusal(version=2), "names (…:v<version>)")

    def test_a_reason_code_from_another_category_fails(self):
        self.check(refusal(reason_code="fraction_word"), "not allowed for phone_country_prefix")

    def test_a_pending_entry_may_rest_on_pending_rows(self):
        pending_row = row("de-phone-ctl-001", "phone_country_prefix", "control", "Drei plus vier ist sieben.",
                          "preserve", ["Drei plus vier ist sieben."], reason="plus_arithmetic", status="pending")
        entry = refusal(panel_status="pending", review_ref=None)
        data = {"schema_version": 1, "language": "de", "reviewed_entries": [], "pending_entries": [entry]}
        result = Tree(self, refusals=data, ctl=[pending_row, phone_formatted()]).run()
        self.assertEqual(result.returncode, 0, result.stderr)


class FrozenMembershipTests(unittest.TestCase):
    def test_a_pending_row_is_counted_pending_and_excluded_from_the_frozen_set(self):
        pending = row("de-phone-hold-001", "phone_country_prefix", "holdout", "Ruf mich unter plus 43 664 1234567 an.",
                      "convert", ["Ruf mich unter +43 664 1234567 an."],
                      spans=[{"spoken_span": "plus 43", "value": "x", "written_forms": ["+43"]}], status="pending")
        result = Tree(self, hold=[pending]).run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK: 4 rows, 3 panel-reviewed, 1 pending or draft", result.stdout)

    def test_frozen_mode_fails_with_the_exact_deficits(self):
        result = Tree(self).run("--frozen")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("frozen:phone_country_prefix:development: 1 panel-reviewed rows, need 20", result.stderr)
        self.assertIn("frozen:phone_country_prefix:holdout: 1 panel-reviewed rows, need 59", result.stderr)
        self.assertIn("frozen:phone_country_prefix:control_lexical: 1 panel-reviewed rows, need 30", result.stderr)
        self.assertIn("frozen:phone_country_prefix:control_formatted: 1 panel-reviewed rows, need 29", result.stderr)
        self.assertIn("frozen:ordinal:development: 0 panel-reviewed rows, need 20", result.stderr)
        self.assertIn("frozen:clock_idiom:holdout: 0 panel-reviewed rows, need 59", result.stderr)


if __name__ == "__main__":
    unittest.main()
