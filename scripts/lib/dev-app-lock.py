#!/usr/bin/env python3
"""scripts/lib/dev-app-lock.py: who owns the shared dev app right now (#3400).

Every worktree's dev build is `com.enviouswispr.app.dev`, and only one runs at
a time (`build-dev-app.sh` step 2 quits every other one). Before this tool,
ownership was settled by broadcast chat between sessions plus process probes
that cannot prove ownership (`code-tooling.md` FACT:
process-and-agent-occupancy-probes-are-unreliable). This file is the one owner
of a machine-wide claim that every checkout reads.

    dev-app-lock.py status
    dev-app-lock.py claim   [--label TEXT] [--worktree PATH]
    dev-app-lock.py release

Exit status: 0 done, 3 held by someone else (the holder card is printed),
2 could not decide (fail closed: treat the app as busy and say why).

WHO THE HOLDER IS. The nearest ancestor process named `claude` or `codex` is
the session. Its pid plus start time is the identity, because pids are
recycled and a start time is not. The holder stays the holder after the
command that claimed exits, for as long as that session process lives.

WHEN A HOLD ENDS. `release`, the holder session process exiting, or
IDLE_SECONDS with no claim from the holder (each claim renews it). A process
check that fails is "cannot tell", never "gone": treating it as gone is how a
live holder loses the app.

NO SESSION FOUND. A run with no `claude`/`codex` ancestor is the founder by
hand. The founder is never blocked (`tools-and-apps.md` RULE:
act-immediately-never-ask-saurabh-permission-for-app-actions), so that run
writes nothing and only prints who holds the app, if anyone.

WHY flock AND NOT mkdir. Every read and write of the holder card happens under
an exclusive `flock` on one small file, held for milliseconds. The kernel
drops that lock when its process dies, so a crash can never leave it stuck,
and taking over a stale hold needs no separate "is the old lock still the one
I judged" step, which is where `mkdir` reclaim schemes race.

`scripts/` is tracked, so every checkout has its own copy of this file at its
own commit, all sharing one directory. A card whose `version` this copy does
not know is refused, never rewritten.
"""

import argparse
import fcntl
import json
import math
import os
import subprocess
import sys
import time
import uuid

# 2: `started` is UTC (round-1 TZ fix); a v1 card holds local time.
VERSION = 2
LOCK_DIR = os.path.expanduser("~/Library/Caches/EnviousWispr/dev-app-lock")
AGENT_NAMES = ("claude", "codex")
IDLE_SECONDS = 15 * 60
PS = "/bin/ps"

EXIT_OK = 0
EXIT_UNDECIDED = 2
EXIT_HELD = 3


class Undecided(Exception):
    """A question this tool could not answer. Callers treat the app as busy."""


def process_info(pid):
    """(ppid, lstart, comm) for a live pid, None when provably gone.

    Raises Undecided when `ps` itself fails, because an empty answer from a
    broken `ps` looks exactly like a dead process.
    """
    try:
        out = subprocess.run(
            [PS, "-o", "ppid=,lstart=,comm=", "-p", str(pid)],
            # `lstart` prints LOCAL time: two sessions with different TZ
            # values would see different start strings for one live process
            # and call it dead. Pin both locale and zone.
            capture_output=True, text=True,
            env={**os.environ, "LC_ALL": "C", "TZ": "UTC"})
    except OSError as e:
        raise Undecided(f"could not run {PS}: {e}")
    line = out.stdout.strip()
    # macOS and procps both exit 1 with no output for an absent pid. Exit 1
    # WITH an error message is ps failing, not the process being gone.
    if out.returncode == 1 and not line and not out.stderr.strip():
        return None
    if out.returncode != 0 or not line:
        raise Undecided(f"{PS} failed for pid {pid} (exit {out.returncode}): "
                        f"{out.stderr.strip()}")
    # `lstart` is always five words: Sat Oct  3 12:10:09 2026.
    parts = line.split(None, 6)
    if len(parts) < 7:
        raise Undecided(f"unexpected {PS} line for pid {pid}: {line!r}")
    return int(parts[0]), " ".join(parts[1:6]), parts[6]


def find_session():
    """The nearest `claude`/`codex` ancestor as {kind, pid, started}, or None."""
    pid = os.getppid()
    seen = 0
    while pid > 1 and seen < 64:
        info = process_info(pid)
        if info is None:
            # An ancestor vanished mid-walk. Answering "no session" here would
            # turn an agent run into a founder run, which skips the lock.
            raise Undecided(f"ancestor pid {pid} exited while finding the session")
        ppid, started, comm = info
        if ppid < 1 or ppid == pid:
            raise Undecided(f"invalid parent pid {ppid} for pid {pid}")
        name = os.path.basename(comm)
        if name in AGENT_NAMES:
            return {"kind": name, "pid": pid, "started": started}
        pid, seen = ppid, seen + 1
    if pid != 1:
        # The walk stopped before reaching pid 1 (launchd/init): the chain was
        # not fully read, so "no session" is unproven and must not skip the lock.
        raise Undecided("ancestor chain did not reach pid 1")
    return None


def holder_alive(card):
    """True if the holder session still runs, False if provably gone."""
    info = process_info(card["pid"])
    return info is not None and info[1] == card["started"]


def describe(card, now):
    idle = int(now - card["last_action_at"])
    held = int(now - card["claimed_at"])
    return (f"{card['kind']} session pid {card['pid']}, "
            f"label \"{card.get('label') or '-'}\", "
            f"worktree {card.get('worktree') or '-'}, "
            f"held {held // 60}m{held % 60:02d}s, "
            f"last claim {idle // 60}m{idle % 60:02d}s ago")


class Store:
    """The holder card, read and written only while the flock is held."""

    def __init__(self):
        os.makedirs(LOCK_DIR, exist_ok=True)
        self.card_path = os.path.join(LOCK_DIR, "holder.json")
        self.fd = os.open(os.path.join(LOCK_DIR, "mutex"),
                          os.O_RDWR | os.O_CREAT, 0o644)

    def __enter__(self):
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)

    def read(self):
        try:
            with open(self.card_path) as f:
                card = json.load(f)
        except FileNotFoundError:
            return None
        except (OSError, ValueError) as e:
            raise Undecided(f"unreadable holder card {self.card_path}: {e}. "
                            "Delete that file by hand if no session holds the app.")
        if not isinstance(card, dict) or card.get("version") != VERSION:
            raise Undecided(
                f"holder card {self.card_path} has version "
                f"{card.get('version') if isinstance(card, dict) else '?'}, "
                f"this checkout knows {VERSION}. Leaving it alone.")
        # A right-version card with a wrong-typed field could make a live
        # holder look dead (started=None never matches) or feed garbage to ps.
        if type(card.get("pid")) is not int or card["pid"] <= 1:
            raise Undecided(f"holder card {self.card_path} has an invalid pid")
        for key in ("kind", "started", "nonce"):
            if not isinstance(card.get(key), str) or not card[key]:
                raise Undecided(f"holder card {self.card_path} has an invalid {key}")
        for key in ("claimed_at", "last_action_at"):
            value = card.get(key)
            if type(value) not in (int, float) or not math.isfinite(value):
                raise Undecided(f"holder card {self.card_path} has an invalid {key}")
        return card

    def write(self, card):
        tmp = f"{self.card_path}.{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            json.dump(card, f, indent=2)
            f.write("\n")
        os.replace(tmp, self.card_path)

    def clear(self):
        try:
            os.unlink(self.card_path)
        except FileNotFoundError:
            pass


def stale_reason(card, now):
    """Why a hold has ended on its own, or None while it stands."""
    if not holder_alive(card):
        return "its session has exited"
    if now - card["last_action_at"] > IDLE_SECONDS:
        return f"no claim for over {IDLE_SECONDS // 60} minutes"
    return None


def same_session(card, me):
    return me is not None and card["pid"] == me["pid"] \
        and card["started"] == me["started"]


def cmd_status(_args):
    now = time.time()
    with Store() as store:
        card = store.read()
        if card is None:
            print("dev-app-lock: free")
            return EXIT_OK
        reason = stale_reason(card, now)
    if reason:
        print(f"dev-app-lock: free ({reason}; last holder: {describe(card, now)})")
    else:
        print(f"dev-app-lock: held by {describe(card, now)}")
    return EXIT_OK


def cmd_claim(args):
    now = time.time()
    me = find_session()
    if me is None:
        # The founder is never blocked, so nothing below may wait on the
        # mutex or fail on a bad card. The heads-up is best effort.
        print("dev-app-lock: no Claude or Codex session found, so this is a "
              "founder run and takes no lock.")
        try:
            with open(os.path.join(LOCK_DIR, "holder.json")) as f:
                print(f"dev-app-lock: heads-up, last recorded holder: "
                      f"{describe(json.load(f), now)}")
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f"dev-app-lock: heads-up unavailable ({type(e).__name__})")
        return EXIT_OK
    with Store() as store:
        # Read the clock AFTER the mutex: a claimer that waited (or was
        # suspended) must not write a last-claim time that is already old.
        now = time.time()
        card = store.read()
        note = "claimed"
        if card is not None:
            if same_session(card, me):
                note = "renewed"
            else:
                reason = stale_reason(card, now)
                if reason is None:
                    print(f"dev-app-lock: BUSY. Held by {describe(card, now)}. "
                          "Wait and re-run `status`, or ask that session.")
                    return EXIT_HELD
                note = f"took over ({reason}; was {describe(card, now)})"
        new = {
            "version": VERSION,
            "kind": me["kind"],
            "pid": me["pid"],
            "started": me["started"],
            "label": args.label,
            "worktree": args.worktree,
            "claimed_at": card["claimed_at"] if note == "renewed" else now,
            "last_action_at": now,
            "nonce": card["nonce"] if note == "renewed" else uuid.uuid4().hex,
        }
        store.write(new)
    print(f"dev-app-lock: {note} by {describe(new, now)}")
    return EXIT_OK


def cmd_release(_args):
    now = time.time()
    me = find_session()
    with Store() as store:
        card = store.read()
        if card is None:
            print("dev-app-lock: already free")
            return EXIT_OK
        if not same_session(card, me):
            print(f"dev-app-lock: not yours to release. Held by {describe(card, now)}")
            return EXIT_HELD
        store.clear()
    print("dev-app-lock: released")
    return EXIT_OK


def default_worktree():
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else os.getcwd()


def main(argv):
    parser = argparse.ArgumentParser(prog="dev-app-lock.py")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    claim = sub.add_parser("claim")
    claim.add_argument("--label", default="")
    claim.add_argument("--worktree", default=None)
    sub.add_parser("release")
    args = parser.parse_args(argv)
    try:
        if args.command == "claim" and args.worktree is None:
            args.worktree = default_worktree()
        return {"status": cmd_status, "claim": cmd_claim,
                "release": cmd_release}[args.command](args)
    except (Undecided, OSError, KeyError, TypeError, ValueError,
            OverflowError, RecursionError) as e:
        # OSError: the lock folder cannot be made or opened (a Codex sandbox
        # that blocks writes outside the worktree lands here). KeyError and
        # TypeError: a card of the right version with missing or wrong fields.
        # All of them are "could not decide", never a traceback a caller
        # might read as a different exit code. ValueError/OverflowError: a ps
        # line or timestamp that does not parse.
        print(f"dev-app-lock: cannot decide, treating the app as busy: "
              f"{type(e).__name__}: {e}", file=sys.stderr)
        return EXIT_UNDECIDED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
