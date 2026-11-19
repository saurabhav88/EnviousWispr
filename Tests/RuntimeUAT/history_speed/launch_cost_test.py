"""Offline test for launch_cost.py parsing (#4656): pass counting and ps CPU times."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from launch_cost import count_full_passes, parse_cpu_time  # noqa: E402

LINES = [
    "Filtering the log data using \"subsystem == ...\"",
    "2026-11-18 18:09:36.745 Sp EnviousWispr[52491:e8a8353] [com.enviouswispr.app:HistorySpeed] [spid excl, process, event] HistoryWatcherReady",
    "2026-11-18 18:09:37.552 Sp EnviousWispr[52491:e8a83f3] [com.enviouswispr.app:HistorySpeed] [spid excl, process, event] HistoryDiscoveryDone",
    "2026-11-18 18:09:38.637 Sp EnviousWispr[52491:e8a83f3] [com.enviouswispr.app:HistorySpeed] [spid excl, process, event] HistoryDiscoveryDone",
    "2026-11-18 18:09:38.700 Sp EnviousWispr[30182:e7df38c] [com.enviouswispr.app:HistorySpeed] [spid excl, process, event] HistoryDiscoveryDone",
]


class LaunchCostParsing(unittest.TestCase):
    def test_counts_only_the_subjects_full_passes(self):
        self.assertEqual(count_full_passes(LINES, 52491), 2)
        self.assertEqual(count_full_passes(LINES, 30182), 1)
        self.assertEqual(count_full_passes(LINES, 524), 0)   # a pid prefix is not the pid

    def test_cpu_time_shapes(self):
        self.assertAlmostEqual(parse_cpu_time("0:05.93\n"), 5.93)
        self.assertAlmostEqual(parse_cpu_time("1:02:03.50"), 3723.5)
        self.assertIsNone(parse_cpu_time(""))
        self.assertIsNone(parse_cpu_time("n/a"))


if __name__ == "__main__":
    unittest.main()
