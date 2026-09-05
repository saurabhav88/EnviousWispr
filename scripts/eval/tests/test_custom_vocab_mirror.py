#!/usr/bin/env python3
"""Regression tests for the CUSTOM VOCABULARY mirror in acceptance_gate.py (#2609).

Production renders the block through `CustomVocabularyFormatter.render`, which
sorts the words by `(priority, canonical)` before emitting a line per word. The
Python mirror iterated `DEFAULT_CUSTOM_VOCAB` in declaration order, so the gate
measured a system prompt in which `EnviousWispr` led the list while every user
received one led by `API`. Same class as the #1255 prompt-body drift, one layer
down: a byte-identical prompt body above a differently ordered vocab block is
still a different prompt.

Run from repo root:
  python3 scripts/eval/tests/test_custom_vocab_mirror.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import acceptance_gate as gate  # noqa: E402

# Mirrors `CustomWord.init(priority: Int = 0)`: every `builtinDefaults` entry
# takes the default, so production's `(priority, canonical)` key collapses to
# `(0, canonical)` for the whole shipped list.
BUILTIN_PRIORITY = 0

_ALIAS_MARKER = " (may be misheard as: "


def _rendered_canonicals(block: str) -> list[str]:
    """The canonical of each `- ...` line, in the order the block emits them."""
    header, *lines = block.split("\n")
    assert header == gate.CUSTOM_VOCAB_HEADER, header
    out = []
    for line in lines:
        assert line.startswith("- "), line
        out.append(line[2:].split(_ALIAS_MARKER, 1)[0])
    return out


class CustomVocabMirrorTests(unittest.TestCase):
    def test_first_entry_is_api_like_production(self) -> None:
        # The concrete symptom from #2609: production emits `API` first, the
        # gate emitted `EnviousWispr` first.
        self.assertEqual(_rendered_canonicals(gate.render_custom_vocab())[0], "API")

    def test_render_order_matches_swift_priority_canonical_sort(self) -> None:
        expected = [
            canonical
            for canonical, _aliases in sorted(
                gate.DEFAULT_CUSTOM_VOCAB,
                key=lambda entry: (BUILTIN_PRIORITY, entry[0]),
            )
        ]
        self.assertEqual(_rendered_canonicals(gate.render_custom_vocab()), expected)
        # Nothing was dropped or duplicated by sorting.
        self.assertEqual(len(expected), len(gate.DEFAULT_CUSTOM_VOCAB))

    def test_canonicals_stay_within_ascii_so_python_and_swift_sort_alike(self) -> None:
        # Swift's String `<` compares Unicode scalars after canonical
        # normalization; Python's str `<` compares raw code points. Those agree
        # on ASCII (case-sensitive, uppercase before lowercase, so
        # "VS Code" < "iOS" < "macOS") but can diverge on precomposed vs
        # decomposed non-ASCII forms. The mirror's sort is only provably
        # production-identical while every canonical is ASCII, so a non-ASCII
        # addition must fail here rather than silently reorder the block.
        for canonical, _aliases in gate.DEFAULT_CUSTOM_VOCAB:
            self.assertTrue(canonical.isascii(), f"non-ASCII canonical: {canonical!r}")


EXPECTED_TESTS = 3


def _main() -> int:
    """Run the suite, but refuse to report success on a shrunken one (#2013).

    `unittest.main()` exits 0 when it discovers ZERO tests, so wiring this into CI
    without a count assertion would buy a green check that means nothing.
    """
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    found = suite.countTestCases()
    if found != EXPECTED_TESTS:
        print(f"FAIL: discovered {found} tests, expected {EXPECTED_TESTS}")
        return 1
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(_main())
