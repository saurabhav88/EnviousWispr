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
    out = subprocess.run(["ps", "-eww", "-o", "pid=,comm="],
                         capture_output=True, text=True).stdout
    me = str(os.getpid())
    found = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        pid, exe = line.strip().split(None, 1)
        if pid == me:
            continue
        # An EXACT suffix, so the app's own XPC service and `llama-server` - both
        # inside the same bundle and both in this listing - are excluded.
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
    found = running_enviouswispr_instances()
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
        # Same bundle, sibling executables. `comm` lists them, and an EXACT
        # suffix is what keeps them out of the count; a substring test would
        # treble every instance.
        ("the app's own XPC service and llama-server are not instances", ONE + [
            "  555 /Users/x/EW/build/EnviousWispr Local.app/Contents/XPCServices"
            "/EnviousWisprASRService.xpc/Contents/MacOS/EnviousWisprASRService",
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
