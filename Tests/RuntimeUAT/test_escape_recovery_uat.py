#!/usr/bin/env python3
"""Control for the Escape Recovery UAT harness itself.

    python3 Tests/RuntimeUAT/test_escape_recovery_uat.py

A HARNESS CONTRACT test, in the sense of testing-philosophy.md
RULE: every-test-declares-which-of-four-things-it-protects. It protects the
INSTRUMENT and must never be counted as product coverage: nothing here says
anything about whether Escape Recovery works.

NOTHING RUNS THIS AUTOMATICALLY. It needs no app, no screen and no audio, so it
is cheap to run by hand, but no CI job invokes it -- stated rather than implied,
because a suite no gate invokes reports nothing.

WHAT IT EXISTS FOR
------------------
The UAT started a dictation and, on the path where its start signal timed out,
returned without stopping it. The recording kept running and the founder ended
it by hand (2026-08-18). Every row below asserts the OUTCOME that report was
about -- is a recording left running -- rather than that some function was
called, and the last row is a two-way control: remove the grace window and the
late take is missed again, which is the old shape exactly.
"""
import sys, types, pathlib

# THIS file's directory, never a hardcoded one. It used to name
# `EnviousWispr-escape-recovery`, a worktree that has since been deleted, and the
# test kept passing only because Python puts a script's own directory on the path
# anyway. Harmless while that path is absent; a silent wrong-subject test the
# moment a stale copy exists there, since the import would resolve to ANOTHER
# checkout's harness while the report named this one.
HERE = str(pathlib.Path(__file__).resolve().parent)
sys.path.insert(0, HERE)

# The real ones need PyObjC and a live app; the subject under test is the
# harness's control flow, not the key-posting.
presses = []
si = types.ModuleType("simulate_input")
si.hold_key = lambda key, dur: presses.append(key)
sys.modules["simulate_input"] = si
# `ui_helpers` imports ApplicationServices at module scope, so importing the
# harness pulls in PyObjC transitively and this "needs no app, no screen"
# control would die on a plain Python before a single row ran. Stubbed for the
# same reason the two live-only modules above are.
uh = types.ModuleType("ui_helpers")
uh.find_app_pid = lambda *a, **k: None
uh.find_element = lambda *a, **k: None
uh.get_attr = lambda *a, **k: None
uh.get_ax_app = lambda *a, **k: None
sys.modules["ui_helpers"] = uh

w = types.ModuleType("wispr_eyes")
w.tts = lambda *a, **k: "/dev/null"
w.connect = lambda *a, **k: None
w.tap = lambda *a, **k: True
w._text_visible = lambda *a, **k: False
w.press_key = lambda *a, **k: None
sys.modules["wispr_eyes"] = w

import escape_recovery_uat as uat

LOG = []          # the fake app log, newest last
RUNNING = [True]  # is the dev app up

uat.log_text = lambda: "\n".join(LOG)
uat.app_is_running = lambda: RUNNING[0]

fails = []
def ok(name, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}{('  :: ' + detail) if detail else ''}")
    if not cond:
        fails.append(name)

START = "[Pipeline] Recording started. Backend: parakeet"
TERM = "[Telemetry] dictation_terminal result=cancelled"

print("in_flight")
LOG[:] = []
ok("an empty log is not in flight", not uat.in_flight(0))
LOG[:] = [START]
ok("a start with no terminal IS in flight", uat.in_flight(0))
LOG[:] = [START, TERM]
ok("a start then a terminal is not", not uat.in_flight(0))
LOG[:] = [TERM, START]
ok("ORDER decides, not the count", uat.in_flight(0),
   "a rotated log holding an orphan terminal must not read as idle forever")
LOG[:] = [START, TERM, START, TERM]
ok("two complete sessions are not in flight", not uat.in_flight(0))

print("\nensure_stopped")
LOG[:] = [START]
presses.clear()
# The cancel press ends it: model that by appending the terminal the app writes.
_orig = si.hold_key
def cancel_works(key, dur):
    presses.append(key)
    if key == "lctrl":
        LOG.append(TERM)
si.hold_key = cancel_works
ok("a live recording is stopped", uat.ensure_stopped(0) is True)
ok("and the CANCEL key is what stopped it", presses == ["lctrl"], f"pressed {presses}")

LOG[:] = [START, TERM]
presses.clear()
ok("an idle app is left alone", uat.ensure_stopped(0) is True)
ok("with no keypress at all", presses == [], f"pressed {presses}")

RUNNING[0] = False
LOG[:] = [START]
presses.clear()
ok("a dead app needs no keypress", uat.ensure_stopped(0) is True and presses == [])
RUNNING[0] = True

# THE REGRESSION ITSELF: a start that arrives after the wait gave up.
si.hold_key = _orig
LOG[:] = []
presses.clear()
import time as _time


class LateStart:
    """The start appears after a DELAY, which is what a late take is.

    An earlier version of this control keyed on the read COUNT and was useless:
    `ensure_stopped` reads the log twice by construction, so the start landed on
    the second read whatever the grace window was, and the row measured the stub
    rather than the code. Time is the axis the grace window is about, so time is
    what the control has to vary.
    """
    def __init__(self, after=2.0):
        self.due = _time.monotonic() + after
    def __call__(self):
        lines = list(LOG)
        if _time.monotonic() >= self.due and START not in lines:
            LOG.append(START)
            lines = list(LOG)
        return "\n".join(lines)
uat.log_text = LateStart()
def cancel_works2(key, dur):
    presses.append(key)
    if key == "lctrl":
        LOG.append(TERM)
si.hold_key = cancel_works2
stopped = uat.ensure_stopped(0, "late", grace=5.0)
ok("a LATE start is caught and stopped", stopped is True,
   "this is the 2026-08-18 leak: the founder found this recording still running")
ok("the late take was cancelled, not left", presses == ["lctrl"], f"pressed {presses}")

# MUTATION CONTROL: without the grace window the late start is missed, which is
# precisely the old behaviour. If this row does NOT report a leak, the grace
# window is decorative and the fix is not doing the work.
uat.log_text = LateStart()
LOG[:] = []
presses.clear()
missed = uat.ensure_stopped(0, "late", grace=0.0)
ok("control: with grace=0 the late take IS missed", missed is True and presses == [],
   "the old code's shape -- returns 'nothing to stop' while a take is starting")

print("\nDOMAIN is bound to the app's own authority")
import re, pathlib as _pl
_src = _pl.Path(__file__).resolve().parents[2] / "Sources/EnviousWisprServices/SettingsDefaults.swift"
_m = re.search(r'sharedSuite\s*=\s*"([^"]+)"', _src.read_text())
ok("the authority was readable", bool(_m),
   "a silent miss here would make the row below pass on nothing")
ok("the harness writes where the dev build READS", _m and uat.DOMAIN == _m.group(1),
   f"harness={uat.DOMAIN!r} authority={_m.group(1) if _m else None!r}")

print("\napply_settings read-back")
# The guard that would have caught the wrong-domain bug. Stubbed at the process
# boundary: what is under test is whether a value that did not land ABORTS.
# Held BEFORE stubbing, because a later row tests `stop_app` ITSELF and a stub
# left in place would make that row exercise the stub. It did, on the first run:
# the guard reported as absent while it was working perfectly, which is the
# "assertion never reaches its subject" failure in the harness rather than the
# product. The row failing is what surfaced it.
REAL_STOP_APP = uat.stop_app
uat.stop_app = lambda: None
uat.start_app = lambda: None
STORE = {}
uat.defaults_write = lambda k, v, kind="-int": STORE.__setitem__(k, (str(v), kind))
uat.defaults_delete = lambda k: STORE.pop(k, None)
uat.defaults_read = lambda k: STORE.get(k)

STORE.clear()
try:
    uat.apply_settings([("cancelKeyCode", 59, "-int"),
                        ("escapeRecoveryEnabled", None, None)], "row")
    ok("settings that land are accepted", True)
except uat.Aborted as e:
    ok("settings that land are accepted", False, str(e))

# The real defect: written to a domain nothing reads, so the read-back is empty.
STORE.clear()
uat.defaults_write = lambda k, v, kind="-int": None  # the write goes nowhere
try:
    uat.apply_settings([("cancelKeyCode", 59, "-int")], "row")
    ok("a write that goes nowhere ABORTS", False,
       "this is the 2026-08-18 wrong-domain bug -- it must never pass silently")
except uat.Aborted as e:
    ok("a write that goes nowhere ABORTS", True, str(e))

# And the opposite: a key that should be gone but is not.
STORE.clear()
STORE["escapeRecoveryEnabled"] = ("1", "-bool")
uat.defaults_delete = lambda k: None  # the delete goes nowhere
try:
    uat.apply_settings([("escapeRecoveryEnabled", None, None)], "row")
    ok("a delete that goes nowhere ABORTS", False,
       "a restore-to-default row would then leave the previous value in place")
except uat.Aborted as e:
    ok("a delete that goes nowhere ABORTS", True, str(e))

print("\nunreadable is not empty")
# The review finding, as a control. Every held-text assertion WANTS to see "",
# so a lookup that fails to "" satisfies all of them while proving nothing.
uat.field_text = lambda path: None
try:
    uat.readable("/tmp/whatever", "row")
    ok("an unreadable field ABORTS", False, "it would have passed as 'empty'")
except uat.Aborted as e:
    ok("an unreadable field ABORTS", True, str(e)[:70])

uat.field_text = lambda path: ""
try:
    ok("a genuinely empty field is returned, not refused", uat.readable("/tmp/x", "row") == "")
except uat.Aborted as e:
    ok("a genuinely empty field is returned, not refused", False, str(e))

uat.field_text = lambda path: "hello"
ok("control: text comes back unchanged", uat.readable("/tmp/x", "row") == "hello")

print("\nstop_app fails closed")
import subprocess as _sp
_real_run = _sp.run
_sp.run = lambda *a, **k: None
uat.stop_app = REAL_STOP_APP   # the subject, not the stub an earlier row installed
RUNNING[0] = True   # never dies, whatever we send it
try:
    uat.stop_app()
    ok("an app that will not exit ABORTS", False,
       "settings would then be written under a live app, which overwrites them on quit")
except uat.Aborted as e:
    ok("an app that will not exit ABORTS", True, str(e)[:70])
RUNNING[0] = False  # exits promptly
try:
    uat.stop_app()
    ok("control: an app that does exit is fine", True)
except uat.Aborted as e:
    ok("control: an app that does exit is fine", False, str(e))
_sp.run = _real_run

# ---------------------------------------------------------------------------
# The restore PROPERTY, added 2026-08-19 after four consecutive review findings
# in one place.
#
# Every one of those was a check that verified PART of the outcome and looked
# like it verified all of it: the exit status but not the value, the value but
# not the plist type, the write but not whether the app was down to receive it.
# Adding a fifth clause would have been the same mistake again, so this asserts
# the WHOLE property instead:
#
#     restore(before) returning True implies the domain now equals `before`
#     for every key it was given — same value, same type, same presence.
#
# Swept over the cross-product of starting states and the ways a run can disturb
# them, rather than over cases someone thought of.
# ---------------------------------------------------------------------------

def test_restore_property():
    import importlib, itertools, subprocess
    import escape_recovery_uat as _stubbed

    # RELOAD FIRST. The rows above replace `defaults_write`, `defaults_delete`
    # and `defaults_read` with in-memory fakes and never restore them, so a test
    # written after them measures the stubs rather than the harness — the exact
    # wrong-subject failure this whole file exists to catch. Caught here by the
    # property failing 36/36 with "cannot read domain at all" rather than by
    # anyone noticing the stubs.
    harness = importlib.reload(_stubbed)

    probe = "com.enviouswispr.propertyprobe"
    saved_domain, harness.DOMAIN = harness.DOMAIN, probe

    starts = [None, ("1", "-int"), ("1", "-bool"), ("0", "-bool"),
              ("53", "-int"), ("dark", "-string")]
    disturbances = {
        "leave": None,
        "delete": None,
        "to-int-1": ("-int", "1"),
        "to-bool-true": ("-bool", "true"),
        "to-string-dark": ("-string", "dark"),
        "to-int-999": ("-int", "999"),
    }

    def put(state):
        subprocess.run(["defaults", "delete", probe, "k"], capture_output=True)
        if state is not None:
            # Through the harness's own writer: a raw `defaults write ... -bool 1`
            # exits 255, which is the defect this file now guards. The first
            # version of this test wrote raw and died on it.
            harness.defaults_write("k", state[0], kind=state[1])

    harness.defaults_write("bystander", "7", kind="-int")  # keeps the domain readable
    violations = []
    try:
        for start, how in itertools.product(starts, disturbances):
            put(start)
            before = {"k": harness.defaults_read("k")}
            if how == "delete":
                subprocess.run(["defaults", "delete", probe, "k"], capture_output=True)
            elif how != "leave":
                kind, val = disturbances[how]
                harness.defaults_write("k", val, kind=kind)
            claimed = harness.restore(before)
            after = harness.defaults_read("k")
            if claimed and after != before["k"]:
                violations.append(("claimed success but differs", start, how, before["k"], after))
            if not claimed and after == before["k"]:
                violations.append(("false alarm", start, how, before["k"], after))
    finally:
        subprocess.run(["defaults", "delete", probe], capture_output=True)
        harness.DOMAIN = saved_domain

    ok("restore: a claimed success always means the domain matches what was captured",
          not violations,
          "" if not violations else f"{len(violations)} violation(s): {violations[:3]}")


test_restore_property()

# ---- #3437: the Undo-through-the-cascade checks --------------------------------------------
# HARNESS CONTRACT rows: each pairs a correct outcome with near-identical wrong ones, and requires
# the wrong ones to FAIL through the harness's own `verify_undo`, never a re-implementation of it.
print("\n#3437 undo checks")

HELD = "The quick brown fox jumps over the lazy dog."
LEGACY = HELD + " "


def verdicts(**overrides):
    """Runs `verify_undo` on a correct key-paste Undo with `overrides` applied; returns the
    names of the checks it FAILED."""
    args = dict(
        name="u", window=("[EscapeRecovery] escape recovery restore: outcome=pasted age_ms=10 take=t1\n"
                          "[PipelineTiming] Paste cascade: tier=cgevent, app=com.example.panel, duration=3ms"),
        field_value=LEGACY, expected=LEGACY,
        others={"panel field B": ("", "")},
        board=uat.SENTINEL, board_expected=uat.expected_clipboard("cgevent", True, HELD),
        bundle="com.example.panel", route="cgevent", notice_expected=False)
    args.update(overrides)
    uat.results.clear()
    uat.verify_undo(**args)
    return [n for n, status, _ in uat.results if status == "FAIL"]


ok("a correct key-paste Undo passes every check", verdicts() == [], str(verdicts()))
for label, field in [("wrong text", "The quick brown fox. "), ("missing trailing space", HELD),
                     ("extra space", " " + LEGACY), ("changed casing", LEGACY.lower()),
                     ("duplicate insertion", LEGACY + LEGACY)]:
    ok(f"a field with {label} fails", any("original field" in n for n in verdicts(field_value=field)))
ok("a written sentinel field fails",
   any("panel field B" in n for n in verdicts(others={"panel field B": ("x", "")})))
ok("a missing restore line fails",
   any("one restore" in n for n in verdicts(window="Paste cascade: tier=cgevent, app=com.example.panel,")))
ok("a delivery into another app fails",
   any("delivered by tier" in n for n in verdicts(
       window="escape recovery restore: outcome=pasted age_ms=1 take=t\n"
              "Paste cascade: tier=cgevent, app=com.apple.TextEdit,")))
ok("a Copied notice where none belongs fails",
   any("no Copied notice" in n for n in verdicts(
       window="escape recovery restore: outcome=pasted age_ms=1 take=t\n"
              "Paste cascade: tier=cgevent, app=com.example.panel,\n"
              "ESCAPE_RECOVERY_NOTICE shown=true why=presented")))
ok("a wrong clipboard fails", any("clipboard" in n for n in verdicts(board=LEGACY)))

gone = dict(window=("escape recovery restore: outcome=clipboard_only age_ms=1 take=t\n"
                    "Paste cascade: tier=clipboard_only, app=com.apple.TextEdit,\n"
                    "ESCAPE_RECOVERY_NOTICE shown=true why=presented"),
            field_value=None, expected=None, others={}, board=LEGACY,
            board_expected=uat.expected_clipboard("clipboard_only", True, HELD),
            bundle="com.apple.TextEdit", route="clipboard_only", notice_expected=True)
ok("a clipboard-only Undo with its notice passes", verdicts(**gone) == [], str(verdicts(**gone)))
ok("a refused notice fails",
   any("Copied notice was shown" in n for n in verdicts(**{**gone, "window": gone["window"].replace(
       "shown=true why=presented", "shown=false why=refused")})))
ok("a stale notice fails",
   any("Copied notice was shown" in n for n in verdicts(**{**gone, "window": gone["window"].replace(
       "shown=true why=presented", "shown=false why=stale")})))
ok("an absent notice fails",
   any("Copied notice was shown" in n for n in verdicts(**{**gone, "window": gone["window"].replace(
       "\nESCAPE_RECOVERY_NOTICE shown=true why=presented", "")})))

ok("restore ON and OFF expect different boards after a key paste",
   uat.expected_clipboard("cgevent", True, HELD) == uat.SENTINEL
   and uat.expected_clipboard("cgevent", False, HELD) == LEGACY)
ok("a direct write never touches the board, restore on or off",
   uat.expected_clipboard("ax_direct", True, HELD) == uat.expected_clipboard("ax_direct", False, HELD)
   == uat.SENTINEL)
ok("the legacy payload never doubles a trailing space",
   uat.legacy_payload("a ") == "a " and uat.legacy_payload("a") == "a ")
ok("a selection is replaced and its neighbours kept",
   uat.expected_field("Start. alpha end", 7, 5, HELD) == "Start. " + HELD + " end")
ok("a corrupted selection does not match",
   uat.expected_field("Start. alpha end", 7, 5, HELD) != "Start. " + HELD + "alpha end")
ok("an empty field expects the legacy payload; a field between spaces expects the bare text",
   uat.expected_insertion("empty", HELD) == LEGACY
   and uat.expected_insertion("between_spaces", HELD) == HELD)

ok("the held row's text prefers polished, then processed, then raw",
   uat.held_row_text({"text": "raw", "processedText": "proc", "polishedText": "pol"}) == "pol"
   and uat.held_row_text({"text": "raw", "processedText": "proc"}) == "proc"
   and uat.held_row_text({"text": "raw"}) == "raw")


def aborts(call):
    try:
        call()
    except uat.Aborted:
        return True
    return False


ok("exactly one new held row is required",
   uat.new_held_row({"a.json"}, {"a.json": {"text": "old"}, "b.json": {"text": "new"}}) == "new"
   and aborts(lambda: uat.new_held_row({"a.json"}, {"a.json": {"text": "old"}}))
   and aborts(lambda: uat.new_held_row(set(), {"a.json": {"text": "x"}, "b.json": {"text": "y"}})))
ok("an unreadable held row aborts rather than expecting nothing",
   aborts(lambda: uat.new_held_row(set(), {"a.json": {"text": ""}})))
ok("a rotated log invalidates the phase's evidence",
   uat.evidence_is_current(100, 100) and not uat.evidence_is_current(100, 40))

# The overlay's Copied text is a separate check in the gone-field phase: drive that phase with every
# live boundary faked and require a FAIL when the overlay never shows the sentence.
_saved = {k: getattr(uat, k) for k in (
    "new_textedit_doc", "set_clipboard", "log_length", "log_since", "hold_take", "press_undo",
    "overlay_shows", "wait_for_cleanup", "subprocess", "wait_for")}
try:
    uat.new_textedit_doc = lambda name: "/tmp/fake-doc.txt"
    uat.set_clipboard = lambda text: None
    uat.log_length = lambda: 0
    uat.log_since = lambda base: gone["window"]
    uat.hold_take = lambda path, base: HELD
    uat.press_undo = lambda base: True
    uat.wait_for_cleanup = lambda route, restore_on, held: LEGACY
    uat.subprocess = types.SimpleNamespace(run=lambda *a, **k: None)
    for shown, should_fail in ((True, False), (False, True)):
        uat.overlay_shows = (lambda answer: lambda text: answer)(shown)
        uat.results.clear()
        uat.wait_for = (lambda real: lambda what, pred, deadline=45.0, poll=0.25: pred())(uat.wait_for)
        uat.phase_gone_field()
        failed = [n for n, status, _ in uat.results if status == "FAIL"]
        ok(f"gone field: overlay {'shows' if shown else 'never shows'} Copied -> "
           f"{'FAIL' if should_fail else 'pass'}",
           any("overlay showed" in n for n in failed) == should_fail, str(failed))
finally:
    for k, v in _saved.items():
        setattr(uat, k, v)

print("\n" + "=" * 56)
print(f"{len(fails)} failed" if fails else "all rows passed")
for f in fails:
    print(f"  FAILED: {f}")
sys.exit(1 if fails else 0)
