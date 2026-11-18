import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import banner_watch


class BannerJumpTest(unittest.TestCase):
    def test_bracketed_move_is_measured(self):
        r = banner_watch.banner_jump([(3000, False, 311), (3100, False, 311), (3200, True, 376), (3300, True, 376)])
        self.assertEqual(r["jump_pt"], 65)
        self.assertIsNone(r["jump_not_measured"])
        self.assertEqual(r["seen_at_ms"], 3200)

    def test_later_movement_after_the_banner_is_not_counted(self):
        r = banner_watch.banner_jump([(3000, False, 311), (3100, True, 376), (3200, True, 500)])
        self.assertEqual(r["jump_pt"], 65)

    def test_banner_on_first_poll_is_not_measured(self):
        r = banner_watch.banner_jump([(3000, True, 376), (3100, True, 376)])
        self.assertIsNone(r["jump_pt"])
        self.assertIn("before", r["jump_not_measured"])

    def test_unreadable_position_before_is_not_measured(self):
        r = banner_watch.banner_jump([(3000, False, None), (3100, True, 376)])
        self.assertIsNone(r["jump_pt"])

    def test_unreadable_position_after_is_not_measured(self):
        r = banner_watch.banner_jump([(3000, False, 311), (3100, True, None), (3200, True, None)])
        self.assertIsNone(r["jump_pt"])
        self.assertIn("after", r["jump_not_measured"])

    def test_never_seen_is_not_a_zero_jump(self):
        r = banner_watch.banner_jump([(3000, False, 311), (3100, False, 311)])
        self.assertIsNone(r["jump_pt"])
        self.assertEqual(r["jump_not_measured"], "banner never seen")

    def test_no_reads(self):
        self.assertIsNone(banner_watch.banner_jump([])["jump_pt"])


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
