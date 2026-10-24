#!/usr/bin/env python3
"""Real kernel-lock controls against private copies of the CI queue owner."""

import fcntl
import os
from pathlib import Path
import pwd
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
DEFINITION = 'LOCK_PATH = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Caches/EnviousWispr/local-ci/runner.lock"'


class QueueContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ew-ci-queue-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.lock = self.root / "private-cache/runner.lock"
        source = (HERE / "local-ci-queue.py").read_text()
        self.assertEqual(source.count(DEFINITION), 1, "private copy rewrite must fail closed")
        self.helpers = []
        for name in ("checkout-a", "checkout-b", "checkout-c"):
            folder = self.root / name
            folder.mkdir()
            helper = folder / "queue.py"
            helper.write_text(source.replace(DEFINITION, f"LOCK_PATH = Path({str(self.lock)!r})"))
            self.helpers.append(helper)
        self.call(self.helpers[0], "prepare")
        self.fds = []
        self.addCleanup(self.close_fds)

    def close_fds(self):
        for fd in self.fds:
            os.close(fd)

    def descriptor(self):
        fd = os.open(self.lock, os.O_RDWR)
        self.fds.append(fd)
        return fd

    def call(self, helper, *args, fd=None, rc=0):
        result = subprocess.run([sys.executable, str(helper), *map(str, args)],
                                pass_fds=() if fd is None else (fd,),
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, rc, result.stdout + result.stderr)
        return result

    def test_resource_comes_from_account_not_home_environment(self):
        # `path` is read-only: this checks the original owner without creating or
        # acquiring its production resource.
        result = subprocess.run([sys.executable, str(HERE / "local-ci-queue.py"), "path"],
                                env=dict(os.environ, HOME=str(self.root / "fake-home")),
                                capture_output=True, text=True, check=True, timeout=10)
        expected = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Caches/EnviousWispr/local-ci/runner.lock"
        self.assertEqual(result.stdout.strip(), str(expected))

    def test_child_acquisition_excludes_others_until_parent_descriptor_closes(self):
        owner = self.descriptor()
        self.call(self.helpers[0], "acquire", owner, fd=owner)
        rival = self.descriptor()
        with self.assertRaises(BlockingIOError):
            fcntl.flock(rival, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.close(owner)
        self.fds.remove(owner)
        fcntl.flock(rival, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(self.lock.read_bytes(), b"")

    def waiting_line(self, proc):
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(timeout=8), "queue never announced its wait")
            self.assertIn("waiting", proc.stdout.readline())

    def test_three_checkout_requests_share_one_slot_and_waiters_do_not_enter(self):
        owner = self.descriptor()
        self.call(self.helpers[0], "acquire", owner, fd=owner)
        pending = []
        try:
            for helper in self.helpers[1:]:
                fd = self.descriptor()
                proc = subprocess.Popen([sys.executable, str(helper), "acquire", str(fd)],
                                        pass_fds=(fd,), stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True)
                pending.append(proc)
                self.waiting_line(proc)
                self.assertIsNone(proc.poll())
            # Admit one waiter. Its acquiring child exits, but this test's
            # inherited parent descriptor must keep the next waiter excluded.
            os.close(owner)
            self.fds.remove(owner)
            deadline = time.monotonic() + 8
            while all(p.poll() is None for p in pending) and time.monotonic() < deadline:
                time.sleep(0.01)  # deadline-fallback: wait for the acquisition exit signal
            completed = [p for p in pending if p.poll() is not None]
            self.assertEqual(len(completed), 1)
            self.assertEqual(completed[0].returncode, 0)
            self.assertEqual(sum(p.poll() is None for p in pending), 1)
        finally:
            for proc in pending:
                if proc.poll() is None:
                    proc.terminate()
                proc.communicate(timeout=10)

    def test_waiter_handles_int_even_when_background_signal_was_ignored(self):
        owner = self.descriptor()
        self.call(self.helpers[0], "acquire", owner, fd=owner)
        rival = self.descriptor()
        proc = subprocess.Popen(["bash", "-c", 'trap "" INT; exec "$@"', "ignored-int",
                                 sys.executable, str(self.helpers[1]), "acquire", str(rival)],
                                pass_fds=(rival,), stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        try:
            self.waiting_line(proc)
            proc.send_signal(signal.SIGINT)
            proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 130)
            with self.assertRaises(BlockingIOError):
                fcntl.flock(rival, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.communicate(timeout=10)

    def test_foreign_descriptor_is_refused(self):
        foreign = self.root / "foreign"
        foreign.write_text("keep")
        fd = os.open(foreign, os.O_RDWR)
        try:
            self.call(self.helpers[0], "acquire", fd, fd=fd, rc=2)
        finally:
            os.close(fd)
        self.assertEqual(foreign.read_text(), "keep")

    def test_symlink_resource_is_refused_without_touching_target(self):
        self.lock.unlink()
        target = self.root / "keep"
        target.write_text("keep")
        self.lock.symlink_to(target)
        self.call(self.helpers[0], "prepare", rc=2)
        self.assertEqual(target.read_text(), "keep")

    def test_bash_holds_the_lease_after_acquisition_helper_exits(self):
        command = 'exec 9<>"$1"; "$2" "$3" acquire 9; "$2" -c "$4" "$1"'
        probe = "import fcntl,sys; f=open(sys.argv[1], 'r+');\ntry:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError:\n sys.exit(0)\nsys.exit(1)"
        result = subprocess.run(["bash", "-c", command, "queue-bash-control", str(self.lock),
                                 sys.executable, str(self.helpers[0]), probe],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
