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

    # --- #4089/#4090: short runs go first ------------------------------------
    def spawn(self, helper, kind=None):
        fd = self.descriptor()
        args = [sys.executable, str(helper), "acquire", str(fd)]
        if kind:
            args += ["--kind", kind]
        proc = subprocess.Popen(args, pass_fds=(fd,), stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        self.addCleanup(self.reap, proc)
        return proc, fd

    def reap(self, proc):
        if proc.poll() is None:
            proc.terminate()
        proc.communicate(timeout=10)

    def wait_exit(self, procs, count, seconds=8):
        deadline = time.monotonic() + seconds
        while sum(p.poll() is not None for p in procs) < count and time.monotonic() < deadline:
            time.sleep(0.01)  # deadline-fallback: wait for the acquisition exit signal
        return [p for p in procs if p.poll() is not None]

    def release(self, fd):
        os.close(fd)
        self.fds.remove(fd)

    def hold(self, kind=None):
        owner = self.descriptor()
        args = ["acquire", owner] + (["--kind", kind] if kind else [])
        self.call(self.helpers[0], *args, fd=owner)
        return owner

    def test_registered_shorts_all_go_before_a_waiting_full(self):
        owner = self.hold("full")
        full, full_fd = self.spawn(self.helpers[1], "full")
        self.waiting_line(full)
        shorts = []
        for helper in (self.helpers[2], self.helpers[0]):
            proc, fd = self.spawn(helper, "short")
            self.waiting_line(proc)
            shorts.append((proc, fd))
        # Two registered shorts and one full are waiting. Release the slot three
        # times; each release must admit a short until no short is left.
        self.release(owner)
        done = self.wait_exit([p for p, _ in shorts], 1)
        self.assertEqual(len(done), 1, "the first release must admit one short")
        self.assertIsNone(full.poll(), "a full run took the slot while a short was registered")
        first_fd = next(fd for p, fd in shorts if p in done)
        self.release(first_fd)
        self.assertEqual(len(self.wait_exit([p for p, _ in shorts], 2)), 2)
        self.assertIsNone(full.poll(), "a full run took the slot while a short was registered")
        second_fd = next(fd for p, fd in shorts if fd != first_fd)
        self.release(second_fd)
        self.assertEqual(self.wait_exit([full], 1), [full])
        self.assertEqual(full.returncode, 0)

    def test_full_never_takes_a_free_slot_while_a_short_is_registered(self):
        # This test plays a registered short: it holds priority.lock shared while
        # the slot is free. A full waiter must not take the free slot until the
        # registration is gone.
        registration = os.open(self.lock.with_name("priority.lock"), os.O_RDWR)
        self.fds.append(registration)
        fcntl.flock(registration, fcntl.LOCK_SH)
        full, _ = self.spawn(self.helpers[1], "full")
        self.waiting_line(full)
        self.assertEqual(self.wait_exit([full], 1, seconds=2.5), [], "a full run ignored a registered short")
        self.release(registration)
        self.assertEqual(self.wait_exit([full], 1), [full])
        self.assertEqual(full.returncode, 0)

    def test_waiting_short_holds_its_registration_until_it_has_the_slot(self):
        owner = self.hold("full")
        short, short_fd = self.spawn(self.helpers[1], "short")
        self.waiting_line(short)
        probe = os.open(self.lock.with_name("priority.lock"), os.O_RDWR)
        self.fds.append(probe)
        with self.assertRaises(BlockingIOError):
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.release(owner)
        self.assertEqual(self.wait_exit([short], 1), [short])
        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)  # registration dropped after acquiring
        with self.assertRaises(BlockingIOError):
            fcntl.flock(self.descriptor(), fcntl.LOCK_EX | fcntl.LOCK_NB)  # slot still held via short_fd

    def test_full_waiter_proceeds_when_no_short_is_queued(self):
        owner = self.hold("full")
        fulls = [self.spawn(h, "full") for h in self.helpers[1:]]
        for proc, _ in fulls:
            self.waiting_line(proc)
        self.release(owner)
        done = self.wait_exit([p for p, _ in fulls], 1)
        self.assertEqual(len(done), 1)
        self.assertEqual(sum(p.poll() is None for p, _ in fulls), 1, "two full runs shared the slot")

    def test_short_waits_for_a_full_that_already_holds_the_slot(self):
        owner = self.hold("full")
        short, _ = self.spawn(self.helpers[1], "short")
        self.waiting_line(short)
        self.assertEqual(self.wait_exit([short], 1, seconds=1.5), [], "a short entered a held slot")
        self.release(owner)
        self.assertEqual(self.wait_exit([short], 1), [short])
        self.assertEqual(short.returncode, 0)

    def test_older_helper_without_kind_still_excludes(self):
        owner = self.hold()  # an older runner's call shape: no --kind
        short, _ = self.spawn(self.helpers[1], "short")
        self.waiting_line(short)
        self.assertEqual(self.wait_exit([short], 1, seconds=1.5), [])
        self.release(owner)
        self.assertEqual(self.wait_exit([short], 1), [short])

    def test_unknown_kind_is_refused(self):
        fd = self.descriptor()
        self.call(self.helpers[0], "acquire", fd, "--kind", "medium", fd=fd, rc=2)

    def bash_cancel(self, kind, register_short_first):
        owner = self.hold("full")
        if register_short_first:
            blocker, _ = self.spawn(self.helpers[2], "short")
            self.waiting_line(blocker)
        rival = self.descriptor()
        proc = subprocess.Popen(["bash", "-c", 'trap "" INT; exec "$@"', "ignored-int",
                                 sys.executable, str(self.helpers[1]), "acquire", str(rival),
                                 "--kind", kind],
                                pass_fds=(rival,), stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        self.addCleanup(self.reap, proc)
        self.waiting_line(proc)
        proc.send_signal(signal.SIGINT)
        proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 130)
        with self.assertRaises(BlockingIOError):
            fcntl.flock(rival, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.release(owner)

    def test_cancel_a_short_waiting_for_the_slot(self):
        self.bash_cancel("short", register_short_first=False)

    def test_cancel_a_full_polling_for_the_slot(self):
        self.bash_cancel("full", register_short_first=False)

    def test_cancel_a_full_waiting_on_the_priority_gate(self):
        self.bash_cancel("full", register_short_first=True)

    def test_cancelled_short_drops_its_registration(self):
        owner = self.hold("full")
        short, _ = self.spawn(self.helpers[1], "short")
        self.waiting_line(short)
        short.send_signal(signal.SIGTERM)
        short.communicate(timeout=10)
        full, _ = self.spawn(self.helpers[2], "full")
        self.waiting_line(full)
        self.release(owner)
        self.assertEqual(self.wait_exit([full], 1), [full], "a cancelled short kept blocking full runs")

    def non_regular_priority(self, make):
        priority = self.lock.with_name("priority.lock")
        priority.unlink()
        make(priority)
        fd = self.descriptor()
        self.call(self.helpers[0], "acquire", fd, "--kind", "short", fd=fd, rc=2)
        return priority

    def test_symlinked_priority_file_is_refused_without_touching_target(self):
        target = self.root / "keep-priority"
        target.write_text("keep")
        self.non_regular_priority(lambda p: p.symlink_to(target))
        self.assertEqual(target.read_text(), "keep")

    def test_directory_priority_file_is_refused(self):
        self.assertTrue(self.non_regular_priority(lambda p: p.mkdir()).is_dir())

    def test_fifo_priority_file_is_refused(self):
        self.non_regular_priority(lambda p: os.mkfifo(p))

    def test_prepare_creates_both_lock_files(self):
        self.assertTrue(self.lock.is_file())
        self.assertTrue(self.lock.with_name("priority.lock").is_file())


if __name__ == "__main__":
    unittest.main()
