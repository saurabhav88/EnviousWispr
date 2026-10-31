#!/usr/bin/env python3
"""Safety controls for measured-cost admission and four-process partitioning."""

from pathlib import Path
import tempfile
import unittest

from local_test_plan import plan_groups


class PlanningContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ew-local-plan-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Tests/EnviousWisprTests").mkdir(parents=True)
        self.profile = {"schema": 2, "slots": 4,
                        "costs": {"EnviousWisprTests/Protected": 100}, "blocks": []}
        for name in ("A", "B", "C"):
            path = self.root / "Tests/EnviousWisprTests" / (name + ".swift")
            path.write_text("struct " + name + " {}\n")
            suite = "EnviousWisprTests/" + name
            self.profile["costs"][suite] = 100
            self.profile["blocks"].append({"suites": [{
                "suite": suite, "file": "Tests/EnviousWisprTests/" + path.name}]})

    def test_four_balanced_slots_exclude_protected_suite(self):
        groups, loads = plan_groups(self.root, self.profile)
        self.assertEqual(loads, [100, 100, 100, 100])
        self.assertEqual(len(groups), 4)
        selected = [name for _, names in groups[1:] for name in names]
        self.assertEqual(set(selected), {"EnviousWisprTests/" + n for n in "ABC"})
        self.assertEqual(len(selected), len(set(selected)))

    def test_edited_test_file_keeps_its_admission(self):
        # #4279: the review mark is the .localParallel tag in the source, not a file hash.
        (self.root / "Tests/EnviousWisprTests/A.swift").write_text("struct A { let edited = 1 }\n")
        groups, loads = plan_groups(self.root, self.profile)
        self.assertEqual(loads, [100, 100, 100, 100])
        self.assertIn("EnviousWisprTests/A", [n for _, names in groups[1:] for n in names])

    def test_removed_test_file_falls_back_to_protected_slot(self):
        (self.root / "Tests/EnviousWisprTests/B.swift").unlink()
        groups, loads = plan_groups(self.root, self.profile)
        self.assertEqual(loads[0], 200)
        self.assertEqual(sorted(name for _, names in groups[1:] for name in names),
                         ["EnviousWisprTests/A", "EnviousWisprTests/C"])

    def test_old_hash_entries_and_old_schema_fail_closed(self):
        self.profile["blocks"][0]["suites"][0]["sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            plan_groups(self.root, self.profile)
        del self.profile["blocks"][0]["suites"][0]["sha256"]
        self.profile["schema"] = 1
        with self.assertRaises(ValueError):
            plan_groups(self.root, self.profile)

    def test_paths_outside_the_main_test_target_fail_closed(self):
        for bad in ("Tests/EnviousWisprASRTests/A.swift", "/abs/A.swift",
                    "Tests/EnviousWisprTests/../A.swift"):
            with self.subTest(path=bad):
                self.profile["blocks"][0]["suites"][0]["file"] = bad
                with self.assertRaises(ValueError):
                    plan_groups(self.root, self.profile)

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
