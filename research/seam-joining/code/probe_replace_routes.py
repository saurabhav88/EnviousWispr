"""Which mechanism can replace a SPAN of text fastest and most reliably?

The prototype currently posts one backspace per character and then pastes. The
founder's objection, 2026-07-25: it is visibly slow, and a dropped keystroke in
a burst of forty leaves one character behind. Both complaints are about the same
mechanism, so this measures every alternative on the SAME staged field.

  A  backspace x N + paste     what ships in the prototype today, the baseline
  B  AX set range + paste      one accessibility call to select, one Cmd+V
  C  AX set range + AX write   pure accessibility, no synthetic keys at all
  D  shift+Left x N + paste    keystroke selection, non-destructive until paste
  E  AXValue whole rewrite     hand the app a whole new document
  F  shift+Home + paste        one keystroke, but claims the whole line

Judged by reading the field back: the exact expected string, or it failed. An
accepted call that changes nothing is the failure this exists to catch — both
Chromium apps returned success and did nothing when probed this morning
(validation-discipline.md RULE: verify-the-feature-not-the-crash).

The replacement is deliberately a DIFFERENT length from the span it replaces, so
a route that is off by one cannot pass by coincidence.

Run it through `measure_replace.py`, which stages each app. Running this file
directly operates on whatever is focused right now.
"""

import time

import Quartz
from AppKit import NSPasteboard, NSPasteboardTypeString, NSWorkspace
from ApplicationServices import (AXUIElementCopyAttributeValue,
                                 AXUIElementCreateApplication,
                                 AXUIElementSetAttributeValue, AXValueCreate,
                                 AXValueGetValue, kAXValueCFRangeType)

DELETE_KEY, V_KEY, LEFT_ARROW, HOME_KEY = 51, 9, 123, 115
SHIFT = Quartz.kCGEventFlagMaskShift
COMMAND = Quartz.kCGEventFlagMaskCommand


# ── primitives ───────────────────────────────────────────────────────────────

def attr(element, name):
    err, value = AXUIElementCopyAttributeValue(element, name, None)
    return value if err == 0 else None


def frontmost():
    NSWorkspace.sharedWorkspace().runningApplications()
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    return (app.processIdentifier(), app.localizedName()) if app else (None, None)


def focused_element():
    """The frontmost app's focused element, waking Chromium's tree if needed.

    Chrome and Electron apps build no accessibility tree until an assistive
    client asks for one, so the first read returns nothing at all — which reads
    exactly like "this app has no text field" and is not that. Setting the two
    opt-in flags below is what a screen reader does; without it Chrome measured
    as unreachable when it is merely asleep.
    """
    pid, name = frontmost()
    if pid is None:
        return None, None
    application = AXUIElementCreateApplication(pid)
    element = attr(application, "AXFocusedUIElement")
    if element is not None:
        return element, name
    for flag in ("AXManualAccessibility", "AXEnhancedUserInterface"):
        AXUIElementSetAttributeValue(application, flag, True)
    for _ in range(10):
        time.sleep(0.3)
        element = attr(application, "AXFocusedUIElement")
        if element is not None:
            return element, name
    return None, name


def read_range(element):
    raw = attr(element, "AXSelectedTextRange")
    if raw is None:
        return None
    ok, value = AXValueGetValue(raw, kAXValueCFRangeType, None)
    return (int(value[0]), int(value[1])) if ok else None


def write_range(element, location, length):
    value = AXValueCreate(kAXValueCFRangeType, (location, length))
    if value is None:
        return False
    return AXUIElementSetAttributeValue(element, "AXSelectedTextRange", value) == 0


def post_key(keycode, flags=0, settle=0.004):
    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for pressed in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(source, keycode, pressed)
        if flags:
            Quartz.CGEventSetFlags(event, flags)
        Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, event)
        time.sleep(settle)


def type_text(text):
    """Type through key events, the only channel some apps honour at all."""
    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for character in text:
        for pressed in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(source, 0, pressed)
            Quartz.CGEventKeyboardSetUnicodeString(event, len(character), character)
            Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, event)
        time.sleep(0.012)


def put_on_clipboard(text):
    board = NSPasteboard.generalPasteboard()
    saved = board.stringForType_(NSPasteboardTypeString)
    board.clearContents()
    board.setString_forType_(text, NSPasteboardTypeString)
    return saved


def restore_clipboard(saved):
    board = NSPasteboard.generalPasteboard()
    board.clearContents()
    if saved:
        board.setString_forType_(saved, NSPasteboardTypeString)


# ── the routes ───────────────────────────────────────────────────────────────
# Each takes the focused element, how many characters behind the caret to
# replace, and the text to put there. Returns None, or a reason it could not
# even be attempted. Correctness is judged by the caller reading the field.

def route_backspace_paste(element, span_len, replacement, caret):
    saved = put_on_clipboard(replacement)
    try:
        for _ in range(span_len):
            post_key(DELETE_KEY)
        time.sleep(0.15)
        post_key(V_KEY, COMMAND)
        time.sleep(0.30)
    finally:
        restore_clipboard(saved)
    return None


def route_axrange_paste(element, span_len, replacement, caret):
    if caret is None:
        return "app reports no caret position"
    if not write_range(element, caret - span_len, span_len):
        return "selection range not settable"
    time.sleep(0.05)
    saved = put_on_clipboard(replacement)
    try:
        post_key(V_KEY, COMMAND)
        time.sleep(0.30)
    finally:
        restore_clipboard(saved)
    return None


def route_axrange_axwrite(element, span_len, replacement, caret):
    if caret is None:
        return "app reports no caret position"
    if not write_range(element, caret - span_len, span_len):
        return "selection range not settable"
    time.sleep(0.05)
    err = AXUIElementSetAttributeValue(element, "AXSelectedText", replacement)
    time.sleep(0.15)
    return None if err == 0 else f"AXSelectedText refused (AXError {err})"


def route_shiftleft_paste(element, span_len, replacement, caret):
    saved = put_on_clipboard(replacement)
    try:
        for _ in range(span_len):
            post_key(LEFT_ARROW, SHIFT)
        time.sleep(0.10)
        post_key(V_KEY, COMMAND)
        time.sleep(0.30)
    finally:
        restore_clipboard(saved)
    return None


def route_axvalue(element, span_len, replacement, caret):
    current = attr(element, "AXValue")
    if not isinstance(current, str):
        return "app exposes no whole value"
    if caret is None:
        caret = len(current)
    rebuilt = current[:caret - span_len] + replacement + current[caret:]
    err = AXUIElementSetAttributeValue(element, "AXValue", rebuilt)
    time.sleep(0.15)
    return None if err == 0 else f"AXValue refused (AXError {err})"


def route_shifthome_paste(element, span_len, replacement, caret):
    """Selects to the start of the LINE, not the start of the span.

    Included because it is the only single-keystroke option, and because in a
    terminal the line often IS the span. Expected to destroy preceding text
    anywhere else; the measurement is there to show exactly where.
    """
    saved = put_on_clipboard(replacement)
    try:
        post_key(HOME_KEY, SHIFT)
        time.sleep(0.10)
        post_key(V_KEY, COMMAND)
        time.sleep(0.30)
    finally:
        restore_clipboard(saved)
    return None


ROUTES = [
    ("A backspace x N + paste", route_backspace_paste),
    ("B AX set range + paste", route_axrange_paste),
    ("C AX set range + AX write", route_axrange_axwrite),
    ("D shift+Left x N + paste", route_shiftleft_paste),
    ("E AXValue whole rewrite", route_axvalue),
    ("F shift+Home + paste", route_shifthome_paste),
]


def run_route(route, element, span_len, replacement, caret):
    """Returns (unavailable_reason, elapsed_ms)."""
    start = time.perf_counter()
    problem = route(element, span_len, replacement, caret)
    return problem, (time.perf_counter() - start) * 1000
