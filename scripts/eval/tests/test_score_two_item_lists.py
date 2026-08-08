#!/usr/bin/env python3
"""Exact-structure tests for the legacy two-item list scorer."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


EVAL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL_DIR))

import score_two_item_lists as scorer  # noqa: E402


class TwoItemStructureTests(unittest.TestCase):
    def test_bare_two_bullet_list_passes(self) -> None:
        self.assertTrue(scorer.structure_ok("- first\n- second")[0])

    def test_header_before_two_bullets_passes(self) -> None:
        self.assertTrue(scorer.structure_ok("Tasks:\n- first\n- second")[0])

    def test_trailing_header_or_prose_fails(self) -> None:
        self.assertFalse(scorer.structure_ok("- first\n- second\nNote:")[0])
        self.assertFalse(scorer.structure_ok("- first\n- second\nExtra prose.")[0])


if __name__ == "__main__":
    unittest.main()
