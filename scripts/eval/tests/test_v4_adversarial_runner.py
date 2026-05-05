#!/usr/bin/env python3
"""Focused regression tests for v4_adversarial_runner.py."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import v4_adversarial_runner as runner


class V4AdversarialRunnerTests(unittest.TestCase):
    def test_missing_secret_aborts_provider_instead_of_recording_case_error(self) -> None:
        original_polish_one = runner.polish_one
        original_short_bypass = runner._is_short_input_bypass
        try:
            runner._is_short_input_bypass = lambda _text: False

            def raise_missing_secret(_provider: str, _text: str) -> str:
                raise runner.MissingSecretError("Missing key file: fake")

            runner.polish_one = raise_missing_secret
            cases = [{"id": "CASE-1", "asr_input": "please polish this sentence"}]

            with tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(runner.MissingSecretError):
                    runner.polish_provider("gpt-4o-mini", cases, Path(tmp))

                out_path = Path(tmp) / "candidates" / "gpt-4o-mini.jsonl"
                self.assertEqual(out_path.read_text(encoding="utf-8"), "")
        finally:
            runner.polish_one = original_polish_one
            runner._is_short_input_bypass = original_short_bypass

    def test_flagged_cases_include_non_passing_error_and_tie_majorities(self) -> None:
        cases = [
            {
                "id": "PASS",
                "category": "benign",
                "persona": "engineer",
                "asr_input": "normal dictated text",
            },
            {
                "id": "JUDGE-NONPASS",
                "category": "payload_social",
                "persona": "adversary",
                "asr_input": "normal dictated text",
            },
        ]
        cands = {
            "PASS": "normal dictated text",
            "JUDGE-NONPASS": "normal dictated text",
        }
        provider_votes = {
            "gemini-3-pro-preview": {
                "PASS": [{"verdict": "RESISTED"}],
                "JUDGE-NONPASS": [{"verdict": "ERROR"}],
            },
            "gpt-5.4-2026-03-05": {
                "PASS": [{"verdict": "RESISTED"}],
                "JUDGE-NONPASS": [
                    {"verdict": "FOLLOWED"},
                    {"verdict": "RESISTED"},
                    {"verdict": "ERROR"},
                ],
            },
        }

        report = runner.aggregate_provider_report("gpt-4o-mini", cases, cands, provider_votes)

        self.assertEqual(report["overall_pass"], 1)
        self.assertEqual(report["flagged_cases"], ["JUDGE-NONPASS"])
        self.assertEqual(
            report["per_case"]["JUDGE-NONPASS"]["judge_majorities"],
            {
                "gemini-3-pro-preview": "ERROR",
                "gpt-5.4-2026-03-05": "TIE",
            },
        )
        self.assertFalse(report["per_case"]["JUDGE-NONPASS"]["overall_pass"])


if __name__ == "__main__":
    unittest.main()
