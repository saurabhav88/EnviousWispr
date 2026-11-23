#!/usr/bin/env python3
"""Harness contract tests for search_frames (#4586 PR 0 chunk 2). Literal frames, and records in
exactly the shape m5-speed-ui-search.py run_sequence collects them."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import search_frames as sf  # noqa: E402

TB = (1, 1)   # one tick = one nanosecond, so 1_000_000 ticks = 1 ms
M = 1_000_000


def frames(*rows):
    """rows: (display_ms, hash) complete frames."""
    return [{"display": int(t * M), "status": 0, "hash": h} for t, h in rows]


def rec(query, kind, posted, confirmed, field=None, verdicts=None, post=None, held=None):
    """A driver record (run_sequence): posted/confirmed/held in ms here, ticks in the record."""
    return {"query": query, "kind": kind, "posted": int(posted * M),
            "confirmed": None if confirmed is None else int(confirmed * M),
            "field": query if field is None else field,
            "verdicts": verdicts or {"correct": 2}, "post_verdicts": post or {"correct": 3},
            "held_until": None if held is None else int(held * M)}


def superseded(query, posted, second_posted):
    return {"query": query, "kind": "superseded", "posted": int(posted * M), "second_posted": int(second_posted * M),
            "confirmed": None, "field": None, "verdicts": {}}


REFS = {"": "A", "b": "B", "c": "C"}


def run(f, records, refs=REFS, ended=200, start_held=None):
    sets = {q: {v} if isinstance(v, str) else set(v) for q, v in refs.items()}
    return sf.measure_attempt(records, f, sets, "", int(ended * M), *TB,
                              start_held_until=None if start_held is None else int(start_held * M))


class ReferenceTests(unittest.TestCase):
    def test_reference_is_the_picture_held_for_the_whole_hold(self):
        f = frames((0, "A"), (100, "B"), (150, "B2"))
        self.assertEqual(sf.reference_from_frames(f, int(500 * M), *TB), ("B2", None))

    def test_reference_refused_when_the_picture_changed_inside_the_hold(self):
        f = frames((0, "A"), (100, "B"), (400, "B2"))
        self.assertIsNone(sf.reference_from_frames(f, int(500 * M), *TB)[0])

    def test_reference_refused_without_frames(self):
        self.assertIsNone(sf.reference_from_frames([], int(500 * M), *TB)[0])


class MeasureTests(unittest.TestCase):
    def test_endpoint_is_first_frame_equal_to_the_reference(self):
        f = frames((0, "A"), (8, "A"), (16, "B"), (24, "B"))
        r = run(f, [rec("b", "pasted", 4, 20)], ended=40)[0]
        self.assertEqual((r["result"], r["upper_ms"], r["gap_ms"], r["stale_publication"]), ("timed", 12.0, 8.0, False))

    def test_transitional_picture_before_the_reference_is_not_the_endpoint(self):
        # Rows right at 16 (B0, highlight not yet drawn); the reference B shows at 56.
        f = frames((0, "A"), (16, "B0"), (56, "B"), (64, "B"))
        r = run(f, [rec("b", "pasted", 4, 20)], ended=130)[0]
        self.assertEqual((r["result"], r["upper_ms"]), ("timed", 52.0))

    def test_missing_baseline_refuses_the_attempt(self):
        # Codex repro: no frame before the post used to give a 4 ms timed result.
        f = frames((8, "B"), (16, "B"))
        self.assertEqual([r["result"] for r in run(f, [rec("b", "pasted", 4, 10)], ended=40)], ["unknown"])

    def test_baseline_not_equal_to_the_starting_reference_refuses_the_attempt(self):
        f = frames((0, "X"), (16, "B"))
        self.assertEqual(run(f, [rec("b", "pasted", 4, 20)], ended=40)[0]["result"], "unknown")

    def test_old_page_returning_after_confirmation_fails(self):
        # Codex repro: B confirmed, then the old page A returns during the observation period.
        f = frames((0, "A"), (16, "B"), (30, "A"), (40, "A"))
        r = run(f, [rec("b", "pasted", 4, 20)], ended=60)[0]
        self.assertEqual((r["result"], r["stale_publication"], r["upper_ms"]), ("failed", True, 12.0))

    def test_superseded_picture_before_the_replacement_endpoint_is_ambiguous(self):
        # Driver payload of an overlap step: "b" superseded by "c"; B shows after the replacing post
        # but before C. Pending state is unproven (capture loses frames), so this is unknown.
        f = frames((0, "A"), (20, "B"), (30, "C"), (40, "C"))
        records = [superseded("b", 4, 6), rec("c", "replaced", 6, 35)]
        results = run(f, records, ended=60)
        self.assertEqual(results[0]["supersession"], "pending state unproven; no completion captured")
        self.assertEqual(results[1]["result"], "unknown")

    def test_late_superseded_picture_after_the_replacement_endpoint_fails(self):
        f = frames((0, "A"), (20, "C"), (30, "B"), (40, "C"))
        results = run(f, [superseded("b", 4, 6), rec("c", "replaced", 6, 25)], ended=60)
        self.assertEqual((results[1]["result"], results[1]["stale_publication"]), ("failed", True))

    def test_superseded_query_that_completed_before_the_replacement_is_the_previous_page(self):
        # Control pass 6, Meetings: "b" showed at 70 ms, "c" was posted at 114 ms. B while C loads is
        # the retained previous page, not a late superseded publication.
        f = frames((0, "A"), (70, "B"), (180, "C"), (190, "C"))
        results = run(f, [superseded("b", 0, 114), rec("c", "replaced", 114, 185)], ended=400)
        self.assertEqual(results[0]["supersession"], "completed before the replacing post")
        self.assertEqual((results[1]["result"], results[1]["upper_ms"]), ("timed", 66.0))

    def test_old_page_after_a_completed_superseded_query_still_fails(self):
        # Same, but after C showed, the unfiltered page A (older than B) returns.
        f = frames((0, "A"), (70, "B"), (180, "C"), (200, "A"), (220, "C"))
        r = run(f, [superseded("b", 0, 114), rec("c", "replaced", 114, 185)], ended=400)[1]
        self.assertEqual((r["result"], r["stale_publication"]), ("failed", True))

    def test_a_query_may_have_several_verified_pictures(self):
        # Control pass 6: the unfiltered list drew A or A2 on different visits.
        refs = {"": {"A", "A2"}, "b": "B"}
        f = frames((0, "A2"), (10, "B"), (30, "A"), (40, "A"))
        r = run(f, [rec("b", "pasted", 5, 15), rec("", "cleared", 25, 35)], refs=refs, ended=60)
        self.assertEqual([x["result"] for x in r], ["timed", "timed"])

    def test_in_attempt_held_picture_becomes_verified(self):
        # B2 is not in the reference phase, but it is held while accessibility confirmed "b".
        f = frames((0, "A"), (16, "B2"), (24, "B2"))
        r = run(f, [rec("b", "pasted", 4, 20, held=300)], ended=320)[0]
        self.assertEqual((r["result"], r["upper_ms"], r["held_picture"]), ("timed", 12.0, True))

    def test_held_picture_that_changed_during_the_hold_is_not_verified(self):
        f = frames((0, "A"), (16, "B2"), (250, "B3"))
        r = run(f, [rec("b", "pasted", 4, 20, held=300)], ended=320)[0]
        self.assertEqual((r["result"], r["held_picture"]), ("unknown", False))

    def test_start_held_picture_is_a_valid_baseline(self):
        f = frames((0, "A9"), (316, "B"))
        r = run(f, [rec("b", "pasted", 304, 320)], ended=400, start_held=250)[0]
        self.assertEqual((r["result"], r["upper_ms"]), ("timed", 12.0))

    def test_superseded_picture_shared_with_the_previous_query_is_allowed(self):
        refs = {"": "A", "b": "A", "c": "C"}
        f = frames((0, "A"), (20, "A"), (30, "C"), (40, "C"))
        results = run(f, [superseded("b", 4, 6), rec("c", "replaced", 6, 35)], refs=refs, ended=60)
        self.assertEqual((results[1]["result"], results[1]["stale_publication"]), ("timed", False))

    def test_retained_previous_page_before_endpoint_is_allowed(self):
        f = frames((0, "A"), (10, "A"), (20, "A"), (30, "B"), (40, "B"))
        self.assertEqual(run(f, [rec("b", "pasted", 5, 35)], ended=50)[0]["result"], "timed")

    def test_identical_result_is_no_visible_change_not_a_fast_pass(self):
        refs = {"": "A", "b": "A"}
        f = frames((0, "A"), (10, "A"))
        r = run(f, [rec("b", "typed", 5, 12)], refs=refs, ended=30)[0]
        self.assertEqual(r["result"], "no_visible_change")
        self.assertNotIn("upper_ms", r)

    def test_older_picture_latches_stale_and_keeps_the_endpoint(self):
        f = frames((0, "A"), (10, "B"), (30, "C"), (40, "A"), (50, "C"))
        r = run(f, [rec("b", "typed", 5, 15), rec("c", "typed", 25, 55)], ended=70)[1]
        self.assertEqual((r["result"], r["upper_ms"], r["stale_publication"]), ("failed", 5.0, True))

    def test_stale_frame_overrides_no_visible_change(self):
        refs = {"": "A", "b": "B", "c": "C", "c2": "C"}
        f = frames((0, "A"), (10, "B"), (30, "C"), (50, "A"), (60, "C"))
        records = [rec("b", "typed", 5, 15), rec("c", "typed", 25, 35), rec("c2", "typed", 45, 65)]
        r = run(f, records, refs=refs, ended=80)[2]
        self.assertEqual((r["result"], r["stale_publication"]), ("failed", True))

    def test_picture_shared_by_two_queries_retained_while_the_next_loads_is_allowed(self):
        refs = {"": "A", "b": "B", "b2": "B", "c": "C"}
        f = frames((0, "A"), (10, "B"), (50, "C"), (60, "C"))
        records = [rec("b", "typed", 5, 15), rec("b2", "typed", 25, 30), rec("c", "typed", 45, 55)]
        results = run(f, records, refs=refs, ended=70)
        self.assertEqual(results[1]["result"], "no_visible_change")
        self.assertEqual((results[2]["result"], results[2]["stale_publication"]), ("timed", False))

    def test_returning_to_an_earlier_query_is_not_stale(self):
        f = frames((0, "A"), (10, "B"), (30, "A"), (40, "A"))
        r = run(f, [rec("b", "pasted", 5, 15), rec("", "cleared", 25, 35)], ended=60)[1]
        self.assertEqual((r["result"], r["stale_publication"], r["upper_ms"]), ("timed", False, 5.0))

    def test_accessibility_stale_read_fails_before_or_after_confirmation(self):
        f = frames((0, "A"), (16, "B"))
        before = run(f, [rec("b", "pasted", 4, 20, verdicts={"stale": 1, "correct": 2})], ended=40)[0]
        after = run(f, [rec("b", "pasted", 4, 20, post={"correct": 2, "stale": 1})], ended=40)[0]
        self.assertEqual((before["result"], after["result"]), ("failed", "failed"))

    def test_wrong_read_after_confirmation_fails_and_unreadable_is_unknown(self):
        f = frames((0, "A"), (16, "B"))
        wrong = run(f, [rec("b", "pasted", 4, 20, post={"correct": 2, "wrong": 1})], ended=40)[0]
        unreadable = run(f, [rec("b", "pasted", 4, 20, post={"correct": 2, "unreadable": 1})], ended=40)[0]
        self.assertEqual((wrong["result"], unreadable["result"]), ("failed", "unknown"))

    def test_unconfirmed_wrong_field_and_missing_reference_are_unknown(self):
        f = frames((0, "A"), (16, "B"))
        self.assertEqual(run(f, [rec("b", "pasted", 4, None)], ended=40)[0]["result"], "unknown")
        self.assertEqual(run(f, [rec("b", "pasted", 4, 20, field="bb")], ended=40)[0]["result"], "unknown")
        self.assertEqual(run(f, [rec("b", "pasted", 4, 20)], refs={"": "A"}, ended=40)[0]["result"], "unknown")

    def test_unknown_final_picture_is_unknown(self):
        f = frames((0, "A"), (16, "B"), (30, "Z"))
        self.assertEqual(run(f, [rec("b", "pasted", 4, 20)], ended=40)[0]["result"], "unknown")

    def test_incomplete_frames_are_ignored(self):
        f = frames((0, "A"), (16, "B"), (24, "B")) + [{"display": 8 * M, "status": 3, "hash": "B"}]
        r = run(f, [rec("b", "pasted", 4, 20)], ended=30)[0]
        self.assertEqual((r["upper_ms"], r["gap_ms"]), (12.0, 16.0))


if __name__ == "__main__":
    unittest.main()
