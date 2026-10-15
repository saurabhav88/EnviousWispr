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
import uuid

PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 1 << 20

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2
EXIT_NOT_OWNER = 3

# The machine-wide lock owner lives in the main checkout and is shared by every
# worktree; older worktree copies may lack the current policy.
LOCK_OWNER_PATH = "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/scripts/lib/dev-app-lock.py"
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
Changes need the shared dev-app lock (dev-app-lock.py claim) unless run by hand.
"""


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


class Boundaries:
    """Everything the CLI reads from outside itself. `main` uses these real ones; the
    self-test hands `run` fakes for the process table, git, the lock owner, the socket and
    the import client, and runs everything else as shipped."""

    def instances(self):
        from instance_guard import running_enviouswispr_instances
        return running_enviouswispr_instances()

    def git_toplevel(self, cwd):
        out = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True)
        if out.returncode != 0 or not out.stdout.strip():
            return None
        return out.stdout.strip()

    def load_lock_owner(self):
        spec = importlib.util.spec_from_file_location("ew_dev_app_lock", LOCK_OWNER_PATH)
        if spec is None or spec.loader is None:
            raise ImportError(f"cannot load {LOCK_OWNER_PATH}")
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

    def call(self, cmd, args):
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


def _door_call(session, cmd, wire, mutation):
    try:
        reply = session.call(cmd, wire)
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
    return (EXIT_OK if reply["ok"] else EXIT_FAILED), reply


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
        return error.exit_status, error.document()
    if args.self_test:
        from dev_control_self_test import run_self_test
        return run_self_test()
    if args.group is None:
        build_parser().print_usage()
        return EXIT_USAGE, CliError("usage", "no command given", EXIT_USAGE).document()
    try:
        socket_route = route(args)
        mutation = socket_route is None or socket_route[2]
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


def main(argv=None):
    try:
        status, document = run(sys.argv[1:] if argv is None else argv, Boundaries())
    except Exception as error:  # a defect here must still leave one JSON document
        status = EXIT_FAILED
        document = {"ok": False, "error": {"code": "internalError",
                                           "message": f"{type(error).__name__}: {error}"}}
    sys.stdout.write(json.dumps(document) + "\n")
    sys.stdout.flush()
    return status


if __name__ == "__main__":
    sys.exit(main())
