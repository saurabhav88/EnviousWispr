#!/usr/bin/env python3
"""Safety controls for measured-cost admission and four-process partitioning."""

import hashlib
from pathlib import Path
import tempfile
import unittest

from local_test_plan import plan_groups


class PlanningContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ew-local-plan-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Tests").mkdir()
        self.profile = {"schema": 1, "slots": 4,
                        "costs": {"EnviousWisprTests/Protected": 100}, "blocks": []}
        for name in ("A", "B", "C"):
            path = self.root / "Tests" / (name + ".swift")
            path.write_text("struct " + name + " {}\n")
            suite = "EnviousWisprTests/" + name
            self.profile["costs"][suite] = 100
            self.profile["blocks"].append({"suites": [{
                "suite": suite, "file": "Tests/" + path.name,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}]})

    def test_four_balanced_slots_exclude_protected_suite(self):
        groups, loads = plan_groups(self.root, self.profile)
        self.assertEqual(loads, [100, 100, 100, 100])
        self.assertEqual(len(groups), 4)
        selected = [name for _, names in groups[1:] for name in names]
        self.assertEqual(set(selected), {"EnviousWisprTests/" + n for n in "ABC"})
        self.assertEqual(len(selected), len(set(selected)))

    def test_changed_or_removed_test_file_falls_back_to_protected_slot(self):
        (self.root / "Tests/A.swift").write_text("struct Changed {}\n")
        (self.root / "Tests/B.swift").unlink()
        groups, loads = plan_groups(self.root, self.profile)
        self.assertEqual(loads[0], 300)
        self.assertEqual([name for _, names in groups[1:] for name in names],
                         ["EnviousWisprTests/C"])

    def test_new_unreviewed_suite_stays_protected(self):
        self.profile["costs"]["EnviousWisprTests/NewSuite"] = 50
        groups, loads = plan_groups(self.root, self.profile)
        self.assertEqual(loads[0], 150)
        self.assertNotIn("EnviousWisprTests/NewSuite", str(groups[1:]))

    def test_baseline_writer_has_one_worker_and_no_selectors(self):
        groups, loads = plan_groups(self.root, self.profile, baseline_writer=True)
        self.assertEqual(groups, [("serial", ())])
        self.assertEqual(loads, [400])

    def test_ast_affinity_is_never_split(self):
        entries = [b["suites"][0] for b in self.profile["blocks"]]
        self.profile["blocks"] = [{"suites": entries}]
        groups, _ = plan_groups(self.root, self.profile)
        self.assertEqual(len(groups), 2)
        self.assertEqual(set(groups[1][1]), {e["suite"] for e in entries})

    def test_bad_profile_fails_closed(self):
        for cost in (float("nan"), -1, "100", True):
            with self.subTest(cost=cost):
                self.profile["costs"]["EnviousWisprTests/A"] = cost
                with self.assertRaises(ValueError):
                    plan_groups(self.root, self.profile)


if __name__ == "__main__":
    unittest.main()
