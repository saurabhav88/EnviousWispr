"""`dev_control.py --self-test`: the CLI's own parser, routing, ownership decision and
transport against fakes (#3765).

Harness Contract: this checks the instrument agents drive the dev build through. When it
fails, a UAT script talks to the wrong app, changes the app without holding the shared
lock, or reads a reply it cannot trust; no customer sees it.

Everything outside the CLI is faked at its boundary and nothing else: the process table,
git, the lock owner module, the socket (an in-process AF_UNIX server on a private path)
and the import client. The CLI's own `run` parses, routes, decides and validates exactly
as shipped. Nothing here contacts a running app, the real lock, or the founder's stores.
"""

import contextlib
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

import dev_control

HERE = os.path.dirname(os.path.abspath(__file__))
CATEGORIES = ("routes", "valueSyntax", "lock", "instances", "identity", "framing", "output",
              "import")
_DOORS = []


class _Results:
    def __init__(self):
        self.counts = {name: 0 for name in CATEGORIES}
        self.failures = []

    def check(self, category, name, condition, detail=""):
        if condition:
            self.counts[category] += 1
            print(f"  ok      [{category}] {name}", file=sys.stderr)
        else:
            self.failures.append(f"[{category}] {name}: {detail}")
            print(f"  FAIL    [{category}] {name}: {detail}", file=sys.stderr)


# MARK: - Fakes at the boundaries


class FakeDoor:
    """A private AF_UNIX server that speaks the door's framing. `respond(request)` returns
    a list of byte chunks to send, the string "close" to hang up, or "silent"."""

    def __init__(self, pid, executable):
        self.pid = pid
        self.executable = executable
        self.launch = str(uuid.uuid4())
        self.received = []
        self.exchanges = 0
        self.respond = self.reply_ok
        self.results = {}
        self.faults = []
        self.folder = tempfile.mkdtemp(prefix="ewdc-selftest-")
        self.path = os.path.join(self.folder, "door.sock")
        self._listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener.bind(self.path)
        self._listener.listen(8)
        self._stopped = False
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        _DOORS.append(self)

    def envelope(self, request, **fields):
        reply = {"id": request.get("id"), "ok": True, "result": {}, "pid": self.pid,
                 "launch": self.launch, "executable": self.executable, "door": 1}
        reply.update(fields)
        return reply

    def frame(self, reply):
        return json.dumps(reply, ensure_ascii=False).encode("utf-8") + b"\n"

    def reply_ok(self, request):
        cmd = request.get("cmd")
        result = {"pong": True} if cmd == "ping" else self.results.get(cmd, {"echo": cmd})
        return [self.frame(self.envelope(request, result=result))]

    def _serve(self):
        while not self._stopped:
            try:
                conn, _ = self._listener.accept()
            except OSError:
                return
            with conn:
                buffer = b""
                hang_up = False
                while not hang_up:
                    try:
                        chunk = conn.recv(65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    buffer += chunk
                    while b"\n" in buffer:
                        line, _, buffer = buffer.partition(b"\n")
                        request = json.loads(line)
                        self.received.append(request)
                        self.exchanges += 1
                        try:
                            answer = self.respond(request)
                        except Exception as error:  # a broken case must not stop the server
                            self.faults.append(repr(error))
                            answer = "close"
                        if answer == "close":
                            hang_up = True
                            break
                        if answer == "silent":
                            continue
                        for index, piece in enumerate(answer):
                            if index:
                                time.sleep(0.02)  # settle: spaces pieces into separate reads; no case waits on it
                            conn.sendall(piece)

    def commands(self):
        return [r.get("cmd") for r in self.received]

    def stop(self):
        self._stopped = True
        try:
            self._listener.close()
        finally:
            shutil.rmtree(self.folder, ignore_errors=True)


class FixtureConnection(dev_control.Connection):
    """The shipped Connection, opened on the fixture's private socket path."""

    def __init__(self, path, pid, timeout):
        self.pid = int(pid)
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.settimeout(timeout)
        try:
            self._sock.connect(path)
        except OSError as error:
            self._sock.close()
            raise dev_control.DoorError(f"cannot connect: {error}") from error
        self._buffer = b""


class FakeLock:
    class Undecided(Exception):
        pass

    def __init__(self, session=None, status=0, find_error=None, main_error=None):
        self.session = session
        self.status = status
        self.find_error = find_error
        self.main_error = main_error
        self.find_calls = 0
        self.main_calls = []

    def find_session(self):
        self.find_calls += 1
        if self.find_error is not None:
            raise self.find_error
        return self.session

    def main(self, argv):
        self.main_calls.append(list(argv))
        print("dev-app-lock: chatter from the owner")
        if self.main_error is not None:
            raise self.main_error
        return self.status


AGENT = {"kind": "claude", "pid": 4242, "started": "Wed Oct 14 10:00:00 2026"}


class FakeBoundaries(dev_control.Boundaries):
    reply = {"status": "finished", "history": "row"}

    def __init__(self, instances, door=None, lock=None, toplevel=None, pyobjc=True,
                 main_thread=True, backend=None, lock_load_error=None):
        self._instances = instances
        self.door = door
        self.lock = lock if lock is not None else FakeLock(session=None)
        self.toplevel = toplevel
        self.pyobjc = pyobjc
        self.main_thread = main_thread
        self.backend = backend
        self.lock_load_error = lock_load_error
        self.backend_loads = 0
        self.backend_calls = []
        self.touched = []

    def instances(self):
        self.touched.append("instances")
        return dict(self._instances)

    def git_toplevel(self, cwd):
        self.touched.append("git")
        return self.toplevel

    def load_lock_owner(self):
        self.touched.append("lock")
        if self.lock_load_error is not None:
            raise self.lock_load_error
        return self.lock

    def connect(self, pid, timeout):
        self.touched.append("connect")
        if self.door is None:
            raise dev_control.DoorError("no socket for that pid")
        return FixtureConnection(self.door.path, pid, timeout)

    def has_pyobjc(self):
        return self.pyobjc

    def is_main_thread(self):
        if self.main_thread is None:  # the shipped check
            return dev_control.Boundaries.is_main_thread(self)
        return self.main_thread

    def load_import_backend(self):
        self.backend_loads += 1
        if isinstance(self.backend, Exception):
            raise self.backend

        def call(pid, path, **kwargs):
            self.backend_calls.append((pid, path, kwargs))
            return self.reply() if callable(self.reply) else self.reply

        return call


def _run(argv, boundaries, timeout=1.0):
    """The CLI's `run`, with its stdout and stderr captured so a stray print is caught."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status, document = dev_control.run(argv, boundaries, timeout=timeout)
    return status, document, out.getvalue(), err.getvalue()


def _code(document):
    return (document.get("error") or {}).get("code")


# MARK: - Fixtures on disk


class Tree:
    """Real folders, so symlinks and path boundaries resolve the way they will on disk."""

    def __init__(self):
        self.base = os.path.realpath(tempfile.mkdtemp(prefix="ewdc-tree-"))
        self.wt = self._dir("wt")
        self.sibling = self._dir("wt-2")
        self.spaced = self._dir("EW - issue")
        self.link = os.path.join(self.base, "link-to-wt")
        os.symlink(self.wt, self.link)

    def _dir(self, name):
        path = os.path.join(self.base, name)
        os.makedirs(path)
        return path

    @staticmethod
    def dev(root):
        return (f"{root}/.derivedData/Dev/Build/Products/Dev/EnviousWispr Local.app"
                "/Contents/MacOS/EnviousWispr")

    @staticmethod
    def release(root):
        return (f"{root}/.derivedData/Release/Build/Products/Release/EnviousWispr.app"
                "/Contents/MacOS/EnviousWispr")

    def clean(self):
        shutil.rmtree(self.base, ignore_errors=True)


# MARK: - Cases


def routes_and_values(r, tree):
    exe = tree.dev(tree.wt)
    door = FakeDoor(111, exe)
    word_id = str(uuid.uuid4())
    socket_routes = [
        (["ping"], "ping", None),
        (["status"], "status", None),
        (["settings", "list"], "settings.list", None),
        (["settings", "get", "llmModel"], "settings.get", {"key": "llmModel"}),
        (["settings", "set", "fillerRemovalEnabled", "false"], "settings.set",
         {"key": "fillerRemovalEnabled", "value": False}),
        (["words", "list"], "words.list", None),
        (["words", "add", "Fooflux", "--alias", "foo flux", "--alias", "fu flux"], "words.add",
         {"word": "Fooflux", "aliases": ["foo flux", "fu flux"]}),
        (["words", "update", word_id, "--word", "Foofluxx"], "words.update",
         {"id": word_id, "word": "Foofluxx"}),
        (["words", "remove", word_id], "words.remove", {"id": word_id}),
        (["history", "list", "--limit", "5"], "history.list", {"limit": 5}),
        (["history", "get", word_id], "history.get", {"id": word_id}),
    ]
    try:
        for argv, cmd, wire in socket_routes:
            door.received.clear()
            status, document, out, _ = _run(["--worktree", tree.wt] + argv,
                                             FakeBoundaries({"111": exe}, door=door))
            sent = door.received[-1] if door.received else {}
            expected = {"pong": True} if cmd == "ping" else {"echo": cmd}
            r.check("routes", " ".join(argv[:2]),
                    status == 0 and door.commands() == ["ping", cmd] and sent.get("args") == wire
                    and ("args" in sent) == (wire is not None) and out == ""
                    and document.get("result") == expected,
                    f"status={status} sent={door.received} out={out!r}")

        b = FakeBoundaries({"111": exe}, door=door)
        status, document, _, _ = _run(
            ["--worktree", tree.wt, "file", "transcribe", "/abs/clip.m4a", "--timeout", "30"], b)
        r.check("routes", "file transcribe",
                status == 0 and document.get("ok") is True and b.backend_calls == [
                    (111, "/abs/clip.m4a", {"timeout": 30.0, "worktree": tree.wt, "echo": False})],
                f"status={status} calls={b.backend_calls}")

        values = [
            (["3"], 3), (["0.5"], 0.5), (["1e300"], 1e300), (["null"], None), (["true"], True),
            (['"parakeet"'], "parakeet"), (["parakeet", "--string"], "parakeet"),
            (["true", "--string"], "true"), (['{"mode": "auto"}'], {"mode": "auto"}),
            (['["a", 2]'], ["a", 2]),
        ]
        for extra, expected in values:
            door.received.clear()
            status, _, _, _ = _run(["--worktree", tree.wt, "settings", "set", "k"] + extra,
                                   FakeBoundaries({"111": exe}, door=door))
            value = (door.received[-1].get("args") or {}).get("value", "<missing>") \
                if door.received else "<none>"
            r.check("valueSyntax", f"VALUE {extra}",
                    status == 0 and value == expected and type(value) is type(expected),
                    f"got {value!r}")
        for bad in (["parakeet"], ["NaN"], ["Infinity"], ["-Infinity"], ["{bad"], ["1e400"],
                    ["[1, 1e400]"], ['{"a": {"b": -1e400}}']):
            door.received.clear()
            status, document, _, _ = _run(["--worktree", tree.wt, "settings", "set", "k"] + bad,
                                          FakeBoundaries({"111": exe}, door=door))
            r.check("valueSyntax", f"VALUE {bad} refused before contact",
                    status == 2 and _code(document) == "usage" and door.received == [],
                    f"status={status} doc={document}")
        door.received.clear()
        status, _, _, _ = _run(["--worktree", tree.wt, "settings", "set", "k", "{}", "--force"],
                               FakeBoundaries({"111": exe}, door=door))
        r.check("valueSyntax", "--force adds force true",
                status == 0 and door.received[-1].get("args")
                == {"key": "k", "value": {}, "force": True}, str(door.received))
        for argv, wire in (
            (["words", "update", word_id, "--clear-aliases"], {"id": word_id, "aliases": []}),
            (["words", "update", word_id, "--alias", "x"], {"id": word_id, "aliases": ["x"]}),
            (["words", "add", "Plain"], {"word": "Plain"}),
            (["history", "list"], {}),
        ):
            door.received.clear()
            status, _, _, _ = _run(["--worktree", tree.wt] + argv,
                                   FakeBoundaries({"111": exe}, door=door))
            r.check("valueSyntax", " ".join(argv[:1] + argv[2:]),
                    status == 0 and door.received[-1].get("args") == wire, str(door.received))
        door.received.clear()
        status, _, _, _ = _run(
            ["--worktree", tree.wt, "words", "update", word_id, "--alias", "x", "--clear-aliases"],
            FakeBoundaries({"111": exe}, door=door))
        r.check("valueSyntax", "--alias with --clear-aliases refused",
                status == 2 and door.received == [], f"status={status}")

        door.results["words.add"] = {"outcome": "existing", "word": {"id": word_id}}
        status, document, _, _ = _run(["--worktree", tree.wt, "words", "add", "Fooflux"],
                                      FakeBoundaries({"111": exe}, door=door))
        r.check("routes", "a word outcome passes through unchanged",
                status == 0 and document.get("result") == door.results["words.add"], str(document))
        door.respond = lambda q: door.reply_ok(q) if q["cmd"] == "ping" else [door.frame(
            door.envelope(q, ok=False, result=None,
                          error={"code": "notFound", "message": "no word has that id"}))]
        status, document, _, _ = _run(["--worktree", tree.wt, "words", "remove", word_id],
                                      FakeBoundaries({"111": exe}, door=door))
        r.check("routes", "a door refusal exits 1 with its code",
                status == 1 and _code(document) == "notFound", f"status={status} doc={document}")
    finally:
        door.stop()


def lock_cases(r, tree):
    exe = tree.dev(tree.wt)
    door = FakeDoor(111, exe)
    word_id = str(uuid.uuid4())
    mutations = [
        ["settings", "set", "fillerRemovalEnabled", "false"],
        ["settings", "set", "toggleKeyCode", "12", "--force"],
        ["words", "add", "Fooflux"],
        ["words", "update", word_id, "--word", "W"],
        ["words", "remove", word_id],
        ["file", "transcribe", "/abs/clip.m4a"],
    ]
    try:
        for argv in mutations:
            for label, lock, want_status, want_code, dispatched in (
                ("founder", FakeLock(session=None), 0, None, True),
                ("owned agent", FakeLock(session=AGENT, status=0), 0, None, True),
                ("free slot or peer hold", FakeLock(session=AGENT, status=3), 3, "lockNotHeld",
                 False),
            ):
                door.received.clear()
                b = FakeBoundaries({"111": exe}, door=door, lock=lock)
                status, document, out, err = _run(["--worktree", tree.wt] + argv, b)
                reached = bool(door.received) or bool(b.backend_calls)
                checked = lock.main_calls == ([] if lock.session is None else [["check"]])
                name = " ".join(argv[:2]) + (" --force" if "--force" in argv else "")
                r.check("lock", f"{label}: {name}",
                        status == want_status and _code(document) == want_code
                        and reached == dispatched and checked and lock.find_calls == 1
                        and out == "" and ("chatter" in err) == (lock.session is not None),
                        f"status={status} doc={document} reached={reached} main={lock.main_calls}")
        for label, kwargs in (
            ("find_session raises", dict(lock=FakeLock(find_error=FakeLock.Undecided("no chat id")))),
            ("check exits 2", dict(lock=FakeLock(session=AGENT, status=2))),
            ("check raises SystemExit(2)", dict(lock=FakeLock(session=AGENT, main_error=SystemExit(2)))),
            ("check raises SystemExit(0)", dict(lock=FakeLock(session=AGENT, main_error=SystemExit(0)))),
            ("check raises", dict(lock=FakeLock(session=AGENT, main_error=OSError("sandbox")))),
            ("the owner will not load", dict(lock_load_error=ImportError("missing"))),
        ):
            door.received.clear()
            status, document, out, _ = _run(["--worktree", tree.wt, "words", "add", "X"],
                                            FakeBoundaries({"111": exe}, door=door, **kwargs))
            r.check("lock", f"undecidable: {label}",
                    status == 2 and _code(document) == "lockUndecided" and door.received == []
                    and out == "", f"status={status} doc={document}")
        b = FakeBoundaries({"111": exe}, door=door,
                           lock=FakeLock(session=AGENT, main_error=SystemExit(0)))
        door.received.clear()
        status, document, _, _ = _run(["--worktree", tree.wt, "file", "transcribe", "/abs/c.m4a"], b)
        r.check("lock", "undecidable: SystemExit(0) blocks a file import",
                status == 2 and _code(document) == "lockUndecided" and door.received == []
                and b.backend_loads == 0, f"status={status} doc={document}")
        reader_lock = FakeLock(find_error=AssertionError("a read must not ask the lock"))
        for argv in (["status"], ["settings", "list"], ["history", "list"], ["words", "list"]):
            status, _, _, _ = _run(["--worktree", tree.wt] + argv,
                                   FakeBoundaries({"111": exe}, door=door, lock=reader_lock))
            r.check("lock", f"a read needs no ownership: {argv[0]}",
                    status == 0 and reader_lock.find_calls == 0, f"status={status}")
        real = dev_control.Boundaries().load_lock_owner()
        r.check("lock", "the main-checkout owner loads and exposes find_session, main, Undecided",
                callable(getattr(real, "find_session", None))
                and callable(getattr(real, "main", None))
                and isinstance(getattr(real, "Undecided", None), type),
                dev_control.LOCK_OWNER_PATH)
    finally:
        door.stop()


def instance_cases(r, tree):
    dev, rel = tree.dev, tree.release
    refusals_with_list = {"noInstance", "instanceAmbiguous", "notDevBuild"}
    cases = [
        ("zero instances", {}, tree.wt, 2, "noInstance"),
        ("one dev instance", {"111": dev(tree.wt)}, tree.wt, 0, None),
        ("two dev instances under the worktree",
         {"111": dev(tree.wt),
          "112": f"{tree.wt}/build/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"},
         tree.wt, 2, "instanceAmbiguous"),
        ("a lone Release host", {"333": rel(tree.wt)}, tree.wt, 2, "notDevBuild"),
        ("dev plus Release host", {"111": dev(tree.wt), "333": rel(tree.wt)}, tree.wt, 2,
         "instanceAmbiguous"),
        ("only a sibling-prefix worktree runs", {"222": dev(tree.sibling)}, tree.wt, 2,
         "noInstance"),
        ("this worktree and its sibling-prefix run",
         {"111": dev(tree.wt), "222": dev(tree.sibling)}, tree.wt, 0, None),
        ("a worktree path with a space-hyphen", {"444": dev(tree.spaced)}, tree.spaced, 0, None),
        ("a symlinked worktree argument", {"111": dev(tree.wt)}, tree.link, 0, None),
        ("a missing worktree", {"111": dev(tree.wt)}, os.path.join(tree.base, "gone"), 2,
         "worktreeUnresolved"),
    ]
    for label, instances, worktree, want_status, want_code in cases:
        mine = [p for p, e in instances.items() if e == dev(os.path.realpath(worktree))]
        pid = int(mine[0]) if mine else 1
        door = FakeDoor(pid, instances.get(str(pid), ""))
        try:
            status, document, _, _ = _run(["--worktree", worktree, "status"],
                                          FakeBoundaries(instances, door=door))
            candidates = (document.get("error") or {}).get("candidates")
            listed = [{"pid": int(p), "executable": e} for p, e in sorted(instances.items())]
            r.check("instances", label,
                    status == want_status and _code(document) == want_code
                    and (want_code not in refusals_with_list or candidates == listed),
                    f"status={status} doc={document}")
        finally:
            door.stop()
    door = FakeDoor(111, dev(tree.wt))
    try:
        status, _, _, _ = _run(["status"], FakeBoundaries({"111": dev(tree.wt)}, door=door,
                                                            toplevel=tree.wt))
        r.check("instances", "the default worktree is git's toplevel", status == 0,
                f"status={status}")
        status, document, _, _ = _run(["status"], FakeBoundaries({"111": dev(tree.wt)}, door=door,
                                                                   toplevel=None))
        r.check("instances", "no git toplevel refuses",
                status == 2 and _code(document) == "worktreeUnresolved", str(document))
    finally:
        door.stop()


def identity_cases(r, tree):
    exe = tree.dev(tree.wt)
    door = FakeDoor(111, exe)

    def at_ping(**fields):
        def respond(q):
            if q["cmd"] != "ping":
                return door.reply_ok(q)
            reply = door.envelope(q, result={"pong": True})
            reply.update(fields)
            return [door.frame(reply)]
        return respond

    def later(**fields):
        def respond(q):
            if q["cmd"] == "ping":
                return door.reply_ok(q)
            reply = door.envelope(q, result={"echo": q["cmd"]})
            reply.update(fields)
            return [door.frame(reply)]
        return respond

    try:
        for label, respond in (
            ("wrong door version", at_ping(door=2)),
            ("wrong pid", at_ping(pid=999)),
            ("wrong executable", at_ping(executable=tree.dev(tree.sibling))),
            ("missing launch", at_ping(launch=None)),
            ("launch not a UUID", at_ping(launch="launch-1")),
            ("wrong request id", at_ping(id="someone-else")),
            ("no boolean ok", at_ping(ok="yes")),
            ("ping not answered with pong", at_ping(result={})),
        ):
            door.received.clear()
            door.respond = respond
            status, document, _, _ = _run(["--worktree", tree.wt, "words", "add", "X"],
                                          FakeBoundaries({"111": exe}, door=door))
            r.check("identity", f"{label} at ping refuses before dispatch",
                    status == 2 and _code(document) == "identityRefused"
                    and door.commands() == ["ping"],
                    f"status={status} doc={document} {door.commands()}")
        status, document, _, _ = _run(["--worktree", tree.wt, "status"],
                                      FakeBoundaries({"111": exe}, door=None))
        r.check("identity", "no door socket refuses",
                status == 2 and _code(document) == "doorUnavailable", str(document))
        for label, respond, argv, want_status, want_code, want_outcome in (
            ("a later reply from another launch", later(launch=str(uuid.uuid4())), ["status"],
             2, "identityChanged", "none"),
            ("a mutation answered by another launch", later(launch=str(uuid.uuid4())),
             ["words", "add", "X"], 2, "identityChanged", "unknown"),
            ("a later reply from another executable", later(executable="/x"), ["status"], 2,
             "identityChanged", "none"),
            ("a later reply naming another pid", later(pid=5), ["status"], 2, "identityChanged",
             "none"),
            ("a later reply with ok but no result", later(result=None), ["status"], 1,
             "doorError", None),
            ("a later reply with another request id", later(id="other"), ["status"], 1,
             "doorError", None),
            ("a malformed reply to a mutation", later(result=None), ["words", "add", "X"], 1,
             "outcomeUnknown", None),
            ("a mutation whose reply was too large to send",
             later(ok=False, result=None,
                   error={"code": "responseTooLarge", "message": "reply over limit"}),
             ["settings", "set", "k", "1"], 1, "outcomeUnknown", None),
            ("a read whose reply was too large stays the door's refusal",
             later(ok=False, result=None,
                   error={"code": "responseTooLarge", "message": "reply over limit"}),
             ["history", "list"], 1, "responseTooLarge", None),
        ):
            door.respond = respond
            status, document, _, _ = _run(["--worktree", tree.wt] + argv,
                                          FakeBoundaries({"111": exe}, door=door))
            outcome = (document.get("error") or {}).get("outcome")
            r.check("identity", label,
                    status == want_status and _code(document) == want_code
                    and outcome == want_outcome, f"status={status} doc={document}")
    finally:
        door.stop()


def framing_cases(r, tree):
    exe = tree.dev(tree.wt)
    door = FakeDoor(111, exe)
    limit = dev_control.MAX_FRAME_BYTES

    def padded(q, size):
        reply = door.envelope(q, result={"pad": ""})
        reply["result"]["pad"] = "a" * (size - len(json.dumps(reply).encode("utf-8")))
        data = json.dumps(reply).encode("utf-8")
        assert len(data) == size, len(data)
        return data

    def for_status(answer):
        return lambda q: door.reply_ok(q) if q["cmd"] == "ping" else answer(q)

    def split(q):
        data = door.frame(door.envelope(q, result={"word": "café"}))
        cut = data.index("é".encode("utf-8")) + 1  # inside the two-byte character
        return [data[:5], data[5:cut], data[cut:]]

    try:
        for label, respond, want_status, want_code in (
            ("a reply split across reads, inside a multibyte character", for_status(split), 0,
             None),
            ("a reply of exactly the frame limit",
             for_status(lambda q: [padded(q, limit) + b"\n"]), 0, None),
            ("a reply one byte over the limit",
             for_status(lambda q: [padded(q, limit + 1) + b"\n"]), 1, "doorError"),
            ("a reply that never ends", for_status(lambda q: [b"a" * (limit + 10)]), 1,
             "doorError"),
            ("invalid UTF-8", for_status(lambda q: [b'{"ok": true, "x": "\xff"}\n']), 1,
             "doorError"),
            ("invalid JSON", for_status(lambda q: [b"{not json\n"]), 1, "doorError"),
            ("a JSON array, not an object", for_status(lambda q: [b"[1, 2]\n"]), 1, "doorError"),
            ("a reply carrying NaN", for_status(lambda q: [
                door.frame(door.envelope(q))[:-2] + b', "x": NaN}\n']), 1, "doorError"),
            ("a reply whose number overflows to infinity", for_status(lambda q: [
                door.frame(door.envelope(q))[:-2] + b', "x": [1e400]}\n']), 1, "doorError"),
            ("EOF before the reply", for_status(lambda q: "close"), 1, "doorError"),
            ("no reply before the timeout", for_status(lambda q: "silent"), 1, "doorError"),
        ):
            door.respond = respond
            status, document, _, _ = _run(["--worktree", tree.wt, "status"],
                                          FakeBoundaries({"111": exe}, door=door), timeout=0.5)
            r.check("framing", label, status == want_status and _code(document) == want_code,
                    f"status={status} code={_code(document)}")

        door.respond = door.reply_ok
        door.received.clear()
        connection = FixtureConnection(door.path, 111, 1.0)
        try:
            try:
                connection.request("settings.set", {"key": "k", "value": float("nan")})
                refused = False
            except dev_control.DoorError:
                refused = True
            r.check("framing", "a request carrying NaN is refused before it is sent",
                    refused and door.received == [], str(door.received))
        finally:
            connection.close()

        # Coalesced replies to pipelined requests, through the shipped Connection.
        door.respond = lambda q: [] if q["id"] == "first" else [
            door.frame(door.envelope({"id": "first"}, result={"n": 1}))
            + door.frame(door.envelope(q, result={"n": 2}))]
        connection = FixtureConnection(door.path, 111, 1.0)
        try:
            connection.send_raw(
                b'{"id": "first", "cmd": "status"}\n{"id": "second", "cmd": "status"}\n')
            first, second = connection.read_reply(), connection.read_reply()
            r.check("framing", "two coalesced replies are read in order",
                    first["id"] == "first" and second["id"] == "second", f"{first} {second}")
        finally:
            connection.close()
    finally:
        door.stop()


def import_cases(r, tree):
    exe = tree.dev(tree.wt)
    door = FakeDoor(111, exe)
    argv = ["--worktree", tree.wt, "file", "transcribe", "/abs/clip.m4a"]
    try:
        for label, reply, want_status in (
            ("a finished import", {"status": "finished", "history": "row"}, 0),
            ("a busy refusal", {"status": "busy"}, 1),
            ("a refused import", {"status": "refused", "reason": "polishNotReady"}, 1),
            ("an import timeout", {"status": "timeout"}, 1),
            ("an accepted reply is not completion", {"status": "accepted"}, 1),
        ):
            b = FakeBoundaries({"111": exe}, door=door)
            b.reply = reply
            status, document, _, _ = _run(argv, b)
            r.check("import", label,
                    status == want_status and document.get("result") == reply
                    and document.get("ok") is (want_status == 0), f"status={status} doc={document}")

        def no_answer():
            raise RuntimeError("pid 111 did not answer the transcribe request")

        b = FakeBoundaries({"111": exe}, door=door)
        b.reply = no_answer
        status, document, _, _ = _run(argv, b)
        r.check("import", "a client error is an import failure",
                status == 1 and _code(document) == "importFailed", str(document))
        for bad in ("nan", "inf", "-inf", "0", "-1"):
            door.received.clear()
            b = FakeBoundaries({"111": exe}, door=door)
            status, document, _, _ = _run(argv + ["--timeout", bad], b)
            r.check("import", f"--timeout {bad} refused before any contact",
                    status == 2 and _code(document) == "usage" and b.touched == []
                    and door.received == [] and b.backend_loads == 0,
                    f"status={status} doc={document} touched={b.touched}")
        b = FakeBoundaries({"111": exe}, door=door)
        status, _, _, _ = _run(argv + ["--timeout", "0.5"], b)
        r.check("import", "a positive fractional timeout is passed on",
                status == 0 and b.backend_calls and b.backend_calls[-1][2]["timeout"] == 0.5,
                str(b.backend_calls))
        for label, kwargs in (
            ("no PyObjC", dict(pyobjc=False)),
            ("the import client will not load", dict(backend=ImportError("No module named objc"))),
        ):
            door.received.clear()
            b = FakeBoundaries({"111": exe}, door=door, **kwargs)
            status, document, _, _ = _run(argv, b)
            r.check("import", label,
                    status == 1 and _code(document) == "dependencyUnavailable"
                    and not b.backend_calls, f"status={status} doc={document}")
        holder = {}

        def off_main():
            holder["result"] = _run(argv, FakeBoundaries({"111": exe}, door=door,
                                                         main_thread=None))

        thread = threading.Thread(target=off_main)
        thread.start()
        thread.join()
        status, document, _, _ = holder["result"]
        r.check("import", "the shipped main-thread check refuses another thread",
                status == 1 and _code(document) == "dependencyUnavailable", str(document))
        status, _, _, _ = _run(argv, FakeBoundaries({"111": exe}, door=door, main_thread=None))
        r.check("import", "the shipped main-thread check passes the main thread", status == 0,
                f"status={status}")
        b = FakeBoundaries({"111": exe}, door=door)
        for socket_argv in (["status"], ["words", "list"], ["settings", "list"]):
            _run(["--worktree", tree.wt] + socket_argv, b)
        r.check("import", "socket commands never load the import client or PyObjC",
                b.backend_loads == 0 and "import_door" not in sys.modules
                and "objc" not in sys.modules, f"loads={b.backend_loads}")
        dev_control.Boundaries().has_pyobjc()
        r.check("import", "the PyObjC probe imports nothing",
                "objc" not in sys.modules and "Foundation" not in sys.modules, "")
    finally:
        door.stop()


def output_cases(r, tree):
    script = os.path.join(HERE, "dev_control.py")
    missing = os.path.join(tree.base, "gone")
    for label, argv, want_status, want_code in (
        ("no command", [], 2, "usage"),
        ("help", ["--help"], 0, None),
        ("an unknown command", ["dance"], 2, "usage"),
        ("a non-integer limit", ["--worktree", missing, "history", "list", "--limit", "x"], 2,
         "usage"),
        ("a setting VALUE that is not JSON",
         ["--worktree", missing, "settings", "set", "k", "parakeet"], 2, "usage"),
        ("a missing worktree", ["--worktree", missing, "status"], 2, "worktreeUnresolved"),
        ("a missing worktree on a mutation", ["--worktree", missing, "words", "add", "X"], 2,
         "worktreeUnresolved"),
    ):
        done = subprocess.run([sys.executable, "-I", script] + argv, capture_output=True,
                              text=True, timeout=60)
        lines = done.stdout.splitlines()
        try:
            document = json.loads(lines[0]) if len(lines) == 1 else None
        except ValueError:
            document = None
        r.check("output", f"entrypoint: {label}",
                done.returncode == want_status and isinstance(document, dict)
                and _code(document) == want_code and "Traceback" not in done.stderr,
                f"exit={done.returncode} stdout={done.stdout!r} stderr={done.stderr[-200:]!r}")

    class Broken(dev_control.Boundaries):
        def git_toplevel(self, cwd):
            raise KeyError("boom")

    real = dev_control.Boundaries
    out, err = io.StringIO(), io.StringIO()
    dev_control.Boundaries = Broken
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = dev_control.main(["status"])
    finally:
        dev_control.Boundaries = real
    lines = out.getvalue().splitlines()
    r.check("output", "an internal defect still prints one JSON document",
            status == 1 and len(lines) == 1 and _code(json.loads(lines[0])) == "internalError",
            out.getvalue())


def run_self_test():
    """(exit status, document): 0 only when every category ran and nothing failed."""
    r = _Results()
    tree = Tree()
    _DOORS.clear()
    print("dev_control self-test", file=sys.stderr)
    try:
        routes_and_values(r, tree)
        lock_cases(r, tree)
        instance_cases(r, tree)
        identity_cases(r, tree)
        framing_cases(r, tree)
        import_cases(r, tree)
        output_cases(r, tree)
    finally:
        tree.clean()
    exchanges = sum(door.exchanges for door in _DOORS)
    for door in _DOORS:
        r.failures.extend(f"fake door fault: {fault}" for fault in door.faults)
    empty = [name for name, count in r.counts.items() if count == 0]
    if empty:
        r.failures.append(f"categories that never ran: {empty}")
    if exchanges == 0:
        r.failures.append("no AF_UNIX exchange happened")
    total = sum(r.counts.values())
    print(f"dev_control self-test: {total} passed, {len(r.failures)} failed", file=sys.stderr)
    ok = not r.failures and total > 0
    summary = {"cases": total, "categories": r.counts, "socketExchanges": exchanges,
               "failures": r.failures}
    return (dev_control.EXIT_OK if ok else dev_control.EXIT_FAILED), \
        {"ok": ok, "result": {"selfTest": summary}}
