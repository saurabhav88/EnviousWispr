#!/usr/bin/env python3
"""Process-boundary tests of the real local group supervisor and verdict owners."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent


class GroupContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ew-local-groups-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "scripts/lib").mkdir(parents=True)
        shutil.copyfile(HERE / "local-test-groups.py", self.root / "scripts/local-test-groups.py")
        shutil.copyfile(HERE / "local_test_plan.py", self.root / "scripts/local_test_plan.py")
        for name in ("xcode-test-run.sh", "lane-verdict.sh", "lane-verdict.py"):
            shutil.copyfile(HERE / "lib" / name, self.root / "scripts/lib" / name)
        self.products = self.root / "products"
        self.products.mkdir()
        (self.products / "EnviousWispr_macosx-arm64.xctestrun").write_text("fixture")
        self.logs = self.root / "build/logs"
        self.logs.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Primary fixture boundary: recorded xcodebuild argv, actual independent
        # processes and signal delivery, literal vendor-shaped result payloads.
        self.executable("xcodebuild", r'''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
assert args[0] == 'test-without-building', args
root = Path(os.environ['FIXTURE_ROOT'])
name = Path(args[args.index('-resultBundlePath') + 1]).stem
(root / (name + '-args.json')).write_text(json.dumps(args))
(root / (name + '-env.json')).write_text(json.dumps({k: os.environ.get(k) for k in ('TEST_RUNNER_EW_APP_LOG_DIRECTORY', 'TEST_RUNNER_CI')}))
(root / (name + '.started')).write_text(str(os.getpid()))
(root / (name + '-group.pid')).write_text(str(os.getpgrp()))
peers = os.environ.get('EXPECTED_GROUPS', 'source,serial').split(',')
deadline = time.monotonic() + 8
while not all((root / (peer + '.started')).exists() for peer in peers):
    if time.monotonic() > deadline: sys.exit(91)
    time.sleep(0.01)
if os.environ.get('HOLD_GROUP') == name:
    child_code = 'import os,signal,sys,time; from pathlib import Path; '
    if os.environ.get('IGNORE_CHILD_TERM'): child_code += 'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
    child_code += 'Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)'
    child = subprocess.Popen([sys.executable, '-c', child_code, str(root / 'grandchild.pid')])
    while True: time.sleep(0.05)
if os.environ.get('FAIL_GROUP') == name: sys.exit(65)
target = 'EnviousWisprTests'
suites = [a.split(':', 1)[1].split('/')[1] for a in args if a.startswith('-only-testing:')]
if os.environ.get('MISSING_SUITE') and suites: suites.pop()
groups = [(target, suites)] if name != 'serial' else [(target, ['StatefulTests']), ('EnviousWisprDesktopEffectsTests', ['DesktopTests']), ('EnviousWisprASRTests', ['ASRTests'])]
if os.environ.get('LEAK_SOURCE') and name == 'serial': groups[0][1].append('DesktopEffectIsolationFreezeTests')
bundles = []
for bundle, suite_names in groups:
    cases = []
    for suite in suite_names:
        identity = bundle + '/' + suite + '/caseOne()'
        result = 'Failed' if os.environ.get('FAIL_VERDICT') == name else 'Passed'
        cases.append({'nodeType': 'Test Case', 'name': 'a real case', 'nodeIdentifier': suite + '/caseOne()', 'nodeIdentifierURL': 'test://com.apple.xcode/Fixture/' + identity, 'result': result, 'children': [{'nodeType': 'Arguments', 'name': 'input: 1', 'result': result}]})
    bundles.append({'nodeType': 'Unit test bundle', 'name': bundle, 'children': cases})
if os.environ.get('DUPLICATE_IDENTITY') and name == 'source': bundles[0]['children'].append(dict(bundles[0]['children'][0]))
bundle = Path(args[args.index('-resultBundlePath') + 1]); bundle.mkdir()
(bundle / 'result.json').write_text(json.dumps({'testNodes': [{'nodeType': 'Test Plan', 'children': bundles}]}))
print('Test run with ' + str(sum(len(b['children']) for b in bundles)) + ' tests passed.')
(root / (name + '.finished')).write_text('finished')
''')
        self.executable("xcrun", r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
assert args[0] == 'xcresulttool', args
if args[1] == 'get':
    bundle = Path(args[args.index('--path') + 1])
    print((bundle / 'result.json').read_text()); sys.exit(0)
assert args[1:3] == ['merge', '--output-path'], args
if os.environ.get('FAIL_MERGE'): sys.exit(70)
output = Path(args[3]); output.mkdir()
roots = []
for path in args[4:]: roots.extend(json.loads((Path(path) / 'result.json').read_text())['testNodes'])
if os.environ.get('DROP_MERGED_CASE'): roots[0]['children'][0]['children'].pop()
# Xcode may give merged results another run-specific URL prefix.
def rewrite(node):
    if 'nodeIdentifierURL' in node: node['nodeIdentifierURL'] = node['nodeIdentifierURL'].replace('/Fixture/', '/MergedRun/')
    for child in node.get('children', []): rewrite(child)
for node in roots: rewrite(node)
if os.environ.get('DROP_PARAMETER'): roots[0]['children'][0]['children'][0]['children'] = []
(output / 'result.json').write_text(json.dumps({'testNodes': roots}))
''')
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        FIXTURE_ROOT=str(self.root), CI="")
        for key in ("HOLD_GROUP", "FAIL_GROUP", "FAIL_VERDICT", "MISSING_SUITE", "LEAK_SOURCE",
                    "FAIL_MERGE", "DROP_MERGED_CASE", "DROP_PARAMETER", "DUPLICATE_IDENTITY", "IGNORE_CHILD_TERM",
                    "EXPECTED_GROUPS", "TEST_RUNNER_EW_WRITE_TEST_INVENTORY_BASELINE",
                    "TEST_RUNNER_EW_REAL_BOUNDARY"):
            self.env.pop(key, None)
        self.command = [sys.executable, str(self.root / "scripts/local-test-groups.py"),
                        "--products", str(self.products), "--scheme", "EnviousWispr",
                        "--log", str(self.logs / "combined.log"),
                        "--result-bundle", str(self.logs / "complete.xcresult")]

    def executable(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def run_groups(self, rc=0, **env):
        result = subprocess.run(self.command, env=dict(self.env, **env), capture_output=True,
                                text=True, timeout=20)
        self.assertEqual(result.returncode, rc, result.stdout + result.stderr)
        return result

    def test_real_workers_overlap_and_use_complementary_exact_selections(self):
        result = self.run_groups()
        source = json.loads((self.root / "source-args.json").read_text())
        serial = json.loads((self.root / "serial-args.json").read_text())
        expected = ["EnviousWisprTests/" + suite for suite in (
            "DesktopEffectIsolationFreezeTests", "ProviderSetupCredentialOwnershipTests",
            "SettingsMapRegistrationTests", "SentryScopeWriterFreezeTests")]
        self.assertEqual([a for a in source if a.startswith("-only-testing:")],
                         ["-only-testing:" + name for name in expected])
        self.assertEqual([a for a in serial if a.startswith("-skip-testing:")],
                         ["-skip-testing:" + name for name in expected])
        self.assertIn("4 source + 3 serial test cases; all results preserved", result.stdout)
        self.assertEqual((self.logs / "combined.log").read_text().count("Test run with"), 2)
        self.assertTrue((self.logs / "complete.xcresult/result.json").exists())
        envs = [json.loads((self.root / (name + "-env.json")).read_text()) for name in ("source", "serial")]
        self.assertNotEqual(envs[0]["TEST_RUNNER_EW_APP_LOG_DIRECTORY"],
                            envs[1]["TEST_RUNNER_EW_APP_LOG_DIRECTORY"])
        self.assertEqual([e["TEST_RUNNER_CI"] for e in envs], ["", ""])
        for args in (source, serial):
            self.assertEqual(args[args.index("-parallel-testing-enabled") + 1], "NO")

    def four_worker_profile(self):
        (self.root / "Tests/EnviousWisprTests").mkdir(parents=True)
        profile = {"schema": 2, "slots": 4,
                   "costs": {"__protected__": 100}, "blocks": []}
        for name in ("A", "B", "C"):
            path = self.root / "Tests/EnviousWisprTests" / (name + ".swift")
            path.write_text("struct " + name + " {}\n")
            suite = "EnviousWisprTests/" + name
            profile["costs"][suite] = 100
            profile["blocks"].append({"suites": [{"suite": suite,
                "file": "Tests/EnviousWisprTests/" + path.name}]})
        (self.root / "scripts/local-test-costs.json").write_text(json.dumps(profile))

    def test_four_workers_use_disjoint_outputs_and_preserve_all_results(self):
        self.four_worker_profile()
        names = ["serial", "worker-1", "worker-2", "worker-3"]
        result = self.run_groups(EXPECTED_GROUPS=",".join(names))
        self.assertEqual((self.logs / "combined.log").read_text().count("Test run with"), 4)
        envs = [json.loads((self.root / (n + "-env.json")).read_text()) for n in names]
        self.assertEqual(len({e["TEST_RUNNER_EW_APP_LOG_DIRECTORY"] for e in envs}), 4)
        all_selected = []
        for name in names[1:]:
            args = json.loads((self.root / (name + "-args.json")).read_text())
            self.assertEqual(args[args.index("-parallel-testing-enabled") + 1], "NO")
            all_selected.extend(a.removeprefix("-only-testing:") for a in args
                                if a.startswith("-only-testing:"))
        serial = json.loads((self.root / "serial-args.json").read_text())
        skipped = [a.removeprefix("-skip-testing:") for a in serial if a.startswith("-skip-testing:")]
        self.assertEqual(sorted(all_selected), sorted(skipped))
        self.assertEqual(len(set(all_selected)), 3)
        self.assertIn("all results preserved", result.stdout)

    def test_failure_in_a_new_worker_rejects_the_whole_run(self):
        self.four_worker_profile()
        self.run_groups(rc=1, EXPECTED_GROUPS="serial,worker-1,worker-2,worker-3", FAIL_GROUP="worker-2")
        self.assertFalse((self.logs / "combined.log").exists())

    def test_writer_mode_is_one_process_without_skip_selections(self):
        self.four_worker_profile()
        self.run_groups(EXPECTED_GROUPS="serial", TEST_RUNNER_EW_WRITE_TEST_INVENTORY_BASELINE="1")
        args = json.loads((self.root / "serial-args.json").read_text())
        self.assertFalse(any(a.startswith(("-skip-testing:", "-only-testing:")) for a in args))
        self.assertFalse((self.root / "worker-1.started").exists())

    def test_real_boundary_mode_is_one_process_without_skip_selections(self):
        # #4279: real-model and GPU tests in tagged suites must never run beside the protected worker.
        self.four_worker_profile()
        self.run_groups(EXPECTED_GROUPS="serial", TEST_RUNNER_EW_REAL_BOUNDARY="1")
        args = json.loads((self.root / "serial-args.json").read_text())
        self.assertFalse(any(a.startswith(("-skip-testing:", "-only-testing:")) for a in args))
        self.assertFalse((self.root / "worker-1.started").exists())

    def test_either_worker_failure_fails_the_complete_run(self):
        for name in ("source", "serial"):
            with self.subTest(group=name):
                self.run_groups(rc=1, FAIL_GROUP=name)
                self.assertFalse((self.logs / "combined.log").exists())

    def test_structured_failure_is_not_hidden_by_successful_worker_exit(self):
        self.run_groups(rc=1, FAIL_VERDICT="source")
        self.assertFalse((self.logs / "complete.xcresult").exists())

    def test_every_selected_suite_must_appear(self):
        self.assertIn("missing=", self.run_groups(rc=1, MISSING_SUITE="1").stderr)

    def test_duplicate_normalized_case_identity_fails_without_combined_log(self):
        self.assertIn("duplicate test case", self.run_groups(rc=1, DUPLICATE_IDENTITY="1").stderr)
        self.assertFalse((self.logs / "combined.log").exists())

    def test_source_suite_cannot_also_run_in_remainder(self):
        self.assertIn("also ran", self.run_groups(rc=1, LEAK_SOURCE="1").stderr)

    def test_merge_failure_has_no_complete_log(self):
        self.run_groups(rc=1, FAIL_MERGE="1")
        self.assertFalse((self.logs / "combined.log").exists())

    def test_merge_must_preserve_case_and_parameter_results(self):
        self.assertIn("every original", self.run_groups(rc=1, DROP_PARAMETER="1").stderr)

    def test_merge_cannot_drop_a_whole_case(self):
        self.assertIn("every original", self.run_groups(rc=1, DROP_MERGED_CASE="1").stderr)

    def test_existing_named_result_is_never_replaced(self):
        output = self.logs / "complete.xcresult"
        output.mkdir()
        marker = output / "keep"
        marker.write_text("existing")
        self.run_groups(rc=1)
        self.assertEqual(marker.read_text(), "existing")
        self.assertFalse((self.root / "source.started").exists())

    def test_missing_xctestrun_fails_closed(self):
        (self.products / "EnviousWispr_macosx-arm64.xctestrun").unlink()
        self.run_groups(rc=1)
        self.assertFalse((self.logs / "combined.log").exists())

    def test_completed_leader_stays_reserved_until_peer_cleanup(self):
        proc = subprocess.Popen(self.command, env=dict(self.env, HOLD_GROUP="serial"),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            finished = self.root / "source.finished"
            deadline = time.monotonic() + 8
            while not finished.exists() and time.monotonic() < deadline:
                time.sleep(0.01)  # deadline-fallback: source body completion signal
            self.assertTrue(finished.exists())
            leader = int((self.root / "source-group.pid").read_text())
            state = "running"
            while time.monotonic() < deadline:
                result = subprocess.run(["ps", "-o", "stat=", "-p", str(leader)],
                                        capture_output=True, text=True)
                state = result.stdout.strip()
                if not state or state.startswith("Z"):
                    break
                time.sleep(0.01)  # deadline-fallback: leader's actual OS exit state
            self.assertTrue(state.startswith("Z"), f"completed leader lost its reservation: {state!r}")
            self.assertIsNone(proc.poll(), "peer should still be held")
            proc.terminate()
            proc.communicate(timeout=15)
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(leader)],
                                   capture_output=True, text=True).stdout.strip()
            self.assertEqual(state, "", "cleanup must reap the reserved leader")
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.communicate(timeout=15)

    def test_cancellation_reaps_workers_and_their_descendants(self):
        self.cancellation_reaps(False)

    def test_cancellation_stops_a_descendant_that_ignores_term(self):
        self.cancellation_reaps(True)

    def cancellation_reaps(self, ignores_term):
        child_env = dict(self.env, HOLD_GROUP="serial")
        if ignores_term:
            child_env["IGNORE_CHILD_TERM"] = "1"
        proc = subprocess.Popen(self.command, env=child_env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            marker = self.root / "grandchild.pid"
            deadline = time.monotonic() + 8
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(marker.exists())
            proc.send_signal(signal.SIGTERM)
            out, _ = proc.communicate(timeout=15)
            self.assertNotEqual(proc.returncode, 0, out)
            self.assertFalse((self.logs / "combined.log").exists())
            pids = [int(marker.read_text()), int((self.root / "serial.started").read_text())]
            for pid in pids:
                status = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
                self.assertTrue(not status.stdout.strip() or status.stdout.strip().startswith("Z"),
                                f"owned process {pid} survived cancellation: {status.stdout}")
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.communicate(timeout=15)


if __name__ == "__main__":
    unittest.main()
