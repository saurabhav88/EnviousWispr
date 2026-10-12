#!/usr/bin/env python3
"""The single-instance guard for the RuntimeUAT harness, and its control.

SPLIT OUT OF `wispr_eyes.py` SO A CI JOB CAN RUN IT (#2426). `wispr_eyes`
imports `ui_helpers`, which imports `ApplicationServices` — so importing it at
all requires PyObjC on the runner, and the pull-request workflow's RuntimeUAT step was
deliberately limited to modules that need nothing heavy. This module imports
`os`, `subprocess` and `sys` and nothing else, so the guard — the part actually
worth gating — runs on the hosted runner while the UI-driving harness around it
stays out of CI, where it could not run headless anyway.

`wispr_eyes.py` re-exports both functions, so every existing caller and every
`wispr_eyes.running_enviouswispr_instances(...)` reference keeps working.

Run the control:

    python3 Tests/RuntimeUAT/instance_guard.py --self-test
"""

import os
import subprocess
import sys
from dataclasses import dataclass


class InstanceGuardError(RuntimeError):
    """The intended app identity could not be established safely."""


@dataclass(frozen=True)
class TargetIdentity:
    pid: int
    executable: str
    start: tuple[int, int]


def process_start(pid):
    """Read the native microsecond start token, never a formatted timestamp.

    Layout: Apple's sys/proc_info.h proc_bsdinfo, PROC_PIDTBSDINFO (3).
    Imported lazily so offline controls need no native library or PyObjC.
    """
    import ctypes
    if sys.platform != "darwin" or type(pid) is not int or pid <= 0:
        raise InstanceGuardError("native process identity requires a valid macOS PID")

    class BSDInfo(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint32) for name in (
            "flags", "status", "xstatus", "pid", "ppid", "uid", "gid",
            "ruid", "rgid", "svuid", "svgid", "reserved")]
        _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
        _fields_ += [(name, ctypes.c_uint32) for name in (
            "nfiles", "pgid", "pjobc", "tdev", "tpgid")]
        _fields_ += [("nice", ctypes.c_int32), ("seconds", ctypes.c_uint64),
                     ("microseconds", ctypes.c_uint64)]

    try:
        lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        read = lib.proc_pidinfo
        read.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                         ctypes.c_void_p, ctypes.c_int]
        read.restype = ctypes.c_int
        info = BSDInfo()
        size = ctypes.sizeof(info)
        got = read(pid, 3, 0, ctypes.byref(info), size)
    except (OSError, AttributeError) as error:
        raise InstanceGuardError(f"native identity unavailable: {error}") from error
    if (got != size or info.pid != pid or info.seconds <= 0
            or info.microseconds >= 1_000_000):
        raise InstanceGuardError("native process identity is missing or malformed")
    return int(info.seconds), int(info.microseconds)


def pin_target(expected_pid, expected_executable):
    if (type(expected_pid) is not int or expected_pid <= 0
            or not isinstance(expected_executable, str)
            or not os.path.isabs(expected_executable)
            or not expected_executable.endswith(".app/Contents/MacOS/EnviousWispr")):
        raise InstanceGuardError("invalid expected app identity")
    before = process_start(expected_pid)
    found = running_enviouswispr_instances()
    after = process_start(expected_pid)
    if found != {str(expected_pid): expected_executable} or before != after:
        raise InstanceGuardError("app is ambiguous, replaced, or not the expected executable")
    return TargetIdentity(expected_pid, expected_executable, after)


def verify_target(target):
    if not isinstance(target, TargetIdentity):
        raise InstanceGuardError("a pinned app identity is required")
    current = pin_target(target.pid, target.executable)
    if current != target:
        raise InstanceGuardError("pinned app process was replaced; refusing automatic rebind")
    return target


def running_enviouswispr_instances():
    """Every running EnviousWispr app bundle, as {pid: executable path}.

    Reads `comm`, NOT `command`. `command` is the executable PLUS its arguments
    with no delimiter between them, so recovering the executable means guessing
    where the arguments begin - and every guess is wrong for some legal path. An
    earlier version split on the first `" -"`, which silently truncates
    `/Users/x/EW - issue/build/EnviousWispr Local.app/...` to `/Users/x/EW` and
    drops that instance from the count. `comm` is the executable alone, so there
    is nothing to parse. (Verified here: on macOS it is the full path, unlike
    Linux where `comm` is the basename.)

    Still excludes our own pid. A caller's argv routinely carries both
    `EnviousWispr` (a worktree path) and `.app/Contents/MacOS/` (a script running
    under `Python.app`), and excluding `python3` does not help - the interpreter's
    binary is named `Python`. The basename test already rejects `.../Python`, so
    the pid check is the second of two mechanisms rather than the only one; the
    self-test carries a row that binds it, because a mutant proved the obvious row
    did not.

    Deliberately NOT scoped to `EnviousWispr Local.app`. A Release-configuration
    test host is named `EnviousWispr.app`, carries the PRODUCTION bundle id, and
    answers the same global hotkey; a `Local.app` pattern cannot see it, which is
    exactly the instance you most want counted.
    """
    # `-ww` asks for unlimited width. macOS `ps(1)` documents that output can be
    # truncated to the terminal width and that a second `-w` lifts the bound. It
    # did NOT reproduce here - piped output stayed intact at 88,841 characters
    # even with COLUMNS=60 - so this is insurance, not a fix for an observed
    # truncation. It earns its place because the failure would be SILENT and in
    # the dangerous direction: a truncated suffix drops a real instance, and the
    # verdict becomes unattributable with nothing to indicate it.
    try:
        result = subprocess.run(["ps", "-eww", "-o", "pid=,comm="],
                                capture_output=True, text=True, timeout=5)
    except (OSError, UnicodeError, subprocess.TimeoutExpired) as error:
        raise InstanceGuardError(f"process enumeration failed: {error}") from error
    stderr = getattr(result, "stderr", "")
    if result.returncode != 0 or not isinstance(stderr, str) or stderr.strip():
        raise InstanceGuardError("process enumeration did not complete cleanly")
    out = result.stdout
    if not isinstance(out, str) or not out.strip():
        raise InstanceGuardError("process enumeration returned no readable table")
    me = str(os.getpid())
    found = {}
    seen = set()
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            raise InstanceGuardError("malformed process table row")
        pid, exe = parts
        if (len(pid) > 10 or not pid.isascii() or not pid.isdecimal()
                or not 0 < int(pid) <= 2_147_483_647 or pid != str(int(pid))):
            raise InstanceGuardError("malformed process PID")
        if pid in seen:
            raise InstanceGuardError("duplicate PID in process table")
        seen.add(pid)
        if pid == me:
            continue
        # An EXACT suffix, so a sibling executable in the same bundle (e.g.
        # `llama-server`) is excluded.
        if exe.endswith(".app/Contents/MacOS/EnviousWispr"):
            found[pid] = exe
    return found


def _require_single_instance(what):
    """REFUSE rather than choose when more than one EnviousWispr is running.

    Every instance answers the same global hotkey and writes the same shared
    `app.log`, so a marker count drawn from that log is unattributable the moment
    there are two. Measured 2026-08-25: a second instance inside the window
    returned 2 of every marker with DISTINCT session ids - two real recordings
    from one gesture - which reads as the app double-counting a synthetic press.
    A confident wrong subject, pointing at production code.

    Returns the instance map so the caller can re-check it afterwards. A wrong
    refusal costs a rerun; a wrong verdict costs somebody a debugging session in
    correct code.
    """
    try:
        found = running_enviouswispr_instances()
    except InstanceGuardError as error:
        print(f"BLOCKED: {what}: {error}")
        return None
    if len(found) != 1:
        rows = "\n".join(f"    {p}  {c}" for p, c in sorted(found.items()))
        print(f"BLOCKED: {what} needs exactly ONE running EnviousWispr; "
              f"found {len(found)}.\n{rows}")
        return None
    return found


def run_guard_cases():
    """Control for the single-instance guard - a HARNESS CONTRACT test.

    It protects the INSTRUMENT and says nothing about whether hands-free works
    (testing-philosophy.md RULE: every-test-declares-which-of-four-things-it-protects).

    CI RUNS THIS, as of #2426. It did not before, and the reason it did not is
    the reason this module exists: these rows lived in `wispr_eyes.py`, which
    imports `ui_helpers` and so needs PyObjC to import at all, and wiring that to
    the required check would have rested on an untested assumption about the
    hosted runner. Moving the guard to a module importing `os` and `subprocess`
    removes the assumption rather than testing it. It runs beside the siblings
    that were already wired in on the same grounds, `ptt_binding.py` and
    `faultInjection.py`. By hand, either entry point drives these same rows:

        python3 Tests/RuntimeUAT/instance_guard.py --self-test
        python3 Tests/RuntimeUAT/wispr_eyes.py --self-test

    Every row drives the real function with an injected `ps` table, and the set is
    two-way: three rows must REFUSE and two must PASS, so a guard that stopped
    classifying anything fails here rather than looking clean.
    """
    import types
    real_run = subprocess.run
    me = str(os.getpid())

    def fake(rows):
        def _run(cmd, *a, **k):
            if list(cmd[:1]) == ["ps"]:
                return types.SimpleNamespace(stdout="\n".join(rows), returncode=0)
            return real_run(cmd, *a, **k)
        return _run

    ONE = ["  111 /Users/x/EW/build/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"]
    cases = [
        ("one dev instance", ONE, 1, True),
        ("two dev instances", ONE + [
            "  222 /Users/x/wt/.derivedData/Dev/Build/Products/Dev/EnviousWispr Local.app"
            "/Contents/MacOS/EnviousWispr"], 2, False),
        # The Release test host carries the PRODUCTION bundle id and answers the same
        # global hotkey, and a pattern scoped to `EnviousWispr Local.app` cannot see
        # it - which is the instance you most want counted.
        ("dev + Release test host", ONE + [
            "  333 /Users/x/wt/.derivedData/Release/Build/Products/Release/EnviousWispr.app"
            "/Contents/MacOS/EnviousWispr"], 2, False),
        # The probe's own argv carries `EnviousWispr` (a worktree path) AND
        # `.app/Contents/MacOS/` (it runs under Python.app). A command-line
        # substring test finds itself; excluding `python3` does not help, because
        # the interpreter's binary is named `Python`.
        ("one instance + this probe's own argv", ONE + [
            f"  {me} /opt/homebrew/Frameworks/Python.framework/Versions/3.13/Resources"
            f"/Python.app/Contents/MacOS/Python -u /tmp/EnviousWispr/probe.py"], 1, True),
        # The row above does NOT bind the pid exclusion, and a mutant proved it: a
        # Python probe's executable is `.../Python`, which the basename test
        # already rejects, so removing `if pid == me` left the self-test green.
        # This row is the one that binds it - our own pid wearing an executable
        # the basename test WOULD accept. Contrived as a process, exact as a
        # requirement: the two mechanisms answer different questions ("is this an
        # EnviousWispr app" and "is this me"), and only this row can tell whether
        # the second one is still there.
        ("our own pid wearing a matching executable", ONE + [
            f"  {me} /Users/x/EW/build/EnviousWispr Local.app"
            f"/Contents/MacOS/EnviousWispr"], 1, True),
        ("no instance at all", ["  999 /usr/bin/vim"], 0, False),
        # A worktree or parent directory may legally contain " - ". An earlier
        # version recovered the executable by splitting `command` on the first
        # `" -"`, which truncates this to `/Users/x/EW` and drops the instance -
        # a real second app going uncounted, which is the one failure this guard
        # exists to prevent. Reading `comm` removes the parse entirely; this row
        # is what stops anyone reintroducing one.
        ("a path containing a space-hyphen is still counted", ONE + [
            "  444 /Users/x/EW - issue/build/EnviousWispr Local.app"
            "/Contents/MacOS/EnviousWispr"], 2, False),
        # Same bundle, a sibling executable. `comm` lists it, and an EXACT
        # suffix is what keeps it out of the count; a substring test would
        # treble every instance.
        ("llama-server (a bundled sibling executable) is not an instance", ONE + [
            "  556 /Users/x/EW/build/EnviousWispr Local.app/Contents/Resources"
            "/llama-server"], 1, True),
    ]

    failures = []
    for name, rows, want_n, want_pass in cases:
        subprocess.run = fake(rows)
        try:
            n = len(running_enviouswispr_instances())
            got_pass = _require_single_instance("self-test") is not None
        finally:
            subprocess.run = real_run
        if n != want_n or got_pass != want_pass:
            failures.append(f"{name}: count={n} (want {want_n}), "
                            f"guard={'PASS' if got_pass else 'REFUSED'} "
                            f"(want {'PASS' if want_pass else 'REFUSED'})")
        else:
            print(f"  ok      {name}")
    return failures, len(cases)


def _assert(condition):
    if condition is not True:
        raise AssertionError("offline control outcome mismatch")


def run_identity_cases():
    """Offline harness contracts: real guards/callers, fake OS and AX boundaries."""
    import ast
    import pathlib
    import types
    from unittest.mock import patch
    failures, count = [], 0
    executable = "/Users/x/EW/build/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"
    valid = {"111": executable}

    def case(name, action, refused=False):
        nonlocal count
        count += 1
        try:
            action()
        except InstanceGuardError:
            if not refused:
                failures.append(name + ": unexpected refusal")
        except Exception as error:
            failures.append(name + ": " + repr(error))
        else:
            if refused:
                failures.append(name + ": accepted invalid identity")

    token = (123, 456)
    target = TargetIdentity(111, executable, token)
    for name, table in [("one", valid), ("none", {}),
                        ("multiple", {**valid, "222": executable}),
                        ("wrong path", {"111": executable + "-other"})]:
        with patch(__name__ + ".running_enviouswispr_instances", return_value=table), \
             patch(__name__ + ".process_start", return_value=token):
            case(name, lambda: pin_target(111, executable), refused=name != "one")
    for name, starts, refused in [
        ("stable pin", [token, token], False),
        ("reuse during enumeration", [token, (124, 456)], True),
        ("reuse since pin", [(124, 456), (124, 456)], True),
    ]:
        with patch(__name__ + ".running_enviouswispr_instances", return_value=valid), \
             patch(__name__ + ".process_start", side_effect=starts):
            case(name, lambda: verify_target(target), refused)
    with patch(__name__ + ".process_start", side_effect=InstanceGuardError("unreadable")):
        case("unreadable native identity", lambda: verify_target(target), True)
    for name, result in [
        ("producer failure", types.SimpleNamespace(stdout="", stderr="", returncode=1)),
        ("producer stderr", types.SimpleNamespace(stdout="", stderr="error", returncode=0)),
        ("malformed row", types.SimpleNamespace(stdout="not-a-pid", stderr="", returncode=0)),
        ("duplicate pid", types.SimpleNamespace(stdout="111 /a\n111 /b", stderr="", returncode=0)),
        ("unreadable table", types.SimpleNamespace(stdout=None, stderr="", returncode=0)),
    ]:
        with patch.object(subprocess, "run", return_value=result):
            case(name, running_enviouswispr_instances, True)
    with patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("ps", 5)):
        case("enumeration timeout", running_enviouswispr_instances, True)

    # Compile the exact caller functions without importing PyObjC or executing module setup.
    source = pathlib.Path(__file__).with_name("wispr_eyes.py").read_text()
    names = {"connect", "_ensure_connected", "_verify_element", "perform_action", "set_attr",
             "tap", "close_window", "_ax", "_cancel_menu", "_open_settings", "batch"}
    tree = ast.parse(source)
    nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
    assert {n.name for n in nodes} == names
    caller = {"_pid": None, "_app": None, "_target": None,
              "InstanceGuardError": InstanceGuardError, "pin_target": pin_target,
              "verify_target": verify_target, "running_enviouswispr_instances": lambda: running_enviouswispr_instances(),
              "pathlib": pathlib, "__file__": str(pathlib.Path(__file__).with_name("wispr_eyes.py")),
              "find_app_pid": lambda _: (_ for _ in ()).throw(AssertionError("unexpected lookup")),
              "get_ax_app": lambda pid: ("app", pid), "element_pid": lambda el: el,
              "_raw_perform_action": lambda el, action: (calls.append((el, action)), True)[1],
              "_raw_set_attr": lambda el, attr, value: (calls.append((el, attr, value)), True)[1]}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), source, "exec"), caller)
    calls = []
    with patch(__name__ + ".running_enviouswispr_instances", return_value=valid), \
         patch(__name__ + ".process_start", return_value=token):
        case("explicit connection", lambda: caller["connect"](expected_pid=111, expected_executable=executable))
        case("internal reconnect retains pin", caller["connect"])
        case("conflicting rebind", lambda: caller["connect"](expected_pid=222), True)
        case("valid AX mutation", lambda: caller["perform_action"](111, "AXPress"))
        assert len(calls) == 1
        case("wrong AX owner", lambda: caller["perform_action"](222, "AXPress"), True)
        assert len(calls) == 1
    with patch(__name__ + ".running_enviouswispr_instances", return_value={}), \
         patch(__name__ + ".process_start", return_value=token):
        case("disappears before AX action", lambda: caller["perform_action"](111, "AXPress"), True)
        assert len(calls) == 1
    # Malformed producer values are always refusal, never a successful absence.
    for text in ["", " ", "0 /a", "-1 /a", "² /a", "2147483648 /a", "00111 /a", "111", "9" * 5000 + " /a"]:
        with patch.object(subprocess, "run", return_value=types.SimpleNamespace(
                stdout=text, stderr="", returncode=0)):
            case("invalid table " + repr(text), running_enviouswispr_instances, True)
    with patch.object(subprocess, "run", return_value=types.SimpleNamespace(
            stdout="999 /usr/bin/vim", stderr="", returncode=0)):
        case("readable unrelated table", lambda: _assert(running_enviouswispr_instances() == {}))
    for error in [OSError("producer"), UnicodeError("decode")]:
        with patch.object(subprocess, "run", side_effect=error):
            case("producer exception " + type(error).__name__, running_enviouswispr_instances, True)

    # Exercise the actual native validation, replacing only its C-library boundary.
    import ctypes
    class Native:
        argtypes = None
        restype = None
        def __init__(self, size="exact", pid=111, seconds=123, micros=456):
            self.size, self.pid, self.seconds, self.micros = size, pid, seconds, micros
        def __call__(self, pid, flavor, arg, pointer, size):
            import struct
            # Independent SDK ABI literals; never fill the subject's named fields.
            _assert((pid, flavor, arg, size) == (111, 3, 0, 136))
            data = bytearray(136)
            struct.pack_into("=I", data, 12, self.pid)
            struct.pack_into("=Q", data, 120, self.seconds)
            struct.pack_into("=Q", data, 128, self.micros)
            ctypes.memmove(pointer, bytes(data), 136)
            return 136 if self.size == "exact" else self.size
    for name, reader, refused in [
        ("native valid", Native(), False), ("native zero", Native(size=0), True),
        ("native short", Native(size=1), True), ("native wrong PID", Native(pid=222), True),
        ("native no start", Native(seconds=0), True),
        ("native micro zero", Native(micros=0), False),
        ("native micro max", Native(micros=999999), False),
        ("native micro overflow", Native(micros=1000000), True),
    ]:
        with patch.object(sys, "platform", "darwin"), patch.object(ctypes, "CDLL", return_value=types.SimpleNamespace(proc_pidinfo=reader)):
            action = ((lambda: process_start(111)) if refused else
                      (lambda: _assert(process_start(111) == (reader.seconds, reader.micros))))
            case(name, action, refused)
    with patch.object(sys, "platform", "darwin"), patch.object(ctypes, "CDLL", side_effect=OSError("missing library")):
        case("native unavailable library", lambda: process_start(111), True)
    with patch.object(sys, "platform", "darwin"), patch.object(ctypes, "CDLL", return_value=types.SimpleNamespace()):
        case("native unavailable symbol", lambda: process_start(111), True)

    caller.update({"_ACTIONABLE": ["AXButton"], "_find_match": lambda *a, **k: 111,
                   "get_attr": lambda el, attr: 111 if attr == "AXCloseButton" else "AXButton",
                   "_txt": lambda _: "control", "find_all_elements": lambda *a, **k: [111],
                   "_iter_children_with_menubars": lambda _: [], "element_frame": lambda _: (),
                   "_ui_terms": {}, "NavigationError": RuntimeError, "time": __import__("time")})
    caller["_sn"] = types.SimpleNamespace(AX=lambda **kwargs: types.SimpleNamespace(**kwargs))
    for name in ["see", "read", "read_cards", "nav", "menu", "type_text", "press_key", "wait_for",
                 "clipboard", "health", "screenshot", "zoom", "scroll", "hold_key", "begin_test",
                 "end_test", "record_tts"]:
        caller[name] = lambda *a, **k: (_ for _ in ()).throw(AssertionError("unexpected action"))
    with patch(__name__ + ".running_enviouswispr_instances", return_value=valid), patch(__name__ + ".process_start", return_value=token):
        for name, action in [
            ("attribute mutation", lambda: _assert(caller["set_attr"](111, "AXSelected", True) is True)),
            ("tap integration", lambda: _assert(caller["tap"]("control") is True)),
            ("close integration", lambda: _assert(caller["close_window"]() is True)),
            ("adapter press", lambda: _assert(caller["_ax"]().press(111) is True)),
            ("menu cancellation", lambda: caller["_cancel_menu"](111)),
            ("settings open", caller["_open_settings"]),
        ]:
            n = len(calls);case(name, action);_assert(len(calls) == n + 1)
        case("conflicting executable", lambda: caller["connect"](expected_executable=executable + "-other"), True)
        original_owner = caller["element_pid"]
        caller["element_pid"] = lambda _: (_ for _ in ()).throw(RuntimeError("unreadable"))
        n = len(calls);case("unreadable AX owner", lambda: caller["set_attr"](111, "AXSelected", True), True);_assert(len(calls) == n)
        caller["element_pid"] = original_owner
    with patch(__name__ + ".running_enviouswispr_instances", return_value={}), patch(__name__ + ".process_start", return_value=token):
        for name, action in [("tap refusal", lambda: caller["tap"]("control")),
                             ("close refusal", caller["close_window"]),
                             ("adapter refusal", lambda: caller["_ax"]().press(111)),
                             ("cancel refusal", lambda: caller["_cancel_menu"](111)),
                             ("settings refusal", caller["_open_settings"])]:
            n = len(calls);case(name, action, True);_assert(len(calls) == n)
    with patch(__name__ + ".running_enviouswispr_instances", return_value=valid), patch(__name__ + ".process_start", return_value=token):
        subsequent = []
        def lost(*args, **kwargs):
            raise InstanceGuardError("lost inside batch")
        old_tap = caller["tap"];caller["tap"] = lost;caller["see"] = lambda: subsequent.append(True)
        case("batch propagates and stops", lambda: caller["batch"]([("tap", "control"), ("see",)]), True)
        _assert(subsequent == []);caller["tap"] = old_tap
        old_target = caller["_target"];caller["_target"] = None
        caller["find_app_pid"] = lambda name: 999 if name == "TextEdit" else None
        case("other app lookup preserved", lambda: caller["connect"]("TextEdit"))
        _assert(caller["_pid"] == 999);caller["_target"] = old_target;caller["_pid"] = 111;caller["_app"] = ("app", 111)
    checkout_executable = str(pathlib.Path(caller["__file__"]).resolve().parents[2]
                              / "build/EnviousWispr Local.app/Contents/MacOS/EnviousWispr")
    with patch(__name__ + ".running_enviouswispr_instances", return_value={"111": checkout_executable}), patch(__name__ + ".process_start", return_value=token):
        caller["_target"] = None
        case("own checkout default", caller["connect"])
        _assert(caller["_target"].executable == checkout_executable)
    with patch(__name__ + ".running_enviouswispr_instances", return_value=valid), patch(__name__ + ".process_start", return_value=token):
        caller["_target"] = None
        case("wrong checkout default refuses", caller["connect"], True)
    caller["_target"] = target;caller["_pid"] = 111;caller["_app"] = ("app",111)
    with patch(__name__ + ".running_enviouswispr_instances", return_value=valid), patch(__name__ + ".process_start", return_value=(124,456)):
        n = len(calls)
        case("replacement refuses reconnect", caller["connect"], True)
        case("replacement refuses attribute mutation", lambda: caller["set_attr"](111,"AXSelected",True), True)
        _assert(len(calls) == n and caller["_target"] == target)
    old_attr = caller["get_attr"]
    try:
        for role, name, action in [
            ("AXButton", "late tap press refusal", lambda: caller["tap"]("control")),
            ("AXRow", "late tap attribute refusal", lambda: caller["tap"]("control")),
            ("AXButton", "late close refusal", caller["close_window"]),
        ]:
            caller["get_attr"] = lambda el, attr, r=role: 111 if attr == "AXCloseButton" else r
            with patch(__name__ + ".running_enviouswispr_instances", side_effect=[valid, {}]), \
                 patch(__name__ + ".process_start", return_value=token):
                n = len(calls)
                case(name, action, True)
                _assert(len(calls) == n)
    finally:
        caller["get_attr"] = old_attr

    # Execute the actual ownership helper; only the native AX API is replaced.
    helper_path = pathlib.Path(__file__).with_name("ui_helpers.py")
    helper_tree = ast.parse(helper_path.read_text())
    helper_nodes = [n for n in helper_tree.body if isinstance(n, ast.FunctionDef) and n.name == "element_pid"]
    _assert(len(helper_nodes) == 1)
    helper = {"kAXErrorSuccess": 0}
    exec(compile(ast.Module(body=helper_nodes, type_ignores=[]), str(helper_path), "exec"), helper)
    old_owner = caller["element_pid"]
    caller["element_pid"] = helper["element_pid"]
    try:
        for name, result, refused in [
            ("valid", (0, 111), False), ("API error", (1, 111), True),
            ("missing", (0, None), True), ("Boolean", (0, True), True),
            ("zero", (0, 0), True), ("negative", (0, -1), True),
        ]:
            helper["AXUIElementGetPid"] = lambda el, out, r=result: r
            with patch(__name__ + ".running_enviouswispr_instances", return_value=valid), \
                 patch(__name__ + ".process_start", return_value=token):
                n = len(calls)
                case("native AX owner " + name, lambda: caller["perform_action"](111, "AXPress"), refused)
                _assert(len(calls) == n + (0 if refused else 1))
        def ax_error(*args):
            raise OSError("AX API failed")
        helper["AXUIElementGetPid"] = ax_error
        with patch(__name__ + ".running_enviouswispr_instances", return_value=valid), \
             patch(__name__ + ".process_start", return_value=token):
            n = len(calls)
            case("native AX owner raised error", lambda: caller["perform_action"](111, "AXPress"), True)
            _assert(len(calls) == n)
    finally:
        caller["element_pid"] = old_owner
    print(f"identity controls: {count} cases, {len(failures)} failures")
    return failures, count


def _self_test():
    """The guard control, as CI runs it.

    Two-way by construction: three rows must REFUSE and the rest must PASS, so a
    guard that stopped classifying anything fails here rather than looking clean.
    """
    failures, total = run_guard_cases()
    if failures:
        for f in failures:
            print(f"  FAIL    {f}")
        print(f"\ninstance_guard self-test: {len(failures)} of {total} FAILED")
        return 1
    print(f"\ninstance_guard self-test: {total}/{total} passed")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    print("instance_guard is a library. Run `--self-test` for the harness control.")
    sys.exit(2)
