#!/usr/bin/env python3
"""Exercise the real runner with private, recorded Xcode/setup boundaries.

No app compilation or real cache deletion. Pass --runner PATH for a baseline
control. These checks prove command orchestration, not Xcode test discovery.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
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
        (lib / 'lane-verdict.sh').write_text('''ew_lane_verdict() {
  echo "verdict:$3:required=${EW_LANE_REQUIRED_BUNDLES-unset}" >> "$TRACE"
  return "${VERDICT_RC:-0}"
}
''')
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        xcode = bin_dir / 'xcodebuild'
        xcode.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps(args) + '\\n')
if args[0] == 'test':
    Path(args[args.index('-resultBundlePath') + 1]).mkdir()
    Path(os.environ['PACKAGE_STATE']).write_text('current lockfile dependencies')
    print('Test run with 2 tests passed.')
    sys.exit(int(os.environ.get('XCODE_RC', '0')))
''')
        xcode.chmod(0o755)
        self.env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                        TRACE=str(self.root / 'trace'), CALLS=str(self.root / 'calls'),
                        DERIVED_DATA_PATH=str(self.root / 'derived'),
                        PACKAGE_STATE=str(self.root / 'package-state'),
                        PUBLISHED_STATE=str(self.root / 'published-state'), STUB_SEEDED='1')
        (self.root / 'package-state').write_text('old lockfile dependencies')
        self.env.pop('XCODE_RC', None)
        self.env.pop('VERDICT_RC', None)
        self.sentinel = self.root / 'derived/keep-cache'
        self.sentinel.parent.mkdir()
        self.sentinel.write_text('unchanged compatible cache')

    def run_runner(self, *args, rc=0, **env):
        result = subprocess.run(['bash', str(self.root / 'scripts/xcode-test.sh'),
                                 '--log-dir', str(self.root / 'logs'), *args],
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

    def test_default_is_full_debug_with_required_bundles(self):
        self.run_runner()
        self.assertEqual(self.configurations(), ['Debug'])
        self.assertFalse(any(arg.startswith('-only-testing:') for arg in self.tests[0]))
        self.assertIn('verdict:Debug lane:required=unset', (self.root / 'trace').read_text())

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


if __name__ == '__main__':
    unittest.main(argv=[__file__, *UNIT_ARGS])
