#!/usr/bin/env python3
"""scripts/lib/dev-app-lock.py: who owns the shared dev app right now (#3400).

Every worktree's dev build is `com.enviouswispr.app.dev`, and only one runs at
a time (`build-dev-app.sh` step 2 quits every other one). Before this tool,
ownership was settled by claim and release messages broadcast to every live
session, each costing every peer a turn. This file is the one owner of a
machine-wide claim that every checkout reads instead.

    dev-app-lock.py status
    dev-app-lock.py claim   [--label TEXT] [--worktree PATH]
    dev-app-lock.py release
    dev-app-lock.py check                 (requires the caller's existing hold)
    dev-app-lock.py remind  --event NAME   (Claude/Codex hook; always exit 0)
    dev-app-lock.py wait-mark              (hook; reads the hook JSON on stdin; always exit 0)

Exit status: 0 done, 3 held by someone else (the holder card is printed),
2 could not decide (fail closed: treat the app as busy and say why).

WHO THE HOLDER IS. The nearest ancestor process named `claude` or `codex` is
the host (see `agent_kind` for name forms). PID/start time binds its process
incarnation. Codex also requires its native chat ID, since desktop chats share
one host. Hook session_id and shell CODEX_THREAD_ID identify the current chat.
CODEX_SESSION_ID is a legacy fallback, and can differ in nested CLI sessions.
The holder stays the holder after the
command that claimed exits, for as long as that session process lives.

WHEN A HOLD ENDS. Three ways: the holder runs `release`, the holder session
process exits, or the holder has been WAITING ON THE FOUNDER for WAIT_SECONDS
with no reply from him (founder 2026-10-20, #3952: "it's been 10 minutes and no
reply from me ... that session should self release it so other sessions can
continue"). There is still no plain idle timer (founder 2026-10-03): a holder
that is working, or waiting on its own background job, keeps the app however
long it takes, because a timer would let a peer quit an app that is mid-test.
`wait-mark` (a hook) records the wait as event files named for the hold's
nonce, `wait-<nonce>.*`, when the holder's turn ends asking him something (a `NEED YOU`/`DONE` status line, the desktop
app's blocking question box, `AskUserQuestion`) and clears it when he replies.
A sleeping session cannot release itself, so the release happens at the next
peer `claim`: past WAIT_SECONDS the card counts as released. `remind` nudges
the holder session every REMIND_SECONDS so a forgotten hold is noticed by its
own session. A process check that fails is "cannot tell", never "gone":
treating it as gone is how a live holder loses the app.

NO SESSION FOUND. A run with no agent ancestor AND no Codex context is the founder by
hand. The founder is never blocked (`tools-and-apps.md` RULE:
act-immediately-never-ask-saurabh-permission-for-app-actions), so that run
writes nothing and only prints who holds the app, if anyone.

WHY flock AND NOT mkdir. Every read and write of the holder card happens under
an exclusive `flock` on one small file, held for milliseconds. The kernel
drops that lock when its process dies, so a crash can never leave it stuck,
and taking over an exited holder's card needs no separate "is the old lock
still the one I judged" step, which is where `mkdir` reclaim schemes race.

`scripts/` is tracked, so every checkout has its own copy of this file at its
own commit, all sharing one directory. A card whose `version` this copy does
not know is refused, never rewritten.
"""

import argparse
import fcntl
import json
import math
import os
import re
import subprocess
import sys
import time
import uuid

# 2: UTC starts; 3: no idle timer; 4: Codex chat identity. Old readers refuse v4.
VERSION = 4
LOCK_DIR = os.path.expanduser("~/Library/Caches/EnviousWispr/dev-app-lock")
AGENT_NAMES = ("claude", "codex")
REMIND_SECONDS = 30 * 60
# #3952: a hold whose session has waited this long on the founder, with no
# reply, counts as released.
WAIT_SECONDS = 10 * 60
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
            [PS, "-o", "ppid=,lstart=,stat=,comm=", "-p", str(pid)],
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
    parts = line.split(None, 7)
    if len(parts) != 8:
        raise Undecided(f"unexpected {PS} line for pid {pid}: {line!r}")
    # An exited process its parent has not reaped yet (a zombie) still lists
    # its pid and start time; it is gone, not a live holder.
    if parts[6].startswith("Z"):
        return None
    return int(parts[0]), " ".join(parts[1:6]), parts[7]


def codex_chat_id(native_session_id=None):
    """Native thread identity wins over an inherited legacy session ID."""
    value = (native_session_id if native_session_id is not None else
             os.environ.get("CODEX_THREAD_ID", os.environ.get("CODEX_SESSION_ID")))
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value) is None:
        raise Undecided("Codex chat identity is missing or invalid")
    return value


def find_session(native_session_id=None):
    """Nearest agent process, plus native chat identity for Codex."""
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
        kind = agent_kind(comm)
        if kind is not None:
            me = {"kind": kind, "pid": pid, "started": started}
            if kind == "codex":
                me["session_id"] = codex_chat_id(native_session_id)
            return me
        pid, seen = ppid, seen + 1
    if pid != 1:
        # The walk stopped before reaching pid 1 (launchd/init): the chain was
        # not fully read, so "no session" is unproven and must not skip the lock.
        raise Undecided("ancestor chain did not reach pid 1")
    if native_session_id is not None or any(
            k in os.environ for k in ("CODEX_THREAD_ID", "CODEX_SESSION_ID")):
        raise Undecided("Codex context found without a recognized agent process")
    return None


# The native installer runs Claude Code from a version-named file, e.g.
# ~/.local/share/claude/versions/2.1.288. Launched through the `claude`
# symlink, ps shows `claude`; launched by full path it can show this path.
CLAUDE_VERSION_PATH = re.compile(
    re.escape(os.path.expanduser("~/.local/share/claude/versions/"))
    + r"\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?")


# #3952: the Claude desktop app (Code tab) runs one Claude Code process per
# session from its own bundle, e.g. ~/Library/Application Support/Claude/
# claude-code/2.1.299/4fa9694b7975/claude.app/Contents/MacOS/claude (measured
# 2026-10-20). "Application Support" has a space, so the first-word rule below
# reads it as `Application` and the session ran as a founder run that took no
# lock, letting peers quit its app mid-test. The outer app
# (/Applications/Claude.app/...) and its `disclaimer` helper are hosts, not
# sessions, and stay unrecognized.
CLAUDE_DESKTOP_PATH = re.compile(
    re.escape(os.path.expanduser("~/Library/Application Support/Claude/claude-code/"))
    + r"\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?/[A-Za-z0-9]+"
    + re.escape("/claude.app/Contents/MacOS/claude"))


def agent_kind(comm):
    """`claude`/`codex` when this ps `comm` is a session process, else None.

    Measured on this Mac 2026-10-03: interactive sessions show `claude`;
    daemon-hosted sessions rewrite their title to `claude bg-spare` (the
    session itself; its tool shells are its children) and their host to
    `claude bg-pty-host` (a host, never a session: refused). Matching only
    the exact name `claude` missed the
    daemon form, which turned an agent run into a founder run that skips the
    lock. So the FIRST WORD's basename is what counts. A path with spaces
    (`/Applications/Claude.app/...`) fails closed toward "not a session".

    Stated limit: a command detached from its session (a new Terminal window,
    launchctl, a pre-existing tmux server, a background job that outlives its
    shell) has no agent ancestor and runs as a founder run.
    """
    if "claude" in AGENT_NAMES and CLAUDE_DESKTOP_PATH.fullmatch(comm):
        return "claude"
    words = comm.split()
    name = os.path.basename(words[0]) if words else ""
    if name in AGENT_NAMES:
        if name == "claude" and words[1:] == ["bg-pty-host"]:
            # The daemon's host serves many sessions; reaching it means the
            # session process was not in the chain, so nobody can be named.
            raise Undecided("Claude host process found without a session process")
        return name
    if "claude" in AGENT_NAMES and CLAUDE_VERSION_PATH.fullmatch(comm):
        return "claude"
    return None


def holder_alive(card):
    """True if the holder session still runs, False if provably gone."""
    info = process_info(card["pid"])
    return info is not None and info[1] == card["started"]


# #3952: the wait on the founder lives OUTSIDE the card, as event files named
# `wait-<nonce>.<ns>.set` and `wait-<nonce>.<ns>.clear`, created without the
# mutex. A reply must never be lost because another process holds the mutex
# (Codex review rounds 1 and 2: skipping or a bounded wait could both drop it
# while a stalled `ps` held the mutex), and a late "set" must never undo an
# earlier-stamped reply (round 3), so each event is its own create-only file
# stamped when its hook STARTED, and the newest event wins. The nonce ties the
# events to one hold, so a takeover can never inherit an old hold's wait.
_NONCE = re.compile(r"[A-Za-z0-9_-]{1,64}")
_WAIT_EVENT = re.compile(r"([0-9]{1,20})\.(set|clear)")


def wait_file(card):
    """Name prefix of this hold's wait events, or None for an unsafe nonce."""
    nonce = card.get("nonce")
    if not isinstance(nonce, str) or _NONCE.fullmatch(nonce) is None:
        return None
    return os.path.join(LOCK_DIR, f"wait-{nonce}")


def _wait_event(card, action, when):
    path = wait_file(card)
    if path is None:
        return
    try:
        fd = os.open(f"{path}.{int(when * 1_000_000_000)}.{action}",
                     os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        return
    os.close(fd)


def start_wait(card, when):
    _wait_event(card, "set", when)


def end_wait(card, when=None):
    _wait_event(card, "clear", time.time() if when is None else when)


def waited(card, now):
    """Seconds the holder has waited on the founder, or None if it is not waiting.

    Replays this hold's events in stamp order: a clear ends a wait, and the
    first set after it starts one (the oldest unanswered ask counts). Anything
    unreadable counts as not waiting: the safe direction keeps the holder's app.
    """
    path = wait_file(card)
    if path is None:
        return None
    prefix = os.path.basename(path) + "."
    events = []
    try:
        for name in os.listdir(LOCK_DIR):
            if name.startswith(prefix):
                m = _WAIT_EVENT.fullmatch(name[len(prefix):])
                if m:
                    events.append((int(m.group(1)), m.group(2) == "clear"))
    except OSError:
        return None
    since = None
    # At equal stamps the clear sorts last, so the reply wins.
    for stamp, is_clear in sorted(events):
        if is_clear:
            since = None
        elif since is None:
            since = stamp / 1_000_000_000
    return None if since is None else max(0.0, now - since)


def clear_all_waits():
    """Drop every wait file. Run under the mutex when a hold starts or ends,
    which also sweeps a file a racing `wait-mark` left for an ended hold."""
    try:
        names = os.listdir(LOCK_DIR)
    except FileNotFoundError:
        return
    for name in names:
        if name.startswith("wait-"):
            try:
                os.unlink(os.path.join(LOCK_DIR, name))
            except FileNotFoundError:
                pass


def wait_expired(card, now):
    w = waited(card, now)
    return w is not None and w >= WAIT_SECONDS


def describe(card, now):
    held = int(now - card["claimed_at"])
    chat = f", chat {card['session_id']}" if card.get("session_id") else ""
    w = waited(card, now)
    wait = "" if w is None else (
        f", waiting on the founder {int(w) // 60}m{int(w) % 60:02d}s "
        f"(released at {WAIT_SECONDS // 60}m with no reply)")
    return (f"{card['kind']} session pid {card['pid']}{chat}, "
            f"label \"{card.get('label') or '-'}\", "
            f"worktree {card.get('worktree') or '-'}, "
            f"held {held // 60}m{held % 60:02d}s{wait}")


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
        if not isinstance(card, dict) or card.get("version") not in (3, VERSION):
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
        for key in ("claimed_at", "reminded_at"):
            value = card.get(key)
            if type(value) not in (int, float) or not math.isfinite(value):
                raise Undecided(f"holder card {self.card_path} has an invalid {key}")
        if card["version"] == VERSION and card["kind"] == "codex":
            value = card.get("session_id")
            if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value) is None:
                raise Undecided(f"holder card {self.card_path} has an invalid Codex chat ID")
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


class NonBlockingStore(Store):
    """For the reminder hook: skip rather than wait if the mutex is busy, so
    a stuck claimer can never stall a session's prompt or tool call."""

    def __enter__(self):
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            os.close(self.fd)
            raise
        return self


def same_session(card, me):
    return me is not None and card["kind"] == me["kind"] \
        and card["pid"] == me["pid"] and card["started"] == me["started"] \
        and (me["kind"] != "codex" or
             bool(card.get("session_id")) and card["session_id"] == me.get("session_id"))


def cmd_status(_args):
    now = time.time()
    with Store() as store:
        card = store.read()
        if card is None:
            print("dev-app-lock: free")
            return EXIT_OK
        alive = holder_alive(card)
    if alive and wait_expired(card, now):
        print(f"dev-app-lock: free (holder waited on the founder with no reply; "
              f"was {describe(card, now)})")
    elif alive:
        print(f"dev-app-lock: held by {describe(card, now)}")
    else:
        print(f"dev-app-lock: free (holder session exited; was {describe(card, now)})")
    return EXIT_OK


def cmd_claim(args):
    now = time.time()
    me = find_session(args.native_session_id)
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
        now = time.time()
        card = store.read()
        if card is not None and same_session(card, me):
            # Claiming again is app work, so it is not waiting any more.
            end_wait(card)
            print(f"dev-app-lock: already yours ({describe(card, now)})")
            return EXIT_OK
        note = "claimed"
        if card is not None:
            if not holder_alive(card):
                note = f"took over (holder session exited; was {describe(card, now)})"
            elif wait_expired(card, now):
                note = ("took over (holder waited on the founder with no reply; "
                        f"was {describe(card, now)})")
            else:
                print(f"dev-app-lock: BUSY. Held by {describe(card, now)}. "
                      "Wait and re-run `status`, or ask that session.")
                return EXIT_HELD
        new = {
            "version": VERSION,
            "kind": me["kind"],
            "pid": me["pid"],
            "started": me["started"],
            "label": args.label,
            "worktree": args.worktree,
            "claimed_at": now,
            "reminded_at": now,
            "nonce": uuid.uuid4().hex,
        }
        if me["kind"] == "codex":
            new["session_id"] = me["session_id"]
        clear_all_waits()
        store.write(new)
    print(f"dev-app-lock: {note} by {describe(new, now)}")
    return EXIT_OK


def cmd_release(args):
    now = time.time()
    me = find_session(args.native_session_id)
    with Store() as store:
        card = store.read()
        if card is None:
            print("dev-app-lock: already free")
            return EXIT_OK
        if not same_session(card, me) or (args.nonce is not None and args.nonce != card["nonce"]):
            print(f"dev-app-lock: not yours to release. Held by {describe(card, now)}")
            return EXIT_HELD
        clear_all_waits()
        store.clear()
    print("dev-app-lock: released")
    return EXIT_OK


def cmd_check(args):
    """Read-only ownership check; a free slot still requires a separate claim."""
    me = find_session(args.native_session_id)
    with NonBlockingStore() as store:
        card = store.read()
        if card is not None and same_session(card, me):
            print(f"dev-app-lock: yours ({describe(card, time.time())})")
            return EXIT_OK
    print("dev-app-lock: claim the shared dev app in a separate tool call first")
    return EXIT_HELD


def cmd_remind(args):
    """Claude Code hook: nudge the HOLDER session every REMIND_SECONDS.

    Runs on every tool call and prompt of every session, so it must be cheap
    and must never fail a session. With no card (nobody holds the app, the
    normal case) it returns before running ps. Non-holders get nothing.
    """
    try:
        card_path = os.path.join(LOCK_DIR, "holder.json")
        if not os.path.exists(card_path):
            return EXIT_OK
        now = time.time()
        with open(card_path) as f:
            peek = json.load(f)
        if now - peek.get("reminded_at", now) < REMIND_SECONDS:
            return EXIT_OK
        me = find_session(args.native_session_id)
        if me is None or not same_session(peek, me):
            return EXIT_OK
        with NonBlockingStore() as store:
            now = time.time()
            card = store.read()
            if card is None or not same_session(card, me) \
                    or now - card["reminded_at"] < REMIND_SECONDS:
                return EXIT_OK
            card["reminded_at"] = now
            store.write(card)
        text = (f"Reminder: this session holds the shared dev app "
                f"({describe(card, now)}). If your dev-app work is done, run "
                f"`python3 {os.path.abspath(__file__)} release` now; otherwise "
                "ignore this.")
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": args.event, "additionalContext": text}}))
    except Exception:
        pass
    return EXIT_OK


# The GR-STATUS-FIRST line `<label> — <STATUS>`, matched the way the Stop gate
# ~/.claude/scripts/envious-notify-gate.py (`_STATUS_LINE`, `_NOT_A_LABEL`)
# matches it. Only the two statuses that wait on the founder count here.
_WAITING_STATUS_LINE = re.compile(r"^(?P<label>.+?)\s[—–-]\s(?:DONE|NEED YOU)(?::.*)?$")
_NOT_A_LABEL = ("#", ">", "`", '"', "'", "- ", "* ", "+ ")
# Prompts that reach a session without the founder replying: a background
# task finishing and a peer session's message. Anything else is his reply.
_NOT_HIS_REPLY = re.compile(r"\s*(?:<task-notification>|Another Claude session sent a message:)")
# The desktop app's blocking question box. It ends the turn without running
# Stop hooks (measured 2026-10-20, #3952), so it marks here instead.
DESKTOP_QUESTION_TOOL = "mcp__ccd_turn__wrap_up"


def waits_on_founder(message):
    first = message.strip().splitlines()[0].strip() if message.strip() else ""
    m = _WAITING_STATUS_LINE.fullmatch(first)
    return bool(m) and bool(m.group("label").strip()) \
        and not m.group("label").strip().startswith(_NOT_A_LABEL)


def wait_decision(payload):
    """"set", "clear" or None (leave the card alone) for one hook event."""
    name = payload.get("hook_event_name")
    if name == "Stop":
        message = payload.get("last_assistant_message")
        if not isinstance(message, str) or not message.strip():
            return None
        # The Stop gate's second stop ends on its bare `Pushed.` line; the
        # first stop already decided. Any other second stop (a Codex hook
        # block, then `WAITING ON tests`) is a real new ending and decides.
        if payload.get("stop_hook_active") and message.strip() == "Pushed.":
            return None
        return "set" if waits_on_founder(message) else "clear"
    if name == "UserPromptSubmit":
        prompt = payload.get("prompt")
        if isinstance(prompt, str) and _NOT_HIS_REPLY.match(prompt):
            return None
        return "clear"
    tool = payload.get("tool_name")
    if name == "PreToolUse" and tool == "AskUserQuestion":
        return "set"
    if name == "PostToolUse" and tool == "AskUserQuestion":
        return "clear"
    if name == "PostToolUse" and tool == DESKTOP_QUESTION_TOOL:
        tool_input = payload.get("tool_input")
        if isinstance(tool_input, dict) and tool_input.get("blocked") is True:
            return "set"
    return None


def cmd_wait_mark(args):
    """Hook: record whether the HOLDER is waiting on the founder.

    Runs on many events of every session, so it is cheap, silent and never
    fails a session. Non-holders and a free lock change nothing. It takes no
    mutex: the card is replaced atomically (`Store.write`), so reading it
    unlocked sees a whole card, and each event is one create-only file. Stated limit: a reply landing in the milliseconds
    between a peer's read of an expired wait and its takeover loses to the
    takeover; the wait had already run its full ten minutes.
    """
    # Stamp the event when the hook starts, so a slow "set" sorts before a
    # later reply however late it lands.
    event_time = time.time()
    try:
        if not os.path.exists(os.path.join(LOCK_DIR, "holder.json")):
            return EXIT_OK
        payload = args.hook_payload
        if payload is None:
            payload = json.loads(sys.stdin.read(1_048_576) or "null")
        if not isinstance(payload, dict):
            return EXIT_OK
        decision = wait_decision(payload)
        if decision is None:
            return EXIT_OK
        me = find_session(args.native_session_id)
        if me is None:
            return EXIT_OK
        with open(os.path.join(LOCK_DIR, "holder.json")) as f:
            card = json.load(f)
        if not isinstance(card, dict) or not same_session(card, me):
            return EXIT_OK
        if decision == "set":
            start_wait(card, event_time)
        else:
            end_wait(card, event_time)
    except Exception:
        pass
    return EXIT_OK


def default_worktree():
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else os.getcwd()


def main(argv, native_session_id=None, hook_payload=None):
    parser = argparse.ArgumentParser(prog="dev-app-lock.py")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("check")
    claim = sub.add_parser("claim")
    claim.add_argument("--label", default="")
    claim.add_argument("--worktree", default=None)
    release = sub.add_parser("release")
    release.add_argument("--nonce", default=None)
    remind = sub.add_parser("remind")
    remind.add_argument("--event", default="PostToolUse")
    sub.add_parser("wait-mark")
    args = parser.parse_args(argv)
    args.native_session_id = native_session_id
    args.hook_payload = hook_payload
    try:
        if args.command == "claim" and args.worktree is None:
            args.worktree = default_worktree()
        return {"status": cmd_status, "claim": cmd_claim, "release": cmd_release,
                "remind": cmd_remind, "check": cmd_check,
                "wait-mark": cmd_wait_mark}[args.command](args)
    except (Undecided, OSError, KeyError, TypeError, ValueError,
            OverflowError, RecursionError) as e:
        # OSError: the lock folder cannot be made or opened (a Codex sandbox
        # that blocks writes outside the worktree lands here). KeyError and
        # TypeError: a card of the right version with missing or wrong fields.
        # ValueError/OverflowError: a ps line or timestamp that does not parse.
        # All of them are "could not decide", never a traceback a caller
        # might read as a different exit code.
        print(f"dev-app-lock: cannot decide, treating the app as busy: "
              f"{type(e).__name__}: {e}", file=sys.stderr)
        return EXIT_UNDECIDED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
