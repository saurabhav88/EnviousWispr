"""The whole seam join, end to end, against a live app.

Earlier probes settled the mechanism one question at a time: rewriting the
whole field is inconsistent (undo fails in Chrome, the caret jumps to the start
in Slack), while a posted backspace behaves correctly in both. This runs the
ACTUAL edit the feature would perform and checks the text a user would read.

The starting state is what the app really looks like after a first recording,
including the trailing space delivery adds (`PasteService.appendTrailingSpace`):

    "I mean the ideal outcome. "          caret at the end

The join has to reach:

    "I mean the ideal outcome would be recognizing when two sentences..."

so it removes the terminator AND the trailing space, then inserts a space plus
the lowercased payload. Two characters back, not one — a detail no
single-character probe would have surfaced.

Measured: does the final text match exactly, how long the edit takes, and
whether one undo puts the user's document back.
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

FIRST = "I mean the ideal outcome. "
SECOND = "Would be recognizing when two sentences belong together."
WANTED = "I mean the ideal outcome would be recognizing when two sentences belong together."


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


def paste(text):
    """Deliver text the way the shipped paste path does: clipboard then Cmd+V."""
    from AppKit import NSPasteboard, NSPasteboardTypeString

    board = NSPasteboard.generalPasteboard()
    previous = board.stringForType_(NSPasteboardTypeString)
    board.clearContents()
    board.setString_forType_(text, NSPasteboardTypeString)
    post_key(9, Quartz.kCGEventFlagMaskCommand)  # V
    time.sleep(0.25)
    board.clearContents()
    if previous:
        board.setString_forType_(previous, NSPasteboardTypeString)


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

    baseline = attr(element, "AXValue") or ""
    print(f"\n{name}  starting from {len(baseline)} chars")

    # Stage the state a first recording leaves behind.
    paste(FIRST)
    time.sleep(0.2)
    staged = attr(element, "AXValue") or ""
    if not staged.rstrip().endswith(FIRST.rstrip()):
        print(f"  could not stage the first recording (got {staged[-30:]!r})")
        return 1
    print(f"  staged: {staged[-30:]!r}")

    # How many characters have to go? NOT a constant. Chrome keeps the trailing
    # space delivery appends and needs two deletes; Slack's composer strips it
    # from the value we read back and needs one. Count from what the document
    # actually contains — the same caret read the feature already performs —
    # rather than assuming what we wrote is what is there.
    trailing = len(staged) - len(staged.rstrip())
    deletes = trailing + (1 if staged.rstrip().endswith((".", "!", "?")) else 0)
    print(f"  trailing space : {trailing}   deletes needed : {deletes}")

    start = time.perf_counter()
    for _ in range(deletes):
        post_key(DELETE_KEYCODE)
        time.sleep(0.012)
    payload = " " + SECOND[0].lower() + SECOND[1:]
    paste(payload)
    elapsed = (time.perf_counter() - start) * 1000

    time.sleep(0.25)
    joined = attr(element, "AXValue") or ""
    got = joined[len(baseline):]
    ok = got.strip() == WANTED
    print(f"  joined: {got.strip()[-60:]!r}")
    print(f"  matches target : {'YES' if ok else 'NO'}")
    if not ok:
        print(f"    wanted tail  : {WANTED[-60:]!r}")
    print(f"  edit time      : {elapsed:.0f} ms  (2 deletes + paste)")

    # Can the user walk it back?
    post_key(Z_KEYCODE, Quartz.kCGEventFlagMaskCommand)
    time.sleep(0.35)
    after_undo = attr(element, "AXValue") or ""
    print(f"  one undo gives : {after_undo[len(baseline):].strip()[-46:]!r}")

    # Restore the field to exactly how it was found.
    for _ in range(14):
        current = attr(element, "AXValue") or ""
        if current == baseline:
            break
        post_key(Z_KEYCODE, Quartz.kCGEventFlagMaskCommand)
        time.sleep(0.18)
    current = attr(element, "AXValue") or ""
    if current != baseline:
        AXUIElementSetAttributeValue(element, "AXValue", baseline)
        time.sleep(0.15)
        current = attr(element, "AXValue") or ""
    print(f"  field restored : {'yes' if current == baseline else 'NO — CHECK BY HAND'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
