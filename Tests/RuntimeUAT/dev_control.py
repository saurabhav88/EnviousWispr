#!/usr/bin/env python3
"""Client and CLI for the #3765 dev control door in a RUNNING dev build.

The app side is `Sources/EnviousWisprAppKit/App/Debug/DevControl/DevControlDoor.swift`
(DEBUG builds only). It listens on `/tmp/ew-dev-control-<uid>/<pid>.sock` and answers one
newline-delimited JSON object per request:

    request  {"id": "<client id>", "cmd": "ping", "args": {...}}
    reply    {"id", "ok": true, "result": {...}} or {"id", "ok": false, "error": {...}}
             plus always "pid", "launch", "executable", "door"

Socket commands use the standard library only. `file transcribe` alone loads the PyObjC
import client (`import_door.py`), and only when that command runs.

CLI, from a worktree whose dev build is running:

    python3 Tests/RuntimeUAT/dev_control.py status
    python3 Tests/RuntimeUAT/dev_control.py settings set fillerRemovalEnabled false
    python3 Tests/RuntimeUAT/dev_control.py words add fooFlux --alias "foo flux"
    python3 Tests/RuntimeUAT/dev_control.py models download whisper
    <secret source> | python3 Tests/RuntimeUAT/dev_control.py keys set openai
    R=$(python3 Tests/RuntimeUAT/dev_control.py dictation start --front-app com.apple.TextEdit)
    python3 Tests/RuntimeUAT/dev_control.py dictation stop --receipt "$R"
    python3 Tests/RuntimeUAT/dev_control.py dictation wait --receipt "$R"
    python3 Tests/RuntimeUAT/dev_control.py --self-test

Stdout carries exactly one JSON document per run; diagnostics go to stderr. Exit status:
0 success, 1 door or operation failure, 2 instance, identity, usage or undecidable lock
ownership, 3 the caller does not hold the shared dev-app lock.
"""

import argparse
import contextlib
import importlib.util
import json
import math
import os
import socket
import subprocess
import sys
import threading
import time
import uuid

PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 1 << 20

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2
EXIT_NOT_OWNER = 3

DEV_EXECUTABLE_SUFFIX = "/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"


class DoorError(Exception):
    """The door could not be reached or answered with something that is not a reply."""


class IdentityError(DoorError):
    """A reply came from a door other than the one this client expects."""


def socket_path(pid, uid=None):
    uid = os.geteuid() if uid is None else uid
    return f"/tmp/ew-dev-control-{uid}/{int(pid)}.sock"


def _read_frame(sock, buffer):
    """One reply frame (newline excluded) and the bytes after it, which belong to later
    replies. Socket failures and oversize frames raise DoorError."""
    while b"\n" not in buffer:
        if len(buffer) > MAX_FRAME_BYTES:
            raise DoorError("reply over frame limit")
        try:
            chunk = sock.recv(65536)
        except OSError as error:  # includes socket.timeout
            raise DoorError(f"receive failed: {error}") from error
        if not chunk:
            raise DoorError("door closed the connection before replying")
        buffer += chunk
    frame, _, rest = buffer.partition(b"\n")
    if len(frame) > MAX_FRAME_BYTES:
        raise DoorError("reply over frame limit")
    return frame, rest


def _git_env():
    """The environment for git discovery, without inherited `GIT_*` overrides: `GIT_DIR`
    beats `git -C`, so a leftover one would point discovery at another repository."""
    return {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def _git_path(cwd, *args):
    """One absolute path git prints for `args` run in `cwd`, resolved; None when git cannot
    run, fails, or prints something that is not one absolute path."""
    try:
        out = subprocess.run(["git", "-C", cwd, *args], capture_output=True, env=_git_env())
    except OSError:
        return None
    if out.returncode != 0 or not out.stdout.endswith(b"\n"):
        return None
    value = os.fsdecode(out.stdout[:-1])
    return os.path.realpath(value) if os.path.isabs(value) else None


def _main_worktree(here):
    """The first entry of `git worktree list` (the main checkout), parsed NUL-delimited so
    any path survives; None for a bare main or any failure."""
    try:
        out = subprocess.run(["git", "-C", here, "worktree", "list", "--porcelain", "-z"],
                             capture_output=True, env=_git_env())
    except OSError:
        return None
    if out.returncode != 0:
        return None
    first = out.stdout.split(b"\0\0", 1)[0].split(b"\0")
    if not first or not first[0].startswith(b"worktree ") or b"bare" in first:
        return None
    return os.path.realpath(os.fsdecode(first[0][len(b"worktree "):]))


def lock_owner_path(here=None):
    """The machine-wide dev-app lock owner in the MAIN checkout of the repository holding
    `here` (default: this file's folder). Every worktree shares the main checkout's git
    directory, and older worktree copies of the owner may lack the current policy. Returns
    None, so the caller refuses, unless git confirms the main checkout is a real checkout
    that owns that shared git directory."""
    here = os.path.dirname(os.path.realpath(__file__)) if here is None else here
    common = _git_path(here, "rev-parse", "--path-format=absolute", "--git-common-dir")
    current = _git_path(here, "rev-parse", "--show-toplevel")
    current_git = _git_path(here, "rev-parse", "--absolute-git-dir")
    main = _main_worktree(here)
    if None in (common, current, current_git, main):
        return None
    if _git_path(main, "rev-parse", "--show-toplevel") != main:
        return None
    if _git_path(main, "rev-parse", "--absolute-git-dir") != common:
        return None
    if current_git == common and current != main:
        return None
    return os.path.join(main, "scripts", "lib", "dev-app-lock.py")


def _reject_constant(name):
    raise ValueError(f"{name} is not JSON")


def decode_reply(frame):
    """A reply frame to a dict; anything that is not a UTF-8 JSON object raises DoorError."""
    try:
        reply = json.loads(frame.decode("utf-8"), parse_constant=_reject_constant)
        # An exponent that overflows (1e400) decodes to infinity without passing through
        # parse_constant; refusing to re-encode it catches that too.
        json.dumps(reply, allow_nan=False)
    except (UnicodeDecodeError, ValueError) as error:
        raise DoorError(f"reply is not JSON: {error}") from error
    if not isinstance(reply, dict):
        raise DoorError("reply is not a JSON object")
    if reply.get("door") != PROTOCOL_VERSION:
        raise IdentityError(f"unsupported door version {reply.get('door')!r}")
    return reply


class Connection:
    """One connection to one door; requests are answered in order."""

    def __init__(self, pid, timeout=10.0):
        self.pid = int(pid)
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.settimeout(timeout)
        try:
            self._sock.connect(socket_path(self.pid))
        except OSError as error:
            self._sock.close()
            raise DoorError(f"cannot connect to door for pid {self.pid}: {error}") from error
        self._buffer = b""

    def send_raw(self, data):
        """Send bytes as-is (tests of the door's framing)."""
        try:
            self._sock.sendall(data)
        except OSError as error:
            raise DoorError(f"send failed: {error}") from error

    def finish_sending(self):
        """Half-close: the door sees EOF but can still reply."""
        try:
            self._sock.shutdown(socket.SHUT_WR)
        except OSError as error:
            raise DoorError(f"shutdown failed: {error}") from error

    def read_reply(self):
        frame, self._buffer = _read_frame(self._sock, self._buffer)
        reply = decode_reply(frame)
        if reply.get("pid") != self.pid:
            raise IdentityError(f"reply names pid {reply.get('pid')!r}, expected {self.pid}")
        return reply

    def request(self, cmd, args=None, request_id=None):
        request_id = request_id or str(uuid.uuid4())
        body = {"id": request_id, "cmd": cmd}
        if args is not None:
            body["args"] = args
        try:
            payload = json.dumps(body, allow_nan=False).encode("utf-8")
        except (TypeError, ValueError, UnicodeError) as error:
            raise DoorError("request is not encodable JSON") from error
        self.send_raw(payload + b"\n")
        reply = self.read_reply()
        if reply.get("id") != request_id:
            raise DoorError("reply id does not match the request")
        return reply

    def set_timeout(self, seconds):
        self._sock.settimeout(seconds)

    def close(self):
        self._sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def request(pid, cmd, args=None, timeout=10.0):
    """Send one request on a fresh connection and return the reply object."""
    with Connection(pid, timeout=timeout) as connection:
        return connection.request(cmd, args)


def ping(pid, timeout=10.0):
    return request(pid, "ping", timeout=timeout)


# MARK: - CLI


class CliError(Exception):
    """A refusal the CLI reports as `{"ok": false, "error": {...}}` with an exit status."""

    def __init__(self, code, message, exit_status, **details):
        super().__init__(message)
        self.code = code
        self.message = message
        self.exit_status = exit_status
        self.details = details

    def document(self):
        error = {"code": self.code, "message": self.message}
        error.update(self.details)
        return {"ok": False, "error": error}


class _ParserExit(Exception):
    def __init__(self, status):
        super().__init__(status)
        self.status = status


class _Parser(argparse.ArgumentParser):
    """Help and usage go to stderr; a usage error becomes a JSON refusal with exit 2."""

    def print_help(self, file=None):
        super().print_help(sys.stderr)

    def print_usage(self, file=None):
        super().print_usage(sys.stderr)

    def exit(self, status=0, message=None):
        if message:
            sys.stderr.write(message)
        raise _ParserExit(status)

    def error(self, message):
        self.print_usage()
        raise CliError("usage", message, EXIT_USAGE)


HELP_EPILOG = """\
settings set VALUE is JSON: true, false, 3, 0.5, null, ["a"], {"mode": "auto"} keep their
types; a string needs JSON quotes ('"parakeet"') or --string (--string parakeet).
Writes persist in the shared preferences every dev and production build reads. --force
skips the screens' checks, not the owner's consequences (a provider change still resets its
model). A successful write does not say when an in-flight dictation adopts the value.
keys set PROVIDER reads the key from stdin only (never an argument) and replies with
presence, never the key; one trailing newline is the line end, not part of the key.
keys clear PROVIDER removes it. A refused store reads storeFailed: the key is unknown.
An AI Polish screen already open keeps showing the key it loaded; reopen it to see a key
set or cleared here.
channel set DEVICE_UID N picks a connected multi-input microphone's input (0 is Input 1);
a whole inputChannelByDeviceUID write is refused toward it, --force stages one.
shortcut set ROLE KEYCODE MODIFIERS saves a Keybinds shortcut whole, checked as the screen
checks it (ROLE: record, cancel, quickAdd, pasteLast, copyLast; recording is stored as
toggleKeyCode/toggleModifiers; MODIFIERS is the modifier-flags integer, 0 for none). A lone
modifier key stores no modifiers. settings set on one half checks the pair it makes.
language set CODE is the language picker's choice: lock and English spelling together
(en-gb locks "en" with British spelling); auto unlocks. settings set languageMode or
englishSpelling alone is refused toward it; --force stages one field.
models download/cancel press the Settings row's own button and return that engine's
state the instant after; poll status for progress. A reply is never a finished download.
dictation start records on the ACTIVE engine and prints a receipt; --receipt takes that
receipt object or the whole document start printed. --front-app brings that app forward
first (best effort: leave the field you want the text in focused); if the app loses the
front after the take starts, the take is cancelled and the error still carries its receipt.
dictation wait polls that receipt every 250 ms and returns its own result and, when it
saved one, that exact History row; a timeout stops watching, never the take. If a start,
stop or cancel reply is lost, its outcome is unknown: read the receipt before retrying.
meeting start asks the same Start the menu and page use; --call-sound/--no-call-sound set
this request only, never the saved setting. waitingForExplainer means the page shows the
call-sound explainer: a person answers it. meeting get returns stored turns (echo flagged)
and the visible projection; --include-text adds the stored text up to 256 KB.
meeting notes-set types and saves a meeting's notes (--text) as the Notes tab does;
notes-get reads them back. summary-write is the Summary tab's Write summary / Write again
(--replace confirms replacing an edited summary); it returns at the start, so poll
summary-get. meeting live prints the recording meeting's live words (memory only);
meeting live-words-status prints the live words engine and language a meeting would use
now, without saving a guess. meeting start --live-engine apple|universal forces that engine
for one meeting.
call simulate fakes call apps holding the microphone (--holders JSON list of {bundleID,
input, evidence, url?, pid?}); the rules, the panel and every Start run as in production.
--clear returns to the real microphone; --press presses a button the call panel shows;
with no option it reads the panel.
Changes need the shared dev-app lock (dev-app-lock.py claim) unless run by hand.
"""


# The CLI's model names are the door's command segments (models.<backend>.<action>).
MODEL_BACKENDS = ("parakeet", "whisper")
# ShortcutRole raw values; the door refuses anything else.
SHORTCUT_ROLES = ("record", "cancel", "quickAdd", "pasteLast", "copyLast")
MODEL_ACTIONS = ("download", "cancel")
# The call panel's buttons `call simulate --press` may name (DevControlCalls.buttons).
CALL_PANEL_BUTTONS = ("yes", "no", "keepRecording", "startNewRecording", "openSettings", "close")
# MeetingEngineChoice raw values (#3973 C2); the door refuses anything else.
MEETING_ENGINES = ("parakeet", "whisper")
# MeetingEntryPoint raw values; the door refuses anything else.
MEETING_ENTRY_POINTS = ("history", "menu")
# CLI verb -> door command for the meeting commands that take only a meeting id; all change
# the app.
MEETING_ID_ACTIONS = {"stop": "meeting.stop", "retry": "meeting.retry",
                      "delete-audio": "meeting.deleteAudio", "delete": "meeting.delete"}


def build_parser():
    parser = _Parser(
        prog="dev_control.py", description="Drive a running EnviousWispr dev build.",
        epilog=HELP_EPILOG, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true", help="run the CLI's own checks")
    parser.add_argument(
        "--worktree", help="the checkout whose dev build to drive (default: git toplevel of cwd)")
    sub = parser.add_subparsers(dest="group", metavar="COMMAND")

    sub.add_parser("ping", help="check the door answers")
    sub.add_parser("status", help="engine, model, import and saved-key state")

    settings = sub.add_parser("settings", help="read or write a setting").add_subparsers(
        dest="action", required=True, metavar="ACTION")
    settings.add_parser("list")
    get = settings.add_parser("get")
    get.add_argument("key")
    set_ = settings.add_parser("set")
    set_.add_argument("key")
    set_.add_argument("value", help="JSON value (see below), or a string with --string")
    set_.add_argument("--string", action="store_true", help="send VALUE as a plain string")
    set_.add_argument("--force", action="store_true", help="skip the screens' checks")

    words = sub.add_parser("words", help="edit Your Words").add_subparsers(
        dest="action", required=True, metavar="ACTION")
    words.add_parser("list")
    add = words.add_parser("add")
    add.add_argument("word")
    add.add_argument("--alias", action="append", default=None, help="repeat for several")
    update = words.add_parser("update")
    update.add_argument("id")
    update.add_argument("--word")
    update.add_argument("--alias", action="append", default=None, help="replaces all aliases")
    update.add_argument("--clear-aliases", action="store_true")
    remove = words.add_parser("remove")
    remove.add_argument("id")

    history = sub.add_parser("history", help="read History").add_subparsers(
        dest="action", required=True, metavar="ACTION")
    history_list = history.add_parser("list")
    history_list.add_argument("--limit", type=int)
    history_get = history.add_parser("get")
    history_get.add_argument("id")

    models = sub.add_parser("models", help="download or cancel a speech model").add_subparsers(
        dest="action", required=True, metavar="ACTION")
    for verb in MODEL_ACTIONS:
        models.add_parser(verb).add_argument("backend", choices=MODEL_BACKENDS)

    keys = sub.add_parser("keys", help="save or clear a cloud polish API key").add_subparsers(
        dest="action", required=True, metavar="ACTION")
    for verb in ("set", "clear"):
        keys.add_parser(verb).add_argument("provider", choices=sorted(KEY_PROVIDERS))

    channel = sub.add_parser("channel", help="a microphone's input socket").add_subparsers(
        dest="action", required=True, metavar="ACTION")
    channel_set = channel.add_parser("set")
    channel_set.add_argument("device_uid", metavar="DEVICE_UID")
    channel_set.add_argument("channel", type=int, help="zero-based input (0 is Input 1)")

    shortcut = sub.add_parser("shortcut", help="a Keybinds shortcut").add_subparsers(
        dest="action", required=True, metavar="ACTION")
    shortcut_set = shortcut.add_parser("set")
    shortcut_set.add_argument("role", choices=SHORTCUT_ROLES)
    shortcut_set.add_argument("key_code", metavar="KEYCODE", type=int)
    shortcut_set.add_argument("modifiers", metavar="MODIFIERS", type=int,
                              help="modifier-flags integer, 0 for none")

    language = sub.add_parser("language", help="the dictation language").add_subparsers(
        dest="action", required=True, metavar="ACTION")
    language.add_parser("set").add_argument(
        "code", help="a picker row code (de, en, en-gb, ...) or auto")

    dictation = sub.add_parser("dictation", help="start, stop or follow one take").add_subparsers(
        dest="action", required=True, metavar="ACTION")
    start = dictation.add_parser("start")
    start.add_argument("--front-app", metavar="BUNDLE_ID")
    for verb in ("stop", "receipt", "wait"):
        sub_ = dictation.add_parser(verb)
        sub_.add_argument("--receipt", required=True, metavar="JSON")
        if verb == "wait":
            sub_.add_argument("--timeout", type=float, default=120.0)
    dictation.add_parser("cancel")

    meeting = sub.add_parser("meeting", help="EnviousMeet: start, stop, read").add_subparsers(
        dest="action", required=True, metavar="ACTION")
    meeting_start = meeting.add_parser("start")
    meeting_start.add_argument("--entry-point", choices=MEETING_ENTRY_POINTS, default="menu")
    call_sound = meeting_start.add_mutually_exclusive_group()
    call_sound.add_argument("--call-sound", dest="call_sound", action="store_const", const=True)
    call_sound.add_argument("--no-call-sound", dest="call_sound", action="store_const",
                            const=False)
    meeting_start.add_argument("--live-engine", choices=["auto", "apple", "universal"])
    meeting.add_parser("status")
    meeting.add_parser("list").add_argument("--limit", type=int)
    meeting_get = meeting.add_parser("get")
    meeting_get.add_argument("id")
    meeting_get.add_argument("--turn-offset", type=int)
    meeting_get.add_argument("--turn-limit", type=int)
    meeting_get.add_argument("--include-text", action="store_true")
    for verb in MEETING_ID_ACTIONS:
        parser_ = meeting.add_parser(verb)
        parser_.add_argument("id")
        if verb == "retry":
            # #3973 C2: Transcribe again on this meeting engine (the door's default: parakeet).
            parser_.add_argument("--engine", choices=MEETING_ENGINES)
    meeting.add_parser("notes-get").add_argument("id")
    notes_set = meeting.add_parser("notes-set")
    notes_set.add_argument("id")
    notes_set.add_argument("--text", required=True)
    meeting.add_parser("summary-get").add_argument("id")
    summary_write = meeting.add_parser("summary-write")
    summary_write.add_argument("id")
    summary_write.add_argument("--replace", action="store_true")
    meeting.add_parser("live")
    meeting.add_parser("live-words-status")

    call = sub.add_parser("call", help="EnviousMeet call detection (simulated)").add_subparsers(
        dest="action", required=True, metavar="ACTION")
    simulate = call.add_parser("simulate").add_mutually_exclusive_group()
    simulate.add_argument("--holders")
    simulate.add_argument("--clear", action="store_true")
    simulate.add_argument("--press", choices=CALL_PANEL_BUTTONS)

    file_ = sub.add_parser("file", help="Transcribe a File").add_subparsers(
        dest="action", required=True, metavar="ACTION")
    transcribe = file_.add_parser("transcribe")
    transcribe.add_argument("path")
    transcribe.add_argument("--timeout", type=float, default=900.0)
    return parser


def _setting_value(args):
    if args.string:
        return args.value
    try:
        value = json.loads(args.value, parse_constant=_reject_constant)
        json.dumps(value, allow_nan=False)  # an overflowing exponent (1e400) is infinity
        return value
    except ValueError as error:
        raise CliError(
            "usage", f"VALUE is not JSON ({error}); quote a string as '\"text\"' or use --string",
            EXIT_USAGE) from error


def route(args):
    """(door command, wire args, is mutation) for a socket command, or None for
    `file transcribe`. The only place a CLI command becomes a door request."""
    key = (args.group, getattr(args, "action", None))
    if key == ("ping", None):
        return "ping", None, False
    if key == ("status", None):
        return "status", None, False
    if key == ("settings", "list"):
        return "settings.list", None, False
    if key == ("settings", "get"):
        return "settings.get", {"key": args.key}, False
    if key == ("settings", "set"):
        wire = {"key": args.key, "value": _setting_value(args)}
        if args.force:
            wire["force"] = True
        return "settings.set", wire, True
    if key == ("words", "list"):
        return "words.list", None, False
    if key == ("words", "add"):
        wire = {"word": args.word}
        if args.alias is not None:
            wire["aliases"] = args.alias
        return "words.add", wire, True
    if key == ("words", "update"):
        if args.alias is not None and args.clear_aliases:
            raise CliError("usage", "--alias and --clear-aliases cannot be combined", EXIT_USAGE)
        wire = {"id": args.id}
        if args.word is not None:
            wire["word"] = args.word
        if args.alias is not None:
            wire["aliases"] = args.alias
        elif args.clear_aliases:
            wire["aliases"] = []
        return "words.update", wire, True
    if key == ("words", "remove"):
        return "words.remove", {"id": args.id}, True
    if args.group == "models" and args.action in MODEL_ACTIONS:
        if args.backend not in MODEL_BACKENDS:
            raise CliError("usage", f"unknown model {args.backend!r}", EXIT_USAGE)
        return f"models.{args.backend}.{args.action}", None, True
    if key == ("keys", "set"):
        # The value is added by `run` from stdin, never from argv.
        return "keys.set", {"provider": KEY_PROVIDERS[args.provider]}, True
    if key == ("keys", "clear"):
        return "keys.clear", {"provider": KEY_PROVIDERS[args.provider]}, True
    if key == ("channel", "set"):
        return "channel.set", {"deviceUID": args.device_uid, "channel": args.channel}, True
    if key == ("shortcut", "set"):
        return "shortcut.set", {"role": args.role, "keyCode": args.key_code,
                                "modifiers": args.modifiers}, True
    if key == ("language", "set"):
        return "language.set", {"code": args.code}, True
    if key == ("dictation", "start"):
        wire = {} if args.front_app is None else {"frontApp": args.front_app}
        return "dictation.start", wire, True
    if key == ("dictation", "stop"):
        return "dictation.stop", {"receipt": receipt_argument(args.receipt)}, True
    if key == ("dictation", "cancel"):
        return "dictation.cancel", None, True
    if key == ("dictation", "receipt"):
        return "dictation.receipt", {"receipt": receipt_argument(args.receipt)}, False
    if key == ("dictation", "wait"):
        # Many requests on one session, not one route: `run` handles it before routing.
        raise CliError("usage", "dictation wait is not a single door request", EXIT_USAGE)
    if key == ("meeting", "start"):
        wire = {"entryPoint": args.entry_point}
        if args.call_sound is not None:
            wire["callSound"] = args.call_sound
        if args.live_engine is not None:
            wire["liveEngine"] = args.live_engine
        return "meeting.start", wire, True
    if key == ("meeting", "status"):
        return "meeting.status", None, False
    if key == ("meeting", "list"):
        return "meeting.list", ({} if args.limit is None else {"limit": args.limit}), False
    if key == ("meeting", "get"):
        wire = {"meetingID": args.id}
        if args.turn_offset is not None:
            wire["turnOffset"] = args.turn_offset
        if args.turn_limit is not None:
            wire["turnLimit"] = args.turn_limit
        if args.include_text:
            wire["includeText"] = True
        return "meeting.get", wire, False
    if key == ("meeting", "notes-get"):
        return "meeting.notes.get", {"meetingID": args.id}, False
    if key == ("meeting", "notes-set"):
        return "meeting.notes.set", {"meetingID": args.id, "notes": args.text}, True
    if key == ("meeting", "summary-get"):
        return "meeting.summary.get", {"meetingID": args.id}, False
    if key == ("meeting", "summary-write"):
        wire = {"meetingID": args.id}
        if args.replace:
            wire["replace"] = True
        return "meeting.summary.write", wire, True
    if key == ("meeting", "live"):
        return "meeting.live", {}, False
    if key == ("meeting", "live-words-status"):
        return "meeting.liveWordsStatus", {}, False
    if key == ("call", "simulate"):
        if args.clear:
            return "call.simulate", {"clear": True}, True
        if args.press is not None:
            return "call.simulate", {"press": args.press}, True
        if args.holders is not None:
            try:
                holders = json.loads(args.holders, parse_constant=_reject_constant)
            except ValueError:
                raise CliError("usage", "--holders must be a JSON list", EXIT_USAGE) from None
            if not isinstance(holders, list):
                raise CliError("usage", "--holders must be a JSON list", EXIT_USAGE)
            return "call.simulate", {"holders": holders}, True
        return "call.simulate", {}, False
    if args.group == "meeting" and args.action in MEETING_ID_ACTIONS:
        wire = {"meetingID": args.id}
        if getattr(args, "engine", None):
            wire["engine"] = args.engine
        return MEETING_ID_ACTIONS[args.action], wire, True
    if key == ("history", "list"):
        return "history.list", ({} if args.limit is None else {"limit": args.limit}), False
    if key == ("history", "get"):
        return "history.get", {"id": args.id}, False
    if key == ("file", "transcribe"):
        # The import client's deadline is `time.time() + timeout`; NaN or infinity would
        # make it wait forever.
        if not math.isfinite(args.timeout) or args.timeout <= 0:
            raise CliError("usage", "--timeout must be positive and finite", EXIT_USAGE)
        return None
    raise CliError("usage", "no command given", EXIT_USAGE)


# CLI provider names and the door's LLMProvider raw values.
KEY_PROVIDERS = {"openai": "openAI", "gemini": "gemini", "claude": "claude"}
MAX_KEY_BYTES = 16 * 1024


def read_key(boundaries):
    """The key from stdin, at most MAX_KEY_BYTES of UTF-8. One trailing newline (LF or
    CRLF) is the line end a pipe adds; nothing else is trimmed. Every refusal is a fixed
    sentence, so the key never reaches an error, a log or stdout."""
    raw = boundaries.read_stdin(MAX_KEY_BYTES + 1)
    if len(raw) > MAX_KEY_BYTES:
        raise CliError("usage", f"the key on stdin is over {MAX_KEY_BYTES} bytes", EXIT_USAGE)
    if raw.endswith(b"\r\n"):
        raw = raw[:-2]
    elif raw.endswith(b"\n"):
        raw = raw[:-1]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise CliError("usage", "the key on stdin is not UTF-8", EXIT_USAGE) from None
    if not text:
        raise CliError("usage", "no key on stdin", EXIT_USAGE)
    return text


RECEIPT_FIELDS = ("launch", "backend", "take")
WAIT_POLL_SECONDS = 0.25


def receipt_argument(text):
    """The receipt object from --receipt: the object itself, or the whole document a
    `dictation start` printed (its result, or its error for frontAppLost). Passed to the
    door unchanged; anything else is a usage error before the app is contacted."""
    try:
        value = json.loads(text, parse_constant=_reject_constant)
    except ValueError as error:
        raise CliError("usage", f"--receipt is not JSON ({error})", EXIT_USAGE) from error
    if isinstance(value, dict) and "receipt" not in value and set(value) != set(RECEIPT_FIELDS):
        for holder in (value.get("result"), value.get("error")):
            if isinstance(holder, dict) and "receipt" in holder:
                value = holder
                break
    if isinstance(value, dict) and "receipt" in value:
        value = value["receipt"]
    if (not isinstance(value, dict) or set(value) != set(RECEIPT_FIELDS)
            or not all(isinstance(value[k], str) for k in RECEIPT_FIELDS)):
        raise CliError("usage", "--receipt must be the receipt dictation start printed",
                       EXIT_USAGE)
    return value


def wait_arguments(args):
    """(receipt, timeout) for `dictation wait`, refused before the app is contacted."""
    receipt = receipt_argument(args.receipt)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        raise CliError("usage", "--timeout must be positive and finite", EXIT_USAGE)
    return receipt, args.timeout


class Boundaries:
    """Everything the CLI reads from outside itself. `main` uses these real ones; the
    self-test hands `run` fakes for the process table, git, the lock owner, the socket and
    the import client, and runs everything else as shipped."""

    def instances(self):
        from instance_guard import running_enviouswispr_instances
        return running_enviouswispr_instances()

    def git_toplevel(self, cwd):
        return _git_path(cwd, "rev-parse", "--show-toplevel")

    def load_lock_owner(self):
        path = lock_owner_path()
        if path is None or not os.path.isfile(path):
            raise ImportError(f"cannot find the main checkout's lock owner ({path})")
        spec = importlib.util.spec_from_file_location("ew_dev_app_lock", path)
        if spec is None or spec.loader is None:
            raise ImportError(f"cannot load {path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def connect(self, pid, timeout):
        return Connection(pid, timeout=timeout)

    def has_pyobjc(self):
        return all(importlib.util.find_spec(name) is not None for name in ("objc", "Foundation"))

    def is_main_thread(self):
        return threading.current_thread() is threading.main_thread()

    def load_import_backend(self):
        from import_door import transcribe_file_backend
        return transcribe_file_backend

    def read_stdin(self, limit):
        return sys.stdin.buffer.read(limit)

    def monotonic(self):
        return time.monotonic()

    def sleep(self, seconds):
        time.sleep(seconds)


def resolve_worktree(requested, boundaries):
    """The worktree as a real path, so a symlinked checkout and the executable path the
    process table reports compare on the same terms."""
    if requested is None:
        top = boundaries.git_toplevel(os.getcwd())
        if top is None:
            raise CliError("worktreeUnresolved",
                           "the current directory is not inside a git checkout; pass --worktree",
                           EXIT_USAGE)
        requested = top
    root = os.path.realpath(os.path.expanduser(requested))
    if not os.path.isdir(root):
        raise CliError("worktreeUnresolved", f"not a directory: {root}", EXIT_USAGE)
    return root


def _is_under(root, path):
    """True when `path` is `root` or inside it, by path components (`/x/wt` does not
    contain `/x/wt-2`)."""
    try:
        return os.path.commonpath([root, path]) == root
    except ValueError:
        return False


def resolve_instance(root, boundaries):
    """The one running app built under `root`, as (pid, executable). Refuses rather than
    picks: zero or several matches list every running instance. Release hosts count as
    candidates (they carry the production bundle id) but have no door, so a lone one is
    refused too."""
    instances = boundaries.instances()
    listed = [{"pid": int(pid), "executable": exe} for pid, exe in sorted(instances.items())]
    mine = [(int(pid), exe) for pid, exe in instances.items()
            if _is_under(root, os.path.realpath(exe))]
    if len(mine) != 1:
        raise CliError(
            "instanceAmbiguous" if mine else "noInstance",
            f"need exactly one running EnviousWispr built under {root}; found {len(mine)}",
            EXIT_USAGE, candidates=listed)
    pid, exe = mine[0]
    if not exe.endswith(DEV_EXECUTABLE_SUFFIX):
        raise CliError("notDevBuild", f"pid {pid} runs {exe}, which is not a dev build",
                       EXIT_USAGE, candidates=listed)
    return pid, exe


def require_mutation_ownership(boundaries):
    """Ask the lock owner whether this caller may change the shared dev app. Its stdout
    goes to our stderr. Only a positively identified founder shell (no agent ancestor)
    skips the check; an agent needs `check` to say the hold is its own."""
    with contextlib.redirect_stdout(sys.stderr):
        try:
            lock = boundaries.load_lock_owner()
        except Exception as error:
            raise CliError("lockUndecided", f"cannot load the lock owner: {error}",
                           EXIT_USAGE) from error
        try:
            session = lock.find_session()
        except Exception as error:
            raise CliError("lockUndecided", f"cannot tell who is calling: {error}",
                           EXIT_USAGE) from error
        if session is None:
            return "founder"
        try:
            status = lock.main(["check"])
        except SystemExit as error:
            raise CliError(
                "lockUndecided",
                "the lock entrypoint exited without returning an ownership decision",
                EXIT_USAGE) from error
        except Exception as error:
            raise CliError("lockUndecided", f"lock check failed: {error}", EXIT_USAGE) from error
    if status == 0:
        return "owned"
    if status == 3:
        raise CliError("lockNotHeld",
                       "this session does not hold the shared dev app; claim it first",
                       EXIT_NOT_OWNER)
    raise CliError("lockUndecided", f"the lock owner could not decide (exit {status})",
                   EXIT_USAGE)


def _valid_uuid(value):
    if not isinstance(value, str):
        return False
    try:
        uuid.UUID(value)
    except ValueError:
        return False
    return True


def _check_envelope(reply):
    ok = reply.get("ok")
    if ok is True:
        if not isinstance(reply.get("result"), dict):
            raise DoorError("reply has ok true but no result object")
    elif ok is False:
        error = reply.get("error")
        if not isinstance(error, dict) or not isinstance(error.get("code"), str):
            raise DoorError("reply has ok false but no error code")
    else:
        raise DoorError("reply has no boolean ok")


class Session:
    """One connection pinned to the door that answered its first ping. Every later reply
    must name the same pid, launch and executable; nothing reconnects or retries."""

    def __init__(self, connection, pid, executable):
        self.connection = connection
        self.pid = pid
        self.executable = executable
        self.launch = None

    def establish(self):
        reply = self.connection.request("ping")
        _check_envelope(reply)
        if reply.get("ok") is not True or reply["result"].get("pong") is not True:
            raise DoorError("ping was not answered with pong")
        if reply.get("executable") != self.executable:
            raise IdentityError(
                f"door runs {reply.get('executable')!r}, expected {self.executable!r}")
        if not _valid_uuid(reply.get("launch")):
            raise IdentityError("door reply has no valid launch id")
        self.launch = reply["launch"]
        return reply

    def call(self, cmd, args, timeout=None):
        if timeout is not None:
            self.connection.set_timeout(timeout)
        reply = self.connection.request(cmd, args)
        _check_envelope(reply)
        if reply.get("launch") != self.launch or reply.get("executable") != self.executable:
            raise IdentityError("a reply came from a different launch of the app")
        return reply


def _open_session(root, boundaries, timeout):
    pid, exe = resolve_instance(root, boundaries)
    try:
        connection = boundaries.connect(pid, timeout)
    except DoorError as error:
        raise CliError("doorUnavailable", str(error), EXIT_USAGE) from error
    session = Session(connection, pid, exe)
    try:
        session.establish()
    except DoorError as error:
        connection.close()
        raise CliError("identityRefused", str(error), EXIT_USAGE) from error
    return session


def _door_call(session, cmd, wire, mutation, timeout=None):
    try:
        reply = session.call(cmd, wire, timeout=timeout)
    except IdentityError as error:
        raise CliError("identityChanged", str(error), EXIT_USAGE,
                       outcome="unknown" if mutation else "none") from error
    except DoorError as error:
        if mutation:
            raise CliError(
                "outcomeUnknown",
                f"{error}; the change may or may not have applied: read the state back "
                "before retrying", EXIT_FAILED) from error
        raise CliError("doorError", str(error), EXIT_FAILED) from error
    if mutation and not reply["ok"] and reply["error"]["code"] == "responseTooLarge":
        # The door dispatched the change and only its reply was too large to send, so
        # the change may have applied. Every other refusal comes before the owner is called.
        raise CliError(
            "outcomeUnknown",
            "the change may have applied, but its reply was over the size limit: read the "
            "state back before retrying", EXIT_FAILED)
    return (EXIT_OK if reply["ok"] else EXIT_FAILED), reply


def _wait(session, receipt, wait_timeout, boundaries, timeout):
    """Poll one receipt until it is terminal or the deadline passes. One validated session
    for the whole wait, so a relaunch is an identity error, never a fresh start. Only that
    receipt ends the wait; its saved row is fetched by its own id."""
    deadline = boundaries.monotonic() + wait_timeout
    polls = 0
    while True:
        remaining = deadline - boundaries.monotonic()
        if remaining <= 0:
            raise CliError(
                "waitTimeout",
                f"the take was still pending after {wait_timeout:g} s; it was not stopped",
                EXIT_FAILED, receipt=receipt, polls=polls)
        status, reply = _door_call(session, "dictation.receipt", {"receipt": receipt}, False,
                                   timeout=min(timeout, remaining))
        polls += 1
        if not reply["ok"]:
            return status, reply
        result = reply["result"]
        if result.get("status") == "terminal":
            break
        if result.get("status") != "pending":
            raise CliError("doorError", f"unexpected receipt status {result.get('status')!r}",
                           EXIT_FAILED)
        boundaries.sleep(min(WAIT_POLL_SECONDS, max(0.0, deadline - boundaries.monotonic())))
    row = None
    saved = result.get("savedRowID")
    if saved is not None:
        remaining = deadline - boundaries.monotonic()
        if remaining <= 0:
            raise CliError(
                "waitTimeout",
                "the take finished, but its History lookup exceeded the wait deadline; "
                "the take was not stopped",
                EXIT_FAILED, receipt=receipt, terminal=result, polls=polls)
        _, fetched = _door_call(session, "history.get", {"id": saved}, False,
                                timeout=min(timeout, remaining))
        if not fetched["ok"]:
            raise CliError(
                fetched["error"]["code"],
                fetched["error"].get("message") or "the History lookup failed",
                EXIT_FAILED, terminal=result)
        row = fetched["result"].get("row")
        if not isinstance(row, dict) or row.get("id") != saved:
            raise CliError("doorError", "history.get returned a different row", EXIT_FAILED)
    return EXIT_OK, {"ok": True, "result": {"terminal": result, "row": row, "polls": polls},
                     "pid": reply.get("pid"), "launch": reply.get("launch"),
                     "executable": reply.get("executable"), "door": reply.get("door")}


def _transcribe(args, root, boundaries, timeout):
    if not boundaries.is_main_thread():
        raise CliError("dependencyUnavailable", "file transcribe must run on the main thread",
                       EXIT_FAILED)
    if not boundaries.has_pyobjc():
        raise CliError(
            "dependencyUnavailable",
            f"{sys.executable} has no PyObjC (objc, Foundation); run with the UAT interpreter",
            EXIT_FAILED)
    # The control door's ping proves this pid is the dev build under `root` before the file
    # goes anywhere. The import client then runs its own discover and executable checks;
    # its launch id belongs to the import protocol and is not compared with this one.
    session = _open_session(root, boundaries, timeout)
    session.connection.close()
    pid = session.pid
    try:
        backend = boundaries.load_import_backend()
    except ImportError as error:
        raise CliError("dependencyUnavailable", f"cannot load the import client: {error}",
                       EXIT_FAILED) from error
    try:
        with contextlib.redirect_stdout(sys.stderr):
            reply = backend(pid, args.path, timeout=args.timeout, worktree=root, echo=False)
    except RuntimeError as error:
        raise CliError("importFailed", str(error), EXIT_FAILED) from error
    finished = isinstance(reply, dict) and reply.get("status") == "finished"
    return (EXIT_OK if finished else EXIT_FAILED), {"ok": finished, "result": reply}


def run(argv, boundaries, timeout=10.0):
    """(exit status, stdout document) for one CLI invocation."""
    try:
        args = build_parser().parse_args(argv)
    except _ParserExit as done:
        return done.status, {"ok": done.status == 0, "result": {"help": "printed to stderr"}}
    except CliError as error:
        if "keys" in argv:
            # argparse names unexpected arguments, and one could be a key typed in argv.
            error.message = "usage error in a keys command; the key goes on stdin, never argv"
        return error.exit_status, error.document()
    if args.self_test:
        from dev_control_self_test import run_self_test
        return run_self_test()
    if args.group is None:
        build_parser().print_usage()
        return EXIT_USAGE, CliError("usage", "no command given", EXIT_USAGE).document()
    try:
        if (args.group, getattr(args, "action", None)) == ("dictation", "wait"):
            receipt, wait_timeout = wait_arguments(args)
            root = resolve_worktree(args.worktree, boundaries)
            session = _open_session(root, boundaries, timeout)
            try:
                return _wait(session, receipt, wait_timeout, boundaries, timeout)
            finally:
                session.connection.close()
        socket_route = route(args)
        mutation = socket_route is None or socket_route[2]
        if socket_route is not None and socket_route[0] == "keys.set":
            socket_route[1]["value"] = read_key(boundaries)
        root = resolve_worktree(args.worktree, boundaries)
        if mutation:
            require_mutation_ownership(boundaries)
        if socket_route is None:
            return _transcribe(args, root, boundaries, timeout)
        cmd, wire, _ = socket_route
        session = _open_session(root, boundaries, timeout)
        try:
            status, reply = _door_call(session, cmd, wire, mutation)
        finally:
            session.connection.close()
        return status, reply
    except CliError as error:
        return error.exit_status, error.document()


# MARK: - In-process client


class DoorRefused(Exception):
    """A CLI call that did not succeed: `code` and `message` come from its JSON document."""

    def __init__(self, code, message, exit_status=EXIT_FAILED, document=None):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.exit_status = exit_status
        self.document = document


class DoorClient:
    """One running dev app, driven through the CLI's own `run` for many calls (#3990).

    Each `run` opens its own session, and a session pins the door only for its own
    requests. A rig makes calls minutes apart (setup, proof, restore), so this pins the
    app ACROSS them: the pid it was made for, and the launch and executable the first
    reply names. A relaunch or another app answering raises `identityChanged`."""

    def __init__(self, pid, boundaries=None, timeout=10.0):
        self.boundaries = boundaries if boundaries is not None else Boundaries()
        self.timeout = timeout
        self.pid = int(pid)
        self.executable = {int(p): exe for p, exe in self.boundaries.instances().items()}.get(
            self.pid)
        if self.executable is None:
            raise DoorRefused("noInstance", f"pid {self.pid} is not a running EnviousWispr",
                              EXIT_USAGE)
        if not self.executable.endswith(DEV_EXECUTABLE_SUFFIX):
            raise DoorRefused("notDevBuild", f"pid {self.pid} runs {self.executable}, which is "
                              "not a dev build", EXIT_USAGE)
        self.worktree = self.boundaries.git_toplevel(os.path.dirname(self.executable))
        if self.worktree is None:
            raise DoorRefused("worktreeUnresolved",
                              f"{self.executable} is not inside a git checkout", EXIT_USAGE)
        self.launch = None

    def call(self, argv):
        """The `result` object of one socket command, routed, owner-checked and dispatched
        exactly as `run` does, except that the session's pid, executable and launch are
        compared with this client's BEFORE the request is sent: a relaunched or different
        app never receives a change. Anything but success raises DoorRefused."""
        try:
            try:
                args = build_parser().parse_args(argv)
            except _ParserExit as done:
                raise CliError("usage", f"parser exited ({done.status})", EXIT_USAGE)
            socket_route = route(args)
            if socket_route is None or socket_route[0] == "keys.set":
                raise CliError("usage", "DoorClient sends plain socket commands only", EXIT_USAGE)
            cmd, wire, mutation = socket_route
            if mutation:
                require_mutation_ownership(self.boundaries)
            session = _open_session(self.worktree, self.boundaries, self.timeout)
            try:
                if session.pid != self.pid or session.executable != self.executable:
                    raise CliError("identityChanged",
                                   f"pid {session.pid} ({session.executable}) answered; "
                                   f"expected pid {self.pid}", EXIT_USAGE)
                if self.launch is None:
                    self.launch = session.launch
                elif session.launch != self.launch:
                    raise CliError("identityChanged", "the app was relaunched since the first "
                                   "call", EXIT_USAGE)
                status, reply = _door_call(session, cmd, wire, mutation)
            finally:
                session.connection.close()
        except CliError as error:
            raise DoorRefused(error.code, error.message, error.exit_status,
                              error.document()) from error
        if status != EXIT_OK:
            error = reply.get("error") or {}
            raise DoorRefused(error.get("code", "failed"), error.get("message", ""), status, reply)
        return reply["result"]

    def follow_relaunch(self):
        """For a RESTORE: re-pin to the same executable after a relaunch. Some drivers restart
        the app on purpose mid-run (`paste_landing_uat.with_warmup_suppressed`,
        `last_dictation_uat.end_take_then_restore`), and the founder's settings must still go
        back. Only the SAME executable (same build, same checkout) is followed; another app is
        still refused. True when it re-pinned."""
        running = {int(p): exe for p, exe in self.boundaries.instances().items()}
        same = [pid for pid, exe in running.items() if exe == self.executable]
        if len(same) != 1:
            raise DoorRefused("identityChanged",
                              f"{len(same)} running apps are {self.executable}; cannot tell "
                              "which one to restore", EXIT_USAGE)
        if same[0] == self.pid:
            # Same pid: a relaunch is not possible without a new pid; `call` still compares
            # the launch.
            return False
        self.pid, self.launch = same[0], None
        return True

    def values(self, *keys):
        """{key: value} for `keys`, all from ONE `settings list` reply (one snapshot)."""
        rows = self.call(["settings", "list"]).get("settings")
        found = {row.get("key"): row.get("value") for row in rows or []
                 if isinstance(row, dict)}
        missing = [key for key in keys if key not in found]
        if missing:
            raise DoorRefused("unknownKey", f"settings list has no {missing}")
        return {key: found[key] for key in keys}

    def set(self, key, value, force=False):
        argv = ["settings", "set", key, json.dumps(value)]
        return self.call(argv + ["--force"] if force else argv)

    def status(self):
        return self.call(["status"])

    def check_owner(self):
        return check_owner(self.boundaries)


def check_owner(boundaries=None):
    """Refuse before a rig changes anything unless this caller may change the shared dev app:
    the decision every door mutation makes (`require_mutation_ownership`), taken BEFORE the
    first system device moves, so a refused caller leaves nothing to restore (#3990)."""
    try:
        return require_mutation_ownership(boundaries if boundaries is not None else Boundaries())
    except CliError as error:
        raise DoorRefused(error.code, error.message, error.exit_status) from error


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        status, document = run(argv, Boundaries())
    except Exception as error:  # a defect here must still leave one JSON document
        status = EXIT_FAILED
        # A key command's defect reports its type only: the text could hold the key.
        detail = type(error).__name__ if "keys" in argv else f"{type(error).__name__}: {error}"
        document = {"ok": False, "error": {"code": "internalError", "message": detail}}
    sys.stdout.write(json.dumps(document) + "\n")
    sys.stdout.flush()
    return status


if __name__ == "__main__":
    sys.exit(main())
