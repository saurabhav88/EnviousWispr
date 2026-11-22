"""Offline tests: the pilot refuses --storage-warning without --open before anything launches (#4586 WP-A);
it removes its fixture copies only when every app it caused to start is proven stopped (#4789)."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from subprocess import TimeoutExpired
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent


class PilotArgs(unittest.TestCase):
    def run_pilot(self, *extra):
        # Nonexistent paths: any attempt to proceed past the argument check would fail differently (not exit 2 with this message).
        return subprocess.run([sys.executable, "-B", str(HERE / "containment_pilot.py"), "/nonexistent/App.app", "sha",
                               "/nonexistent/seed", "/nonexistent/run", *extra], capture_output=True, text=True)

    def test_storage_warning_without_open_is_refused(self):
        r = self.run_pilot("--storage-warning")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--storage-warning only applies to the open driver", r.stderr)

    def test_storage_warning_without_open_is_refused_even_with_scroll(self):
        r = self.run_pilot("--storage-warning", "--scroll")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--open", r.stderr)

    def test_open_spec_parse(self):
        sys.path.insert(0, str(HERE))
        import containment_pilot as pilot
        self.assertEqual(pilot.parse_open_spec("missing,existing", "15"), [("missing", "15"), ("existing", "15")])
        self.assertEqual(pilot.parse_open_spec("existing:3,missing:1", "--warmups"), [("existing", "3"), ("missing", "1")])

    def test_wrong_subject_hash_still_records_cleanup(self):
        # prepare_subject refuses after the run folder exists: the finally block must still run.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            executable = root / "Pinned.app/Contents/MacOS/EnviousWispr"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"not the pinned app")
            run = root / "run"
            r = subprocess.run([sys.executable, "-B", str(HERE / "containment_pilot.py"), str(root / "Pinned.app"),
                                "0" * 64, str(root / "seed"), str(run)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1, r.stderr)
            self.assertIn("pinned executable hash differs", r.stderr)
            self.assertEqual(json.loads((run / "cleanup.json").read_text()),
                             {"removed": {"subject": "absent", "home": "absent"}})


class CopiesKeepReason(unittest.TestCase):
    """Copies stay unless every app the session caused to start is proven stopped (#4789)."""

    def setUp(self):
        sys.path.insert(0, str(HERE))
        import containment_pilot
        self.pilot = containment_pilot
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.run = Path(self._dir.name)
        self.stopped = SimpleNamespace(pid=101, report={"stopped": True})

    def reason(self, own=(), session=None, unwinding=None, relaunched=()):
        return self.pilot.copies_keep_reason(self.run, list(own), session, unwinding, list(relaunched))

    def write(self, name, report):
        (self.run / name).mkdir()
        (self.run / name / "report.json").write_text(json.dumps(report))

    def test_finished_session_and_drivers_remove(self):
        self.write("launch-cost", {"samples": []})
        self.write("open-existing", {"conditions_end": {}})
        self.assertIsNone(self.reason(session=self.stopped, relaunched=["launch-cost", "open-existing"]))

    def test_keep_flag(self):
        self.assertEqual(self.reason(own=["--keep-copies"], session=self.stopped), "--keep-copies")

    def test_timeout_and_interrupt_keep(self):
        for error in (TimeoutExpired("m5-speed-open.py", 7200), KeyboardInterrupt()):
            with self.subTest(error=type(error).__name__):
                self.assertIn(type(error).__name__, self.reason(session=self.stopped, unwinding=error))

    def test_unconfirmed_session_stop_keeps(self):
        self.assertIn("not confirmed stopped", self.reason(session=SimpleNamespace(pid=101, report={"stopped": False})))

    def test_unfinished_relaunch_drivers_keep(self):
        self.assertIn("launch-cost did not finish", self.reason(session=self.stopped, relaunched=["launch-cost"]))
        self.write("open-missing", {"samples": []})   # a per-sample write, not the final one
        self.assertIn("open-missing did not finish", self.reason(session=self.stopped, relaunched=["open-missing"]))


if __name__ == "__main__":
    unittest.main()
