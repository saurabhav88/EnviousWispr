#!/usr/bin/env python3
"""Harness contract tests for fixture.py (#4586 PR 0 chunk 1). Offline: no app, no lock, no AX.

These protect the instrument, not product speed. Expected values are literals written here, never
values read back through fixture.py's own inventory.

    python3 -B -m unittest discover -s Tests/RuntimeUAT/history_speed -p '*_test.py' -v
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fixture  # noqa: E402

CORPUS = {
    "transcripts": {"a.json": b'{"text": "alpha"}', "b.json": b'{"text": "beta"}'},
    "Meetings": {"m1/meeting.json": b'{"title": "standup"}', "m1/audio/chunk-0.caf": b"\x00\x01\x02"},
    "recordings": {"r1.m4a": b"\x10\x11"},
}

# The profile the 2026-11-14 speed run used, verbatim (run folder
# 20261114-122705-3147-history-catalog-build-10ed/isolated-release.sb).
ORIGINAL_PROFILE = """(version 1)
(allow default)
(deny file-write* (subpath "/Users/m4pro_sv/Library/Application Support/EnviousWispr"))
(deny file-read-data (subpath "/Users/m4pro_sv/Library/Application Support/EnviousWispr"))
(deny file-write* (subpath "/Users/m4pro_sv/EnviousWispr"))
(deny file-read-data (subpath "/Users/m4pro_sv/EnviousWispr"))
(deny file-write* (regex #"^/Users/m4pro_sv/Library/Preferences/com\\.enviouswispr\\..*"))
(deny file-write* (subpath "/Users/m4pro_sv/Library/Containers/com.enviouswispr.app"))
(deny file-write* (subpath "/Users/m4pro_sv/Library/Logs/EnviousWispr"))
(deny network-outbound)
"""


def write_corpus(root: Path) -> None:
    for category, files in CORPUS.items():
        for relative, data in files.items():
            path = root / category / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)


class Temp(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name).resolve()
        self.source = self.root / "source"
        write_corpus(self.source)
        self.seed = self.root / "seed"
        # A fake real home, so the unsafe-destination rule is tested without touching the real one.
        self.fake_home = self.root / "realhome"
        (self.fake_home / "Library").mkdir(parents=True)
        patcher = mock.patch.object(fixture.Path, "home", return_value=self.fake_home)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        self._dir.cleanup()


class SeedTests(Temp):
    def test_seed_manifest_matches_literal_corpus(self):
        manifest = fixture.build_seed(self.source, self.seed)
        expected = {c: {p: hashlib.sha256(d).hexdigest() for p, d in files.items()}
                    for c, files in CORPUS.items()}
        self.assertEqual(manifest["categories"], expected)
        self.assertEqual(manifest["counts"], {"transcripts": 2, "Meetings": 2, "recordings": 1})
        self.assertIn("not recorded", manifest["origin"])
        on_disk = json.loads((self.seed / "manifest.json").read_text())
        self.assertEqual(on_disk["categories"], expected)

    def test_seed_refuses_existing_destination(self):
        self.seed.mkdir()
        with self.assertRaisesRegex(fixture.FixtureError, "already exists"):
            fixture.build_seed(self.source, self.seed)

    def test_seed_refuses_missing_category(self):
        (self.source / "recordings" / "r1.m4a").unlink()
        (self.source / "recordings").rmdir()
        with self.assertRaisesRegex(fixture.FixtureError, "missing source category"):
            fixture.build_seed(self.source, self.seed)

    def test_seed_refuses_symlink(self):
        (self.source / "transcripts" / "link.json").symlink_to(self.source / "transcripts" / "a.json")
        with self.assertRaisesRegex(fixture.FixtureError, "symlink"):
            fixture.build_seed(self.source, self.seed)

    def test_verify_detects_changed_missing_and_extra(self):
        fixture.build_seed(self.source, self.seed)
        fixture.verify_seed(self.seed)
        (self.seed / "transcripts" / "a.json").write_bytes(b"tampered")
        with self.assertRaisesRegex(fixture.FixtureError, "1 changed"):
            fixture.verify_seed(self.seed)
        (self.seed / "transcripts" / "a.json").write_bytes(CORPUS["transcripts"]["a.json"])
        (self.seed / "recordings" / "r1.m4a").unlink()
        with self.assertRaisesRegex(fixture.FixtureError, "1 missing"):
            fixture.verify_seed(self.seed)
        (self.seed / "recordings" / "r1.m4a").write_bytes(CORPUS["recordings"]["r1.m4a"])
        (self.seed / "Meetings" / "stray.txt").write_bytes(b"x")
        with self.assertRaisesRegex(fixture.FixtureError, "1 extra"):
            fixture.verify_seed(self.seed)

    def test_verify_refuses_missing_manifest(self):
        fixture.build_seed(self.source, self.seed)
        (self.seed / "manifest.json").unlink()
        with self.assertRaisesRegex(fixture.FixtureError, "no manifest"):
            fixture.verify_seed(self.seed)


class HomeTests(Temp):
    def setUp(self):
        super().setUp()
        fixture.build_seed(self.source, self.seed)

    def test_regenerate_copies_every_category_exactly(self):
        home = fixture.regenerate_home(self.seed, self.root / "home")
        support = home / "Library/Application Support/EnviousWispr"
        counts = {}
        for category, files in CORPUS.items():
            for relative, data in files.items():
                self.assertEqual((support / category / relative).read_bytes(), data)
            counts[category] = sum(1 for p in (support / category).rglob("*") if p.is_file())
        self.assertEqual(counts, {"transcripts": 2, "Meetings": 2, "recordings": 1})
        self.assertFalse((support / "HistoryCatalog").exists())
        self.assertTrue((home / "isolated-release.sb").is_file())

    def test_regenerate_refuses_existing_home(self):
        (self.root / "home").mkdir()
        with self.assertRaisesRegex(fixture.FixtureError, "already exists"):
            fixture.regenerate_home(self.seed, self.root / "home")

    def test_regenerate_refuses_missing_parent(self):
        with self.assertRaisesRegex(fixture.FixtureError, "parent does not exist"):
            fixture.regenerate_home(self.seed, self.root / "nope" / "home")

    def test_regenerate_refuses_real_home_and_library(self):
        for target in (self.fake_home / "fixture", self.fake_home / "Library" / "fixture"):
            with self.assertRaisesRegex(fixture.FixtureError, "real home or Library"):
                fixture.regenerate_home(self.seed, target)
        self.assertEqual(sorted(p.name for p in self.fake_home.iterdir()), ["Library"])

    def test_regenerate_refuses_tampered_seed(self):
        (self.seed / "transcripts" / "b.json").write_bytes(b"changed")
        with self.assertRaisesRegex(fixture.FixtureError, "differs from the manifest"):
            fixture.regenerate_home(self.seed, self.root / "home")
        self.assertFalse((self.root / "home").exists())


class LaunchTests(Temp):
    def setUp(self):
        super().setUp()
        fixture.build_seed(self.source, self.seed)
        self.home = fixture.regenerate_home(self.seed, self.root / "home")
        self.app = self.root / "EnviousWispr.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/EnviousWispr").write_bytes(b"")
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": fixture.SUBJECT_BUNDLE_ID}, handle)
        self.exe = str(self.app / "Contents/MacOS/EnviousWispr")
        self.spawned = []

    def spawn(self, argv, **kw):
        self.spawned.append((argv, kw))
        return mock.Mock(pid=4242)

    def test_profile_keeps_every_original_rule_and_adds_credential_denies(self):
        profile = fixture.sandbox_profile(Path("/Users/m4pro_sv")).splitlines()
        original = ORIGINAL_PROFILE.splitlines()
        rules = [line for line in profile if not line.lstrip().startswith(";")]
        positions = [rules.index(line) for line in original]
        self.assertEqual(positions, sorted(positions))
        for line in [
            '(deny file-write* (subpath "/Users/m4pro_sv/.enviouswispr-keys"))',
            '(deny file-read-data (subpath "/Users/m4pro_sv/.enviouswispr-keys"))',
            '(deny file-write* (subpath "/Users/m4pro_sv/.enviouswispr-recovery-keys"))',
            '(deny file-read-data (subpath "/Users/m4pro_sv/.enviouswispr-recovery-keys"))',
            '(deny file-write* (subpath "/Users/m4pro_sv/Library/HTTPStorages/com.enviouswispr.app"))',
            '(deny file-write* (literal "/Users/m4pro_sv/Library/HTTPStorages/com.enviouswispr.app.binarycookies"))',
        ]:
            self.assertIn(line, rules)

    def test_plan_isolates_child_without_touching_caller(self):
        before = dict(os.environ)
        plan = fixture.launch_plan(self.app, self.home)
        self.assertEqual(dict(os.environ), before)
        self.assertEqual(plan.env["HOME"], str(self.home))
        self.assertEqual(plan.env["CFFIXED_USER_HOME"], str(self.home))
        self.assertEqual(plan.argv, ("/usr/bin/sandbox-exec", "-f", str(self.home / "isolated-release.sb"),
                                     self.exe, "-onboardingState", "completed",
                                     "-recordingStorageWarningThreshold", "none"))

    def test_storage_warning_is_off_by_default_and_on_only_when_asked(self):
        # The banner moves the page during open-History timing; the labelled jump check turns it on.
        on = fixture.launch_plan(self.app, self.home, storage_warning=True)
        self.assertNotIn("-recordingStorageWarningThreshold", on.argv)
        self.assertEqual(on.argv[-2:], ("-onboardingState", "completed"))

    def test_plan_refuses_the_production_identity_on_every_route(self):
        # PR #4658 review: the CLI `launch --app /Applications/EnviousWispr.app` must never start
        # production. Same app, production identity: the plan, the launch and the CLI all refuse.
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": fixture.PRODUCTION_DOMAIN}, handle)
        with self.assertRaisesRegex(fixture.FixtureError, "not the renamed subject"):
            fixture.launch_plan(self.app, self.home)
        with self.assertRaisesRegex(fixture.FixtureError, "not the renamed subject"):
            fixture.launch(self.app, self.home, Path(os.devnull), owner_check=lambda: None,
                           instances=lambda: {}, spawn=self.spawn)
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            status = fixture.main(["launch", "--app", str(self.app), "--home", str(self.home)])
        self.assertEqual(status, 2)
        self.assertIn("not the renamed subject", err.getvalue())
        self.assertEqual(self.spawned, [])
        (self.app / "Contents/Info.plist").unlink()   # no plist at all is refused too
        with self.assertRaisesRegex(fixture.FixtureError, "not the renamed subject"):
            fixture.launch_plan(self.app, self.home)

    def test_plan_refuses_a_folder_that_is_not_a_fixture_home(self):
        plain = self.root / "plain"
        plain.mkdir()
        with self.assertRaisesRegex(fixture.FixtureError, "not a regenerated fixture home"):
            fixture.launch_plan(self.app, plain)

    def test_launch_positive_control_spawns_the_plan(self):
        pid = fixture.launch(self.app, self.home, Path(os.devnull), owner_check=lambda: None,
                             instances=lambda: {}, spawn=self.spawn)
        self.assertEqual(pid, 4242)
        self.assertEqual(len(self.spawned), 1)
        argv, kw = self.spawned[0]
        self.assertEqual(argv[3], self.exe)
        self.assertEqual(kw["env"]["HOME"], str(self.home))

    def test_launch_refusals_spawn_nothing(self):
        def denied():
            raise RuntimeError("dev-app lock held by another session")

        def unreadable():
            raise OSError("ps failed")

        cases = [
            ("denied ownership", dict(owner_check=denied, instances=lambda: {}), RuntimeError),
            ("unreadable instances", dict(owner_check=lambda: None, instances=unreadable), fixture.FixtureError),
            ("undecidable instances", dict(owner_check=lambda: None, instances=lambda: None), fixture.FixtureError),
            ("same executable running", dict(owner_check=lambda: None, instances=lambda: {77: self.exe}),
             fixture.FixtureError),
        ]
        for name, kw, error in cases:
            with self.subTest(name), self.assertRaises(error):
                fixture.launch(self.app, self.home, Path(os.devnull), spawn=self.spawn, **kw)
        self.assertEqual(self.spawned, [])

    def test_launch_allows_a_different_executable(self):
        fixture.launch(self.app, self.home, Path(os.devnull), owner_check=lambda: None,
                       instances=lambda: {77: "/Applications/EnviousWispr.app/Contents/MacOS/EnviousWispr"},
                       spawn=self.spawn)
        self.assertEqual(len(self.spawned), 1)


class SubjectTests(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name).resolve()
        self.app = self.root / "EnviousWispr.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/EnviousWispr").write_bytes(b"binary-bytes")
        subprocess.run(["/usr/bin/plutil", "-create", "xml1", str(self.app / "Contents/Info.plist")], check=True)
        subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Add :CFBundleIdentifier string com.enviouswispr.app",
                        str(self.app / "Contents/Info.plist")], check=True)
        self.sha = hashlib.sha256(b"binary-bytes").hexdigest()

    def tearDown(self):
        self._dir.cleanup()

    def test_subject_is_renamed_copy_with_identical_executable(self):
        subject = fixture.prepare_subject(self.app, self.root / "subject", self.sha)
        self.assertEqual(fixture.subject_identity(subject), "com.enviouswispr.app.historyspeed")
        self.assertEqual((subject / "Contents/MacOS/EnviousWispr").read_bytes(), b"binary-bytes")
        self.assertEqual(fixture.subject_identity(self.app), "com.enviouswispr.app")   # source untouched

    def test_subject_refuses_wrong_hash_and_existing_folder(self):
        with self.assertRaisesRegex(fixture.FixtureError, "hash differs"):
            fixture.prepare_subject(self.app, self.root / "subject", "0" * 64)
        self.assertFalse((self.root / "subject").exists())
        (self.root / "taken").mkdir()
        with self.assertRaisesRegex(fixture.FixtureError, "already exists"):
            fixture.prepare_subject(self.app, self.root / "taken", self.sha)

    def test_pid_must_run_exactly_the_subject(self):
        subject = fixture.prepare_subject(self.app, self.root / "subject", self.sha)
        exe = str(subject / "Contents/MacOS/EnviousWispr")
        self.assertEqual(fixture.require_subject_pid(7, subject, comm=lambda pid: exe), exe)
        for other in ("/Applications/EnviousWispr.app/Contents/MacOS/EnviousWispr",
                      "/Users/x/EW-peer/build/EnviousWispr Local.app/Contents/MacOS/EnviousWispr", None):
            with self.subTest(other), self.assertRaisesRegex(fixture.FixtureError, "not the subject"):
                fixture.require_subject_pid(7, subject, comm=lambda pid, o=other: o)
        with self.assertRaisesRegex(fixture.FixtureError, "not the renamed"):
            fixture.require_subject_pid(7, self.app, comm=lambda pid: exe)

    def test_existing_throwaway_state_refuses_a_session(self):
        home = self.root / "realhome"
        (home / "Library/Preferences").mkdir(parents=True)
        fixture.refuse_existing_throwaway(home, export=lambda domain: None)
        (home / "Library/Preferences/com.enviouswispr.app.historyspeed.plist").write_bytes(b"x")
        with self.assertRaisesRegex(fixture.FixtureError, "throwaway state already exists"):
            fixture.refuse_existing_throwaway(home, export=lambda domain: None)
        (home / "Library/Preferences/com.enviouswispr.app.historyspeed.plist").unlink()
        with self.assertRaisesRegex(fixture.FixtureError, "defaults domain"):
            fixture.refuse_existing_throwaway(home, export=lambda domain: {"k": 1})

    def test_cleanup_removes_only_the_throwaway_identity(self):
        home = self.root / "realhome"
        storages = home / "Library/HTTPStorages"
        (storages / "com.enviouswispr.app.historyspeed").mkdir(parents=True)
        (storages / "com.enviouswispr.app.historyspeed" / "httpstorages.sqlite").write_bytes(b"db")
        (storages / "com.enviouswispr.app").mkdir()
        (storages / "com.enviouswispr.app" / "keep").write_bytes(b"production")
        (home / "Library/Preferences").mkdir(parents=True)
        (home / "Library/Preferences/com.enviouswispr.app.plist").write_bytes(b"production prefs")
        calls = []
        removed = fixture.cleanup_throwaway(
            home, run=lambda argv, **kw: (calls.append(argv), subprocess.CompletedProcess(argv, 0))[1],
            export=lambda domain: None)
        self.assertEqual(calls, [["/usr/bin/defaults", "delete", "com.enviouswispr.app.historyspeed"]])
        self.assertFalse((storages / "com.enviouswispr.app.historyspeed").exists())
        self.assertEqual((storages / "com.enviouswispr.app" / "keep").read_bytes(), b"production")
        self.assertEqual((home / "Library/Preferences/com.enviouswispr.app.plist").read_bytes(), b"production prefs")
        self.assertIn(str(storages / "com.enviouswispr.app.historyspeed"), removed)


class ExportDomainTests(unittest.TestCase):
    EMPTY = (b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>')

    def run_with(self, read_rc, read_err=b"", export_out=b""):
        def run(argv, **kw):
            if argv[1] == "read":
                return subprocess.CompletedProcess(argv, read_rc, stdout=b"", stderr=read_err)
            return subprocess.CompletedProcess(argv, 0, stdout=export_out, stderr=b"")
        return run

    def test_never_existing_domain_is_none_although_export_prints_an_empty_dict(self):
        run = self.run_with(1, b"Domain 'x' not found.\n", self.EMPTY)
        self.assertIsNone(fixture.export_domain("x", run=run))

    def test_existing_domain_returns_its_values(self):
        body = (b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
                b'<key>k</key><string>v</string></dict></plist>')
        self.assertEqual(fixture.export_domain("x", run=self.run_with(0, export_out=body)), {"k": "v"})

    def test_other_read_failures_raise(self):
        with self.assertRaises(fixture.FixtureError):
            fixture.export_domain("x", run=self.run_with(1, b"some other failure"))


class CleanupVerificationTests(unittest.TestCase):
    def test_a_domain_that_survives_delete_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / "Library/HTTPStorages").mkdir(parents=True)
            with self.assertRaisesRegex(fixture.FixtureError, "still present after cleanup"):
                fixture.cleanup_throwaway(home, run=lambda argv, **kw: subprocess.CompletedProcess(argv, 1),
                                          export=lambda domain: {"left": True})


class ContainedSessionTests(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name).resolve()
        self.subject = self.root / "EnviousWispr.app"
        (self.subject / "Contents/MacOS").mkdir(parents=True)
        (self.subject / "Contents/MacOS/EnviousWispr").write_bytes(b"x")
        subprocess.run(["/usr/bin/plutil", "-create", "xml1", str(self.subject / "Contents/Info.plist")], check=True)
        subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Add :CFBundleIdentifier string com.enviouswispr.app.historyspeed",
                        str(self.subject / "Contents/Info.plist")], check=True)
        self.events = []
        self.still_running = None
        self.stop_effect = lambda: True

    def tearDown(self):
        self._dir.cleanup()

    def test_refused_stop_skips_cleanup(self):
        def refused():
            raise fixture.FixtureError("ownership lost")
        self.stop_effect = refused
        self.still_running = "/x/EnviousWispr.app/Contents/MacOS/EnviousWispr"
        with self.assertRaisesRegex(fixture.FixtureError, "cleanup skipped"):
            with self.session({}, {}):
                pass
        self.assertNotIn(("cleanup",), self.events)

    def test_survivor_after_stop_skips_cleanup(self):
        self.still_running = "/x/EnviousWispr.app/Contents/MacOS/EnviousWispr"
        with self.assertRaisesRegex(fixture.FixtureError, "still running"):
            with self.session({}, {}):
                pass
        self.assertNotIn(("cleanup",), self.events)

    def session(self, production_before, production_after, owner=lambda: None):
        snapshots = iter([None, production_before, production_after])   # throwaway check, before, after

        def export(domain):
            self.events.append(("export", domain))
            return next(snapshots)
        return fixture.ContainedSession(
            self.subject, self.root, Path(os.devnull), real_home=self.root / "realhome", owner_check=owner,
            launcher=lambda: (self.events.append(("launch",)), 4242)[1],
            stopper=lambda pid, exe: (self.events.append(("stop", pid)), self.stop_effect())[1],
            export=export, cleanup=lambda: (self.events.append(("cleanup",)), [])[1],
            comm=lambda pid: self.still_running)

    def test_unchanged_production_passes_and_cleans_up(self):
        with self.session({"a": 1}, {"a": 1}) as s:
            self.assertEqual(s.pid, 4242)
        self.assertEqual([e[0] for e in self.events], ["export", "export", "launch", "stop", "export", "cleanup"])
        self.assertEqual(s.report["production_changed_keys"], [])

    def test_changed_production_is_reported_never_restored(self):
        with self.assertRaisesRegex(fixture.FixtureError, r"production preferences changed.*'lastHistoryTab'"):
            with self.session({"lastHistoryTab": "meetings"}, {"lastHistoryTab": "dictations"}):
                pass
        self.assertNotIn("import", [e[0] for e in self.events])
        self.assertIn(("cleanup",), self.events)

    def test_denied_ownership_launches_nothing(self):
        def denied():
            raise RuntimeError("held")
        with self.assertRaises(RuntimeError):
            with self.session({}, {}, owner=denied):
                pass
        self.assertEqual(self.events, [])


class StopTests(unittest.TestCase):
    EXE = "/tmp/EnviousWispr.app/Contents/MacOS/EnviousWispr"

    def run_stop(self, exits_on, start=None, owner_check=lambda: None):
        """A fake process that runs `start` (default EXE) until it receives a signal in `exits_on`."""
        state = {"exe": self.EXE if start is None else start}
        sent = []

        def kill(_pid, sig):
            sent.append(sig)
            if sig in exits_on:
                state["exe"] = None

        result = fixture.stop(9, self.EXE, owner_check=owner_check, comm=lambda _pid: state["exe"],
                              kill=kill, sleep=lambda _: None, timeout=0.2)
        return result, sent

    def test_term_then_gone(self):
        self.assertEqual(self.run_stop({signal.SIGTERM}), (True, [signal.SIGTERM]))

    def test_kill_when_term_is_ignored(self):
        self.assertEqual(self.run_stop({signal.SIGKILL}), (True, [signal.SIGTERM, signal.SIGKILL]))

    def test_survivor_after_kill_fails_clearly(self):
        with self.assertRaisesRegex(fixture.FixtureError, "still running after TERM and KILL"):
            self.run_stop(set())

    def test_already_gone_sends_nothing(self):
        state_gone = fixture.stop(9, self.EXE, owner_check=lambda: None, comm=lambda _pid: None,
                                  kill=lambda *a: self.fail("signalled a gone pid"), sleep=lambda _: None)
        self.assertFalse(state_gone)

    def test_wrong_executable_is_refused(self):
        with self.assertRaisesRegex(fixture.FixtureError, "refusing to stop"):
            self.run_stop({signal.SIGTERM}, start="/Applications/Other.app/Contents/MacOS/Other")

    def test_denied_ownership_sends_nothing(self):
        def denied():
            raise RuntimeError("held")
        with self.assertRaises(RuntimeError):
            self.run_stop({signal.SIGTERM}, owner_check=denied)


class AdapterTests(unittest.TestCase):
    """The real adapters, fed `ps` results through subprocess.run, so "could not tell" is checked
    through the code a launch actually calls, not through an exception-raising fake."""

    def ps(self, returncode, stdout="", stderr=""):
        return mock.patch.object(subprocess, "run", return_value=subprocess.CompletedProcess(
            ["ps"], returncode, stdout=stdout, stderr=stderr))

    def test_comm_present_absent_and_unknown(self):
        with self.ps(0, "/x/EnviousWispr.app/Contents/MacOS/EnviousWispr\n"):
            self.assertEqual(fixture._comm(5), "/x/EnviousWispr.app/Contents/MacOS/EnviousWispr")
        with self.ps(1):
            self.assertIsNone(fixture._comm(5))
        with self.ps(1, stderr="ps: Invalid process id"), self.assertRaises(fixture.FixtureError):
            fixture._comm(5)
        with self.ps(2, stderr="boom"), self.assertRaises(fixture.FixtureError):
            fixture._comm(5)

    def test_failed_instance_listing_refuses_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            write_corpus(root / "source")
            with mock.patch.object(fixture.Path, "home", return_value=root / "realhome"):
                (root / "realhome").mkdir()
                fixture.build_seed(root / "source", root / "seed")
                home = fixture.regenerate_home(root / "seed", root / "home")
            app = root / "EnviousWispr.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/EnviousWispr").write_bytes(b"")
            with open(app / "Contents/Info.plist", "wb") as handle:
                plistlib.dump({"CFBundleIdentifier": fixture.SUBJECT_BUNDLE_ID}, handle)
            spawned = []
            with self.ps(2, stderr="ps: cannot list"), self.assertRaisesRegex(
                    fixture.FixtureError, "cannot read running EnviousWispr instances"):
                fixture.launch(app, home, Path(os.devnull), owner_check=lambda: None,
                               spawn=lambda *a, **k: spawned.append(a))
            self.assertEqual(spawned, [])


class ResetCatalogTests(Temp):
    def setUp(self):
        super().setUp()
        fixture.build_seed(self.source, self.seed)
        self.home = fixture.regenerate_home(self.seed, self.root / "home")
        self.catalog = fixture.catalog_dir(self.home)
        self.catalog.mkdir()
        (self.catalog / "history.sqlite").write_bytes(b"db")

    def test_denied_ownership_deletes_nothing(self):
        def denied():
            raise RuntimeError("held")
        with self.assertRaises(RuntimeError):
            fixture.reset_catalog(self.home, owner_check=denied)
        self.assertTrue((self.catalog / "history.sqlite").exists())

    def test_positive_deletes_only_the_catalog(self):
        self.assertTrue(fixture.reset_catalog(self.home, owner_check=lambda: None))
        self.assertFalse(self.catalog.exists())
        support = self.home / "Library/Application Support/EnviousWispr"
        self.assertEqual(sorted(p.name for p in support.iterdir()), ["Meetings", "recordings", "transcripts"])
        self.assertFalse(fixture.reset_catalog(self.home, owner_check=lambda: None))

    def test_refuses_non_fixture_home_and_symlinked_catalog(self):
        plain = self.root / "plain"
        plain.mkdir()
        with self.assertRaisesRegex(fixture.FixtureError, "not a regenerated fixture home"):
            fixture.reset_catalog(plain, owner_check=lambda: None)
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "keep").write_bytes(b"k")
        (self.catalog / "history.sqlite").unlink()
        self.catalog.rmdir()
        self.catalog.symlink_to(outside)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaisesRegex(
                fixture.FixtureError, "refused or incomplete"):
            fixture.reset_catalog(self.home, owner_check=lambda: None)
        self.assertTrue((outside / "keep").exists())


class EntryPointTests(unittest.TestCase):
    DRIVERS = ["m5-speed-ground-truth.py", "m5-speed-open.py", "m5-speed-scroll.py", "m5-speed-ui-search.py",
               "m5-speed-card.py"]

    def test_drivers_import_without_side_effects(self):
        before_env, before_path = dict(os.environ), list(sys.path)
        for name in self.DRIVERS:
            with self.subTest(name):
                spec = importlib.util.spec_from_file_location("driver", HERE / name)
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                self.assertTrue(callable(module.main))
        self.assertEqual(dict(os.environ), before_env)
        self.assertEqual(sys.path, before_path)

    def test_drivers_print_usage_and_start_nothing(self):
        for name in self.DRIVERS:
            with self.subTest(name):
                result = subprocess.run([sys.executable, "-B", str(HERE / name), "--help"],
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Usage", result.stdout)

    def test_cli_dry_run_starts_nothing_and_errors_exit_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                status = fixture.main(["launch", "--app", tmp, "--home", tmp, "--dry-run"])
            self.assertEqual(status, 2)
            self.assertIn("no app executable", err.getvalue())


if __name__ == "__main__":
    unittest.main()
