from __future__ import annotations

import contextlib
import io
import importlib.util
import json
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


def base_run_005_fixture() -> tuple[dict[str, object], dict[str, object]]:
    source = {
        "path": "docs/experiment-log.md",
        "producing_commit": "2" * 40,
        "git_blob_oid": "3" * 40,
        "sha256": "4" * 64,
        "section_start": "### BASE-RUN-005 - Independent universal-base semantic ranking",
        "section_end": "### ARCH-003",
        "section_payload_sha256": "5" * 64,
    }
    receipt: dict[str, object] = {
        "schema_version": "qwen3-base-run-005-aggregate-v1",
        "source": source,
        "aggregate": {
            "overall": {
                "total": 56,
                "same_language": 54,
                "meaning_safe": 52,
                "cleanup": 28,
                "grammar": 45,
                "damaging": 7,
                "strict": 26,
            },
            "strict_by_language": {
                "de": 6,
                "es": 3,
                "fr": 6,
                "pt": 0,
                "hi": 3,
                "ja": 3,
                "zh": 5,
            },
            "english_twoitem": {
                "total": 20,
                "meaning_safe": 13,
                "damaging": 7,
                "strict": 3,
            },
        },
    }
    spec: dict[str, object] = {
        "source_path": source["path"],
        "source_commit": source["producing_commit"],
        "source_git_blob_oid": source["git_blob_oid"],
        "source_sha256": source["sha256"],
        "source_section_start": source["section_start"],
        "source_section_end": source["section_end"],
        "source_section_payload_sha256": source["section_payload_sha256"],
    }
    return receipt, spec


class Qwen3LanguageEvidenceAuditTests(unittest.TestCase):
    def test_immutable_receipt_survives_later_live_log_without_git_history(self) -> None:
        receipt, spec = base_run_005_fixture()
        relative = Path("docs/receipts/base-run-005.json")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            live_log = root / str(spec["source_path"])
            receipt_path = root / relative
            live_log.parent.mkdir(parents=True)
            receipt_path.parent.mkdir(parents=True)
            live_log.write_text("old evidence\n### LATER-RUN\nnew evidence\n", encoding="utf-8")
            payload = json.dumps(receipt, sort_keys=True).encode("utf-8")
            receipt_path.write_bytes(payload)
            spec.update(
                {
                    "path": relative.as_posix(),
                    "sha256": MODULE.sha256_bytes(payload),
                    "format": "json",
                }
            )

            loaded = MODULE.load_source(root, "base_run_005_receipt", spec)
            parsed = MODULE.parse_base_run_005_receipt(loaded, spec)

            self.assertFalse((root / ".git").exists())
            self.assertIn("LATER-RUN", live_log.read_text(encoding="utf-8"))
            self.assertEqual(parsed["overall"]["strict"], 26)

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

    def test_base_run_005_receipt_validates_provenance_and_counts(self) -> None:
        receipt, spec = base_run_005_fixture()

        result = MODULE.parse_base_run_005_receipt(receipt, spec)

        self.assertEqual(result["overall"]["damaging"], 7)
        self.assertEqual(result["strict_by_language"]["de"], 6)
        self.assertEqual(result["strict_by_language"]["fr"], 6)
        self.assertEqual(result["strict_by_language"]["es"], 3)
        self.assertEqual(result["english_twoitem"]["strict"], 3)

        receipt["source"]["producing_commit"] = "6" * 40
        with self.assertRaises(MODULE.AuditError):
            MODULE.parse_base_run_005_receipt(receipt, spec)

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
