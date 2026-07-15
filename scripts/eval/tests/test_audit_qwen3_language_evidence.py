from __future__ import annotations

import contextlib
import io
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


EVAL_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = EVAL_DIR / "audit_qwen3_language_evidence.py"
sys.path.insert(0, str(EVAL_DIR))
SPEC = importlib.util.spec_from_file_location("audit_qwen3_language_evidence", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def legacy_row(
    case_id: str,
    language: str,
    language_kept: bool,
    meaning_ok: bool,
    polish_ok: bool,
) -> dict[str, object]:
    return {
        "id": case_id,
        "lang": language,
        "input": f"synthetic input {case_id}",
        "judge": {
            "id": case_id,
            "language_kept": language_kept,
            "meaning_ok": meaning_ok,
            "polish_ok": polish_ok,
        },
    }


class Qwen3LanguageEvidenceAuditTests(unittest.TestCase):
    def test_legacy_rejudge_replaces_only_the_pinned_language_slice(self) -> None:
        rows = [
            legacy_row("de-1", "de", True, True, True),
            legacy_row("hi-1", "hi", False, False, False),
        ]
        replacements = [legacy_row("hi-1", "hi", True, True, False)]

        corrected = MODULE.replace_language_slice(
            rows, replacements, "hi", "synthetic_rejudge"
        )
        _, raw = MODULE.aggregate_legacy(corrected, "synthetic_legacy")

        self.assertEqual(raw["de"]["strict_conjunction"], 1)
        self.assertEqual(raw["hi"]["language_kept"], 1)
        self.assertEqual(raw["hi"]["meaning_ok"], 1)
        self.assertEqual(raw["hi"]["polish_ok"], 0)
        self.assertEqual(raw["hi"]["strict_conjunction"], 0)

    def test_type_b_metrics_keep_pass_like_and_three_green_separate(self) -> None:
        rows = [
            {
                "id": "safe-1",
                "behavior": "list_format",
                "behavior_correct": True,
                "meaning_preserved": True,
                "clean_output": True,
                "severity": "S1",
                "verdict": "minor",
            },
            {
                "id": "safe-2",
                "behavior": "list_format",
                "behavior_correct": False,
                "meaning_preserved": True,
                "clean_output": False,
                "severity": "S3",
                "verdict": "major_fail",
            },
            {
                "id": "safe-3",
                "behavior": "grammar_fix",
                "behavior_correct": True,
                "meaning_preserved": True,
                "clean_output": True,
                "severity": "S2",
                "verdict": "soft_fail",
            },
        ]

        counts = MODULE.type_b_counts(rows, "synthetic_type_b")

        self.assertEqual(counts["judge_pass_like"], 1)
        self.assertEqual(counts["strict_three_green"], 2)
        self.assertEqual(counts["s3_s4_judge_severity"], 1)
        self.assertEqual(counts["list_strict_three_green"], 1)
        self.assertEqual(counts["list_s3_s4_with_meaning_preserved"], 1)
        self.assertEqual(counts["list_s3_s4_with_behavior_incorrect"], 1)

    def test_family_exposure_uses_transitive_components(self) -> None:
        corpus = [
            {"id": "case-a", "origin": "case-b", "asr_input": "alpha"},
            {"id": "case-b", "origin": "family-c", "asr_input": "bravo"},
            {"id": "case-d", "origin": "family-d", "asr_input": "charlie"},
        ]
        training = [
            {"id": "case-a", "input": "alpha", "output": "safe"},
            {"id": "train-punctuation", "input": "CHARLIE!", "output": "safe"},
        ]

        counts = MODULE.leakage_counts(corpus, training)

        self.assertEqual(counts["exact_id_overlap"], 1)
        self.assertEqual(counts["simple_normalized_input_overlap"], 1)
        self.assertEqual(counts["conservative_normalized_input_overlap"], 2)
        self.assertEqual(counts["id_origin_family_exposed"], 2)
        self.assertEqual(counts["normalized_seeded_family_exposed"], 3)

    def test_mechanical_counts_are_recomputed_from_pinned_candidates(self) -> None:
        spec = {"model_id": "base", "prompt_sha256": "prompt"}
        twoitem = [
            {
                "id": "two-1",
                "input": "alpha and beta",
                "output": "- Alpha\n- Beta",
                "required": ["alpha", "beta"],
                "forbidden": ["filler"],
                "model_id": "base",
                "prompt_sha256": "prompt",
            }
        ]
        positive = [
            {
                "id": "positive-1",
                "input": "alpha and beta",
                "output": "- Alpha\n- Beta",
                "item_count": 2,
                "model_id": "base",
                "prompt_sha256": "prompt",
            }
        ]
        traps = [
            {
                "id": "trap-1",
                "input": "alpha and beta",
                "output": "Alpha and beta.",
                "model_id": "base",
                "prompt_sha256": "prompt",
            }
        ]

        self.assertEqual(
            MODULE.recompute_twoitem_counts([twoitem], "synthetic_twoitem", spec),
            {
                "total": 1,
                "strict": 1,
                "structure_ok": 1,
                "required_ok": 1,
                "forbidden_ok": 1,
            },
        )
        self.assertEqual(
            MODULE.recompute_overflow_counts(
                positive, traps, "synthetic_overflow", spec
            ),
            {
                "positive_total": 1,
                "activated": 1,
                "intended_count": 1,
                "trap_total": 1,
                "false_lists": 0,
            },
        )

    def test_privacy_guard_rejects_case_text_fields(self) -> None:
        with self.assertRaises(MODULE.AuditError):
            MODULE.assert_private_safe({"metrics": {"raw_transcript": "sentinel"}})

    def test_small_samples_show_wide_uncertainty(self) -> None:
        interval = MODULE.wilson_95(8, 8)
        self.assertLess(interval[0], 0.7)
        self.assertEqual(interval[1], 1.0)

    def test_base_run_005_parser_extracts_only_published_aggregates(self) -> None:
        text = """
### BASE-RUN-005 - Independent universal-base semantic ranking
| Qwen3 4B | 54/56 | 52/56 | 28/56 | 45/56 | 7 | 26/56 |
| German | 5 | 8 | 6 |
| Spanish | 4 | 4 | 3 |
| French | 4 | 4 | 6 |
| Portuguese | 1 | 0 | 0 |
| Hindi | 4 | 2 | 3 |
| Japanese | 5 | 5 | 3 |
| Chinese | 6 | 5 | 5 |
Qwen3 had 13/20 meaning safety, seven damaging rows, and 3/20 strict.
### ARCH-003
"""

        result = MODULE.parse_base_run_005(text)

        self.assertEqual(result["overall"]["damaging"], 7)
        self.assertEqual(result["strict_by_language"]["de"], 6)
        self.assertEqual(result["strict_by_language"]["fr"], 6)
        self.assertEqual(result["strict_by_language"]["es"], 3)
        self.assertEqual(result["english_twoitem"]["strict"], 3)

    def test_failed_rerun_removes_previous_pass_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "report.json"
            output.write_text('{"audit_status":"pass"}\n', encoding="utf-8")

            with contextlib.redirect_stderr(io.StringIO()):
                result = MODULE.main(
                    [
                        "--contract",
                        str(root / "missing-contract.json"),
                        "--output",
                        str(output),
                    ]
                )

            self.assertEqual(result, 2)
            self.assertFalse(output.exists())

    def test_successful_report_write_is_atomic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            output.write_text('{"audit_status":"old"}\n', encoding="utf-8")
            original_replace = Path.replace

            with (
                mock.patch.object(MODULE.os, "fsync", wraps=MODULE.os.fsync) as fsync,
                mock.patch.object(
                    Path,
                    "replace",
                    autospec=True,
                    side_effect=original_replace,
                ) as replace,
            ):
                MODULE.write_report_atomic(output, '{"audit_status":"pass"}\n')

            self.assertEqual(
                output.read_text(encoding="utf-8"),
                '{"audit_status":"pass"}\n',
            )
            fsync.assert_called_once()
            replace.assert_called_once()
            temporary, destination = replace.call_args.args
            self.assertEqual(temporary.parent, output.parent)
            self.assertEqual(destination, output)
            self.assertEqual(list(output.parent.glob(".*.tmp-*")), [])


if __name__ == "__main__":
    unittest.main()
