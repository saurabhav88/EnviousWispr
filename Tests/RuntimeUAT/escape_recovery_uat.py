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


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}{('  :: ' + detail) if detail else ''}")
    return ok


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
    """Lock hands-free so the take survives the PTT debounce, speak, then cancel."""
    si.hold_key("ropt", 0.05)
    time.sleep(0.09)  # settle: the double-press chain window is 500ms; this is the gap
    si.hold_key("ropt", 0.05)
    if not wait_for("recording to start",
                    lambda: "Recording started" in log_since(base), deadline=20.0):
        return False
    subprocess.run(["afplay", w.tts(SENTENCE, engine="say")], timeout=60)
    si.hold_key("lctrl", 0.12)
    return wait_for("the session to reach a terminal",
                    lambda: "dictation_terminal" in log_since(base), deadline=60.0)


def main():
    print("=== Escape Recovery Live UAT (#2087) ===\n")

    if screen_is_locked():
        print("REFUSING TO RUN: the screen is locked.")
        print("With it locked, loginwindow is frontmost, there is no text field to")
        print("paste into, and the run would report a meaningless paste verdict.")
        print("Unlock the screen and run again.")
        return 2

    # Captured BEFORE anything is written, so the `finally` restores rather
    # than resets. A developer running this must not lose their own shortcut.
    before = snapshot(("cancelKeyCode", "cancelModifiersRaw", "escapeRecoveryEnabled"))
    print(f"prior settings: {before}")

    field_a = new_textedit_doc("field-a")
    field_b = new_textedit_doc("field-b")
    print(f"targets: A={field_a}  B={field_b}\n")

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
        reached = dictate_then_cancel(base)
        off = log_since(base)
        check("off: the session concluded", reached)
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
        reached = dictate_then_cancel(base)
        on = log_since(base)
        check("on: the session concluded", reached)
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
            check("retarget: skipped", False, "no recovery to restore")
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

    finally:
        print("\n[restore] putting every setting back to what it was")
        restore(before)
        subprocess.run(["pkill", "-f", "EnviousWispr Local.app/Contents/MacOS/EnviousWispr"],
                       check=False, capture_output=True)

    failed = [n for n, ok, _ in results if not ok]
    print("\n" + "=" * 60)
    print(f"{len(results) - len(failed)}/{len(results)} passed")
    for n in failed:
        print(f"  FAILED: {n}")
    print("=" * 60)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
