#!/usr/bin/env python3
"""Stop a build or test step that prints nothing for too long (#4461, #4507).

  output-watchdog.py run --phase NAME -- COMMAND [ARGS...]

Runs COMMAND in its own process group, copies its raw stdout and stderr bytes to
this process's stdout unchanged (no formatter, no line buffering), and tracks the
time since the last byte. If COMMAND is silent for EW_NO_OUTPUT_LIMIT_SECS
(default 1200, the founder's 20 minutes) it stops the whole group (TERM, a short
grace, then KILL), reaps it, prints a HUNG line naming the phase and the last
XCTest / Swift Testing case that started, records the same text in
$EW_HUNG_MARKER for the runner's single verdict path, and exits 5. Otherwise it
exits with COMMAND's own status. A TERM/INT/HUP sent to this process stops the
group first and then exits 128+signal, so cleanup finishes before the caller's
locks are released.

Silence means "no observed output", not proven deadlock. The group supervisor
(scripts/local-test-groups.py) uses SilenceClock below for its workers, with a
separate clock per worker, so one busy worker never hides a silent sibling.
While output arrives, the runner's holder card gets `last_output_at` at most
every ten seconds (EW_RUNNER_PID / EW_CARD_HOST name the card).
"""

import importlib.util
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time

HUNG_EXIT = 5
DEFAULT_LIMIT = 1200
GRACE_SECONDS = 10
CARD_EVERY = 10
# XCTest: "Test Case '-[Suite test]' started." / "Test Case 'Suite.test' started";
# Swift Testing: "◇ Test name() started."
STARTED = re.compile(rb"Test Case '([^']+)' started|\xe2\x97\x87 Test (.+?) started")


def limit_seconds():
    raw = os.environ.get("EW_NO_OUTPUT_LIMIT_SECS", "")
    if not raw:
        return DEFAULT_LIMIT
    value = float(raw)
    if value <= 0:
        raise ValueError("EW_NO_OUTPUT_LIMIT_SECS must be positive")
    return value


class SilenceClock:
    """One child's silence timer plus the last test it reported starting."""

    def __init__(self, phase):
        self.phase = phase
        self.last = time.monotonic()
        self.last_test = None
        self._tail = b""

    def saw(self, data):
        self.last = time.monotonic()
        text = self._tail + data
        for match in STARTED.finditer(text):
            name = match.group(1) or match.group(2)
            self.last_test = name.decode("utf-8", "replace")
        self._tail = text[-512:]

    def silent_for(self):
        return time.monotonic() - self.last

    def diagnostic(self, limit):
        minutes = limit / 60
        span = f"{minutes:g} min" if limit >= 60 else f"{limit:g} s"
        return (f"no output for {span} in {self.phase}; "
                f"last test: {self.last_test or 'none observed'}")


def record_hung(text):
    """Leave the hung diagnostic for the runner's verdict path (first one wins)."""
    marker = os.environ.get("EW_HUNG_MARKER")
    if not marker:
        return
    try:
        fd = os.open(marker, os.O_WRONLY | os.O_APPEND)
    except OSError:
        return
    try:
        if os.fstat(fd).st_size == 0:
            os.write(fd, text.encode())
    finally:
        os.close(fd)


class CardToucher:
    """Write the holder card's last_output_at, at most every CARD_EVERY seconds."""

    def __init__(self):
        self.next = 0.0
        self.queue = None
        pid = os.environ.get("EW_RUNNER_PID", "")
        host = os.environ.get("EW_CARD_HOST", "")
        self.pid = int(pid) if pid.isdigit() else None
        self.host = host or None
        if self.pid and self.host:
            path = Path(__file__).resolve().parent.parent / "local-ci-queue.py"
            try:
                spec = importlib.util.spec_from_file_location("local_ci_queue_card", path)
                self.queue = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(self.queue)
            except Exception:
                self.queue = None

    def touch(self):
        now = time.monotonic()
        if self.queue is None or now < self.next:
            return
        self.next = now + CARD_EVERY
        try:
            self.queue.touch_card(self.host, self.pid)
        except Exception:
            pass  # the card is informational; never fail a run over it


def leader_exited(pid):
    """Observe the leader's exit WITHOUT reaping it, so its PID/PGID stay
    reserved until the whole group is stopped (same rule as the group supervisor)."""
    status = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    return status is not None


def stop_group(pid):
    """TERM the child's group, wait briefly, KILL what is left."""
    for sig, wait in ((signal.SIGTERM, GRACE_SECONDS), (signal.SIGKILL, 0)):
        try:
            os.killpg(pid, sig)
        except ProcessLookupError:
            return
        except PermissionError:
            pass  # a group of only zombies; the reap below settles it
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            try:
                os.killpg(pid, 0)
            except (ProcessLookupError, PermissionError):
                return
            time.sleep(0.05)


def run(phase, command):
    limit = limit_seconds()
    received = []

    def handler(signum, _frame):
        if not received:
            received.append(signum)

    previous = {sig: signal.signal(sig, handler) for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
    proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, start_new_session=True)
    clock = SilenceClock(phase)
    card = CardToucher()
    out = sys.stdout.buffer
    fd = proc.stdout.fileno()
    hung = False
    try:
        while True:
            if received:
                break
            remaining = limit - clock.silent_for()
            if remaining <= 0:
                hung = True
                break
            ready, _, _ = select.select([fd], [], [], min(remaining, 1.0))
            if not ready:
                if leader_exited(proc.pid):
                    break  # exited; a helper may still hold the pipe; the group stop below ends it
                continue
            data = os.read(fd, 65536)
            if not data:
                # EOF. A child that closed its output but keeps running is still
                # timed against the same limit.
                while not leader_exited(proc.pid) and not received:
                    if clock.silent_for() >= limit:
                        hung = True
                        break
                    time.sleep(0.2)
                break
            out.write(data)
            out.flush()
            clock.saw(data)
            card.touch()
    finally:
        # Leader completion is not proof the owned work ended: stop whatever is
        # left in the group (helpers, or everything on timeout, cancellation or an
        # output-copy error) BEFORE reaping the leader and releasing the caller.
        stop_group(proc.pid)
        proc.wait()
        proc.stdout.close()
        for sig, old in previous.items():
            signal.signal(sig, old)
    if hung:
        text = clock.diagnostic(limit)
        record_hung(text)
        print(f"==> HUNG: {text}", flush=True)
        return HUNG_EXIT
    if received:
        return 128 + received[0]
    return proc.returncode if proc.returncode >= 0 else 128 - proc.returncode


def main(argv):
    if len(argv) >= 5 and argv[0] == "run" and argv[1] == "--phase" and argv[3] == "--":
        try:
            return run(argv[2], argv[4:])
        except (OSError, ValueError) as error:
            print(f"ERROR: output watchdog: {error}", file=sys.stderr)
            return 2
    print("usage: output-watchdog.py run --phase NAME -- COMMAND [ARGS...]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
