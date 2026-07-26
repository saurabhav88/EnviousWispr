"""What does each working edit path COST on a real-sized document?

`probe_edit_paths.py` found two routes that survive Chromium: rewriting the
whole field value, and posting a backspace. They are not equivalent, and the
difference only shows up on a document larger than a test sentence:

  latency      rewriting the whole value is O(document); a keystroke is not
  caret        does the cursor end up where the user left it
  undo         does the user's own undo history survive

Undo is the one that decides it. If our edit collapses a document's undo stack,
we have damaged something the user cannot get back, which is a different class
of harm from a wrong space.

Run with the target app frontmost and a large text field focused.
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
Z_KEYCODE = 6


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
    return value is not None and AXUIElementSetAttributeValue(
        element, "AXSelectedTextRange", value) == 0


def post_key(keycode, flags=0):
    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for pressed in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(source, keycode, pressed)
        if flags:
            Quartz.CGEventSetFlags(event, flags)
        Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, event)
        time.sleep(0.01)


def frontmost():
    NSWorkspace.sharedWorkspace().runningApplications()
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    return app.processIdentifier(), app.localizedName()


def main():
    pid, name = frontmost()
    element = attr(AXUIElementCreateApplication(pid), "AXFocusedUIElement")
    if element is None:
        print(f"{name}: no focused element")
        return 1
    text = attr(element, "AXValue")
    selection = read_range(element)
    if not isinstance(text, str) or len(text) < 200 or selection is None:
        print(f"{name}: need a focused field with 200+ characters "
              f"(got {len(text) if isinstance(text,str) else text})")
        return 1

    caret = selection[0] if selection[0] > 0 else len(text)
    print(f"\n{name}  chars={len(text)}  caret={caret}")

    # Route B: whole-value rewrite.
    start = time.perf_counter()
    AXUIElementSetAttributeValue(element, "AXValue", text[:caret - 1] + text[caret:])
    b_ms = (time.perf_counter() - start) * 1000
    time.sleep(0.15)
    b_after = attr(element, "AXValue")
    b_worked = isinstance(b_after, str) and len(b_after) == len(text) - 1
    b_caret = read_range(element)
    print(f"  B whole-value rewrite : {'works' if b_worked else 'no-op'}  "
          f"{b_ms:.1f} ms  caret now {b_caret}")

    # Can the USER undo our edit, and does their own history survive?
    post_key(Z_KEYCODE, Quartz.kCGEventFlagMaskCommand)
    time.sleep(0.25)
    undone = attr(element, "AXValue")
    b_undo = undone == text
    print(f"  B undo restores       : {'yes' if b_undo else 'NO'}"
          f"{'' if b_undo else f' (len {len(undone) if isinstance(undone,str) else undone})'}")
    if not b_undo:
        AXUIElementSetAttributeValue(element, "AXValue", text)
        time.sleep(0.15)

    write_range(element, caret, 0)
    time.sleep(0.1)

    # Route C: synthetic backspace.
    start = time.perf_counter()
    post_key(DELETE_KEYCODE)
    c_ms = (time.perf_counter() - start) * 1000
    time.sleep(0.15)
    c_after = attr(element, "AXValue")
    c_worked = isinstance(c_after, str) and len(c_after) == len(text) - 1
    c_caret = read_range(element)
    print(f"  C synthetic backspace : {'works' if c_worked else 'no-op'}  "
          f"{c_ms:.1f} ms  caret now {c_caret}")

    post_key(Z_KEYCODE, Quartz.kCGEventFlagMaskCommand)
    time.sleep(0.25)
    undone = attr(element, "AXValue")
    c_undo = undone == text
    print(f"  C undo restores       : {'yes' if c_undo else 'NO'}")
    if not c_undo:
        AXUIElementSetAttributeValue(element, "AXValue", text)

    time.sleep(0.1)
    final = attr(element, "AXValue")
    print(f"\n  field restored        : {'yes' if final == text else 'NO — CHECK BY HAND'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
