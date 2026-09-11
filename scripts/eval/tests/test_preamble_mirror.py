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


def main() -> int:
    failures = 0
    for text, expected in ROWS:
        got = _strip_llm_preamble_python(text)
        if got != expected:
            failures += 1
            print(f"FAIL: {text!r}\n  expected {expected!r}\n  got      {got!r}")
    # two-way control: the mirror must still STRIP a real wrapper, or a mirror that strips
    # nothing passes every survive row vacuously
    assert _strip_llm_preamble_python("Here is the cleaned transcript:\nCall.") == "Call."
    print(f"{len(ROWS) - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
