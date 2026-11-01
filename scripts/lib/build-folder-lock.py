#!/usr/bin/env python3
"""One build at a time inside one checkout's .derivedData (#4293).

The local Debug test lane and the dev app build share .derivedData/Dev, and two
xcodebuild processes in one derived-data folder fail ("database is locked"). The
shared steps around the build (project generation, package seeding, toolchain
preparation, grouped test workers, the deploy copy) are not covered by Xcode's own
lock either. So scripts/xcode-test.sh, scripts/build-dev-app.sh and
scripts/lib/l10n-build-with-receipt.sh hold this per-checkout lock around them.

Same pattern as scripts/local-ci-queue.py: Bash holds a descriptor for the whole
run and a short Python child takes fcntl.flock on it. The child shares that
open-file description, so its exit does not release the parent's lock. Never
explicitly unlock or remove the persistent file. The kernel releases the lock
when the last shared descriptor closes, including inherited descendants.

Commands:
  path ROOT          print ROOT/.derivedData/.ew-build.lock
  prepare ROOT       create it if needed (never a symlink) and print it
  acquire FD ROOT    lock FD, which must name that file; waits, saying so once
"""

import fcntl
import os
from pathlib import Path
import signal
import stat
import sys
import time

LOCK_NAME = ".ew-build.lock"


def lock_path(root):
    root = Path(root)
    if not root.is_absolute():
        raise ValueError("checkout root must be an absolute path")
    return root / ".derivedData" / LOCK_NAME


def checked_descriptor(fd, path):
    if fd < 3:
        raise ValueError("the build lock needs a dedicated inherited descriptor")
    expected = path.lstat()
    actual = os.fstat(fd)
    if not stat.S_ISREG(expected.st_mode) or not stat.S_ISREG(actual.st_mode):
        raise ValueError("build lock must be a regular file, never a symlink")
    if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
        raise ValueError("build lock descriptor does not name this checkout's lock file")


def prepare(root):
    path = lock_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        checked_descriptor(fd, path)
    finally:
        os.close(fd)
    print(path)


def acquire(fd, root):
    path = lock_path(root)
    checked_descriptor(fd, path)

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    # A shell's background jobs may inherit SIGINT ignored; cancel promptly anyway.
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    started = time.monotonic()
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("==> Build lock: another build or test run is using this checkout's .derivedData; waiting", flush=True)
        fcntl.flock(fd, fcntl.LOCK_EX)
    print(f"==> phase build lock wait: {time.monotonic() - started:.3f}s", flush=True)
    # No LOCK_UN here. The parent still owns the same descriptor.


def main(argv):
    try:
        if len(argv) == 2 and argv[0] == "path":
            print(lock_path(argv[1]))
        elif len(argv) == 2 and argv[0] == "prepare":
            prepare(argv[1])
        elif len(argv) == 3 and argv[0] == "acquire":
            acquire(int(argv[1]), argv[2])
        else:
            raise ValueError("usage: build-folder-lock.py path ROOT | prepare ROOT | acquire FD ROOT")
    except (OSError, ValueError) as error:
        print(f"ERROR: build lock: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
