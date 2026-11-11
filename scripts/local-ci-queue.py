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

Hosts (#4507): one slot per Mac named in the local host list (scripts/lib/
mac_hosts.py). The local Mac keeps LOCK_PATH exactly, so runners that already use
it stay mutually exclusive; a backup Mac's slot lives on THIS Mac at
local-ci/hosts/<name>/runner.lock, because every session runs here. The parent
opens one descriptor per candidate slot; `acquire-any` locks the inherited
descriptors in host order and reports which one won (a printed name is never a
descriptor transfer). priority.lock stays one global file, so short runs go first
across all Macs. A holder card (holder.json beside each slot) describes the
holder for status and WAITING lines only: the flock decides ownership, a card
never does.
"""

import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import signal
import stat
import subprocess
import sys
import time


# OS identity, not HOME: changing a shell environment must not create a second
# queue. Tests rewrite this one literal in a private COPY, never in production.
LOCK_PATH = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Caches/EnviousWispr/local-ci/runner.lock"


KINDS = ("short", "full")


def priority_path():
    return LOCK_PATH.with_name("priority.lock")


HOST_NAME = re.compile(r"[a-z0-9-]{1,32}")


def host_slot_path(host):
    """The slot file for one host; "local" keeps LOCK_PATH (older runners share it)."""
    if host == "local":
        return LOCK_PATH
    if not HOST_NAME.fullmatch(host):
        raise ValueError(f"not a host name: {host!r}")
    return LOCK_PATH.parent / "hosts" / host / "runner.lock"


def card_path(host):
    return host_slot_path(host).with_name("holder.json")


def process_start(pid):
    """`ps` start time in a fixed locale and zone, or None when the pid is gone."""
    result = subprocess.run(["/bin/ps", "-o", "lstart=", "-p", str(pid)], capture_output=True,
                            text=True, env={"LC_ALL": "C", "TZ": "UTC", "PATH": "/usr/bin:/bin"})
    started = result.stdout.strip()
    return started or None


def write_card(host, pid, kind, label, worktree, config_sha256):
    """Describe the holder of a slot this process's parent now owns (atomic replace)."""
    card = card_path(host)
    card.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    data = {"version": 1, "host": host, "pid": pid, "started": process_start(pid),
            "label": label, "worktree": worktree, "kind": kind,
            "claimed_at": time.time(), "last_output_at": None,
            "config_sha256": config_sha256}
    tmp = card.with_name(f"holder.json.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data))
    os.replace(tmp, card)


def touch_card(host, pid):
    """Set last_output_at on the card held by `pid` (the runner); never create one."""
    card = card_path(host)
    try:
        data = json.loads(card.read_text())
    except (OSError, ValueError):
        return
    if not isinstance(data, dict) or data.get("pid") != pid:
        return
    data["last_output_at"] = time.time()
    tmp = card.with_name(f"holder.json.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data))
    os.replace(tmp, card)


def read_card(host):
    """The card when its holder process is still the same process, else None."""
    try:
        data = json.loads(card_path(host).read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get("pid"), int):
        return None
    if data.get("started") is None or process_start(data["pid"]) != data["started"]:
        return None
    return data


def describe_holder(host):
    card = read_card(host)
    if card is None:
        return f"{host}: held, holder unknown (an older runner, or its card is stale)"
    minutes = int((time.time() - card.get("claimed_at", time.time())) // 60)
    return f"{host}: {card.get('label') or 'unlabeled'} ({card.get('kind')}, {minutes} min, {card.get('worktree')})"


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


def prepare_host(host):
    """Create one host's slot file (and the shared priority file); print its path."""
    path = host_slot_path(host)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.close(open_checked(path))
    os.close(open_checked(priority_path()))
    print(path)


def try_slots(slots):
    """Lock the first free inherited slot descriptor in host order; its host, or None."""
    for host, fd in slots:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return host
        except BlockingIOError:
            continue
    return None


def waiting_line(slots, note):
    holders = "; ".join(describe_holder(host) for host, _ in slots)
    return f"==> Local CI queue: every Mac's slot is taken; waiting (short runs go first) [{note}] held by: {holders}"


def acquire_any(slots, kind):
    """Take the first free slot among inherited descriptors, in the order given."""
    if kind not in KINDS:
        raise ValueError(f"queue kind must be one of {', '.join(KINDS)}")
    if not slots:
        raise ValueError("acquire-any needs at least one HOST=FD slot")
    for host, fd in slots:
        checked_descriptor(fd, host_slot_path(host))

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    started = time.monotonic()
    announced = False
    won = None
    if kind == "short":
        pfd = open_checked(priority_path())
        try:
            fcntl.flock(pfd, fcntl.LOCK_SH)  # registered until a slot is ours
            while won is None:
                won = try_slots(slots)
                if won is None:
                    if not announced:
                        print(waiting_line(slots, "short run"), flush=True)
                        announced = True
                    time.sleep(1)  # poll: several slots cannot be awaited with one blocking flock
        finally:
            os.close(pfd)
    else:
        while won is None:
            pfd = open_checked(priority_path())
            try:
                try:
                    fcntl.flock(pfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    if not announced:
                        print(waiting_line(slots, "full run; a short run is queued"), flush=True)
                        announced = True
                    fcntl.flock(pfd, fcntl.LOCK_EX)
                won = try_slots(slots)
            finally:
                os.close(pfd)
            if won is None:
                if not announced:
                    print(waiting_line(slots, "full run"), flush=True)
                    announced = True
                time.sleep(1)  # poll: never block on a slot while holding priority.lock
    print(f"==> phase local CI queue wait: {time.monotonic() - started:.3f}s", flush=True)
    print(f"==> Local CI queue: slot acquired on {won}", flush=True)
    print(f"EW_SLOT_HOST={won}", flush=True)
    return won


def parse_options(args, allowed):
    """--name value pairs into a dict; anything else is a usage error."""
    options = {}
    if len(args) % 2:
        raise ValueError("options must be --name value pairs")
    for flag, value in zip(args[::2], args[1::2]):
        if not flag.startswith("--") or flag[2:] not in allowed or flag[2:] in options:
            raise ValueError(f"unknown or repeated option {flag}")
        options[flag[2:]] = value
    return options


CARD_OPTIONS = ("label", "worktree", "config-sha256")
WON_OPTIONS = CARD_OPTIONS + ("won-file",)


def record(host, kind, options):
    """Write the holder card for the parent runner, when the caller asked for one."""
    if "label" in options:
        write_card(host, os.getppid(), kind, options["label"], options.get("worktree", ""),
                   options.get("config-sha256", "none"))


def main(argv):
    usage = ("usage: local-ci-queue.py path|prepare|prepare-host HOST|"
             "acquire FD [--kind short|full] [--label L --worktree W --config-sha256 H]|"
             "acquire-any --kind short|full --slots HOST=FD,... [--label L --worktree W --config-sha256 H]")
    try:
        if argv == ["path"]:
            print(LOCK_PATH)  # Read-only, including when HOME is overridden.
        elif argv == ["prepare"]:
            prepare()
        elif len(argv) == 2 and argv[0] == "prepare-host":
            prepare_host(argv[1])
        elif len(argv) == 2 and argv[0] == "acquire":
            acquire(int(argv[1]))  # an older runner copy: treated as a full run
        elif len(argv) == 4 and argv[0] == "acquire" and argv[2] == "--kind":
            acquire(int(argv[1]), argv[3])
        elif len(argv) > 4 and argv[0] == "acquire" and argv[2] == "--kind":
            options = parse_options(argv[4:], CARD_OPTIONS)
            acquire(int(argv[1]), argv[3])
            record("local", argv[3], options)
        elif argv and argv[0] == "acquire-any":
            options = parse_options(argv[1:], ("kind", "slots") + WON_OPTIONS)
            slots = []
            for item in options.get("slots", "").split(","):
                host, sep, fd = item.partition("=")
                if not sep:
                    raise ValueError("--slots takes HOST=FD,...")
                slots.append((host, int(fd)))
            kind = options.get("kind", "full")
            won = acquire_any(slots, kind)
            record(won, kind, options)
            if "won-file" in options:  # how a shell parent learns which descriptor won
                Path(options["won-file"]).write_text(won + "\n")
        else:
            raise ValueError(usage)
    except (OSError, ValueError) as error:
        print(f"ERROR: local CI queue: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
