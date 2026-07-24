from __future__ import annotations

import importlib.util
import hashlib
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "score_eg1_english_list_novel.py"
SPEC = importlib.util.spec_from_file_location("score_eg1_english_list_novel", MODULE_PATH)
assert SPEC and SPEC.loader
SCORER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCORER)


def corpus_row(case_id: str, role: str, **overrides: object) -> dict[str, object]:
    row: dict[str, object] = {
        "id": case_id,
        "split": "dev",
        "gold_status": "candidate_unreviewed",
        "native_reviewed": False,
        "training_eligible": False,
        "benchmark_role": role,
        "domain": "work_admin",
        "case_type": "explicit_bullets" if role == "positive_list" else "woven_argument",
        "item_count": 2,
        "length_bucket": "short",
        "compound_required": False,
        "items": ["archive logs", "rotate keys"] if role == "positive_list" else ["cost", "speed"],
        "compound_items": [],
        "scope_anchors": ["for Maya by Friday"] if role == "positive_list" else ["for the board"],
        "forbidden": ["um"],
        "expected_formatting": "bullets" if role == "positive_list" else "prose",
    }
    row.update(overrides)
    return row


class NovelEnglishListScorerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.positive = self.root / "positive.jsonl"
        self.restraint = self.root / "restraint.jsonl"
        self.candidates = self.root / "candidates.jsonl"
        self.write(
            self.positive,
            [
                corpus_row("p1", "positive_list"),
                corpus_row(
                    "p2",
                    "positive_list",
                    case_type="spoken_ordinals",
                    expected_formatting="numbered",
                    items=["sign and date the affidavit", "notify the clerk"],
                    compound_items=["sign and date the affidavit"],
                    compound_required=True,
                    scope_anchors=["Before filing"],
                ),
            ],
        )
        self.write(self.restraint, [corpus_row("r1", "prose_restraint")])
        self.good_outputs = {
            "p1": "For Maya by Friday:\n- archive logs\n- rotate keys",
            "p2": "Before filing:\n1. sign and date the affidavit\n2. notify the clerk",
            "r1": "The analyst compared cost and speed for the board.",
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def write(path: Path, rows: list[dict[str, object]]) -> None:
        path.write_text(
            "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
        )

    @staticmethod
    def sha256(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def write_candidates(self, outputs: dict[str, str], model_id: str = "model-a") -> Path:
        path = self.root / f"{model_id}.jsonl"
        self.write(
            path,
            [
                {"id": case_id, "model_id": model_id, "output": output}
                for case_id, output in outputs.items()
            ],
        )
        return path

    def report(self, outputs: dict[str, str] | None = None) -> dict[str, object]:
        candidate = self.write_candidates(outputs or self.good_outputs)
        return SCORER.build_report(self.positive, self.restraint, [candidate])

    def case(self, report: dict[str, object], case_id: str, model_id: str = "model-a") -> dict[str, object]:
        rows = report["models"][model_id]["case_results"]
        return next(row for row in rows if row["id"] == case_id)

    def test_clean_outputs_pass_and_report_is_development_only(self) -> None:
        report = self.report()
        model = report["models"]["model-a"]
        self.assertEqual(report["status"], "development_unreviewed_deterministic_only")
        self.assertFalse(report["semantic_proof"])
        self.assertEqual(model["positive"]["strict"]["successes"], 2)
        self.assertEqual(model["restraint"]["false_list"]["successes"], 0)

    def test_source_receipts_pin_actual_file_hashes(self) -> None:
        candidate = self.write_candidates(self.good_outputs)
        report = SCORER.build_report(self.positive, self.restraint, [candidate])
        self.assertEqual(report["scorer_source"]["sha256"], self.sha256(MODULE_PATH.resolve()))
        self.assertEqual(report["corpora"]["positive"]["sha256"], self.sha256(self.positive))
        self.assertEqual(report["corpora"]["restraint"]["sha256"], self.sha256(self.restraint))
        self.assertEqual(report["candidate_sources"][0]["sha256"], self.sha256(candidate))
        self.assertEqual(
            report["models"]["model-a"]["candidate_sources"], report["candidate_sources"]
        )

    def test_candidate_error_is_visible_and_still_fails_quality(self) -> None:
        path = self.write_candidates(self.good_outputs)
        rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
        for row in rows:
            if row["id"] == "p1":
                row["error"] = "timeout"
        self.write(path, rows)
        report = SCORER.build_report(self.positive, self.restraint, [path])
        model = report["models"]["model-a"]
        result = self.case(report, "p1")
        self.assertEqual(result["candidate_error"], "timeout")
        self.assertFalse(result["inference_ok"])
        self.assertFalse(result["strict"])
        self.assertEqual(model["inference_failure_count"], 1)
        self.assertEqual(model["inference_failure_ids"], ["p1"])
        self.assertEqual(model["candidate_error_count"], 1)
        self.assertEqual(model["positive"]["forbidden_cleanup"]["successes"], 1)

    def test_empty_restraint_output_fails_inference_no_list_and_cleanup(self) -> None:
        outputs = dict(self.good_outputs)
        outputs["r1"] = ""
        report = self.report(outputs)
        model = report["models"]["model-a"]
        result = self.case(report, "r1")
        self.assertTrue(result["empty_output"])
        self.assertFalse(result["inference_ok"])
        self.assertEqual(model["inference_failure_ids"], ["r1"])
        self.assertEqual(model["empty_output_ids"], ["r1"])
        self.assertEqual(model["restraint"]["no_list"]["successes"], 0)
        self.assertEqual(model["restraint"]["forbidden_cleanup"]["successes"], 0)

    def test_missing_and_extra_ids_fail_closed(self) -> None:
        missing = dict(self.good_outputs)
        del missing["r1"]
        with self.assertRaisesRegex(ValueError, "missing=\\['r1'\\]"):
            self.report(missing)
        extra = {**self.good_outputs, "unknown": "text"}
        with self.assertRaisesRegex(ValueError, "extra=\\['unknown'\\]"):
            self.report(extra)

    def test_duplicate_candidate_id_fails_closed(self) -> None:
        path = self.write_candidates(self.good_outputs)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"id": "p1", "model_id": "model-a", "output": "again"}) + "\n")
        with self.assertRaisesRegex(ValueError, "duplicate candidate id"):
            SCORER.build_report(self.positive, self.restraint, [path])

    def test_wrong_marker_is_visible_even_when_list_activates(self) -> None:
        outputs = dict(self.good_outputs)
        outputs["p2"] = "Before filing:\n- sign and date the affidavit\n- notify the clerk"
        result = self.case(self.report(outputs), "p2")
        self.assertTrue(result["activated"])
        self.assertEqual(result["wrong_marker_count"], 2)
        self.assertFalse(result["structure_ok"])
        self.assertFalse(result["strict"])

    def test_trailing_header_fails_primary_structure_gate(self) -> None:
        outputs = dict(self.good_outputs)
        outputs["p1"] = "- archive logs\n- rotate keys\nFor Maya by Friday:"
        result = self.case(self.report(outputs), "p1")
        self.assertFalse(result["header_ok"])
        self.assertFalse(result["structure_ok"])
        self.assertFalse(result["strict"])

    def test_compound_split_fails_atomicity(self) -> None:
        outputs = dict(self.good_outputs)
        outputs["p2"] = "Before filing:\n1. sign the affidavit\n2. date the affidavit\n3. notify the clerk"
        report = self.report(outputs)
        result = self.case(report, "p2")
        self.assertFalse(result["compound_atomic"])
        self.assertIn("p2", report["models"]["model-a"]["damage_proxies"]["positive_compound_split"])

    def test_fused_items_plus_fabricated_line_fail_atomicity(self) -> None:
        outputs = dict(self.good_outputs)
        outputs["p1"] = (
            "For Maya by Friday:\n"
            "- archive logs and rotate keys\n"
            "- delete the database"
        )
        result = self.case(self.report(outputs), "p1")
        self.assertEqual(result["line_item_hits"], [["archive logs", "rotate keys"], []])
        self.assertFalse(result["atomic_items"])
        self.assertFalse(result["strict"])

    def test_scope_loss_is_content_damage(self) -> None:
        outputs = dict(self.good_outputs)
        outputs["p1"] = "- archive logs\n- rotate keys"
        result = self.case(self.report(outputs), "p1")
        self.assertFalse(result["scope_preserved"])
        self.assertTrue(result["content_damage"])
        self.assertFalse(result["strict"])

    def test_forbidden_retention_fails_cleanup(self) -> None:
        outputs = dict(self.good_outputs)
        outputs["p1"] = "For Maya by Friday:\n- um archive logs\n- rotate keys"
        result = self.case(self.report(outputs), "p1")
        self.assertFalse(result["forbidden_cleanup"])
        self.assertFalse(result["strict"])

    def test_restraint_list_is_counted_as_false_list(self) -> None:
        outputs = dict(self.good_outputs)
        outputs["r1"] = "For the board:\n- cost\n- speed"
        report = self.report(outputs)
        result = self.case(report, "r1")
        self.assertTrue(result["false_list"])
        self.assertEqual(report["models"]["model-a"]["restraint"]["false_list"]["successes"], 1)

    def test_paired_counts_and_exact_mcnemar(self) -> None:
        left = self.write_candidates(self.good_outputs, "model-a")
        right_outputs = dict(self.good_outputs)
        right_outputs["p2"] = "Before filing: sign and date the affidavit, then notify the clerk."
        right_outputs["r1"] = "For the board:\n- cost\n- speed"
        right = self.write_candidates(right_outputs, "model-b")
        report = SCORER.build_report(self.positive, self.restraint, [right, left])
        source_paths = [source["path"] for source in report["candidate_sources"]]
        self.assertEqual(source_paths, sorted(source_paths))
        self.assertEqual(report["models"]["model-a"]["candidate_sources"][0]["path"], str(left))
        self.assertEqual(report["models"]["model-b"]["candidate_sources"][0]["path"], str(right))
        paired = report["paired_comparisons"][0]["combined_strict_diagnostic_only"]
        self.assertEqual(
            {key: paired[key] for key in ("both_pass", "left_only", "right_only", "both_fail")},
            {"both_pass": 1, "left_only": 2, "right_only": 0, "both_fail": 0},
        )
        self.assertEqual(paired["exact_mcnemar_p_two_sided"], 0.5)
        self.assertFalse(report["reporting_contract"]["combined_percentage_allowed"])

    def test_empty_metric_slice_is_unmeasured(self) -> None:
        value = SCORER.metric(0, 0)
        self.assertEqual(value["successes"], 0)
        self.assertEqual(value["total"], 0)
        self.assertIsNone(value["rate"])
        self.assertIsNone(value["wilson_95"])


if __name__ == "__main__":
    unittest.main()
