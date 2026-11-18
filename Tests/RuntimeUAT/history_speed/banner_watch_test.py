import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import banner_watch


class Clock:
    def __init__(self, step=100, start=0):
        self.t, self.step = start - step, step

    def now(self):
        self.t += self.step
        return self.t


class FindBannerTest(unittest.TestCase):
    class Reader:
        def __init__(self, elements):   # [(identifier, role)]
            self.elements = elements

        def find_outside_list(self, window, predicate):
            return [e for e in self.elements if predicate(e, e[1])]

    class UI:
        @staticmethod
        def get_attr(element, name):
            return element[0] if name == "AXIdentifier" else None

    def find(self, elements):
        return banner_watch.find_banner(self.Reader(elements), self.UI, "w")

    def test_banner_present(self):
        self.assertIs(self.find([("history.recordingStorage.openSettings", "AXButton")]), True)

    def test_absent_on_a_loaded_page(self):
        self.assertIs(self.find([("x", "AXButton"), ("y", "AXTable")]), False)

    def test_nothing_readable_is_unknown_not_absent(self):
        self.assertIsNone(self.find([]))
        self.assertIsNone(self.find([("x", "AXGroup")]))
        self.assertIsNone(self.find([("sidebar", "AXButton")]))   # a button alone is not the History page


class WatchTest(unittest.TestCase):
    def run_watch(self, shown_at, deadline=1000, start=0, unreadable_at=()):
        clock = Clock(start=start)
        tick = {"n": 0}

        def read():
            tick["n"] += 1
            return None if tick["n"] in unreadable_at else tick["n"] in shown_at
        return banner_watch.watch(read, clock.now, lambda: None, deadline)

    def test_banner_seen_reports_first_time(self):
        r = self.run_watch({3, 4})
        self.assertEqual(r["seen_at_ms"], 200)
        self.assertTrue(r["watched_to_deadline"])

    def test_never_seen_is_none(self):
        r = self.run_watch(set())
        self.assertIsNone(r["seen_at_ms"])
        self.assertTrue(r["watched_to_deadline"])
        self.assertEqual(r["reads"], 11)

    def test_reads_continue_to_the_deadline_even_after_the_banner(self):
        self.assertEqual(self.run_watch({1})["reads"], 11)

    def test_first_read_after_the_deadline_is_not_a_watch(self):
        r = self.run_watch(set(), start=2000)
        self.assertFalse(r["watched_to_deadline"])
        self.assertEqual(r["reads"], 1)

    def test_an_unreadable_window_is_not_a_banner_free_watch(self):
        r = self.run_watch(set(), unreadable_at={5, 6})
        self.assertFalse(r["watched_to_deadline"])
        self.assertEqual(r["unreadable_reads"], 2)
        self.assertIsNone(r["seen_at_ms"])

    def test_banner_matched_by_identifier(self):
        self.assertEqual(banner_watch.BANNER_IDENTIFIER, "history.recordingStorage.openSettings")


class SummarizerExclusionTest(unittest.TestCase):
    def summarize(self, extra):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d) / "main" / "open-existing"
            folder.mkdir(parents=True)
            report = {"launch_to_page_ms": {"p50": 1, "p95": 2}, "window_to_page_ms": {"p95": 1}, "results": {},
                      "capture_late": 0, "budget_verdict": "PASS", "attempts": 3}
            report.update(extra)
            (folder / "report.json").write_text(json.dumps(report))
            return subprocess.run([sys.executable, "-B", str(HERE / "summarize_baseline.py"), d],
                                  capture_output=True, text=True).stdout

    def test_timing_report_is_listed(self):
        self.assertIn("Open History, existing", self.summarize({}))

    def test_the_banner_mode_is_excluded(self):
        for extra in ({"storage_warning": True}, {"diagnostic": "storage-warning"}):
            self.assertNotIn("Open History", self.summarize(extra), extra)


if __name__ == "__main__":
    unittest.main()
