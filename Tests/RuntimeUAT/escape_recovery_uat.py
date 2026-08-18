#!/usr/bin/env python3
"""Live UAT for Escape Recovery (#2087), driven end to end.

    python3 Tests/RuntimeUAT/escape_recovery_uat.py

Run it with the screen UNLOCKED. It configures the app, drives a real recording
through a real cancel, reads the result out of the app log and out of the target
document, then puts every setting back.

WHY THIS EXISTS RATHER THAN A CHECKLIST
---------------------------------------
The item that matters cannot be covered by a unit test at any price: #2087 §11.1
item 3 — cancel while dictating into field A, move focus to field B, press the
pill's Paste, and confirm the text lands in A. The retarget runs through
`AXUIElementSetAttributeValue` against a live app, so a test can prove the app
ASKS to be retargeted and never that the caret moved.

WAITING
-------
Every wait is on a SIGNAL the subject produces — a log line it writes, a process
it starts, a file it fills — with a deadline as the fallback, never as the
mechanism. `wait_for` returns whether the signal arrived, so an exhausted
deadline is reported as itself and never read as "the thing happened".
The handful of raw settles that remain are PHYSICAL, annotated individually, and
have no signal to wait on: the gap between two synthetic keypresses, and window
focus, which macOS acknowledges nowhere observable from here.

TWO PRECONDITIONS, BOTH CHECKED, BOTH FAIL LOUDLY
-------------------------------------------------
1. **The screen must be unlocked.** With it locked, `com.apple.loginwindow` is
   frontmost, there is no text field anywhere, and the paste cascade reports
   `tier=clipboard_only` for want of a target. The pipeline still runs and still
   logs, so the run LOOKS real and its paste verdict is worthless. Measured
   2026-08-18.
2. **The cancel key is rebound to a bare modifier for the duration.** Escape is
   registered through Carbon `RegisterEventHotKey`, and on macOS 26 WindowServer
   does not deliver synthetic presses to those — the app never sees them, which
   is why `wispr_eyes.test_cancel()` reports a failure that is about the harness
   rather than the product. A bare modifier takes the EVENT TAP path instead
   (`ShortcutBinding.isCarbonRegistrable` is false for it), which does receive
   synthetic events. The kernel records `.user(.shortcut)` either way, so this
   exercises the same production branch, and the app's own copy says the key is
   user-configurable — a different key is a supported configuration, not a test
   mode.

Every preference it touches is snapshotted first and put back in a `finally`, so
an exception or a Ctrl-C still leaves the machine as it was found — including for
a developer who had already customised the cancel shortcut. Restoring is not the
same as resetting, and an earlier revision did the second while claiming the
first.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import simulate_input as si  # noqa: E402
import wispr_eyes as w  # noqa: E402

DOMAIN = "com.enviouswispr.app.dev"
APP = os.path.join(os.path.dirname(os.path.dirname(HERE)), "build", "EnviousWispr Local.app")
LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
LCTRL = 59  # left Control, a bare modifier: the event-tap path
SENTENCE = ("The quick brown fox jumps over the lazy dog "
            "and then keeps running through the quiet field.")

results = []


class Aborted(Exception):
    """The run cannot produce a meaningful verdict, so it stops.

    Raised rather than pressing on, because the assertions after a missing
    recording all pass for the wrong reason: nothing was kept because nothing
    was said, and the target field is empty because nothing was ever going to
    fill it. A summary reading 5/9 when four of the five are vacuous is worse
    than no run at all -- it reads as evidence.
    """


def record(name, status, detail=""):
    results.append((name, status, detail))
    print(f"  {status}  {name}{('  :: ' + detail) if detail else ''}")


def check(name, ok, detail=""):
    record(name, "PASS" if ok else "FAIL", detail)
    return ok


def skip(name, detail=""):
    """Not run, and never counted as passed."""
    record(name, "SKIP", detail)


def wait_for(what, predicate, deadline=45.0, poll=0.25):
    """Wait for a signal the subject produces. Returns whether it arrived.

    The deadline is a FALLBACK, not the mechanism: exhausting it returns False
    and the caller reports a missing signal, rather than proceeding as though
    the thing had happened.
    """
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(poll)  # settle: poll interval between reads of the signal
    print(f"    (no signal: {what} within {deadline:.0f}s)")
    return False


def defaults_write(key, value, kind="-int"):
    subprocess.run(["defaults", "write", DOMAIN, key, kind, str(value)], check=True)


def defaults_delete(key):
    subprocess.run(["defaults", "delete", DOMAIN, key], check=False, capture_output=True)


# `defaults read-type` wording -> the write flag that reproduces it. Restoring
# a value without its TYPE is not restoring it: `SettingsManager` reads these
# keys with `as? Int`, `as? UInt` and `as? Bool`, every one of which fails on a
# string and falls through to the default. The key would be present, the value
# would look right in `defaults read`, and the app would ignore it.
_TYPE_FLAG = {
    "integer": "-int",
    "boolean": "-bool",
    "float": "-float",
    "string": "-string",
}


def defaults_read(key):
    """The stored value AND its property-list type, or None when absent."""
    out = subprocess.run(["defaults", "read", DOMAIN, key], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    kind = subprocess.run(
        ["defaults", "read-type", DOMAIN, key], capture_output=True, text=True)
    # "Type is integer" -> "integer". Unknown wording falls back to `-string`,
    # which is wrong for an exotic type but never worse than the untyped write
    # it replaces.
    word = kind.stdout.strip().rsplit(" ", 1)[-1] if kind.returncode == 0 else "string"
    return (out.stdout.strip(), _TYPE_FLAG.get(word, "-string"))


def snapshot(keys):
    """What was there BEFORE, so `restore` puts back rather than resets."""
    return {k: defaults_read(k) for k in keys}


def restore(before):
    """Put every key back to the value it held, deleting only what was absent.

    Deleting unconditionally would silently reset a developer's own cancel
    shortcut, which is a destructive tidy-up wearing the word "restore".
    """
    for key, captured in before.items():
        if captured is None:
            defaults_delete(key)
        else:
            value, flag = captured
            subprocess.run(["defaults", "write", DOMAIN, key, flag, value], check=False)


def screen_is_locked():
    import Quartz
    d = Quartz.CGSessionCopyCurrentDictionary()
    return bool(d.get("CGSSessionScreenIsLocked", 0)) if d else False


def log_text():
    with open(LOG, "rb") as fh:
        return fh.read().decode("utf-8", "replace")


def log_length():
    return len(log_text().splitlines())


def log_since(baseline):
    return "\n".join(log_text().splitlines()[baseline:])


def app_is_running():
    return subprocess.run(
        ["pgrep", "-f", "EnviousWispr Local.app/Contents/MacOS/EnviousWispr"],
        capture_output=True).returncode == 0


def in_flight(base):
    """Is a dictation running right now, per the app's own log?

    Ordered, not counted: whichever of the two markers appears LAST decides.
    Counting would be thrown by a rotated file that holds a terminal whose start
    it no longer carries, and would then report a live recording forever.
    """
    last = None
    for line in log_since(base).splitlines():
        if "Recording started" in line:
            last = "start"
        elif "dictation_terminal" in line:
            last = "terminal"
    return last == "start"


def ensure_stopped(base, why="", grace=0.0):
    """Leave no dictation running. Called on EVERY exit path, failures included.

    This is the fix for the 2026-08-18 leak, and the placement is the whole
    point: the stop has to happen on the path where the harness is already
    confused about what the app is doing. That is precisely the path that
    leaked, because the old code returned from it immediately.

    `grace` is for the one case where "no recording" cannot be trusted yet: the
    start signal timed out, so a take may be about to appear. Everywhere else it
    is 0, because waiting for a start that is not coming would add a pause and a
    "no signal" line to every clean run -- noise that trains the reader to skim
    exactly the output that reports a leak.

    The cancel key is pressed rather than the record key: it ends the take
    whichever branch the setting selects, and with Escape Recovery ON it is the
    branch under test anyway. It is only bound to `lctrl` while this run's
    rebind stands, so this must run BEFORE the settings are restored.
    """
    if not app_is_running():
        return True
    if not in_flight(base) and grace > 0:
        # A start can arrive after the wait for it gave up -- that is the leak.
        wait_for("a late recording start", lambda: in_flight(base), deadline=grace)
    if not in_flight(base):
        return True
    print(f"    (stopping a live recording{(': ' + why) if why else ''})")
    for _ in range(2):
        si.hold_key("lctrl", 0.12)
        if wait_for("the recording to stop", lambda: not in_flight(base), deadline=30.0):
            return True
    print("    !! a recording is STILL live and the cancel key is not reaching it.")
    print("    !! quitting the app below is the remaining stop.")
    return False


def restart_app():
    """Restart, waiting on the app's OWN readiness line rather than a guess."""
    subprocess.run(["pkill", "-f", "EnviousWispr Local.app/Contents/MacOS/EnviousWispr"],
                   check=False, capture_output=True)
    wait_for("the old instance to exit", lambda: not app_is_running(), deadline=15.0)
    base = log_length()
    subprocess.run(["open", "-n", APP], check=True)
    if not wait_for("the app to finish its startup scan",
                    lambda: "scan finished" in log_since(base), deadline=60.0):
        raise RuntimeError("app did not reach a ready state; aborting rather than guessing")


def focus(path):
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    time.sleep(1.5)  # settle: window focus; macOS exposes no observable ack for it


def new_textedit_doc(name):
    """A real foreign text field, which is the only honest paste target."""
    path = f"/tmp/ew-uat-{name}.txt"
    open(path, "w").close()
    focus(path)
    return path


def dictate_then_cancel(base):
    """Lock hands-free so the take survives the PTT debounce, speak, then cancel.

    Returns "ok", "no-start", or "no-terminal" -- three outcomes, not a bool,
    because they call for different things. A missed START aborts the phase: no
    recording means no assertion below it means anything. A missed TERMINAL is
    a real finding about the product AND a live recording to clean up.
    """
    si.hold_key("ropt", 0.05)
    time.sleep(0.09)  # settle: the double-press chain window is 500ms; this is the gap
    si.hold_key("ropt", 0.05)
    if not wait_for("recording to start",
                    lambda: "Recording started" in log_since(base), deadline=20.0):
        ensure_stopped(base, "the start signal never arrived, so the take may be late",
                       grace=5.0)
        return "no-start"
    subprocess.run(["afplay", w.tts(SENTENCE, engine="say")], timeout=60)
    si.hold_key("lctrl", 0.12)
    if not wait_for("the session to reach a terminal",
                    lambda: "dictation_terminal" in log_since(base), deadline=60.0):
        ensure_stopped(base, "the cancel did not conclude the session")
        return "no-terminal"
    return "ok"


def main():
    print("=== Escape Recovery Live UAT (#2087) ===\n")

    if screen_is_locked():
        print("REFUSING TO RUN: the screen is locked.")
        print("With it locked, loginwindow is frontmost, there is no text field to")
        print("paste into, and the run would report a meaningless paste verdict.")
        print("Unlock the screen and run again.")
        return 2

    # A dictation left live by an earlier run would be stopped by the first
    # restart below, but it would also mean somebody is mid-recording right now
    # -- say so and refuse, rather than quitting the app under them.
    if app_is_running() and in_flight(max(0, log_length() - 400)):
        print("REFUSING TO RUN: a dictation is live in the dev app right now.")
        print("Stopping it here would end a recording this run did not start.")
        return 2

    # Captured BEFORE anything is written, so the `finally` restores rather
    # than resets. A developer running this must not lose their own shortcut.
    before = snapshot(("cancelKeyCode", "cancelModifiersRaw", "escapeRecoveryEnabled"))
    print(f"prior settings: {before}")

    field_a = new_textedit_doc("field-a")
    field_b = new_textedit_doc("field-b")
    print(f"targets: A={field_a}  B={field_b}\n")

    # Bound before the try: the `finally` reads both, and an exception raised
    # before the first phase would otherwise fail INSIDE the cleanup -- losing
    # the settings restore, which is the one thing that must never be skipped.
    base = log_length()
    aborted = None

    try:
        # ---- OFF path first: the promise that covers everyone -------------
        print("[1] Setting OFF — cancel must discard, exactly as it always has")
        defaults_delete("escapeRecoveryEnabled")
        defaults_write("cancelKeyCode", LCTRL)
        # `cancelModifiersRaw`, NOT `cancelModifiers`. That is the key
        # `SettingsManager` reads and writes; the other name is read by nothing,
        # so writing it leaves any existing modifiers in place and the binding
        # stays Carbon-registrable — the exact condition the rebind exists to
        # avoid, failing only on a machine that had a customised shortcut.
        defaults_write("cancelModifiersRaw", 0)
        restart_app()

        base = log_length()
        focus(field_a)
        status = dictate_then_cancel(base)
        off = log_since(base)
        check("off: the session concluded", status == "ok",
              "" if status == "ok" else status)
        if status != "ok":
            raise Aborted(f"the OFF phase never completed a recording ({status})")
        check("off: the take is CANCELLED", "terminal cancelled" in off,
              "the disposition never leaves .ordinary with the setting off")
        check("off: nothing was kept", "escape recovery: keeping this take" not in off)
        check("off: field A is untouched", open(field_a).read().strip() == "")

        # ---- ON path: the feature -----------------------------------------
        print("\n[2] Setting ON — cancel must KEEP the dictation")
        defaults_write("escapeRecoveryEnabled", "true", kind="-bool")
        restart_app()

        base = log_length()
        focus(field_a)
        status = dictate_then_cancel(base)
        on = log_since(base)
        check("on: the session concluded", status == "ok",
              "" if status == "ok" else status)
        if status != "ok":
            raise Aborted(f"the ON phase never completed a recording ({status})")
        kept = check("on: the recovery branch fired",
                     "escape recovery: keeping this take" in on)
        check("on: delivery was SUPPRESSED, not clipboard-only",
              "tier=clipboard_only" not in on,
              "a kept take is held; nothing is pasted, nothing touches the clipboard")
        check("on: field A is still empty", open(field_a).read().strip() == "",
              "the text is HELD until the user asks for it")

        # ---- The item nothing else can cover: §11.1 item 3 -----------------
        print("\n[3] Paste with focus MOVED — the item no unit test can reach")
        if not kept:
            skip("retarget: the paste with focus moved",
                 "nothing was kept, so there is no recovery to restore")
        else:
            focus(field_b)
            w.connect()
            tapped = w.tap("Paste")
            landed = wait_for("text to land in either field",
                              lambda: bool(open(field_a).read().strip()
                                           or open(field_b).read().strip()),
                              deadline=20.0)
            a_text = open(field_a).read().strip()
            b_text = open(field_b).read().strip()
            check("retarget: the pill's Paste was reachable", bool(tapped))
            check("retarget: something was pasted", landed)
            check("retarget: text landed in the ORIGINAL field A", len(a_text) > 0,
                  f"A={a_text[:60]!r}")
            check("retarget: field B was NOT written", b_text == "",
                  f"B={b_text[:60]!r} — focus moved, so a naive paste lands here")

    except Aborted as stop:
        aborted = str(stop)

    finally:
        # Order matters: the stop presses the cancel key, which is only bound to
        # `lctrl` until `restore` puts the real binding back.
        ensure_stopped(base, "cleaning up before restoring settings")
        print("\n[restore] putting every setting back to what it was")
        restore(before)
        subprocess.run(["pkill", "-f", "EnviousWispr Local.app/Contents/MacOS/EnviousWispr"],
                       check=False, capture_output=True)

    passed = [n for n, s, _ in results if s == "PASS"]
    failed = [n for n, s, _ in results if s == "FAIL"]
    skipped = [n for n, s, _ in results if s == "SKIP"]
    print("\n" + "=" * 60)
    print(f"{len(passed)}/{len(results)} passed, "
          f"{len(failed)} failed, {len(skipped)} not run")
    for n in failed:
        print(f"  FAILED: {n}")
    for n in skipped:
        print(f"  NOT RUN: {n}")
    if aborted:
        # Said in full rather than implied by a number, because the number is
        # what misled the last reader of this script.
        print(f"\n  RUN ABORTED: {aborted}")
        print("  This is NOT a partial pass. The remaining items were never")
        print("  exercised, and no verdict about the feature follows from it.")
    print("=" * 60)
    if aborted:
        return 2
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
