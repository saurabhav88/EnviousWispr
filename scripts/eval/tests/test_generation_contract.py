#!/usr/bin/env python3
"""Tests for model-generation settings that must survive the generic runner."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace


EVAL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL_DIR))

from generation_contract import resolve_eos_token_id  # noqa: E402


class GenerationContractTests(unittest.TestCase):
    def test_preserves_publisher_eos_list(self) -> None:
        config = SimpleNamespace(eos_token_id=[200020, 199999])
        self.assertEqual(resolve_eos_token_id(config, 199999), [200020, 199999])

    def test_preserves_publisher_single_eos(self) -> None:
        config = SimpleNamespace(eos_token_id=151645)
        self.assertEqual(resolve_eos_token_id(config, 151643), 151645)

    def test_falls_back_when_publisher_eos_is_missing(self) -> None:
        self.assertEqual(resolve_eos_token_id(SimpleNamespace(), 2), 2)
        self.assertEqual(
            resolve_eos_token_id(SimpleNamespace(eos_token_id=None), 2), 2
        )


if __name__ == "__main__":
    unittest.main()
