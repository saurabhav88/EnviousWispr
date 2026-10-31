#!/usr/bin/env python3
"""Regression tests for the PREAMBLE-STRIP mirror in acceptance_gate.py (#2795).

Production strips an assistant wrapper line through Swift `String.strippingLLMPreamble`
(LLMProtocol.swift); the tier-bench judges cloud candidates through the Python mirror
`_strip_llm_preamble_python`, so the two must agree or the benchmark measures text no
user receives. The rows below are the Swift suite's rows (PreambleStrippingTests) and
must stay in step with them: add a row THERE, add it HERE.

Run from repo root:
  python3 scripts/eval/tests/test_preamble_mirror.py
"""
from __future__ import annotations

import sys
import json
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from acceptance_gate import _strip_llm_preamble_python  # noqa: E402

ROWS = [
    # wrapper lines strip
    ("Here is the corrected version:\nThe actual text.", "The actual text."),
    ("Below is the cleaned transcript:\nHello world.", "Hello world."),
    ("The corrected text:\nFixed version here.", "Fixed version here."),
    ("Corrected version:\nFixed.", "Fixed."),
    ("Here is the cleaned transcript:\nCall.", "Call."),
    ("Sure! Here is the cleaned transcript:\nCall.", "Call."),
    ("Here's the cleaned up text:\nCall.", "Call."),
    ("Below is your transcript:\nCall.", "Call."),
    ("Here is the revised transcript:\nHello.", "Hello."),
    ("Here is the updated text:\nHello.", "Hello."),
    ("Here is the final version:\nHello.", "Hello."),
    # dictated lead-ins survive (#2795)
    ("Here are the things we should do before lunch:\n- Call.",
     "Here are the things we should do before lunch:\n- Call."),
    ("Below the fold, three items:\n- One.", "Below the fold, three items:\n- One."),
    ("Here are the conversion steps:\n- Open Settings.", "Here are the conversion steps:\n- Open Settings."),
    ("Here are the textile suppliers:\n- One.", "Here are the textile suppliers:\n- One."),
    # untouched content
    ("Summary:\nThe project is on track.", "Summary:\nThe project is on track."),
    ("Sure enough it worked.", "Sure enough it worked."),
]


SOURCE_ROWS = [
    ("sure I can do that tomorrow", "Sure, I can do that tomorrow.", "Sure, I can do that tomorrow."),
    ("I can do that tomorrow", "Sure, I can do that tomorrow.", "I can do that tomorrow."),
    ("got it I will send the file tonight", "Got it. I will send the file tonight.", "Got it. I will send the file tonight."),
    ("please send the file", "Got it. I will send the file tonight.", "I will send the file tonight."),
    ("the corrected numbers for q3 are revenue four million", "The corrected numbers for Q3 are:\n- Revenue four million", "The corrected numbers for Q3 are:\n- Revenue four million"),
    ("here’s the cleaned text for the report", "Here's the cleaned text:\nThe report is ready.", "Here's the cleaned text:\nThe report is ready."),
    ("sure send the invoice today", "Sure! Here is the cleaned transcript:\nSure, send the invoice today.", "Sure! Here is the cleaned transcript:\nSure, send the invoice today."),
]


class PreambleMirrorTests(unittest.TestCase):
    def test_existing_candidates_and_added_chatter(self):
        self.assertGreater(len(ROWS), 0)
        for text, expected in ROWS:
            with self.subTest(text=text):
                self.assertEqual(_strip_llm_preamble_python(
                    text, "please send the invoice", strip_transcript_tags=False), expected)

    def test_source_preservation_pairs(self):
        for source, text, expected in SOURCE_ROWS:
            with self.subTest(source=source):
                self.assertEqual(_strip_llm_preamble_python(text, source, strip_transcript_tags=False), expected)

    def test_uncertain_source_preserves(self):
        for source in ("", "...", "\u0301send the invoice"):
            with self.subTest(source=source):
                self.assertEqual(_strip_llm_preamble_python("Sure, send the invoice.", source, False),
                                 "Sure, send the invoice.")

    def test_packed_outer_and_each_members_own_source(self):
        import run_cloud_type_b as runner
        originals = ["please send the final report tomorrow", "sure I can do that tomorrow",
                     "I will send the file tonight"]
        reply = ("Certainly! Here is the cleaned transcript:\n"
                 "<s1>Please send the final report tomorrow.</s1>\n"
                 "<s2>Sure, I can do that tomorrow.</s2>\n"
                 "<s3>Sure, I will send the file tonight.</s3>")
        with patch.object(runner, 'call_once', return_value=(reply, {})) as call:
            summary, rows = runner.polish_pack(
                provider='openai', model='gpt-6.1-sol', api_key='fixture',
                pack={'section_ids': ['one', 'two', 'three']},
                texts=dict(zip(['one', 'two', 'three'], originals)))
        self.assertEqual(call.call_count, 1)
        self.assertEqual(summary['outcome'], 'unwrapped')
        self.assertEqual([row['candidate'] for row in rows],
                         ['Please send the final report tomorrow.', 'Sure, I can do that tomorrow.',
                          'I will send the file tonight.'])

    def test_tier_path_does_not_strip_processed_http_output_again(self):
        import acceptance_gate as gate
        raw = "Here is the cleaned transcript:\nThe cleaned text:\nPlease send the invoice."
        expected = "The cleaned text:\nPlease send the invoice."
        class ReachedValidator(Exception):
            pass
        def inspect(candidates, cases, provider):
            self.assertEqual(candidates, {"one": expected})
            self.assertEqual(provider, "gpt-4o-mini")
            raise ReachedValidator
        with tempfile.TemporaryDirectory() as directory:
            corpus = Path(directory) / "cases.jsonl"
            corpus.write_text(json.dumps({"id": "one", "asr_input": "please send the invoice"}) + "\n")
            with patch.object(gate, "OUT_DIR", Path(directory)), \
                 patch.object(gate, "_preflight_judge"), \
                 patch.object(gate, "call_openai", return_value=raw) as call, \
                 patch.object(gate, "_apply_validator", side_effect=inspect):
                with self.assertRaises(ReachedValidator):
                    gate.mode_tier_bench(["gpt-4o-mini"], corpus, "offline", None, "")
            self.assertEqual(call.call_count, 1)

    def test_source_normalization_does_not_rewrite_output(self):
        output = "The corrected re\u0301sume\u0301:\nThe report is ready."
        self.assertEqual(_strip_llm_preamble_python(output, "the corrected résumé is ready", False), output)
        literal = "<transcript>Hello world</transcript>"
        self.assertEqual(_strip_llm_preamble_python(literal, "Hello world", False), literal)
        self.assertEqual(_strip_llm_preamble_python(literal, "Hello world", True), "Hello world")


if __name__ == "__main__":
    unittest.main()
