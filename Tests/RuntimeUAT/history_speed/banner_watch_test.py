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


class WatchTest(unittest.TestCase):
    def run_watch(self, shown_at, deadline=1000, start=0):
        clock = Clock(start=start)
        tick = {"n": 0}

        def read():
            tick["n"] += 1
            return tick["n"] in shown_at
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

    def test_both_banner_modes_are_excluded(self):
        for extra in ({"storage_warning": True}, {"watch_banner": True}, {"diagnostic": "watch-banner"}):
            self.assertNotIn("Open History", self.summarize(extra), extra)


if __name__ == "__main__":
    unittest.main()
