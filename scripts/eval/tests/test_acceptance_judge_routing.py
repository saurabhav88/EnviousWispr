#!/usr/bin/env python3
"""#4234: acceptance must refuse unfunded judges before any generation."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

EVAL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL))
import acceptance_gate as gate


class StopGeneration(BaseException):
    pass


class FundedAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.corpus = self.root / 'corpus.jsonl'
        self.corpus.write_text(json.dumps({'id': 'one', 'asr_input': 'please send the invoice tomorrow',
                                          'category': 'clean', 'primary_tier': 'faithful'}) + '\n')
        self.baseline = self.root / 'gpt-4o-mini.json'
        self.baseline.write_text(json.dumps({'baseline': {'one': 'Please send the invoice tomorrow.'}}))
        self.golden = self.root / 'golden.json'
        self.golden.write_text(json.dumps({'judge_model': gate.APPROVED_JUDGE_MODEL, 'cases': {}}))
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        for name, value in [('CORPUS', self.corpus), ('BASELINE_DIR', self.root),
                            ('GOLDEN_FILE', self.golden), ('OUT_DIR', self.root / 'out')]:
            self.stack.enter_context(patch.object(gate, name, value))
        self.stack.enter_context(patch.dict(os.environ, {}, clear=True))
        self.stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.stack.enter_context(contextlib.redirect_stderr(io.StringIO()))

    def entries(self):
        return [lambda: gate.mode_run('gpt-4o-mini', 'run'),
                lambda: gate.mode_meta_test('gpt-4o-mini'),
                lambda: gate.mode_bench('bench', self.corpus, 0),
                lambda: gate.mode_tier_bench(['gpt-4o-mini'], self.corpus, 'tier', None, None)]

    def test_dispatch_preserves_payload_and_has_no_direct_fallback(self):
        with patch.object(gate.funded_judge, 'dispatch_judge', return_value='[]') as dispatch:
            self.assertEqual(gate._dispatch_judge(gate.APPROVED_JUDGE_MODEL, 'rubric', 'cases', True), '[]')
            dispatch.assert_called_once_with(gate.APPROVED_JUDGE_MODEL, 'rubric', 'cases')
            for model in ['gemini-3.1-pro-preview', 'gpt-4o', 'claude-sonnet-4-6', 'azure/unknown', '']:
                with self.subTest(model=model), self.assertRaises(SystemExit) as error:
                    gate._dispatch_judge(model, 'rubric', 'cases', True)
                self.assertEqual(error.exception.code, 2)
            self.assertEqual(dispatch.call_count, 1)

    def test_preflight_resolves_identity_once_and_refuses_inherited_context(self):
        with patch.object(gate.funded_judge, 'judge_identity', return_value='azure/gpt-5-6-luna@served') as identity:
            self.assertEqual(gate._preflight_judge(gate.APPROVED_JUDGE_MODEL), 'azure/gpt-5-6-luna@served')
            identity.assert_called_once_with(gate.APPROVED_JUDGE_MODEL)
            for key in ['EW_AZURE_PINNED_MODEL', 'EW_JUDGE_IDENTITY']:
                with patch.dict(os.environ, {key: ''}), self.assertRaises(SystemExit):
                    gate._preflight_judge(gate.APPROVED_JUDGE_MODEL)
            self.assertEqual(identity.call_count, 1)

    def test_all_scoring_modes_stop_before_generation_on_preflight_failure(self):
        with patch.object(gate.funded_judge, 'judge_identity', side_effect=RuntimeError('unavailable')), \
             patch.object(gate, 'polish_one') as single, \
             patch.object(gate, '_http_polish_all') as batch, \
             patch.object(gate, 'judge_chunk') as judge:
            for entry in self.entries():
                with self.assertRaises(SystemExit) as error:
                    entry()
                self.assertEqual(error.exception.code, 2)
            single.assert_not_called(); batch.assert_not_called(); judge.assert_not_called()

    def test_valid_scoring_entries_resolve_once_before_work(self):
        with patch.object(gate.funded_judge, 'judge_identity', return_value='azure/gpt-5-6-luna@served') as identity, \
             patch.object(gate, 'polish_one', side_effect=StopGeneration), \
             patch.object(gate, '_http_polish_all', side_effect=StopGeneration):
            for entry in self.entries():
                before = identity.call_count
                try:
                    entry()
                except StopGeneration:
                    pass
                self.assertEqual(identity.call_count, before + 1)

    def test_golden_mismatch_does_not_probe(self):
        self.golden.write_text(json.dumps({'judge_model': 'old-judge', 'cases': {}}))
        with patch.object(gate.funded_judge, 'judge_identity') as identity:
            self.assertEqual(gate.mode_meta_test('gpt-4o-mini'), 2)
            identity.assert_not_called()

    def test_run_report_carries_served_identity(self):
        scores = [{'id': 'one', 'accuracy': 3, 'conciseness': 3, 'fluency': 3, 'format': 3, 'regression': 2}]
        with patch.object(gate.funded_judge, 'judge_identity', return_value='azure/gpt-5-6-luna@served'), \
             patch.object(gate, 'polish_one', return_value='Please send the invoice tomorrow.'), \
             patch.object(gate, 'judge_chunk', return_value=scores):
            self.assertEqual(gate.mode_run('gpt-4o-mini', 'run'), 0)
        report = json.loads((self.root / 'out/run/report.json').read_text())
        self.assertEqual(report['judge_identity'], 'azure/gpt-5-6-luna@served')
        self.assertEqual(report['judge_model'], gate.APPROVED_JUDGE_MODEL)

    def test_import_and_selftest_are_key_free(self):
        program = '''
import pathlib, subprocess, sys, urllib.request
sys.path.insert(0, sys.argv[1])
def forbidden(*args, **kwargs): raise AssertionError("external side effect")
urllib.request.urlopen = forbidden
subprocess.run = subprocess.Popen = forbidden
import acceptance_gate as g
g._key = g.funded_judge._key = forbidden
g._selftest_mirrors()
g._selftest_afm_arm_env()
'''
        result = subprocess.run([sys.executable, '-c', program, str(EVAL)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
