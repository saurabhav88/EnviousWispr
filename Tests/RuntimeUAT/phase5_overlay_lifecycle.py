"""Identify the overlay window by LIFECYCLE, and refuse when it is not unique.

#2377 chunk 6. Shared by every row that measures a pill, so there is ONE answer
to "which window is that".

**Size, layer and enumeration order are all properties an unrelated window can
have**, so choosing by any of them returns a confident answer for the wrong
window. The lifecycle question has a checkable answer: the overlay APPEARED when
the recording started and was GONE after it stopped. Both halves are required —
appearance alone admits any window that opened during the take, and the
disappearance is what ties a candidate to the recording.

More than one such window returns `AMBIGUOUS` and the caller must refuse, per
tools-and-apps.md RULE: a-harness-that-ACTS-on-a-shared-resource-must-refuse-not-choose.
A wrong refusal costs a rerun; a wrong pick silently retargets the measurement.

Pure and dependency-free: it takes three sets of window ids and no Quartz, so
`phase5_overlay_lifecycle_test.py` can drive every verdict — including
`AMBIGUOUS`, which cannot be staged against a live app on demand.
"""

OK = "OK"
NONE = "NONE"
AMBIGUOUS = "AMBIGUOUS"


def classify(before, during, after):
    """Return `(window_id_or_None, verdict)`.

    `before` / `during` / `after` are iterables of window ids visible at each
    phase. A window counts only if it is absent before, present during, and
    absent after.
    """
    before, during, after = set(before), set(during), set(after)
    appeared = during - before
    lifecycle = appeared - after
    if not lifecycle:
        return None, NONE
    if len(lifecycle) > 1:
        return None, AMBIGUOUS
    return next(iter(lifecycle)), OK


def describe(before, during, after):
    """The classifier's verdict plus the evidence behind it, for a report.

    Every candidate is preserved rather than only the winner. A report that keeps
    just the chosen id cannot be re-adjudicated later, and an `AMBIGUOUS` verdict
    is worth nothing to the next reader without the ids that produced it.
    """
    before, during, after = set(before), set(during), set(after)
    appeared = sorted(during - before)
    lifecycle = sorted(set(appeared) - after)
    wid, verdict = classify(before, during, after)
    return {
        "window_id": wid,
        "verdict": verdict,
        "appeared": appeared,
        "appeared_and_gone": lifecycle,
        "still_present_after": sorted(set(appeared) & after),
    }
