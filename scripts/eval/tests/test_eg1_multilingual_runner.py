#!/usr/bin/env python3
"""Evidence-integrity tests for the CUDA multilingual experiment runner."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path


EVAL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL_DIR))

import eg1_multilingual_runner as runner  # noqa: E402


class MultilingualRunnerEvidenceTest(unittest.TestCase):
    def test_prepare_output_paths_rejects_result_or_manifest_collision(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output_path = Path(tmp) / "run.jsonl"
            manifest_path = output_path.with_suffix(".jsonl.manifest.json")

            output_path.write_text("prior result\n", encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "Refusing to overwrite"):
                runner.prepare_output_paths(output_path)

            output_path.unlink()
            manifest_path.write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "Refusing to overwrite"):
                runner.prepare_output_paths(output_path)

    def test_write_bound_manifest_hashes_output_and_is_exclusive(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output_path = Path(tmp) / "run.jsonl"
            manifest_path = runner.prepare_output_paths(output_path)
            payload = b'{"id":"synthetic"}\n'
            output_path.write_bytes(payload)
            manifest = {"schema_version": "synthetic-run-v1"}

            runner.write_bound_manifest(
                manifest, output_path=output_path, manifest_path=manifest_path
            )
            written = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(written["output_sha256"], hashlib.sha256(payload).hexdigest())
            with self.assertRaises(FileExistsError):
                runner.write_bound_manifest(
                    manifest, output_path=output_path, manifest_path=manifest_path
                )


if __name__ == "__main__":
    unittest.main()
