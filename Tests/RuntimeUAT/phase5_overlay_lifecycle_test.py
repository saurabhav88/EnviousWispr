"""Two-way control for the lifecycle classifier (#2377 chunk 6, C6A).

Every verdict is asserted, INCLUDING the ones a live app cannot be made to
produce on demand. `AMBIGUOUS` is the reason this file exists: two windows
appearing and vanishing together is exactly the case the classifier was written
to refuse, and there is no way to stage it against the real app — so a suite that
only ever ran live would leave the refusal branch unexecuted and indistinguishable
from a branch that does not work.

Paired rows throughout: every accepted case sits beside a near-identical rejected
one, so a classifier that stopped classifying anything cannot read as clean.

Run: `python3 Tests/RuntimeUAT/phase5_overlay_lifecycle_test.py`
"""

import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import phase5_overlay_lifecycle as lc  # noqa: E402

CASES = [
    # (name, before, during, after, expected_id, expected_verdict)
    ("the ordinary pill: appears with the recording, gone after",
     [1], [1, 99], [1], 99, lc.OK),

    # PAIRED REJECTION for the row above: identical except the window outlives
    # the recording, so it was never the pill.
    ("a window that appears and STAYS is not the overlay",
     [1], [1, 99], [1, 99], None, lc.NONE),

    ("a window present all along is not the overlay",
     [1, 99], [1, 99], [1, 99], None, lc.NONE),

    ("nothing appeared at all",
     [1], [1], [1], None, lc.NONE),

    # THE CASE THAT CANNOT BE STAGED LIVE. Two windows share the whole
    # lifecycle, so no property distinguishes them and the classifier must
    # refuse rather than return either.
    ("two windows appear and vanish together: refuse",
     [1], [1, 98, 99], [1], None, lc.AMBIGUOUS),

    ("three candidates refuse just as two do",
     [], [7, 8, 9], [], None, lc.AMBIGUOUS),

    # PAIRED ACCEPTANCE for the row above: one of the three outlives the take,
    # one was already there, so exactly one satisfies the lifecycle.
    ("several appear but only one is gone afterwards",
     [8], [7, 8, 9], [8, 9], 7, lc.OK),

    ("the overlay is found even when the id space is reused across launches",
     [68450], [68450, 68541], [68450], 68541, lc.OK),
]


def main():
    failures = []
    for name, before, during, after, want_id, want_verdict in CASES:
        got_id, got_verdict = lc.classify(before, during, after)
        if (got_id, got_verdict) != (want_id, want_verdict):
            failures.append(
                f"{name}: expected ({want_id}, {want_verdict}), got ({got_id}, {got_verdict})")

    # `describe` must agree with `classify` and must preserve the evidence, or an
    # AMBIGUOUS report is unreadable by whoever has to adjudicate it.
    d = lc.describe([1], [1, 98, 99], [1])
    if d["verdict"] != lc.AMBIGUOUS:
        failures.append(f"describe verdict: expected AMBIGUOUS, got {d['verdict']}")
    if d["appeared_and_gone"] != [98, 99]:
        failures.append(
            f"describe must keep every candidate, got {d['appeared_and_gone']}")

    d2 = lc.describe([1], [1, 99], [1, 99])
    if d2["still_present_after"] != [99]:
        failures.append(
            f"describe must record what outlived the take, got {d2['still_present_after']}")

    for f in failures:
        print(f"FAIL {f}")
    print(f"{len(CASES) + 3 - len(failures)}/{len(CASES) + 3} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
