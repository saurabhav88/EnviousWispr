#!/usr/bin/env python3
"""Harness-contract fixtures for the physical removal boundary (#4197).

Portable cases create no trees and mock OS/process boundaries. Native cases
own disposable roots; teardown uses independently captured OS/find functions,
not the candidate helper or the command being fault-injected. No live mounts.
"""

import argparse
import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
HELPER_PATH = HERE / "remove-tree.py"
REAL_RUN, REAL_LSTAT, REAL_STAT = subprocess.run, os.lstat, os.stat
BASELINE = None
BASELINE_SHA = "4a4c44dbd0053eb07e14c158f32ac6af9e00eb980d2166c0ed2073124efc0cad"


def load(path, name):
    # No import-cache writes, including in portable/read-only review runs.
    module = types.ModuleType(name)
    module.__file__ = str(path)
    exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
    return module


H = load(HELPER_PATH, "physical_remove")


def directory(number, device=1, mode=stat.S_IFDIR):
    return types.SimpleNamespace(st_dev=device, st_ino=number, st_mode=mode | 0o700)


class FakeFS:
    def __init__(self):
        self.entries = {"/": directory(1), "/cache": directory(2), "/cache/old": directory(3)}
        self.run = mock.Mock(return_value=subprocess.CompletedProcess([], 0))

    def lookup(self, path):
        value = self.entries.get(os.path.normpath(path), FileNotFoundError(path))
        if isinstance(value, BaseException):
            raise value
        return value

    def __enter__(self):
        self.stack = contextlib.ExitStack()
        self.stack.enter_context(mock.patch.object(H.os, "lstat", side_effect=self.lookup))
        self.stack.enter_context(mock.patch.object(H.os, "stat", side_effect=self.lookup))
        self.stack.enter_context(mock.patch.object(H.os.path, "realpath", side_effect=lambda p: p))
        self.stack.enter_context(mock.patch.object(H.subprocess, "run", self.run))
        self.stack.enter_context(mock.patch.object(H.sys, "platform", "darwin"))
        self.stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
        return self

    def __exit__(self, *args):
        return self.stack.__exit__(*args)


class PortableTests(unittest.TestCase):
    def test_import_has_no_mutation_or_subprocess(self):
        source = HELPER_PATH.read_text()
        namespace = {"__name__": "import_control", "__file__": str(HELPER_PATH)}
        with mock.patch.object(os, "mkdir") as mkdir, mock.patch.object(os, "unlink") as unlink:
            with mock.patch.object(os, "rmdir") as rmdir, mock.patch.object(subprocess, "run") as run:
                exec(compile(source, str(HELPER_PATH), "exec"), namespace)
        for operation in [mkdir, unlink, rmdir, run]:
            operation.assert_not_called()

    def test_inspect_is_readonly_and_identity_is_explicit(self):
        with FakeFS() as fs:
            observed = H.inspect_target("/cache", "/cache/old")
            self.assertEqual(observed["identity"], "1:3")
            self.assertEqual(observed["root_identity"], "1:2")
            self.assertTrue(observed["exists"])
            fs.run.assert_not_called()
            with self.assertRaisesRegex(ValueError, "identity changed"):
                H.inspect_target("/cache", "/cache/old", "1:99")

    def test_absent_final_is_distinct_from_missing_or_unknown_parents(self):
        with FakeFS() as fs:
            self.assertEqual(H.remove_tree("/cache", "/cache/absent"), 3)
            self.assertEqual(H.remove_tree("/cache", "/cache/missing/child"), 1)
            self.assertEqual(H.remove_tree("/missing", "/missing/child"), 1)
            fs.entries["/"] = FileNotFoundError("parent metadata vanished")
            self.assertEqual(H.remove_tree("/cache", "/cache/old"), 1)
            fs.run.assert_not_called()

    def test_namespace_and_expected_identity_refuse_before_traversal(self):
        for root, target in [("", "/cache/old"), ("relative", "/cache/old"), ("/", "/cache/old"),
                             ("/cache", "/cache"), ("/cache", "/cache/../other"),
                             ("/cache", "/cache-sibling/old"), ("/cache", "relative"),
                             ("/cache", "/cache/bad\0name")]:
            with self.subTest(root=root, target=target), FakeFS() as fs:
                self.assertEqual(H.remove_tree(root, target), 1)
                fs.run.assert_not_called()
        with FakeFS() as fs:
            self.assertEqual(H.remove_tree("/cache", "/cache/old", "1:99"), 1)
            fs.run.assert_not_called()

    def test_component_link_mount_and_unknown_metadata_refuse(self):
        for component in ["/cache", "/cache/middle", "/cache/middle/old"]:
            for kind in ["link", "device", "filesystem-root", "unknown"]:
                with self.subTest(component=component, kind=kind), FakeFS() as fs:
                    fs.entries.update({"/cache/middle": directory(4), "/cache/middle/old": directory(5)})
                    parent = fs.entries[os.path.dirname(component)]
                    if kind == "link":
                        fs.entries[component] = directory(6, mode=stat.S_IFLNK)
                    elif kind == "device":
                        fs.entries[component] = directory(parent.st_ino, device=2)
                    elif kind == "filesystem-root":
                        fs.entries[component] = parent
                    else:
                        fs.entries[component] = PermissionError("metadata unavailable")
                    self.assertEqual(H.remove_tree("/cache", "/cache/middle/old"), 1)
                    fs.run.assert_not_called()

    def test_find_outcomes_require_status_and_actual_disappearance(self):
        with FakeFS() as fs:
            self.assertEqual(H.remove_tree("/cache", "/cache/old"), 1)
            fs.run.assert_called_once_with(["/usr/bin/find", "-P", "/cache/old", "-xdev", "-delete"], check=False)
        for exit_code in [0, 9]:
            with self.subTest(exit_code=exit_code), FakeFS() as fs:
                def removed(*_args, **_kwargs):
                    del fs.entries["/cache/old"]
                    return subprocess.CompletedProcess([], exit_code)
                fs.run.side_effect = removed
                self.assertEqual(H.remove_tree("/cache", "/cache/old"), 0 if exit_code == 0 else 1)
        with FakeFS() as fs:
            fs.run.side_effect = FileNotFoundError("find unavailable")
            self.assertEqual(H.remove_tree("/cache", "/cache/old"), 2)
        with FakeFS() as fs:
            def unknown(*_args, **_kwargs):
                fs.entries["/cache/old"] = PermissionError("postflight unavailable")
                return subprocess.CompletedProcess([], 0)
            fs.run.side_effect = unknown
            self.assertEqual(H.remove_tree("/cache", "/cache/old"), 1)

    def test_creation_namespace_is_readonly_and_not_removal_absence(self):
        with FakeFS() as fs:
            observed = H.inspect_namespace("/cache/new/nested")
            self.assertFalse(observed["exists"])
            self.assertEqual(observed["creation_parent"], "/cache")
            self.assertEqual(observed["parent_identity"], "1:2")
            fs.run.assert_not_called()
            fs.entries["/cache"] = PermissionError("unreadable creation parent")
            with self.assertRaises(PermissionError):
                H.inspect_namespace("/cache/new/nested")

    def test_inspect_cli_has_json_and_explicit_status(self):
        with FakeFS() as fs, contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(H.main(["helper", "inspect", "/cache", "/cache/old"]), 0)
            self.assertEqual(json.loads(output.getvalue())["identity"], "1:3")
            output.seek(0)
            output.truncate()
            self.assertEqual(H.main(["helper", "inspect", "/cache", "/cache/absent"]), 3)
            self.assertFalse(json.loads(output.getvalue())["exists"])
            fs.run.assert_not_called()

    def test_unsupported_platform_and_invocation_are_explicit(self):
        with FakeFS() as fs, mock.patch.object(H.sys, "platform", "linux"):
            self.assertEqual(H.remove_tree("/cache", "/cache/old"), 2)
            self.assertEqual(H.main(["helper", "inspect", "/cache"]), 2)
            fs.run.assert_not_called()
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(H.main(["helper"]), 2)
            self.assertEqual(H.main(["helper", "inspect"]), 2)

    def test_owner_primitives_reject_platform_or_namespace_before_open(self):
        with FakeFS() as fs, mock.patch.object(H.os, "open") as opened:
            self.assertEqual(H.main(["helper", "owner", "/cache", "/cache/../elsewhere"]), 1)
            self.assertEqual(H.main(["helper", "publish-owner", "/cache", "/cache/old", "1:99", "eA=="]), 1)
            self.assertEqual(H.main(["helper", "publish-owner", "/cache", "/cache/old", "1:3", "?"]), 1)
            opened.assert_not_called()
            fs.run.assert_not_called()
        with FakeFS(), mock.patch.object(H.sys, "platform", "linux"), mock.patch.object(H.os, "open") as opened:
            self.assertEqual(H.main(["helper", "owner", "/cache", "/cache/old"]), 2)
            self.assertEqual(H.main(["helper", "rmdir", "/cache", "/cache/old", "1:3"]), 2)
            opened.assert_not_called()

    def test_owner_and_gate_absence_are_nondestructive(self):
        with FakeFS() as fs, mock.patch.object(H.os, "open") as opened:
            self.assertFalse(H.inspect_owner("/cache", "/cache/missing")["exists"])
            self.assertEqual(H.remove_empty("/cache", "/cache/missing", "1:99"), 3)
            opened.assert_not_called()
            fs.run.assert_not_called()


@unittest.skipUnless(sys.platform == "darwin", "native macOS find boundary")
class NativeTests(unittest.TestCase):
    def setUp(self):
        self.home = os.environ.get("HOME")
        self.base = Path(tempfile.mkdtemp(prefix="ew-4197-remove-"))
        self.anchor = REAL_LSTAT(str(self.base))
        self.addCleanup(self.cleanup)
        self.root = self.base / "cache"
        self.root.mkdir()
        self.target = self.root / "old"
        self.target.mkdir()
        (self.target / "payload").write_text("fixture")

    def cleanup(self):
        self.assertEqual(os.environ.get("HOME"), self.home)
        entry, parent = REAL_LSTAT(str(self.base)), REAL_STAT(str(self.base.parent))
        self.assertTrue(stat.S_ISDIR(entry.st_mode))
        self.assertEqual((entry.st_dev, entry.st_ino), (self.anchor.st_dev, self.anchor.st_ino))
        self.assertEqual(entry.st_dev, parent.st_dev)
        self.assertNotEqual((entry.st_dev, entry.st_ino), (parent.st_dev, parent.st_ino))
        # Independent teardown: faults in the candidate/find binding cannot
        # disable this captured primitive. No fixture creates a real mount.
        result = REAL_RUN(["/usr/bin/find", "-P", str(self.base), "-xdev", "-delete"], check=False)
        self.assertEqual(result.returncode, 0)
        with self.assertRaises(FileNotFoundError):
            REAL_LSTAT(str(self.base))

    def test_ordinary_removal_preserves_sibling(self):
        sibling = self.root / "keep"
        sibling.write_text("sentinel")
        self.assertEqual(H.remove_tree(str(self.root), str(self.target)), 0)
        self.assertFalse(self.target.exists())
        self.assertEqual(sibling.read_text(), "sentinel")

    def test_already_absent_is_three_without_credit_or_error(self):
        with contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(H.remove_tree(str(self.root), str(self.root / "absent")), 3)
        self.assertEqual(error.getvalue(), "")

    def test_literal_characters_are_argv_data(self):
        literal = self.root / "literal $ ' ` \t\n"
        literal.mkdir()
        (literal / "keep words").write_text("fixture")
        self.assertEqual(H.remove_tree(str(self.root), str(literal)), 0)
        self.assertFalse(literal.exists())

    def test_symlink_target_retains_destination(self):
        link = self.root / "link"
        link.symlink_to(self.target, target_is_directory=True)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(H.remove_tree(str(self.root), str(link)), 1)
        self.assertTrue(link.is_symlink())
        self.assertEqual((self.target / "payload").read_text(), "fixture")

    def test_real_permission_refusal_retains_target_and_stderr(self):
        if os.geteuid() == 0:
            self.skipTest("root bypasses ordinary permission checks")
        self.target.chmod(0o500)
        try:
            environment = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "TMPDIR": str(self.base),
                           "PYTHONDONTWRITEBYTECODE": "1"}
            if self.home is not None:
                environment["HOME"] = self.home
            result = REAL_RUN([sys.executable, str(HELPER_PATH), str(self.root), str(self.target)],
                              env=environment, text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Permission denied", result.stderr)
            self.assertIn("target remains", result.stderr)
            self.assertTrue(self.target.exists())
        finally:
            self.target.chmod(0o700)

    def test_false_success_and_dangling_link_stay_failures(self):
        def replace_with_link(*_args, **_kwargs):
            (self.target / "payload").unlink()
            self.target.rmdir()
            self.target.symlink_to(self.root / "missing")
            return subprocess.CompletedProcess([], 0)
        with mock.patch.object(H.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(H.remove_tree(str(self.root), str(self.target)), 1)
        with mock.patch.object(H.subprocess, "run", side_effect=replace_with_link):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(H.remove_tree(str(self.root), str(self.target)), 1)
        self.assertTrue(self.target.is_symlink())

    def test_missing_tool_does_not_break_independent_teardown(self):
        with mock.patch.object(H.subprocess, "run", side_effect=FileNotFoundError("fixture find")):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(H.remove_tree(str(self.root), str(self.target)), 2)
        self.assertTrue(self.target.exists())

    def test_inspect_does_not_mutate_existing_or_creation_namespace(self):
        before = (self.target / "payload").read_bytes()
        observed = H.inspect_target(str(self.root), str(self.target))
        self.assertEqual(observed["identity"], H.identity(REAL_LSTAT(str(self.target))))
        future = self.root / "future/nested"
        self.assertFalse(H.inspect_namespace(str(future))["exists"])
        self.assertFalse((self.root / "future").exists())
        self.assertEqual((self.target / "payload").read_bytes(), before)

    def test_owner_snapshot_and_atomic_publication_preserve_exact_bytes(self):
        expected = H.inspect_target(str(self.root), str(self.target))["identity"]
        before = H.inspect_owner(str(self.root), str(self.target), expected)
        self.assertFalse(before["owner_exists"])
        data = b"version=1\npid=123\nstarted=fixture identity\n"
        encoded = base64.b64encode(data).decode("ascii")
        self.assertEqual(H.main(["helper", "publish-owner", str(self.root), str(self.target), expected, encoded]), 0)
        after = H.inspect_owner(str(self.root), str(self.target), expected)
        self.assertEqual(base64.b64decode(after["owner_base64"]), data)
        self.assertEqual((self.target / "owner").read_bytes(), data)
        self.assertEqual(list(self.target.glob(".owner.*")), [])
        self.assertEqual(H.publish_owner(str(self.root), str(self.target), expected, encoded), 0)
        different = base64.b64encode(b"somebody else's owner\n").decode("ascii")
        with self.assertRaisesRegex(ValueError, "refusing overwrite"):
            H.publish_owner(str(self.root), str(self.target), expected, different)
        self.assertEqual((self.target / "owner").read_bytes(), data)

    def test_owner_link_and_oversized_metadata_are_unknown_not_followed(self):
        foreign = self.root / "foreign"
        foreign.write_bytes(b"sentinel")
        owner = self.target / "owner"
        owner.symlink_to(foreign)
        expected = H.inspect_target(str(self.root), str(self.target))["identity"]
        with self.assertRaisesRegex(ValueError, "not a regular file"):
            H.inspect_owner(str(self.root), str(self.target), expected)
        self.assertEqual(foreign.read_bytes(), b"sentinel")
        owner.unlink()
        owner.write_bytes(b"x" * (H.MAX_OWNER_BYTES + 1))
        with self.assertRaisesRegex(ValueError, "envelope"):
            H.inspect_owner(str(self.root), str(self.target), expected)
        self.assertEqual(owner.stat().st_size, H.MAX_OWNER_BYTES + 1)

    def test_empty_gate_removal_is_nonrecursive_and_identity_checked(self):
        expected = H.inspect_target(str(self.root), str(self.target))["identity"]
        with self.assertRaises(OSError):
            H.remove_empty(str(self.root), str(self.target), expected)
        self.assertEqual((self.target / "payload").read_text(), "fixture")
        with self.assertRaisesRegex(ValueError, "identity changed"):
            H.remove_empty(str(self.root), str(self.target), "wrong-instance")
        (self.target / "payload").unlink()
        self.assertEqual(H.remove_empty(str(self.root), str(self.target), expected), 0)
        self.assertEqual(H.remove_empty(str(self.root), str(self.target), expected), 3)

    def test_owner_publication_requires_a_present_registered_instance(self):
        absent = self.root / "absent"
        encoded = base64.b64encode(b"owner bytes").decode("ascii")
        with self.assertRaisesRegex(ValueError, "absent directory"):
            H.publish_owner(str(self.root), str(absent), "unknown", encoded)
        with self.assertRaisesRegex(ValueError, "identity changed"):
            H.inspect_owner(str(self.root), str(self.target), "wrong-instance")
        self.assertFalse(absent.exists())

    def test_frozen_original_rejects_new_absence_contract_for_expected_reason(self):
        if BASELINE is None:
            self.skipTest("local original-versus-candidate control requires --baseline")
        self.assertEqual(hashlib.sha256(BASELINE.read_bytes()).hexdigest(), BASELINE_SHA)
        original = load(BASELINE, "frozen_original")
        absent = str(self.root / "absent")
        with contextlib.redirect_stderr(io.StringIO()) as error:
            old = original.remove_tree(str(self.root), absent)
        self.assertEqual(old, 1)
        self.assertIn("preflight refused", error.getvalue())
        self.assertIn("[Errno 2]", error.getvalue())
        with self.assertRaisesRegex(AssertionError, "1 != 3"):
            self.assertEqual(old, 3)
        self.assertEqual(H.remove_tree(str(self.root), absent), 3)
        self.assertTrue(self.root.is_dir())
        print("BASELINE RED: verified absence returned1; candidate returns3; identical entrypoint/input", flush=True)


def main():
    global BASELINE
    parser = argparse.ArgumentParser()
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--portable", action="store_true")
    selection.add_argument("--native", action="store_true")
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    BASELINE = args.baseline
    groups = []
    if not args.native:
        groups.append(("portable", PortableTests))
    if not args.portable:
        groups.append(("native", NativeTests))
    passed = True
    for name, cls in groups:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(cls)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        executed = result.testsRun - len(result.skipped)
        print("GROUP {}: executed={} skipped={} failures={} errors={}".format(
            name, executed, len(result.skipped), len(result.failures), len(result.errors)), flush=True)
        passed = passed and result.wasSuccessful() and executed > 0
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
