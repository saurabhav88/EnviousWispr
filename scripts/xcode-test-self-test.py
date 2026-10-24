#!/usr/bin/env python3
"""Exercise the real runner with private, recorded Xcode/setup boundaries.

No app compilation or real cache deletion. Pass --runner PATH for a baseline
control. These checks prove command orchestration, not Xcode test discovery.
"""
import argparse
import fcntl
import selectors
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

PARSER = argparse.ArgumentParser(description=__doc__)
PARSER.add_argument('--runner', type=Path, default=Path(__file__).with_name('xcode-test.sh'))
ARGS, UNIT_ARGS = PARSER.parse_known_args()
RUNNER = ARGS.runner.resolve()


class RunnerContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ew-runner-contract-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        lib = self.root / 'scripts/lib'
        lib.mkdir(parents=True)
        shutil.copyfile(RUNNER, self.root / 'scripts/xcode-test.sh')
        # The real receipt owner, against owned classifier and eval-compile
        # stand-ins with the real output contracts (#3729 PR-C).
        shutil.copyfile(RUNNER.with_name('lib') / 'validation-receipt.py', lib / 'validation-receipt.py')
        # Private COPY of the machine queue: a missed rewrite must never acquire
        # the developer's real slot from a self-test fixture.
        queue = (RUNNER.parent / 'local-ci-queue.py').read_text()
        definition = 'LOCK_PATH = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Caches/EnviousWispr/local-ci/runner.lock"'
        self.assertEqual(queue.count(definition), 1)
        (self.root / 'scripts/local-ci-queue.py').write_text(
            queue.replace(definition, f"LOCK_PATH = Path({str(self.root / 'private-queue/runner.lock')!r})"))
        ci = self.root / 'scripts/ci'
        ci.mkdir()
        for name, key, prefix in (('classify-changes.sh', 'needs_build', 'Sources/'),
                                  ('needs-eval-packages.sh', 'needs_eval_packages', 'scripts/eval/')):
            (ci / name).write_text('#!/usr/bin/env bash\n'
                                   f"if grep -q '^{prefix}'; then v=true; else v=false; fi\n"
                                   f"printf '{key}=%s\\n' \"$v\" >>\"$GITHUB_OUTPUT\"\n")
        (ci / 'compile-eval-packages.sh').write_text(
            '#!/usr/bin/env bash\necho eval >> "$TRACE"\nexit "${EVAL_RC:-0}"\n')
        # Replace only dependencies in the private fixture. The runner itself is
        # byte-identical, with no production environment bypass or rewrite.
        (lib / 'ensure-generated.sh').write_text('ew_ensure_generated() { echo generate >> "$TRACE"; }\n')
        (lib / 'spm-seed.sh').write_text('''ew_seed_release_all() { :; }
ew_seed_consume() { echo seed >> "$TRACE"; }
ew_seed_publish() { cp "$PACKAGE_STATE" "$PUBLISHED_STATE"; echo publish >> "$TRACE"; }
ew_seed_resolve_or_unseed() { [ "${STUB_SEEDED:-1}" = 1 ] || return 0; shift; "$@"; }
''')
        (lib / 'log-dir.sh').write_text('''ew_resolve_log_dir() { echo "$2"; }
ew_take_default_lane() { mkdir -p "$1"; }
ew_publish_latest_lane() { :; }
ew_prune_stale_lanes() { :; }
''')
        # A recorded supervisor boundary; the real two-process supervisor and
        # verdict owners have their process tests in local-test-groups-test.py.
        (self.root / 'scripts/local-test-groups.py').write_text('''import argparse, os, signal, sys, time
from pathlib import Path
p = argparse.ArgumentParser()
for name in ('products', 'scheme', 'log', 'result-bundle'): p.add_argument('--' + name, required=True)
a = p.parse_args()
root = Path(os.environ['FIXTURE_ROOT'])
trace = Path(os.environ['TRACE'])
with trace.open('a') as f: f.write('groups\\n')
def stop(sig, frame):
    held = (root / '.derivedData/Test/.ew-validation.lock').exists()
    with trace.open('a') as f: f.write('groups-stopped:lock=' + str(int(held)) + '\\n')
    sys.exit(128 + sig)
signal.signal(signal.SIGTERM, stop)
if os.environ.get('STARTED'): Path(os.environ['STARTED']).write_text(str(os.getpid()))
while os.environ.get('HOLD') and Path(os.environ['HOLD']).exists(): time.sleep(0.01)
if os.environ.get('GROUP_RC'): sys.exit(int(os.environ['GROUP_RC']))
Path(a.result_bundle).mkdir()
Path(a.log).write_text('Test run with 2 tests passed.\\n')
''')
        (lib / 'lane-verdict.sh').write_text('''ew_lane_verdict() {
  echo "verdict:$3:required=${EW_LANE_REQUIRED_BUNDLES-unset}" >> "$TRACE"
  EW_LANE_EXECUTED_COUNT=2
  EW_LANE_JUDGED_BUNDLES="${EW_LANE_REQUIRED_BUNDLES-EnviousWisprTests EnviousWisprDesktopEffectsTests EnviousWisprASRTests}"
  return "${VERDICT_RC:-0}"
}
''')
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        xcode = bin_dir / 'xcodebuild'
        xcode.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
import subprocess, time
args = sys.argv[1:]
if args[0] == '-version':
    swapped = os.environ.get('TOOLCHAIN_FLAG') and Path(os.environ['TOOLCHAIN_FLAG']).exists()
    print('Xcode 27.0')
    print('Build version ' + ('28A1' if swapped else '27A266a'))
    sys.exit(0)
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps(args) + '\\n')
if args[0] == 'build-for-testing':
    Path(os.environ['PACKAGE_STATE']).write_text('current lockfile dependencies')
    sys.exit(int(os.environ.get('BUILD_RC', '0')))
if args[0] == 'test':
    Path(args[args.index('-resultBundlePath') + 1]).mkdir()
    root = Path(os.environ['FIXTURE_ROOT'])
    if os.environ.get('STARTED'):
        Path(os.environ['STARTED']).write_text('running')
    deadline = time.time() + 10
    while os.environ.get('HOLD') and Path(os.environ['HOLD']).exists() and time.time() < deadline:
        time.sleep(0.05)
    if os.environ.get('MUTATE'):
        (root / os.environ['MUTATE']).write_text('changed during the run\\n')
        if os.environ.get('MUTATE_STAGE'):
            subprocess.run(['git', '-C', str(root), 'add', os.environ['MUTATE']], check=True)
    if os.environ.get('TOOLCHAIN_FLAG'):
        Path(os.environ['TOOLCHAIN_FLAG']).write_text('swapped')
    if os.environ.get('PLANT_RECEIPT'):
        planted = root / '.derivedData/Test/ew-validation-receipt.json'
        planted.parent.mkdir(parents=True, exist_ok=True)
        planted.write_text('{}')
    Path(os.environ['PACKAGE_STATE']).write_text('current lockfile dependencies')
    print('Test run with 2 tests passed.')
    sys.exit(int(os.environ.get('XCODE_RC', '0')))
''')
        xcode.chmod(0o755)
        # Result-bundle boundary: reports a node for each selection the recorded
        # test command received, minus OMIT_SELECTION (a suite that never ran).
        xcrun = bin_dir / 'xcrun'
        xcrun.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['XCRUN_CALLS'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
if os.environ.get('XCRESULT_RC'):
    sys.exit(int(os.environ['XCRESULT_RC']))
rows = [json.loads(r) for r in open(os.environ['CALLS'])]
test = [r for r in rows if r[0] == 'test'][-1]
omit = set(filter(None, os.environ.get('OMIT_SELECTION', '').split(',')))
suffix = os.environ.get('NODE_SUFFIX', '')
nodes = [{'nodeIdentifierURL': 'test://com.apple.xcode/EnviousWispr/' + a[len('-only-testing:'):] + suffix}
         for a in test if a.startswith('-only-testing:') and a[len('-only-testing:'):] not in omit]
print(json.dumps({'testNodes': [{'nodeType': 'Test Plan', 'children': nodes}]}))
''')
        xcrun.chmod(0o755)
        self.env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                        TRACE=str(self.root / 'trace'), CALLS=str(self.root / 'calls'),
                        XCRUN_CALLS=str(self.root / 'xcrun-calls'),
                        DERIVED_DATA_PATH=str(self.root / 'derived'),
                        PACKAGE_STATE=str(self.root / 'package-state'),
                        PUBLISHED_STATE=str(self.root / 'published-state'), STUB_SEEDED='1',
                        FIXTURE_ROOT=str(self.root))
        (self.root / 'package-state').write_text('old lockfile dependencies')
        self.env.pop('XCODE_RC', None)
        for name in ('VERDICT_RC', 'XCRESULT_RC', 'OMIT_SELECTION', 'NODE_SUFFIX', 'CI',
                     'EW_LANE_REQUIRED_BUNDLES', 'EVAL_RC', 'HOLD', 'STARTED', 'MUTATE',
                     'MUTATE_STAGE', 'TOOLCHAIN_FLAG', 'PLANT_RECEIPT', 'GROUP_RC', 'BUILD_RC'):
            self.env.pop(name, None)
        self.sentinel = self.root / 'derived/keep-cache'
        self.sentinel.parent.mkdir()
        self.sentinel.write_text('unchanged compatible cache')
        # An owned repository, so the receipt binds a real index tree.
        (self.root / 'Sources').mkdir()
        (self.root / 'Sources/A.swift').write_text('let a = 1\n')
        (self.root / '.gitignore').write_text('.derivedData/\n')
        for cmd in (['init', '-q'], ['config', 'user.email', 't@t'], ['config', 'user.name', 't'],
                    ['add', 'Sources', '.gitignore', 'scripts'], ['commit', '-qm', 'fixture']):
            self.git(*cmd)
        self.receipt = self.root / '.derivedData/Test/ew-validation-receipt.json'
        self.lock = self.root / '.derivedData/Test/.ew-validation.lock'

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.root), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def trace(self):
        path = self.root / 'trace'
        return path.read_text().splitlines() if path.exists() else []

    def receipt_data(self):
        return json.loads(self.receipt.read_text())

    def run_runner(self, *args, rc=0, execution='serial', **env):
        mode = ['--' + execution] if execution else []
        result = subprocess.run(['bash', str(self.root / 'scripts/xcode-test.sh'),
                                 '--log-dir', str(self.root / 'logs'), *mode, *args],
                                env=dict(self.env, **env), text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        self.assertEqual(result.returncode, rc, result.stdout)
        calls = self.root / 'calls'
        self.calls = [json.loads(row) for row in calls.read_text().splitlines()] if calls.exists() else []
        self.tests = [row for row in self.calls if row[0] == 'test']
        self.assertEqual(self.sentinel.read_text(), 'unchanged compatible cache')
        return result

    def configurations(self):
        return [row[row.index('-configuration') + 1] for row in self.tests]

    def test_batch_runs_all_eight_filters_with_one_setup(self):
        filters = [f'Target/Suite{i}' for i in range(8)]
        self.run_runner(*[arg for name in filters for arg in ('--filter', name)])
        self.assertEqual(self.configurations(), ['Debug'])
        self.assertEqual([arg for arg in self.tests[0] if arg.startswith('-only-testing:')],
                         ['-only-testing:' + name for name in filters])
        self.assertEqual(len(self.calls), 2)  # one resolution, one test command
        trace = (self.root / 'trace').read_text().splitlines()
        self.assertEqual(trace.count('generate'), 1)
        self.assertIn('verdict:Debug lane:required=', trace)

    def test_serial_is_full_debug_with_required_bundles(self):
        self.run_runner()
        self.assertEqual(self.configurations(), ['Debug'])
        self.assertFalse(any(arg.startswith('-only-testing:') for arg in self.tests[0]))
        self.assertIn('verdict:Debug lane:required=unset', (self.root / 'trace').read_text())
        self.assertFalse((self.root / 'xcrun-calls').exists())  # no selections to confirm

    def test_default_uses_groups_without_requiring_a_new_command(self):
        self.run_runner(execution=None)
        self.assertIn('groups', self.trace())
        self.assertEqual(self.tests, [])
        self.assertTrue(self.receipt.exists())

    def test_grouped_run_builds_once_then_judges_the_complete_result(self):
        result = self.run_runner('--grouped', execution=None)
        builds = [row for row in self.calls if row[0] == 'build-for-testing']
        self.assertEqual(len(builds), 1)
        self.assertEqual(builds[0][builds[0].index('-configuration') + 1], 'Debug')
        self.assertEqual(self.tests, [])
        trace = self.trace()
        self.assertLess(trace.index('groups'), trace.index('verdict:Debug lane:required=unset'))
        self.assertLess(trace.index('verdict:Debug lane:required=unset'), trace.index('eval'))
        self.assertIn('validation receipt: issued', result.stdout)
        self.assertTrue(Path(self.receipt_data()['result_bundle']).is_dir())

    def test_grouped_build_failure_never_launches_test_groups(self):
        self.run_runner('--grouped', execution=None, rc=65, BUILD_RC='65')
        self.assertFalse(self.receipt.exists())
        self.assertNotIn('groups', self.trace())

    def test_group_failure_cannot_publish_seed_or_receipt(self):
        self.run_runner('--grouped', execution=None, rc=1, GROUP_RC='1')
        self.assertFalse(self.receipt.exists())
        self.assertNotIn('publish', self.trace())
        self.assertNotIn('eval', self.trace())

    def test_conflicting_execution_options_stop_before_setup(self):
        self.run_runner('--grouped', rc=2)
        self.assertEqual(self.calls, [])

    def test_grouped_mode_requires_full_local_debug(self):
        for args, env in [(('--filter', 'Target/Suite'), {}),
                          (('--configuration', 'Release'), {}),
                          ((), {'CI': 'true'}),
                          ((), {'EW_LANE_REQUIRED_BUNDLES': 'EnviousWisprTests'})]:
            with self.subTest(args=args, env=env):
                self.run_runner('--grouped', *args, execution=None, rc=2, **env)
                self.assertEqual(self.calls, [])

    def test_int_during_helper_startup_stops_it_before_generation(self):
        marker, gate = self.root / 'queue-startup', self.root / 'hold-queue-startup'
        gate.write_text('hold')
        queue = self.root / 'scripts/local-ci-queue.py'
        source = queue.read_text()
        entry = 'def acquire(fd):\n    checked_descriptor(fd)\n'
        self.assertEqual(source.count(entry), 1)
        # A private copy holds the observed startup state before custom signal
        # handlers exist. An INT forwarded unchanged would be lost here.
        pause = (f'    signal.signal(signal.SIGINT, signal.SIG_IGN)\n'
                 f'    Path({str(marker)!r}).write_text("ready")\n'
                 f'    deadline = time.monotonic() + 8\n'
                 f'    while Path({str(gate)!r}).exists() and time.monotonic() < deadline:\n'
                 f'        time.sleep(0.01)  # deadline-fallback: fixture startup gate\n')
        queue.write_text(source.replace(entry, entry + pause))
        owner = subprocess.Popen(['bash', str(self.root / 'scripts/xcode-test.sh'),
                                  '--filter', 'Target/Suite', '--log-dir', str(self.root / 'logs-startup')],
                                 env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)  # deadline-fallback: subject announces startup
            self.assertTrue(marker.exists())
            owner.send_signal(signal.SIGINT)
            out, _ = owner.communicate(timeout=3)
            self.assertEqual(owner.returncode, 130, out)
            self.assertFalse(self.lock.exists())
            self.assertFalse(self.receipt.exists())
            self.assertNotIn('generate', self.trace())
        finally:
            if owner.poll() is None:
                os.killpg(owner.pid, signal.SIGTERM)
                owner.communicate(timeout=15)

    def test_queued_top_level_pid_cancellation_releases_checkout_lock(self):
        queue = self.root / 'private-queue/runner.lock'
        queue.parent.mkdir()
        fd = os.open(queue, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        owner = subprocess.Popen(['bash', str(self.root / 'scripts/xcode-test.sh'),
                                  '--serial', '--log-dir', str(self.root / 'logs-queued')],
                                 env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, start_new_session=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(owner.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(timeout=10), 'queued runner did not announce its wait')
                self.assertIn('waiting', owner.stdout.readline())
            self.assertTrue(self.lock.exists())
            self.assertNotIn('generate', self.trace())
            owner.send_signal(signal.SIGTERM)
            out, _ = owner.communicate(timeout=15)
            self.assertNotEqual(owner.returncode, 0, out)
            self.assertFalse(self.lock.exists())
            self.assertFalse(self.receipt.exists())
        finally:
            if owner.poll() is None:
                os.killpg(owner.pid, signal.SIGTERM)
                owner.communicate(timeout=15)
            os.close(fd)

    def test_top_level_pid_cancellation_waits_for_supervisor_before_unlock(self):
        hold, started = self.root / 'hold-groups', self.root / 'started-groups'
        hold.write_text('hold')
        owner = subprocess.Popen(['bash', str(self.root / 'scripts/xcode-test.sh'),
                                  '--grouped', '--log-dir', str(self.root / 'logs-groups')],
                                 env=dict(self.env, HOLD=str(hold), STARTED=str(started)),
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not started.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(started.exists())
            owner.send_signal(signal.SIGTERM)  # parent only, no group-wide shortcut
            out, _ = owner.communicate(timeout=15)
            self.assertNotEqual(owner.returncode, 0, out)
            self.assertIn('groups-stopped:lock=1', self.trace())
            self.assertFalse(self.lock.exists())
            self.assertFalse(self.receipt.exists())
        finally:
            if owner.poll() is None:
                os.killpg(owner.pid, signal.SIGTERM)
                owner.communicate(timeout=15)

    def stub_hook_installer(self):
        hooks = self.root / 'scripts/githooks'
        hooks.mkdir(parents=True)
        installer = hooks / 'install.sh'
        installer.write_text('#!/usr/bin/env bash\necho "hooks:$*" >> "$TRACE"\nexit "${HOOKS_RC:-0}"\n')
        installer.chmod(0o755)

    def test_hook_check_runs_before_setup(self):
        self.stub_hook_installer()
        result = self.run_runner()
        trace = (self.root / 'trace').read_text().splitlines()
        self.assertEqual(trace[0], 'hooks:--ensure')
        self.assertEqual(trace.count('hooks:--ensure'), 1)
        self.assertNotIn('git hooks: not active', result.stdout)
        self.assertEqual(self.configurations(), ['Debug'])

    def test_hook_problem_is_reported_and_never_stops_the_run(self):
        self.stub_hook_installer()
        result = self.run_runner(HOOKS_RC='3')
        self.assertIn('git hooks: not active for this checkout', result.stdout)
        self.assertEqual(self.configurations(), ['Debug'])
        self.assertIn('verdict:Debug lane:required=unset', (self.root / 'trace').read_text())

    def test_selection_missing_from_result_bundle_fails(self):
        result = self.run_runner('--filter', 'Target/SuiteA', '--filter', 'Target/Typo', rc=1,
                                 OMIT_SELECTION='Target/Typo')
        self.assertIn('\n  Target/Typo\n', result.stdout)
        self.assertNotIn('\n  Target/SuiteA\n', result.stdout)
        self.assertFalse((self.root / 'published-state').exists())

    def test_selection_confirmed_by_its_test_cases(self):
        result = self.run_runner('--filter', 'Target/SuiteA', NODE_SUFFIX='/caseOne()')
        self.assertIn('ran all 1 selection(s)', result.stdout)

    def test_test_selection_without_signature_matches(self):
        result = self.run_runner('--filter', 'Target/Suite/caseOne', NODE_SUFFIX='()')
        self.assertIn('ran all 1 selection(s)', result.stdout)

    def test_unreadable_result_bundle_fails(self):
        self.run_runner('--filter', 'Target/SuiteA', rc=1, XCRESULT_RC='1')
        self.assertFalse((self.root / 'published-state').exists())

    def test_option_is_not_taken_as_a_value(self):
        self.run_runner('--filter', 'Target/SuiteA', '--filter', '--release', rc=2)
        self.assertEqual(self.calls, [])

    def test_release_cut_can_run_release_alone(self):
        bundle = str(self.root / 'release receipt.xcresult')
        self.run_runner('--configuration', 'Release', '--result-bundle-path', bundle)
        self.assertEqual(self.configurations(), ['Release'])
        self.assertIn('EnviousWispr-Release', self.calls[0])
        self.assertIn('ENABLE_TESTABILITY=YES', self.tests[0])
        self.assertIn(bundle, self.tests[0])

    def test_release_retained_packages_are_published_after_refresh(self):
        # A retained complete tree is not freshly seeded; the real helper skips
        # explicit resolution here. Only the selected test build refreshes it.
        self.run_runner('--configuration', 'Release', STUB_SEEDED='0')
        self.assertEqual(len(self.calls), 1)
        self.assertEqual((self.root / 'published-state').read_text(),
                         'current lockfile dependencies')
        trace = (self.root / 'trace').read_text().splitlines()
        self.assertTrue(trace[-2].startswith('verdict:Release lane:'))
        self.assertEqual(trace[-1], 'publish')

    def test_legacy_release_preserves_both_lanes(self):
        self.run_runner('--release', '--filter', 'Target/Suite')
        self.assertEqual(self.configurations(), ['Debug', 'Release'])
        self.assertTrue(all('-only-testing:Target/Suite' in row for row in self.tests))

    def test_explicit_both(self):
        self.run_runner('--configuration', 'both')
        self.assertEqual(self.configurations(), ['Debug', 'Release'])

    def test_invalid_configuration_before_setup(self):
        self.run_runner('--configuration', 'Fast', rc=2)
        self.assertEqual(self.calls, [])

    def test_conflicting_selection_before_setup(self):
        self.run_runner('--configuration', 'Debug', '--release', rc=2)
        self.assertEqual(self.calls, [])

    def test_both_rejects_single_result_path(self):
        self.run_runner('--release', '--result-bundle-path', str(self.root / 'one.xcresult'), rc=2)
        self.assertEqual(self.calls, [])

    def test_xcode_failure_is_not_swallowed(self):
        self.run_runner('--release', rc=65, XCODE_RC='65')
        self.assertEqual(self.configurations(), ['Debug'])
        self.assertFalse((self.root / 'published-state').exists())

    def test_verdict_failure_is_not_swallowed(self):
        self.run_runner('--release', rc=1, VERDICT_RC='1')
        self.assertEqual(self.configurations(), ['Debug'])
        self.assertFalse((self.root / 'published-state').exists())

    # --- #3729 PR-C: the validation receipt -------------------------------

    def assert_no_receipt(self, result, reason=None):
        self.assertFalse(self.receipt.exists(), result.stdout)
        if reason:
            self.assertIn(reason, result.stdout)

    def test_full_run_compiles_eval_then_publishes_a_receipt(self):
        tree = self.git('write-tree')
        result = self.run_runner()
        trace = self.trace()
        self.assertEqual(trace.count('eval'), 1)
        self.assertLess(trace.index('verdict:Debug lane:required=unset'), trace.index('eval'))
        data = self.receipt_data()
        self.assertEqual(data['tree'], tree)
        self.assertEqual(data['head'], self.git('rev-parse', 'HEAD'))
        self.assertEqual((data['toolchain'], data['executed_tests'], data['bundles']),
                         ('27A266a', 2, ['EnviousWisprTests', 'EnviousWisprDesktopEffectsTests', 'EnviousWisprASRTests']))
        self.assertEqual((data['configuration'], data['debug_verdict'], data['eval_verdict']),
                         ('Debug', 'PASS', 'PASS'))
        self.assertIn('validation receipt: issued', result.stdout)
        self.assertFalse(self.lock.exists())

    def test_staged_matching_change_binds_the_index_tree(self):
        (self.root / 'Sources/A.swift').write_text('let a = 2\n')
        self.git('add', 'Sources/A.swift')
        self.run_runner()
        self.assertEqual(self.receipt_data()['tree'], self.git('write-tree'))
        self.assertNotEqual(self.receipt_data()['tree'], self.git('rev-parse', 'HEAD^{tree}'))

    def test_unstaged_tracked_change_issues_no_receipt(self):
        (self.root / 'Sources/A.swift').write_text('let a = 2\n')
        result = self.run_runner(EW_ALLOW_NO_RECEIPT='1')
        self.assert_no_receipt(result, 'differs from the index')
        self.assertIn('eval', self.trace())  # the full run still validates

    # #3729: an ineligible full run stops before any build instead of reporting at the end.
    def test_ineligible_full_run_stops_before_setup(self):
        (self.root / 'Sources/A.swift').write_text('let a = 2\n')
        result = self.run_runner(rc=2)
        self.assertIn('differs from the index', result.stdout)
        self.assertIn('EW_ALLOW_NO_RECEIPT=1', result.stdout)
        self.assertEqual(self.tests, [])
        self.assertNotIn('eval', self.trace())
        self.assertFalse(self.receipt.exists())
        self.assertFalse(self.lock.exists())

    def test_ineligible_untracked_input_is_named(self):
        # Scratch files that sort BEFORE the real input must not crowd it out (#3729 review):
        # .github/ sorts before Sources/ and is not a build input for the stand-in classifier.
        scratch = self.root / '.github'
        scratch.mkdir(exist_ok=True)
        for n in range(5):
            (scratch / f'a{n}.txt').write_text('scratch\n')
        (self.root / 'Sources/New.swift').write_text('x\n')
        result = self.run_runner(rc=2)
        self.assertIn('Sources/New.swift', result.stdout)
        self.assertNotIn('.github/a0.txt', result.stdout)
        self.assertEqual(self.tests, [])

    def test_untracked_build_input_issues_no_receipt(self):
        (self.root / 'Sources/New.swift').write_text('x\n')
        self.assert_no_receipt(self.run_runner(EW_ALLOW_NO_RECEIPT='1'), 'untracked file is a build input')

    def test_untracked_eval_input_issues_no_receipt(self):
        (self.root / 'scripts/eval').mkdir()
        (self.root / 'scripts/eval/x.swift').write_text('x\n')
        self.assert_no_receipt(self.run_runner(EW_ALLOW_NO_RECEIPT='1'), 'eval-package input')

    def test_unrelated_untracked_file_still_issues_a_receipt(self):
        (self.root / 'notes.txt').write_text('scratch\n')
        self.run_runner()
        self.assertTrue(self.receipt.exists())

    def test_working_file_changed_mid_run_issues_no_receipt(self):
        result = self.run_runner(MUTATE='Sources/A.swift')
        self.assert_no_receipt(result, 'an input changed during the run')

    def test_index_changed_mid_run_issues_no_receipt(self):
        result = self.run_runner(MUTATE='Sources/A.swift', MUTATE_STAGE='1')
        self.assert_no_receipt(result, 'an input changed during the run')

    def test_toolchain_changed_mid_run_issues_no_receipt(self):
        result = self.run_runner(TOOLCHAIN_FLAG=str(self.root / 'toolchain-swapped'))
        self.assert_no_receipt(result, 'an input changed during the run')

    def test_failed_eval_compile_fails_and_issues_no_receipt(self):
        result = self.run_runner(rc=1, EVAL_RC='1')
        self.assert_no_receipt(result, 'eval packages verdict: FAIL')

    def test_filtered_run_invalidates_and_neither_compiles_eval_nor_issues_a_receipt(self):
        self.run_runner()
        self.assertTrue(self.receipt.exists())
        self.run_runner('--filter', 'Target/SuiteA')
        self.assertEqual(self.trace().count('eval'), 1)  # only the first, full run compiled
        self.assertFalse(self.receipt.exists())
        self.assertFalse(self.lock.exists())

    def test_release_only_run_invalidates_and_neither_compiles_eval_nor_issues_a_receipt(self):
        self.run_runner()
        self.assertTrue(self.receipt.exists())
        self.run_runner('--configuration', 'Release')
        self.assertEqual(self.trace().count('eval'), 1)
        self.assertFalse(self.receipt.exists())
        self.assertFalse(self.lock.exists())

    def test_ci_mode_issues_no_receipt(self):
        self.assert_no_receipt(self.run_runner(CI='true'), 'CI mode')

    def test_weakened_bundle_list_issues_no_receipt(self):
        result = self.run_runner(EW_LANE_REQUIRED_BUNDLES='EnviousWisprTests')
        self.assert_no_receipt(result, 'EW_LANE_REQUIRED_BUNDLES overrides')

    def test_a_failed_run_invalidates_the_previous_receipt(self):
        self.run_runner()
        self.assertTrue(self.receipt.exists())
        self.run_runner(rc=1, VERDICT_RC='1')
        self.assertFalse(self.receipt.exists())
        self.assertFalse(self.lock.exists())

    def test_publication_collision_is_a_failure(self):
        result = self.run_runner(rc=1, PLANT_RECEIPT='1')
        self.assertIn('could not be published', result.stdout)
        self.assertEqual(self.receipt.read_text(), '{}')  # the planted file, never overwritten

    def test_an_existing_lock_refuses_every_kind_of_run_without_touching_anything(self):
        self.run_runner()
        before, tests_before = self.receipt.read_bytes(), len(self.tests)
        self.lock.mkdir()
        (self.lock / 'pid').write_text(f'{os.getpid()}\n')
        for args in ((), ('--filter', 'Target/SuiteA'), ('--configuration', 'Release')):
            result = self.run_runner(*args, rc=2)
            self.assertIn(f'validation lock exists: {self.lock} (pid {os.getpid()})', result.stdout)
            self.assertEqual(self.receipt.read_bytes(), before)
            self.assertEqual(len(self.tests), tests_before)  # no test command ran
            self.assertEqual((self.lock / 'pid').read_text().strip(), str(os.getpid()))

    def test_an_abandoned_lock_is_refused_until_removed(self):
        dead = subprocess.Popen(['true']); dead.wait()
        self.lock.parent.mkdir(parents=True)
        self.lock.mkdir()
        (self.lock / 'pid').write_text(f'{dead.pid}\n')
        result = self.run_runner(rc=2)
        self.assertIn(f"remove the lock with: rm -r '{self.lock}'", result.stdout)
        self.assertTrue(self.lock.exists())
        shutil.rmtree(self.lock)  # the owned fixture's abandoned lock, as the message says
        self.run_runner()
        self.assertTrue(self.receipt.exists())
        self.assertFalse(self.lock.exists())

    def start_held_run(self, log_dir):
        hold, started = self.root / 'hold', self.root / f'started-{log_dir}'
        hold.write_text('hold')
        proc = subprocess.Popen(['bash', str(self.root / 'scripts/xcode-test.sh'),
                                 '--log-dir', str(self.root / log_dir), '--serial'],
                                env=dict(self.env, HOLD=str(hold), STARTED=str(started)),
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                start_new_session=True)
        deadline = time.time() + 10
        while not started.exists() and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(started.exists(), 'the held run never reached its test command')
        return proc, hold

    def test_two_attempts_one_publishes_and_the_other_cannot_disturb_it(self):
        owner, hold = self.start_held_run('logs-owner')
        rival = subprocess.run(['bash', str(self.root / 'scripts/xcode-test.sh'),
                                '--log-dir', str(self.root / 'logs-rival')],
                               env=self.env, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=15)
        self.assertEqual(rival.returncode, 2, rival.stdout)
        self.assertIn('validation lock exists', rival.stdout)
        filtered = subprocess.run(['bash', str(self.root / 'scripts/xcode-test.sh'),
                                   '--log-dir', str(self.root / 'logs-filtered'), '--filter', 'Target/SuiteA'],
                                  env=self.env, text=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, timeout=15)
        self.assertEqual(filtered.returncode, 2, filtered.stdout)
        self.assertTrue(self.lock.exists())
        self.assertEqual((self.lock / 'pid').read_text().strip(), str(owner.pid))
        hold.unlink()
        out, _ = owner.communicate(timeout=15)
        self.assertEqual(owner.returncode, 0, out)
        self.assertIn('validation receipt: issued', out)
        self.assertTrue(self.receipt.exists())
        self.assertFalse(self.lock.exists())

    def test_interruption_releases_the_lock_and_issues_no_receipt(self):
        owner, hold = self.start_held_run('logs-owner')
        os.killpg(owner.pid, signal.SIGTERM)
        owner.communicate(timeout=15)
        self.assertNotEqual(owner.returncode, 0)
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.receipt.exists())
        hold.unlink()
        self.run_runner()  # the next attempt can run
        self.assertTrue(self.receipt.exists())


class EvalCompileContract(unittest.TestCase):
    """The real compile-eval-packages.sh against a recorded `swift` and pin seeder:
    three Release compiles, serially, each in its own package path, tracked pins."""

    def test_three_serial_pinned_release_compiles(self):
        with tempfile.TemporaryDirectory(prefix='ew-eval-contract-') as tmp:
            root = Path(tmp)
            (root / 'scripts/ci').mkdir(parents=True)
            shutil.copyfile(RUNNER.parent / 'ci/compile-eval-packages.sh', root / 'scripts/ci/compile-eval-packages.sh')
            (root / 'scripts/ci/seed-eval-package-pins.py').write_text(
                'import sys\nopen(sys.argv[-1] + ".seeded", "w").write("x")\n')
            (root / 'Package.resolved').write_text('{}')
            for pkg in ('apple_runner', 'alias_runner', 'prompt_render'):
                (root / 'scripts/eval' / pkg).mkdir(parents=True)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            swift = bin_dir / 'swift'
            swift.write_text('#!/usr/bin/env bash\necho "$*" >> "$SWIFT_CALLS"\n')
            swift.chmod(0o755)
            calls = root / 'swift-calls'
            r = subprocess.run(['bash', 'scripts/ci/compile-eval-packages.sh'], cwd=root, text=True,
                               env=dict(os.environ, PATH=f'{bin_dir}{os.pathsep}{os.environ["PATH"]}',
                                        SWIFT_CALLS=str(calls)),
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
            self.assertEqual(r.returncode, 0, r.stdout)
            rows = calls.read_text().splitlines()
            self.assertEqual(rows, [f'build -c release --package-path scripts/eval/{p} --only-use-versions-from-resolved-file'
                                    for p in ('apple_runner', 'alias_runner', 'prompt_render')])
            for pkg in ('apple_runner', 'alias_runner', 'prompt_render'):
                self.assertTrue((root / f'scripts/eval/{pkg}.seeded').exists())



class BuildEntrypointHookContract(unittest.TestCase):
    """The real build-dev-app.sh up to its signing preflight, which a stub `security`
    fails on purpose, so nothing is locked, quit, built or launched."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ew-build-contract-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        lib = self.root / 'scripts/lib'
        lib.mkdir(parents=True)
        shutil.copyfile(RUNNER.with_name('build-dev-app.sh'), self.root / 'scripts/build-dev-app.sh')
        (lib / 'ensure-generated.sh').write_text('ew_ensure_generated() { echo generate >> "$TRACE"; }\n')
        (lib / 'launch-check.sh').write_text(':\n')
        (lib / 'spm-seed.sh').write_text('ew_seed_release_all() { :; }\n')
        (lib / 'l10n-build-with-receipt.sh').write_text(':\n')
        hooks = self.root / 'scripts/githooks'
        hooks.mkdir()
        installer = hooks / 'install.sh'
        installer.write_text('#!/usr/bin/env bash\necho "hooks:$*" >> "$TRACE"\nexit "${HOOKS_RC:-0}"\n')
        installer.chmod(0o755)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        security = bin_dir / 'security'
        security.write_text('#!/usr/bin/env bash\necho security >> "$TRACE"\n')
        security.chmod(0o755)
        self.env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                        TRACE=str(self.root / 'trace'))
        self.env.pop('HOOKS_RC', None)

    def run_build(self, **env):
        result = subprocess.run(['bash', str(self.root / 'scripts/build-dev-app.sh')],
                                env=dict(self.env, **env), text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        # The stub preflight finds no signing identity, so the script stops there.
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("no 'EnviousWispr Dev' code-signing identity", result.stdout)
        self.assertEqual((self.root / 'trace').read_text().splitlines(), ['hooks:--ensure', 'security'])
        return result

    def test_hook_check_runs_once_before_the_preflight(self):
        result = self.run_build()
        self.assertNotIn('git hooks: not active', result.stdout)

    def test_hook_problem_is_reported_and_the_build_continues(self):
        result = self.run_build(HOOKS_RC='3')
        self.assertIn('git hooks: not active for this checkout', result.stdout)


if __name__ == '__main__':
    unittest.main(argv=[__file__, *UNIT_ARGS])
