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

THE SETTINGS IT BORROWS ARE THE REAL ONES
-----------------------------------------
The dev build reads the SHARED defaults domain, not its own — see `DOMAIN`
below. So this run rebinds the cancel shortcut the developer actually uses, and
handing it back correctly is a real obligation rather than tidiness. Two rules
follow, both encoded: settings are written with the app DOWN, because the app
writes its own values back and wins any race; and the app is quit BEFORE the
restore, so it cannot overwrite the restored values on the way out.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import simulate_input as si  # noqa: E402
import wispr_eyes as w  # noqa: E402
from ui_helpers import find_app_pid, find_element, get_attr, get_ax_app  # noqa: E402

# NOT `com.enviouswispr.app.dev`, however wrong that looks next to the dev
# bundle id below. `SettingsDefaults.store` redirects the DEV build to the shared
# suite for every unified key -- the cancel binding and the Escape Recovery flag
# among them -- and reads its own domain only for the one-time migration
# sentinel. Writing to the dev domain is writing where the app never looks: the
# 2026-08-18 run rebound cancel and enabled the feature there, the app read
# neither, and the "ON" phase ran with Escape Recovery OFF while reporting three
# passes. Authority: `Sources/EnviousWisprServices/SettingsDefaults.swift`.
#
# CONSEQUENCE, and it is why `restore` is not housekeeping: this domain is the
# one the developer's own installed app uses. The run borrows their real cancel
# shortcut and must hand it back exactly, type included.
DOMAIN = "com.enviouswispr.app"
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
    """Write one preference, normalising the one value shape `defaults` refuses.

    `defaults write <dom> <key> -bool 1` EXITS 255. The tool accepts only
    true/false/yes/no for `-bool`, while `defaults read` PRINTS a boolean back as
    `1`. So a value round-tripped through a snapshot is in a form the writer
    rejects, and the failure lands in two places that both matter: applying the
    ON phase, and — worse — the `finally` that restores the developer's own
    settings. Observed 2026-08-19: the restore raised here, and the founder's
    `escapeRecoveryEnabled` was left ABSENT rather than back on.

    Normalising at the single write point covers apply and restore together,
    which a fix at either call site would not.
    """
    if kind in ("-bool", "-boolean"):
        text = str(value).strip().lower()
        value = "true" if text in ("1", "true", "yes", "y", "on") else "false"
    subprocess.run(["defaults", "write", DOMAIN, key, kind, str(value)], check=True)


def domain_is_readable():
    """Whether `DOMAIN` can be read at all.

    Asked ONCE per restore rather than per key, because it is the question a
    per-key read-back cannot answer: `defaults read` fails identically for a key
    that is absent and for a domain that cannot be reached, so on its own
    "the key is gone" and "I am blind to this domain" are the same answer, and
    the second would report a successful restore having restored nothing.
    """
    return subprocess.run(
        ["defaults", "read", DOMAIN], capture_output=True).returncode == 0


def defaults_delete(key):
    """Remove one key and report whether it is ACTUALLY gone.

    Verified by reading the key back, NOT by the exit status: `defaults delete`
    exits 1 for a key that was already absent, which is a SUCCESS here, since
    restoring an absent key means leaving it absent.

    **Not by stderr either, and that was measured rather than assumed.** An
    earlier version of this treated the string "does not exist" as the
    already-absent case. Run on 2026-08-19, `defaults` emits the SAME text —
    `Domain (X) not found. Defaults have not been changed.` — for a missing key,
    a missing domain, and an unwritable path alike, so stderr cannot separate
    them and any rule built on it is a coin flip. Do not reintroduce one.

    The blindness this leaves is handled by `domain_is_readable`, called once by
    `restore`, rather than pretended away here.
    """
    subprocess.run(["defaults", "delete", DOMAIN, key], check=False, capture_output=True)
    return defaults_read(key) is None


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

    **Goes through `defaults_write` like every other write, and this line is the
    whole point of the function working at all.** It used to call `subprocess`
    directly, so it skipped the boolean normalisation that lives there: a value
    captured as `1` was handed back as `defaults write ... -bool 1`, which exits
    255. With `check=False` swallowing that, the restore FAILED SILENTLY and the
    developer's own preference was left at whatever the run had set. Measured
    2026-08-19 against the founder's `escapeRecoveryEnabled`.

    **`check=False` is kept deliberately, but no longer means "say nothing".** A
    restore must attempt EVERY key even after one fails, so an exception here
    would abandon the rest — but a failure that prints nothing is how the
    original defect stayed invisible. Each key now reports, and the function
    returns whether everything landed.
    """
    ok = True
    # The blind case, asked once and first: with an unreadable domain every
    # per-key read-back returns "absent" and the restore would report success
    # having written nothing.
    if not domain_is_readable():
        print(f"    RESTORE IMPOSSIBLE: cannot read {DOMAIN} at all")
        return False
    for key, captured in before.items():
        try:
            if captured is None:
                if not defaults_delete(key):
                    raise RuntimeError(
                        f"{key} was absent before this run and will not delete now")
            else:
                value, flag = captured
                defaults_write(key, value, kind=flag)
        except Exception as failure:  # noqa: BLE001 — every key still gets a turn
            ok = False
            print(f"    RESTORE FAILED for {key}: {failure}")
            print(f"    the developer's own {key} is NOT back to what it was")
    # Read back what was just written. An exit status of 0 says the command ran,
    # not that the value is there — the distinction this whole class of defect
    # keeps turning on.
    for key, captured in before.items():
        now = defaults_read(key)
        # The WHOLE tuple, value AND plist type. `defaults_read` returns both and
        # an earlier version compared only the value, which passes a restore that
        # changed the TYPE while printing the same text: `escapeRecoveryEnabled`
        # captured as integer 1 and handed back as boolean true reads "1" either
        # way. The developer is left with a preference of the wrong type, the app
        # may read it differently, and the run reports success.
        if now != captured:
            ok = False
            print(f"    RESTORE DID NOT TAKE for {key}: wanted {captured!r}, reads {now!r}")
    if not ok:
        print("    !! at least one preference was not restored — check it by hand")
    return ok


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


def stop_app():
    """Down, and confirmed down.

    Separate from `start_app` so settings can be written while the app is NOT
    running. `SettingsManager` writes its own values back on change, so a write
    made underneath a live app is a race against it, and the app wins on quit.
    """
    # check=False BY DESIGN and the result is deliberately dropped: `pkill`
    # exits 1 when nothing matched, which is the ordinary case here — the app
    # may already be down. The OUTCOME is what matters and it is verified
    # separately by `app_is_running`, not by this call's status.
    subprocess.run(["pkill", "-f", "EnviousWispr Local.app/Contents/MacOS/EnviousWispr"],
                   check=False, capture_output=True)
    if not wait_for("the old instance to exit", lambda: not app_is_running(), deadline=15.0):
        # FAIL CLOSED. The old code discarded this answer, so an app that
        # ignored or outran SIGTERM left every later step operating under a live
        # instance: settings written underneath it, a second instance launched
        # beside it, and a restore it could overwrite on its own way out. The
        # method's name claims the app is stopped, so it has to be true or raise.
        raise Aborted("the dev app did not exit within 15s; refusing to touch settings under it")


def start_app():
    """Up, waiting on the app's OWN readiness line rather than a guess."""
    base = log_length()
    subprocess.run(["open", "-n", APP], check=True)
    if not wait_for("the app to finish its startup scan",
                    lambda: "scan finished" in log_since(base), deadline=60.0):
        raise RuntimeError("app did not reach a ready state; aborting rather than guessing")


def apply_settings(pairs, label):
    """Write settings with the app DOWN, then prove they are what we asked for.

    The read-back is the check the 2026-08-18 run did not have. It cannot prove
    the app honoured them -- nothing observable from here can -- but it does
    prove the values are in the domain the app reads, which is exactly what was
    wrong that night and silently so.
    """
    stop_app()
    for key, value, kind in pairs:
        if value is None:
            defaults_delete(key)
        else:
            defaults_write(key, value, kind=kind)
    wrong = []
    for key, value, _ in pairs:
        got = defaults_read(key)
        if value is None:
            if got is not None:
                wrong.append(f"{key}={got[0]!r}, expected absent")
        elif got is None:
            wrong.append(f"{key} is absent, expected {str(value)!r}")
        elif got[0] != str(value):
            wrong.append(f"{key}={got[0]!r}, expected {str(value)!r}")
    if wrong:
        raise Aborted(f"{label}: settings did not take -- " + "; ".join(wrong))
    start_app()


def field_text(path):
    """What the DOCUMENT holds. The file on disk is not the oracle.

    TextEdit keeps an unsaved document in memory, so the file stays empty
    however much text is pasted into it. The 2026-08-18 run read the file and
    reported "field A is still empty -- the text is HELD until the user asks for
    it" in the same second the app logged
    `Paste cascade: tier=ax_direct, app=com.apple.TextEdit`. Every paste
    assertion in this harness was unfalsifiable: the empty answer it wanted was
    the only answer it could ever get.

    **Returns None for CANNOT READ and "" only for GENUINELY EMPTY, because
    collapsing the two rebuilds that same defect one layer up.** Without
    Accessibility authorisation, or with a window title that does not match, or
    an editor that exposes no text area, every lookup fails to "" — and "" is
    exactly what the held-text assertions want to see. A successful product
    paste would be reported as a product failure, and an invalid run would be
    reported as a passing one. `readable` turns that into a loud refusal.
    """
    pid = find_app_pid("TextEdit")
    if pid is None:
        return None
    want = os.path.basename(path)
    app = get_ax_app(pid)
    for window in (get_attr(app, "AXWindows") or []):
        if str(get_attr(window, "AXTitle") or "") != want:
            continue
        area = find_element(window, role="AXTextArea")
        if area is None:
            return None
        return str(get_attr(area, "AXValue") or "")
    return None


def focus(path):
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    time.sleep(1.5)  # settle: window focus; macOS exposes no observable ack for it


def new_textedit_doc(name):
    """A real foreign text field, which is the only honest paste target."""
    path = f"/tmp/ew-uat-{name}.txt"
    open(path, "w").close()
    focus(path)
    return path


def readable(path, label):
    """The document's text, or an ABORT — never a silent empty string.

    Every held-text assertion in this run wants to see "", so an unreadable
    field would satisfy them all while proving nothing. Refusing here is the
    difference between "the feature held the text" and "we could not look".
    """
    text = field_text(path)
    if text is None:
        raise Aborted(
            f"{label}: could not read the document through accessibility. "
            "Not an empty field — an unreadable one, and every assertion below "
            "would have passed on it.")
    return text


def verify_can_read(path):
    """Prove the field oracle WORKS before any verdict depends on it.

    Thirty seconds at the start, and it is the difference between a run that
    reports a product failure and a run that reports its own blindness. Writes
    a known string into the document through the same route a paste would take,
    reads it back through the oracle, then clears it.
    """
    marker = "ew-uat-oracle-check"
    focus(path)
    si.type_text(marker)
    got = wait_for("the oracle to read back what we just typed",
                   lambda: (field_text(path) or "").strip().endswith(marker),
                   deadline=10.0)
    # Leave the document as we found it whatever happened, so a failed control
    # does not poison the assertions that follow it.
    w.press_key("a", cmd=True)
    w.press_key("delete")
    return got


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
    # THE SPEECH HAS TO ACTUALLY PLAY, and this used to fail open.
    #
    # `afplay` ran with no `check`, so a missing file, an empty synthesis or a
    # busy audio device produced NO sound and no complaint. The recorder then
    # captured silence, the pipeline concluded `noSpeech`, and the run reported
    # that the recovery branch never fired — a PRODUCT verdict from a harness
    # that never spoke. Measured by hand 2026-08-19, where it cost two runs and
    # a wrong diagnosis before the log said `noSpeech`.
    #
    # Checked in both directions: the clip must exist and be big enough to be
    # speech rather than a header, and playback must exit cleanly.
    clip = w.tts(SENTENCE, engine="say")
    size = os.path.getsize(clip) if os.path.exists(clip) else 0
    if size < 8192:
        raise Aborted(f"the speech clip is missing or too small to be speech ({size} bytes at {clip})")
    subprocess.run(["afplay", clip], timeout=60, check=True)
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

    # ORDER: the in-flight refusal comes FIRST. The migration launch below
    # starts an instance and then stops every one of them, so running it
    # ahead of this check would kill a developer's live recording — the
    # exact thing the check exists to prevent, done by the step that runs
    # before it.
    # A dictation left live by an earlier run would be stopped by the first
    # restart below, but it would also mean somebody is mid-recording right now
    # -- say so and refuse, rather than quitting the app under them.
    if app_is_running() and in_flight(max(0, log_length() - 400)):
        print("REFUSING TO RUN: a dictation is live in the dev app right now.")
        print("Stopping it here would end a recording this run did not start.")
        return 2

    # THE ONE-TIME SETTINGS MIGRATION MUST RUN BEFORE WE SNAPSHOT ANYTHING.
    #
    # On a dev install that has not yet migrated, `SettingsDefaultsMigration`
    # runs at startup and rewrites the shared domain FROM the dev domain: an
    # explicit dev value overwrites ours, and a key the dev store lacks CLEARS
    # ours. So a snapshot-then-launch order reads and verifies values that the
    # very next launch discards, and the run proceeds against settings it never
    # checked — the same silent wrong-settings failure this harness already had
    # once, arriving by a different road.
    #
    # Burning one launch is the cheap fix: the sentinel lives in the DEV domain,
    # so after one startup the migration is done for good.
    sentinel = subprocess.run(
        ["defaults", "read", "com.enviouswispr.app.dev", "didYieldToSharedDefaults_v1"],
        capture_output=True, text=True)
    if sentinel.returncode != 0:
        print("[migration] first launch since settings unification — running it before snapshotting")
        start_app()
        stop_app()

    # Captured BEFORE anything is written, so the `finally` restores rather
    # than resets. A developer running this must not lose their own shortcut.
    before = snapshot(("cancelKeyCode", "cancelModifiersRaw", "escapeRecoveryEnabled"))
    print(f"prior settings: {before}")

    field_a = new_textedit_doc("field-a")
    field_b = new_textedit_doc("field-b")
    print(f"targets: A={field_a}  B={field_b}")

    # The AX connection has to exist before the oracle control, not only before
    # the retarget phase below. `verify_can_read` clears the document with
    # `w.press_key`, and every `w.*` entry point guards on `_ensure_connected`,
    # so without this the control aborts the whole run with "Not connected" —
    # BEFORE it has proven anything, and while reporting nothing about the
    # product. Connecting here rather than inside the control keeps the later
    # reconnect at the retarget phase meaningful: that one re-attaches after
    # focus has moved, which is a different thing from attaching at all.
    w.connect()

    # Before any verdict depends on reading a field, prove we CAN read one.
    # Without this the run cannot tell "the feature held the text" from "the
    # harness cannot see", and those two produce identical output.
    if not verify_can_read(field_a):
        print("REFUSING TO RUN: cannot read a TextEdit document through accessibility.")
        print("Every held-text assertion would pass on that, proving nothing.")
        print("Check that this Python has Accessibility authorization.")
        return 2
    print("[control] the field oracle reads back what is typed into it\n")

    # Bound before the try: the `finally` reads both, and an exception raised
    # before the first phase would otherwise fail INSIDE the cleanup -- losing
    # the settings restore, which is the one thing that must never be skipped.
    base = log_length()
    aborted = None
    # Assumed FAILED until the restore says otherwise, so a path that never
    # reaches the cleanup cannot report clean settings by omission.
    restored = False

    try:
        # ---- OFF path first: the promise that covers everyone -------------
        print("[1] Setting OFF — cancel must discard, exactly as it always has")
        # `cancelModifiersRaw`, NOT `cancelModifiers`. That is the key
        # `SettingsManager` reads and writes; the other name is read by nothing,
        # so writing it leaves any existing modifiers in place and the binding
        # stays Carbon-registrable — the exact condition the rebind exists to
        # avoid, failing only on a machine that had a customised shortcut.
        apply_settings([
            ("escapeRecoveryEnabled", None, None),
            ("cancelKeyCode", LCTRL, "-int"),
            ("cancelModifiersRaw", 0, "-int"),
        ], "OFF phase")

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
        check("off: field A is untouched", readable(field_a, "off").strip() == "")

        # ---- ON path: the feature -----------------------------------------
        print("\n[2] Setting ON — cancel must KEEP the dictation")
        apply_settings([("escapeRecoveryEnabled", 1, "-bool")], "ON phase")

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
        check("on: field A is still empty", readable(field_a, "on").strip() == "",
              "the text is HELD until the user asks for it")

        # ---- The item nothing else can cover: §11.1 item 3 -----------------
        print("\n[3] Paste with focus MOVED — the item no unit test can reach")
        if not kept:
            skip("retarget: the paste with focus moved",
                 "nothing was kept, so there is no recovery to restore")
        else:
            focus(field_b)
            w.connect()
            # The pill's button, whose label the founder renamed on 2026-08-18.
            # Matched by TEXT, so a copy change breaks it silently and the
            # failure reads as "the pill was unreachable" rather than "the label
            # moved" -- keep this in step with
            # `DictationNarrator.escapeRecoveryPillAction`.
            tapped = w.tap("Undo")
            landed = wait_for("text to land in either field",
                              lambda: bool((field_text(field_a) or "").strip()
                                           or (field_text(field_b) or "").strip()),
                              deadline=20.0)
            a_text = readable(field_a, "retarget A").strip()
            b_text = readable(field_b, "retarget B").strip()
            check("retarget: the pill's Paste was reachable", bool(tapped))
            check("retarget: something was pasted", landed)
            check("retarget: text landed in the ORIGINAL field A", len(a_text) > 0,
                  f"A={a_text[:60]!r}")
            check("retarget: field B was NOT written", b_text == "",
                  f"B={b_text[:60]!r} — focus moved, so a naive paste lands here")

    except Aborted as stop:
        aborted = str(stop)

    finally:
        # THREE STEPS, AND THE ORDER IS LOAD-BEARING IN BOTH DIRECTIONS.
        #
        # Stop the recording FIRST: the cancel key it presses is only bound to a
        # bare modifier until the real binding goes back, so a restore-first
        # cleanup could not end a take.
        #
        # Quit the app SECOND, BEFORE restoring. `SettingsManager` writes its
        # in-memory values back to this domain, and this domain is the one the
        # developer's own app reads. Restoring under a live app hands it the
        # right values and then lets it overwrite them on the way out -- the
        # cleanup would be what destroys their cancel shortcut.
        # NESTED, so the restore cannot be skipped by a failure above it.
        # Flat, the promise in this file's header was false: an exception inside
        # `ensure_stopped` -- a log read, a synthetic keypress -- escaped the
        # `finally` before the settings went back, and these are the developer's
        # REAL settings. The stop and the quit are best-effort; the restore is
        # not optional.
        # Whether the app is CONFIRMED down. A restore written underneath a live
        # app is a race this harness loses: `SettingsManager` writes its own
        # values back on quit and wins, so a "successful" restore would be
        # silently undone minutes later. `stop_app` raises when the process
        # outlives its deadline, and the handler below only PRINTS that, so
        # without this flag the restore reported success from exactly that state.
        app_down = False
        try:
            try:
                ensure_stopped(base, "cleaning up before quitting")
            finally:
                stop_app()
            app_down = True
        except Exception as cleanup_error:  # noqa: BLE001 - reported, never swallowed
            print(f"    (cleanup problem, restoring anyway: {cleanup_error})")
        finally:
            print("\n[restore] putting every setting back to what it was")
            # The RESULT is read. `restore` reporting a failure that nothing
            # consumes is an instrument nobody looks at: the run would print its
            # normal summary and exit 0 while the developer's real preferences
            # sat modified. Deliberately NOT raised from this `finally` — that
            # would swallow whatever exception is already in flight, which is the
            # very thing the nested try above exists to prevent. It travels as a
            # flag and lands on the exit status instead.
            restored = restore(before)
            if not app_down:
                # Attempted anyway — a restore that might be undone still beats
                # not trying — but it cannot be REPORTED as done.
                print("    The app was not confirmed down, so anything written")
                print("    just now can be overwritten by it on quit. Treating")
                print("    the restore as UNVERIFIED rather than successful.")
                restored = False

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
    if not restored:
        # Loudest line in the summary, and it outranks the test verdicts: a green
        # run that left the developer's own shortcut rebound is worse than a red
        # one, because nothing else will ever mention it again.
        print("\n  SETTINGS NOT RESTORED. Your own preferences may still be")
        print("  changed by this run. The keys it borrows are cancelKeyCode,")
        print("  cancelModifiersRaw and escapeRecoveryEnabled in")
        print(f"  {DOMAIN} — check them before trusting anything above.")
        print("=" * 60)
        return 3
    if aborted:
        return 2
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
