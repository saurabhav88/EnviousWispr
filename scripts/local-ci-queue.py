#!/usr/bin/env python3
"""One local CI slot across this account's worktrees (#4056).

Bash holds descriptor 9 for the entire run. The acquiring child shares that
open-file description, so its exit does not release the parent's flock. Never
explicitly unlock or remove the persistent file. The kernel releases the slot
when the last shared descriptor closes, including inherited descendants.
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


def checked_descriptor(fd):
    if fd < 3:
        raise ValueError("the CI queue needs a dedicated inherited descriptor")
    expected = LOCK_PATH.lstat()
    actual = os.fstat(fd)
    if not stat.S_ISREG(expected.st_mode) or not stat.S_ISREG(actual.st_mode):
        raise ValueError("CI queue resource must be a regular file, never a symlink")
    if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
        raise ValueError("CI queue descriptor does not name the fixed resource")


def prepare():
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        checked_descriptor(fd)
    finally:
        os.close(fd)
    print(LOCK_PATH)


def acquire(fd):
    checked_descriptor(fd)

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    # A shell's background jobs may inherit SIGINT ignored. Install explicit
    # handlers so cancellation of a queued top-level runner finishes promptly.
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    started = time.monotonic()
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("==> Local CI queue: another run is using this Mac; waiting for its slot", flush=True)
        fcntl.flock(fd, fcntl.LOCK_EX)
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
            acquire(int(argv[1]))
        else:
            raise ValueError("usage: local-ci-queue.py path|prepare|acquire FD")
    except (OSError, ValueError) as error:
        print(f"ERROR: local CI queue: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
