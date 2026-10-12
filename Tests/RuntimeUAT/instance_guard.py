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


@dataclass(frozen=True)
class ExitProof:
    old: TargetIdentity
    replacement_start: tuple[int, int] | None


def prove_target_exited(old):
    """Positive native absence or a different start token; errors never mean exit.

    Darwin kill(2), signal zero: no signal is sent; ESRCH alone proves absence.
    https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kill.2.html
    """
    if (not isinstance(old, TargetIdentity) or type(old.pid) is not int
            or not 0 < old.pid <= 2_147_483_647):
        raise InstanceGuardError("exit proof requires a valid pinned identity")
    try:
        os.kill(old.pid, 0)
    except ProcessLookupError:
        return ExitProof(old, None)
    except OSError as error:
        raise InstanceGuardError("native process existence is unreadable") from error
    try:
        current = process_start(old.pid)
    except InstanceGuardError:
        # It may have exited between the two native reads. Only ESRCH can close that gap.
        try:
            os.kill(old.pid, 0)
        except ProcessLookupError:
            return ExitProof(old, None)
        except OSError as error:
            raise InstanceGuardError("native process existence is unreadable") from error
        raise
    if current == old.start:
        raise InstanceGuardError("pinned process has not exited")
    return ExitProof(old, current)


def verify_exit_proof(old, proof):
    if not isinstance(proof, ExitProof) or proof.old != old:
        raise InstanceGuardError("exit proof belongs to another lifecycle")
    # Re-observe native state at the handoff boundary; a caller-created value is no evidence.
    prove_target_exited(old)
    return proof


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
    import tempfile
    import json
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
    for name, probe, start, refused in [
        ("native ESRCH proves exit", ProcessLookupError(), token, False),
        ("same native token is still alive", None, token, True),
        ("different native token proves old exit", None, (124, 456), False),
        ("native permission failure is unknown", PermissionError(), token, True),
        ("other existence failure is unknown", OSError("read failure"), token, True),
        ("unreadable live native token is unknown", None, InstanceGuardError("unreadable"), True),
    ]:
        with patch.object(os, "kill", side_effect=probe) as probe_call, \
             patch(__name__ + ".process_start", side_effect=start if isinstance(start, Exception) else None,
                   return_value=start):
            def proof_case():
                proof = prove_target_exited(target)
                _assert(proof.old == target)
                _assert(proof.replacement_start == (None if isinstance(probe, ProcessLookupError) else start))
            case(name, proof_case, refused)
            _assert(all(call.args == (111, 0) for call in probe_call.call_args_list))
    with patch.object(os, "kill", side_effect=[None, ProcessLookupError()]), \
         patch(__name__ + ".process_start", side_effect=InstanceGuardError("exited between reads")):
        case("native exit between reads", lambda: _assert(prove_target_exited(target) == ExitProof(target, None)))
    with patch.object(os, "kill", return_value=None), patch(__name__ + ".process_start", return_value=token):
        case("forged stale proof is re-observed", lambda: verify_exit_proof(target, ExitProof(target, None)), True)
    case("proof for another lifecycle refuses", lambda: verify_exit_proof(target,
         ExitProof(TargetIdentity(222, executable, token), None)), True)
    for pid in (0, -1, True, 2_147_483_648):
        with patch.object(os, "kill") as probe_call:
            case("invalid exit PID " + repr(pid), lambda: prove_target_exited(TargetIdentity(pid, executable, token)), True)
            _assert(not probe_call.called)
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
             "tap", "close_window", "_ax", "_cancel_menu", "_open_settings", "batch", "bind_after_verified_exit", "_ui_tables"}
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
    replacement = TargetIdentity(222, executable, (124, 456))
    for name, new, idle, exited, refused in [
        ("explicit verified lifecycle bind", replacement, "idle", True, False),
        ("handoff refuses wrong executable", TargetIdentity(222, executable + "-other", (124, 456)), "idle", True, True),
        ("handoff refuses live replacement", replacement, "recording", True, True),
        ("handoff refuses old instance still alive", replacement, "idle", False, True),
    ]:
        caller.update(_target=target, _pid=111, _app=("app", 111), _TABLES=(111, []),
                      _recording_state=lambda unused: idle)
        with patch.dict(sys.modules, {"instance_guard": sys.modules[__name__]}), \
             patch.object(os, "kill", side_effect=ProcessLookupError() if exited else None), \
             patch(__name__ + ".running_enviouswispr_instances", return_value={"222": executable}), \
             patch(__name__ + ".process_start", side_effect=lambda pid: replacement.start if pid == 222 else token):
            case(name, lambda: caller["bind_after_verified_exit"](target, new, ExitProof(target, None)), refused)
        _assert((caller["_target"], caller["_pid"], caller["_app"]) ==
                ((target, 111, ("app", 111)) if refused else (replacement, 222, ("app", 222))))
        if refused:
            _assert(caller["_TABLES"] == (111, []))
        if not refused:
            with tempfile.TemporaryDirectory(prefix="ew-handoff-tables-") as directory:
                bundle = pathlib.Path(directory) / "Replacement.app" / "Contents"
                resources = bundle / "Resources" / "de.lproj"
                resources.mkdir(parents=True)
                (resources / "Localizable.strings").write_text("private native boundary fixture")
                commands = []
                def read_native(command, **unused):
                    commands.append(command)
                    return types.SimpleNamespace(returncode=0, stderr="", stdout=(
                        str(bundle / "MacOS" / "EnviousWispr") if command[0] == "ps" else
                        json.dumps({"Start Recording": "Neue Aufnahme"})))
                caller.update(subprocess=types.SimpleNamespace(run=read_native), json=json)
                def read_replacement_tables():
                    _assert(caller["_ui_tables"]() == [{"Start Recording": "Neue Aufnahme"}])
                    _assert(caller["_TABLES"] == (222, [{"Start Recording": "Neue Aufnahme"}]))
                    _assert(commands[0][-1] == "222" and len(commands) == 2)
                case("handoff loads the replacement translation table", read_replacement_tables)
    restart_path = pathlib.Path(__file__).with_name("last_dictation_uat.py")
    restart_tree = ast.parse(restart_path.read_text())
    restart_names = {"Aborted", "wait_for", "launch_dev_app_with_endpoint"}
    restart_nodes = [node for node in restart_tree.body
                     if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in restart_names]
    _assert({node.name for node in restart_nodes} == restart_names)
    for name, peer, owner_alive, transfer in [
        ("restart caller binds the verified replacement", False, False, False),
        ("restart caller transfers the existing audio owner", False, False, True),
        ("restart caller refuses an active peer before launch", True, False, False),
        ("restart caller refuses a live old lifecycle before launch", False, True, False),
    ]:
        events, clock_state = [], {"now": 0.0}
        current_table = dict(valid) if peer else {}
        def launch_boundary(command, **kwargs):
            events.append(("launch", command, kwargs))
            current_table.clear(); current_table.update({"222": executable})
            return types.SimpleNamespace(returncode=0)
        w_subject = types.SimpleNamespace(_target=target, _recording_state=lambda new: "idle",
            bind_after_verified_exit=lambda old, new, proof: events.append(("bind", old, new, proof)))
        route_subject = types.SimpleNamespace(transfer_after_verified_exit=
            lambda new, proof: events.append(("transfer", new, proof))) if transfer else None
        namespace = {"w": w_subject, "APP_BUNDLE": executable.removesuffix("/Contents/MacOS/EnviousWispr"),
                     "time": types.SimpleNamespace(monotonic=lambda: clock_state["now"],
                       sleep=lambda seconds: clock_state.update(now=clock_state["now"] + seconds))}
        exec(compile(ast.Module(body=restart_nodes, type_ignores=[]), str(restart_path), "exec"), namespace)
        def restart_case():
            proof = ExitProof(target, None)
            try:
                result = namespace["launch_dev_app_with_endpoint"](proof, route=route_subject)
            except (InstanceGuardError, namespace["Aborted"]):
                _assert((peer or owner_alive) and not events)
                return
            _assert(not peer and not owner_alive and result is True)
            _assert(events[0] == ("launch", ["open", "-n", "--env", "EW_FAULT_INJECTION=1", namespace["APP_BUNDLE"]], {"check": True}))
            wanted = ("transfer", replacement, proof) if transfer else ("bind", target, replacement, proof)
            _assert(events[1:] == [wanted])
        with patch.dict(sys.modules, {"instance_guard": sys.modules[__name__]}), \
             patch.object(os, "kill", side_effect=None if owner_alive else ProcessLookupError()), \
             patch(__name__ + ".running_enviouswispr_instances", side_effect=lambda: dict(current_table)), \
             patch(__name__ + ".process_start", side_effect=lambda pid: replacement.start if pid == 222 else token), \
             patch.object(subprocess, "run", side_effect=launch_boundary):
            case(name, restart_case)
    learning_path = pathlib.Path(__file__).with_name("learn_from_edits_uat.py")
    learning_tree = ast.parse(learning_path.read_text())
    learning_names = {"Aborted", "app_pid", "audio_route", "finish_restore"}
    learning_nodes = [node for node in learning_tree.body
                      if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in learning_names]
    _assert({node.name for node in learning_nodes} == learning_names)
    for name, table, expected, refused in [
        ("learning caller accepts one exact app", {111: executable}, 111, False),
        ("learning caller accepts confirmed absence", {}, None, False),
        ("learning caller refuses duplicate exact apps", {111: executable, 222: executable}, None, True),
        ("learning caller refuses another bundle", {222: executable + "-other"}, None, True),
    ]:
        namespace = {"APP_BIN": executable, "running_instances": lambda: dict(table)}
        exec(compile(ast.Module(body=learning_nodes, type_ignores=[]), str(learning_path), "exec"), namespace)
        def learning_identity():
            try:
                result = namespace["app_pid"]()
            except namespace["Aborted"]:
                _assert(refused)
            else:
                _assert(not refused and result == expected)
        case(name, learning_identity)
    for audio_restored in (True, False):
        events = []
        snaps = {"launchctl": "original-env", "words": "original-bytes", "defaults": {"original": True}}
        namespace = {"w": types.SimpleNamespace(_target=target), "WORDS": "/fixture/words.json",
            "launchctl_set": lambda value: events.append(("environment", value)),
            "file_restore": lambda path, value: events.append(("file", path, value)),
            "defaults_restore": lambda value: events.append(("defaults", value)),
            "verify_restore": lambda *args: (True, "original bytes"),
            "defaults_snapshot": lambda: snaps["defaults"], "launchctl_get": lambda: snaps["launchctl"],
            "legacy_ledger_present": lambda: False}
        exec(compile(ast.Module(body=learning_nodes, type_ignores=[]), str(learning_path), "exec"), namespace)
        lifecycle = types.SimpleNamespace(launch_dev_app_with_endpoint=lambda proof: (events.append(("launch", proof)), True)[1])
        def finish_case():
            restored, _ = namespace["finish_restore"](snaps, True, True, audio_restored)
            _assert(restored is audio_restored)
            _assert(events[:3] == [("environment", "original-env"), ("file", "/fixture/words.json", "original-bytes"), ("defaults", {"original": True})])
            _assert(events[3:] == ([("launch", ExitProof(target, None))] if audio_restored else []))
        with patch.dict(sys.modules, {"instance_guard": sys.modules[__name__], "last_dictation_uat": lifecycle}), \
             patch.object(os, "kill", side_effect=ProcessLookupError()):
            case("learning restoration launch requires completed audio=" + str(audio_restored), finish_case)
    geometry_path = pathlib.Path(__file__).with_name("phase5_geometry_relaunch.py")
    geometry_tree = ast.parse(geometry_path.read_text())
    geometry_names = {"dev_pids", "stop_app", "start_app"}
    geometry_nodes = [node for node in geometry_tree.body if isinstance(node, ast.FunctionDef) and node.name in geometry_names]
    _assert({node.name for node in geometry_nodes} == geometry_names)
    for name, table, expected in [
        ("geometry stop pins one exact instance", valid, True),
        ("geometry stop refuses two exact instances", {**valid, "222": executable}, False),
        ("geometry stop refuses a different bundle", {"222": executable + "-other"}, False),
    ]:
        events = []
        rk = types.SimpleNamespace(_target=target, _active_audio_route=None,
            connect=lambda **kwargs: events.append(("connect", kwargs)))
        namespace = {"rk": rk, "pathlib": pathlib, "BUNDLE": executable.removesuffix("/Contents/MacOS/EnviousWispr"), "_EXIT_PROOF": None}
        exec(compile(ast.Module(body=geometry_nodes, type_ignores=[]), str(geometry_path), "exec"), namespace)
        lifecycle = types.SimpleNamespace(terminate_verified_dev_app=lambda why: (events.append(("terminate", why)), ExitProof(target, None))[1])
        def geometry_stop():
            _assert(namespace["stop_app"]() is expected)
            if expected:
                _assert(events[0] == ("connect", {"expected_pid": 111, "expected_executable": executable}))
                _assert(len(events) == 2 and namespace["_EXIT_PROOF"] == ExitProof(target, None))
            else:
                _assert(not events and namespace["_EXIT_PROOF"] is None)
        with patch.dict(sys.modules, {"instance_guard": sys.modules[__name__], "last_dictation_uat": lifecycle}), \
             patch(__name__ + ".running_enviouswispr_instances", return_value=table):
            case(name, geometry_stop)
    for proved in (True, False):
        events = []
        rk = types.SimpleNamespace(_target=target)
        namespace = {"rk": rk, "pathlib": pathlib, "BUNDLE": executable.removesuffix("/Contents/MacOS/EnviousWispr"),
                     "_EXIT_PROOF": ExitProof(target, None) if proved else None,
                     "require_bundle": lambda: events.append("bundle")}
        exec(compile(ast.Module(body=geometry_nodes, type_ignores=[]), str(geometry_path), "exec"), namespace)
        def launched(proof):
            _assert(proof == ExitProof(target, None))
            events.append("launch"); rk._target = replacement
            return True
        lifecycle = types.SimpleNamespace(launch_dev_app_with_endpoint=launched)
        def geometry_start():
            try:
                result = namespace["start_app"]()
            except RuntimeError:
                _assert(not proved and events == ["bundle"])
            else:
                _assert(proved and result == 222 and events == ["bundle", "launch"])
        with patch.dict(sys.modules, {"instance_guard": sys.modules[__name__], "last_dictation_uat": lifecycle}):
            case("geometry start requires exit proof=" + str(proved), geometry_start)
    fault_path = pathlib.Path(__file__).with_name("faultInjection.py")
    fault_tree = ast.parse(fault_path.read_text())
    fault_names = {"_wait_for_app_exit", "_launch_replacement", "_relaunch_app"}
    fault_nodes = [node for node in fault_tree.body if isinstance(node, ast.FunctionDef) and node.name in fault_names]
    _assert({node.name for node in fault_nodes} == fault_names)
    for name, peer, owner_alive, transfer in [
        ("fault launch preserves armed environment and binds", False, False, False),
        ("fault launch reaps then transfers audio ownership", False, False, True),
        ("fault launch refuses a competing app before spawn", True, False, False),
        ("fault launch refuses a live old process before spawn", False, True, False),
    ]:
        events, clock_state = [], {"now": 0.0}
        table = dict(valid) if peer else {}
        route = types.SimpleNamespace(finish_playback=lambda: events.append("reap"),
            transfer_after_verified_exit=lambda new, proof: events.append(("transfer", new, proof))) if transfer else None
        eyes = types.SimpleNamespace(_target=target, _active_audio_route=route,
            _recording_state=lambda new: "idle",
            bind_after_verified_exit=lambda old, new, proof: events.append(("bind", old, new, proof)))
        process = types.SimpleNamespace(pid=222, poll=lambda: None)
        environment = {"EW_FORCE_READINESS_LOST": "1", "EW_FAULT_INJECTION": "1"}
        def spawned(command, **kwargs):
            _assert(command == [executable] and kwargs["env"] == environment)
            events.append("spawn"); table.clear(); table.update({"222": executable})
            return process
        namespace = {"_import_wispr_eyes": lambda: eyes, "subprocess": subprocess,
                     "time": types.SimpleNamespace(monotonic=lambda: clock_state["now"],
                       sleep=lambda seconds: clock_state.update(now=clock_state["now"] + seconds))}
        exec(compile(ast.Module(body=fault_nodes, type_ignores=[]), str(fault_path), "exec"), namespace)
        def fault_launch():
            proof = ExitProof(target, None)
            try:
                result = namespace["_launch_replacement"](proof, environment)
            except RuntimeError:
                _assert((peer or owner_alive) and not events)
                return
            _assert(not peer and not owner_alive and result is process)
            wanted = ["reap", "spawn", ("transfer", replacement, proof)] if transfer else ["spawn", ("bind", target, replacement, proof)]
            _assert(events == wanted)
        with patch.dict(sys.modules, {"instance_guard": sys.modules[__name__]}), \
             patch.object(os, "kill", side_effect=None if owner_alive else ProcessLookupError()), \
             patch(__name__ + ".running_enviouswispr_instances", side_effect=lambda: dict(table)), \
             patch(__name__ + ".process_start", side_effect=lambda pid: replacement.start if pid == 222 else token), \
             patch.object(subprocess, "Popen", side_effect=spawned):
            case(name, fault_launch)
    for exited in (True, False):
        clock_state = {"now": 0.0}
        namespace = {"_import_wispr_eyes": lambda: types.SimpleNamespace(_target=target),
                     "time": types.SimpleNamespace(monotonic=lambda: clock_state["now"],
                       sleep=lambda seconds: clock_state.update(now=clock_state["now"] + seconds))}
        exec(compile(ast.Module(body=fault_nodes, type_ignores=[]), str(fault_path), "exec"), namespace)
        with patch.dict(sys.modules, {"instance_guard": sys.modules[__name__]}), \
             patch.object(os, "kill", side_effect=ProcessLookupError() if exited else PermissionError()), \
             patch(__name__ + ".process_start", return_value=token):
            case("fault exit probe requires native evidence=" + str(exited),
                 lambda: _assert(namespace["_wait_for_app_exit"](0.5) is exited))
    caller.update(_target=None, _pid=None, _app=None)
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
