"""Which mechanism can actually remove one character from another app's field?

Seam joining has to delete a full stop the previous recording already committed
to the user's document. `probe_ax_modify.py` established that the obvious route
works in native apps and is silently ignored in Chromium ones, so this compares
every route we have on the SAME focused field, back to back.

  A  selection replace   extend the selection back one character, write ""
  B  whole-value rewrite set AXValue to the text minus its last character
  C  synthetic backspace post a Delete key event, the same mechanism the
                         shipped Cmd+V paste already uses

Every route is judged by reading the document back and checking it got exactly
one character shorter. An accepted call that changes nothing is the failure
mode this file exists to catch: both Chromium apps return success and do
nothing (validation-discipline.md RULE: verify-the-feature-not-the-crash).

Each route restores the character afterwards, so a run leaves the field as it
found it. Run with the target app frontmost and a text field focused.
"""

import sys
import time

import Quartz
from ApplicationServices import (AXUIElementCopyAttributeValue,
                                 AXUIElementCreateApplication,
                                 AXUIElementSetAttributeValue, AXValueCreate,
                                 AXValueGetValue, kAXValueCFRangeType)
from AppKit import NSWorkspace

DELETE_KEYCODE = 51


def attr(element, name):
    err, value = AXUIElementCopyAttributeValue(element, name, None)
    return value if err == 0 else None


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


def focused(pid):
    return attr(AXUIElementCreateApplication(pid), "AXFocusedUIElement")


def frontmost():
    NSWorkspace.sharedWorkspace().runningApplications()
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    return app.processIdentifier(), app.localizedName()


def post_backspace():
    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for pressed in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(source, DELETE_KEYCODE, pressed)
        Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, event)
        time.sleep(0.01)


def route_selection_replace(element, text, caret):
    if not write_range(element, caret - 1, 1):
        return "selection not settable"
    AXUIElementSetAttributeValue(element, "AXSelectedText", "")
    return None


def route_whole_value(element, text, caret):
    err = AXUIElementSetAttributeValue(element, "AXValue", text[:caret - 1] + text[caret:])
    return None if err == 0 else f"AXValue not settable (AXError {err})"


def route_backspace(element, text, caret):
    post_backspace()
    return None


ROUTES = [
    ("A selection replace", route_selection_replace),
    ("B whole-value rewrite", route_whole_value),
    ("C synthetic backspace", route_backspace),
]


def type_text(text):
    """Type through key events, the only channel some apps honour at all.

    Excel ignores both AXValue and AXSelectedText writes, so a probe that
    restores through them silently leaves the user's cell modified. Restore has
    to use the same mechanism that worked for the edit.
    """
    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for character in text:
        for pressed in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(source, 0, pressed)
            Quartz.CGEventKeyboardSetUnicodeString(event, len(character), character)
            Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, event)
        time.sleep(0.01)


def restore(element, original_text, original_range):
    """Put the field back exactly as found, by whatever means still works."""
    AXUIElementSetAttributeValue(element, "AXValue", original_text)
    time.sleep(0.08)
    if attr(element, "AXValue") != original_text:
        # AXValue refused; rebuild through the selection instead.
        now = attr(element, "AXValue") or ""
        if len(now) == len(original_text) - 1:
            write_range(element, len(now), 0)
            AXUIElementSetAttributeValue(element, "AXSelectedText", original_text[-1])
            time.sleep(0.08)
    if attr(element, "AXValue") != original_text:
        # Both accessibility writes refused. Type the missing tail back.
        now = attr(element, "AXValue") or ""
        if original_text.startswith(now) and len(now) < len(original_text):
            type_text(original_text[len(now):])
            time.sleep(0.12)
    if original_range:
        write_range(element, original_range[0], original_range[1])
    time.sleep(0.05)
    return attr(element, "AXValue") == original_text


def main():
    pid, name = frontmost()
    element = focused(pid)
    if element is None:
        print(f"{name}: no focused element")
        return 1

    text = attr(element, "AXValue")
    selection = read_range(element)
    role = attr(element, "AXRole")
    if not isinstance(text, str) or not text.strip() or selection is None:
        print(f"{name}: focused {role} has no usable text ({text!r})")
        return 1

    caret = selection[0] if selection[0] > 0 else len(text)
    print(f"\n{name}  role={role}  chars={len(text)}  caret={caret}")
    print(f"  text: {text[-46:]!r}")
    print(f"  removing {text[caret-1]!r} at {caret-1}\n")

    for label, route in ROUTES:
        before = attr(element, "AXValue")
        problem = route(element, before, caret)
        time.sleep(0.12)
        after = attr(element, "AXValue")
        if problem:
            verdict, detail = "UNAVAILABLE", problem
        elif isinstance(after, str) and len(after) == len(before) - 1:
            verdict, detail = "WORKS", f"{len(before)} -> {len(after)} chars"
        elif after == before:
            verdict, detail = "SILENT NO-OP", "call accepted, document unchanged"
        else:
            verdict, detail = "WRONG", f"{len(before)} -> {len(after) if isinstance(after,str) else after}"
        print(f"  {label:24} {verdict:14} {detail}")
        if not restore(element, text, selection):
            print(f"  {'':24} RESTORE FAILED — field left modified, stopping")
            return 1
    print("\n  field restored")
    return 0


if __name__ == "__main__":
    sys.exit(main())
