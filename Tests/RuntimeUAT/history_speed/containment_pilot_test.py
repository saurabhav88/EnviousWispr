"""Offline test: the pilot refuses --storage-warning without --open before anything launches (#4586 WP-A)."""
import subprocess
import sys
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
