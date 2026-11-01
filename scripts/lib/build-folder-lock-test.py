#!/usr/bin/env python3
"""Real kernel-lock controls for scripts/lib/build-folder-lock.py (#4293)."""

import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

HELPER = Path(__file__).resolve().parent / "build-folder-lock.py"


def run(*args, fd=None, wait=True):
    cmd = [sys.executable, str(HELPER), *map(str, args)]
    kwargs = dict(pass_fds=() if fd is None else (fd,), text=True,
                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if wait:
        return subprocess.run(cmd, timeout=10, **kwargs)
    return subprocess.Popen(cmd, **kwargs)


class BuildFolderLock(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ew-build-lock-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve() / "checkout"
        self.root.mkdir()
        self.fds = []
        self.addCleanup(lambda: [os.close(fd) for fd in self.fds])

    def prepared(self):
        result = run("prepare", self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(result.stdout.strip())
        self.assertEqual(path, self.root / ".derivedData/.ew-build.lock")
        return path

    def descriptor(self, path):
        fd = os.open(path, os.O_RDWR)
        self.fds.append(fd)
        return fd

    def free(self, path):
        probe = os.open(path, os.O_RDWR)
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            return False
        finally:
            os.close(probe)

    def test_lock_outlives_the_child_and_ends_with_the_parent_descriptor(self):
        path = self.prepared()
        fd = self.descriptor(path)
        self.assertTrue(self.free(path), "control: an unheld lock must be free")
        result = run("acquire", fd, self.root, fd=fd)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("phase build lock wait", result.stdout)
        self.assertFalse(self.free(path), "the child exited; the parent descriptor must still hold the lock")
        os.close(fd)
        self.fds.remove(fd)
        self.assertTrue(self.free(path), "closing the last descriptor must release the lock")

    def test_second_holder_waits_says_so_and_proceeds_after_release(self):
        path = self.prepared()
        first = self.descriptor(path)
        self.assertEqual(run("acquire", first, self.root, fd=first).returncode, 0)
        second = self.descriptor(path)
        waiter = run("acquire", second, self.root, fd=second, wait=False)
        time.sleep(0.5)
        self.assertIsNone(waiter.poll(), "the second holder must wait while the first holds the lock")
        os.close(first)
        self.fds.remove(first)
        out, err = waiter.communicate(timeout=10)
        self.assertEqual(waiter.returncode, 0, err)
        self.assertIn("waiting", out)
        self.assertFalse(self.free(path))

    def test_refuses_a_symlinked_lock_file(self):
        target = Path(self.tmp.name) / "elsewhere"
        target.write_text("")
        (self.root / ".derivedData").mkdir()
        (self.root / ".derivedData/.ew-build.lock").symlink_to(target)
        result = run("prepare", self.root)
        self.assertEqual(result.returncode, 2)
        self.assertIn("ERROR: build lock", result.stderr)

    def test_refuses_a_descriptor_for_another_file(self):
        self.prepared()
        other = Path(self.tmp.name) / "other.lock"
        other.write_text("")
        fd = self.descriptor(other)
        result = run("acquire", fd, self.root, fd=fd)
        self.assertEqual(result.returncode, 2)
        self.assertIn("does not name this checkout's lock file", result.stderr)

    def test_refuses_a_relative_root(self):
        result = run("path", "relative/checkout")
        self.assertEqual(result.returncode, 2)
        self.assertIn("absolute", result.stderr)


if __name__ == "__main__":
    unittest.main()
