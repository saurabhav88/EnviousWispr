"""Offline test: a quick-mode scroll report (no xctrace) is summarised with hitch NOT MEASURED, never 0 (#4586)."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


class QuickSummary(unittest.TestCase):
    def test_untraced_scroll_shows_hitch_not_measured(self):
        run = {"case": "mid", "tab": "Dictations", "input": "trackpad", "repeat": 0, "verdict": "PASS",
               "hitch": {"ms_per_s": None, "not_traced": True}, "height_changed": [], "rows_seen": 30,
               "travel": {"asymmetry": 0.01, "down": 100, "up": 99}}
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "main" / "scroll"
            report.mkdir(parents=True)
            (report / "report.json").write_text(json.dumps({"runs": [run], "resources_idle": {"seconds": 10, "cpu_s": 0.1}}))
            out = subprocess.run([sys.executable, "-B", str(HERE / "summarize_baseline.py"), tmp],
                                 capture_output=True, text=True, check=True).stdout
        self.assertEqual(out.count("NOT MEASURED (no xctrace; not 0)"), 2)
        combined = next(l for l in out.splitlines() if l.startswith("| **Scroll Dictations trackpad"))
        self.assertTrue(combined.split("|")[5].strip() == "UNPROVEN", combined)   # hitch budget unmeasured: not PASS
        self.assertIn("Resources idle on History (10 s)", out)
        self.assertNotIn("hitch 0", out)


if __name__ == "__main__":
    unittest.main()
