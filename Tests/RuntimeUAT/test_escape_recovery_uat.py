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

HERE = "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-escape-recovery/Tests/RuntimeUAT"
sys.path.insert(0, HERE)

# The real ones need PyObjC and a live app; the subject under test is the
# harness's control flow, not the key-posting.
presses = []
si = types.ModuleType("simulate_input")
si.hold_key = lambda key, dur: presses.append(key)
sys.modules["simulate_input"] = si
w = types.ModuleType("wispr_eyes")
w.tts = lambda *a, **k: "/dev/null"
w.connect = lambda *a, **k: None
w.tap = lambda *a, **k: True
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
       "the OFF phase would then run with the feature ON")
except uat.Aborted as e:
    ok("a delete that goes nowhere ABORTS", True, str(e))

print("\n" + "=" * 56)
print(f"{len(fails)} failed" if fails else "all rows passed")
for f in fails:
    print(f"  FAILED: {f}")
sys.exit(1 if fails else 0)
