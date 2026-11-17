"""Offline tests for scroll_analysis (#4586 WP-A). Each measure is shown able to fail."""
import unittest

import scroll_analysis as sa

HITCHES_XML = """<trace-query-result><node><schema name="hitches"/>
<row><start-time id="1">1500000000</start-time><duration id="2">20000000</duration>
 <process id="3" fmt="EnviousWispr (22314)"><pid id="4">22314</pid></process><boolean id="5">0</boolean></row>
<row><start-time id="6">9000000000</start-time><duration ref="2"/><process ref="3"/><boolean ref="5"/></row>
<row><start-time id="7">1600000000</start-time><duration id="8">5000000</duration><process ref="3"/><boolean ref="5"/></row>
<row><start-time id="9">1700000000</start-time><duration id="10">30000000</duration>
 <process id="11" fmt="WindowServer (300)"><pid id="12">300</pid></process><boolean id="13">1</boolean></row>
</node></trace-query-result>"""

TOC_XML = """<trace-toc><run number="1"><info><summary>
<start-date>2026-11-17T09:44:53.278-05:00</start-date></summary></info></run></trace-toc>"""


class MovingSpanTests(unittest.TestCase):
    def test_span_runs_from_first_to_last_change(self):
        frames = [(0.9, "a"), (1.1, "b"), (1.2, "c"), (1.3, "c"), (1.4, "d"), (2.0, "d")]
        self.assertEqual(sa.moving_span(frames, "a", 1.0, 3.0), (1.1, 1.4))

    def test_still_picture_is_no_span(self):
        frames = [(0.9, "a"), (1.1, "a"), (1.5, "a")]
        self.assertIsNone(sa.moving_span(frames, "a", 1.0, 3.0))

    def test_kept_moving_after_last_event(self):
        self.assertAlmostEqual(sa.kept_moving_after((1.0, 2.5), 2.0), 0.5)
        self.assertEqual(sa.kept_moving_after((1.0, 1.8), 2.0), 0.0)


class HitchTests(unittest.TestCase):
    def test_parse_follows_refs(self):
        self.assertEqual(sa.parse_hitches(HITCHES_XML), [(1.5, 0.02, 22314, False), (9.0, 0.02, 22314, False),
                                                         (1.6, 0.005, 22314, False), (1.7, 0.03, 300, True)])

    def test_trace_start_reads_the_toc(self):
        self.assertAlmostEqual(sa.trace_start_epoch(TOC_XML) % 60, 53.278, places=3)

    def test_only_the_subjects_hitches_inside_moving_spans_count(self):
        rate = sa.hitch_rate(sa.parse_hitches(HITCHES_XML), [(1.0, 2.0)], pid=22314)
        self.assertEqual(rate["other_process"], 1)
        self.assertEqual(rate["count"], 2)
        self.assertEqual(rate["hitch_ms"], 25.0)
        self.assertEqual(rate["ms_per_s"], 25.0)

    def test_no_movement_is_unproven_not_zero(self):
        rate = sa.hitch_rate([], [None])
        self.assertIsNone(rate["ms_per_s"])
        self.assertEqual(sa.verdict(rate, [], {"asymmetry": 0.0}), "UNPROVEN")


class HeightTests(unittest.TestCase):
    def test_a_row_that_grows_after_first_display_counts(self):
        changed, seen = sa.height_changes([{"r1": 40, "r2": 80}, {"r1": 40, "r2": 120}, {"r3": 50}])
        self.assertEqual(seen, 3)
        self.assertEqual(changed, [{"row": "r2", "first": 80, "later": 120}])

    def test_half_point_rounding_does_not_count(self):
        changed, _ = sa.height_changes([{"r1": 40.0}, {"r1": 40.5}])
        self.assertEqual(changed, [])


class TravelTests(unittest.TestCase):
    def test_equal_travel_is_symmetric(self):
        self.assertEqual(sa.travel(100, -900, 100)["asymmetry"], 0.0)

    def test_short_return_fails_budget(self):
        t = sa.travel(100, -900, -400)
        self.assertEqual(t["asymmetry"], 0.5)
        self.assertEqual(sa.verdict({"ms_per_s": 0.0}, [], t), "FAIL")

    def test_all_inside_budget_passes(self):
        self.assertEqual(sa.verdict({"ms_per_s": 4.9}, [], sa.travel(0, -1000, -15)), "PASS")

    def test_one_changed_row_fails(self):
        self.assertEqual(sa.verdict({"ms_per_s": 0.0}, [{"row": "x"}], sa.travel(0, -1000, 0)), "FAIL")


if __name__ == "__main__":
    unittest.main()
