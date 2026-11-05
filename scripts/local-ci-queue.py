#!/usr/bin/env python3
"""One local CI slot across this account's worktrees (#4056).

Bash holds descriptor 9 for the entire run. The acquiring child shares that
open-file description, so its exit does not release the parent's flock. Never
explicitly unlock or remove the persistent file. The kernel releases the slot
when the last shared descriptor closes, including inherited descendants.

Short runs go first (#4089, #4090). A short (filtered) waiter registers by
holding a shared lock on the sibling priority.lock while it waits for the slot,
and drops it once the slot is its own. A full waiter takes the slot only while
it holds priority.lock exclusively, so it never takes the slot while a short
waiter is registered, and it never blocks on the slot while holding that lock:
it polls. No FIFO order, bounded delay or freedom from starvation is promised.
An older copy of this helper (no --kind) still excludes but skips priority.
"""

import fcntl
import os
from pathlib import Path
import pwd
import signal
import stat
import sys
import time


# OS identity, not HOME: changing a shell environment must not create a second
# queue. Tests rewrite this one literal in a private COPY, never in production.
LOCK_PATH = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Caches/EnviousWispr/local-ci/runner.lock"


KINDS = ("short", "full")


def priority_path():
    return LOCK_PATH.with_name("priority.lock")


def checked_descriptor(fd, path=None):
    path = LOCK_PATH if path is None else path
    if fd < 3:
        raise ValueError("the CI queue needs a dedicated inherited descriptor")
    expected = path.lstat()
    actual = os.fstat(fd)
    if not stat.S_ISREG(expected.st_mode) or not stat.S_ISREG(actual.st_mode):
        raise ValueError("CI queue resource must be a regular file, never a symlink")
    if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
        raise ValueError("CI queue descriptor does not name the fixed resource")


def open_checked(path):
    """Open (creating if absent) one persistent lock file; never follow a link."""
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        checked_descriptor(fd, path)
    except BaseException:
        os.close(fd)
        raise
    return fd


def prepare():
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    for path in (LOCK_PATH, priority_path()):
        os.close(open_checked(path))
    print(LOCK_PATH)


WAITING = "==> Local CI queue: another run is using this Mac; waiting for its slot (short runs go first)"


def wait_short(fd):
    # Registered from the moment the shared lock is held until the slot is ours.
    pfd = open_checked(priority_path())
    try:
        fcntl.flock(pfd, fcntl.LOCK_SH)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(WAITING + " [short run]", flush=True)
            fcntl.flock(fd, fcntl.LOCK_EX)
    finally:
        os.close(pfd)  # releases only the priority registration


def wait_full(fd):
    announced = False
    while True:
        pfd = open_checked(priority_path())
        try:
            try:
                fcntl.flock(pfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                if not announced:
                    print(WAITING + " [full run; a short run is queued]", flush=True)
                    announced = True
                fcntl.flock(pfd, fcntl.LOCK_EX)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return
            except BlockingIOError:
                pass
        finally:
            os.close(pfd)
        if not announced:
            print(WAITING + " [full run]", flush=True)
            announced = True
        time.sleep(1)  # poll: never block on the slot while holding priority.lock


def acquire(fd, kind="full"):
    if kind not in KINDS:
        raise ValueError(f"queue kind must be one of {', '.join(KINDS)}")
    checked_descriptor(fd)

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    # A shell's background jobs may inherit SIGINT ignored. Install explicit
    # handlers so cancellation of a queued top-level runner finishes promptly.
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    started = time.monotonic()
    if kind == "short":
        wait_short(fd)
    else:
        wait_full(fd)
    print(f"==> phase local CI queue wait: {time.monotonic() - started:.3f}s", flush=True)
    print("==> Local CI queue: slot acquired (one local test run at a time)", flush=True)
    # No LOCK_UN here. The parent runner still owns the same descriptor.


def main(argv):
    try:
        if argv == ["path"]:
            print(LOCK_PATH)  # Read-only, including when HOME is overridden.
        elif argv == ["prepare"]:
            prepare()
        elif len(argv) == 2 and argv[0] == "acquire":
            acquire(int(argv[1]))  # an older runner copy: treated as a full run
        elif len(argv) == 4 and argv[0] == "acquire" and argv[2] == "--kind":
            acquire(int(argv[1]), argv[3])
        else:
            raise ValueError("usage: local-ci-queue.py path|prepare|acquire FD [--kind short|full]")
    except (OSError, ValueError) as error:
        print(f"ERROR: local CI queue: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
