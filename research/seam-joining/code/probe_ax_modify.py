"""Can we MODIFY text that is already in another app's document?

Seam joining needs to remove a full stop the previous recording left behind.
Everything shipped so far only inserts at the cursor. `accessibility-macos.md`
FACT: reading-caret-context-from-another-app measured READING across these same
apps and found it works broadly; the write side was never measured, and the
11.8% `ax_direct` rate is a cascade OUTCOME, not a capability.

This probe answers the capability question directly, per app:

  settable      is `AXSelectedTextRange` writable at all
  extend        can the selection be extended backwards over the last character
  replace       does writing `AXSelectedText` over that selection actually
                change the document, verified by reading the text back

Nothing here drives dictation or reads the clipboard: it types a known sentence
into the app's own focused field, then tries to remove its final character.
Run it with the target app frontmost and a text field focused.
"""

import sys
import time

from ApplicationServices import (AXUIElementCopyAttributeValue,
                                 AXUIElementCreateApplication,
                                 AXUIElementSetAttributeValue, AXValueCreate,
                                 AXValueGetValue, kAXValueCFRangeType)
from AppKit import NSWorkspace

FOCUSED = "AXFocusedUIElement"
SELECTED_RANGE = "AXSelectedTextRange"
SELECTED_TEXT = "AXSelectedText"
VALUE = "AXValue"
ROLE = "AXRole"
N_CHARS = "AXNumberOfCharacters"


def attr(element, name):
    err, value = AXUIElementCopyAttributeValue(element, name, None)
    return value if err == 0 else None


def running_apps(names):
    """Resolve app names to pids WITHOUT bringing anything to the front.

    Per-app `AXUIElementCreateApplication(pid)` reaches a background app's
    focused element, and `accessibility-macos.md` records it as the stronger
    call than the system-wide one. That matters here: the founder is using this
    machine, so the probe must not steal focus to measure.
    """
    wanted = {n.lower() for n in names}
    found = []
    for app in NSWorkspace.sharedWorkspace().runningApplications():
        label = app.localizedName()
        if label and label.lower() in wanted:
            found.append((app.processIdentifier(), label))
    return found


def read_range(element):
    raw = attr(element, SELECTED_RANGE)
    if raw is None:
        return None
    ok, value = AXValueGetValue(raw, kAXValueCFRangeType, None)
    if not ok:
        return None
    # PyObjC hands a CFRange back as a plain tuple, not a struct.
    return (int(value[0]), int(value[1]))


def write_range(element, location, length):
    value = AXValueCreate(kAXValueCFRangeType, (location, length))
    if value is None:
        return "could not build a range value"
    err = AXUIElementSetAttributeValue(element, SELECTED_RANGE, value)
    return None if err == 0 else f"AXError {err}"


def probe(pid, name):
    app = AXUIElementCreateApplication(pid)
    element = attr(app, FOCUSED)
    if element is None:
        print(f"\n{name}  (pid {pid})\n  no focused element — nothing to probe")
        return

    role = attr(element, ROLE)
    text = attr(element, VALUE)
    count = attr(element, N_CHARS)
    before = read_range(element)
    print(f"\n{name}  (pid {pid})")
    print(f"  role            : {role}")
    print(f"  chars           : {count}")
    print(f"  caret/selection : {before}")
    print(f"  text tail       : {repr(text[-40:]) if isinstance(text, str) else text}")

    if before is None:
        print("  VERDICT         : cannot read a selection — modify is impossible here")
        return

    caret = before[0]
    if caret < 1:
        print("  VERDICT         : caret at position 0, nothing behind it to remove")
        return

    # 1. Is the range settable at all? Re-select the single character behind
    #    the caret — the position a stray full stop would occupy.
    error = write_range(element, caret - 1, 1)
    if error:
        print(f"  settable        : NO ({error})")
        print("  VERDICT         : cannot extend backwards — modify unavailable")
        return
    time.sleep(0.05)

    after = read_range(element)
    extended = after == (caret - 1, 1)
    print(f"  settable        : yes")
    print(f"  extend back 1   : {'yes' if extended else f'NO (got {after})'}")
    if not extended:
        print("  VERDICT         : selection did not take — modify unreliable here")
        return

    doomed = attr(element, SELECTED_TEXT)
    print(f"  selected char   : {repr(doomed)}")

    # 2. Does replacing that selection actually change the document? This is
    #    the real question: a selection that sets but does not accept a write
    #    is useless. Delete the character, verify the document actually got
    #    shorter, then put it back and restore the caret. Verifying by reading
    #    the text back is the point — an AXError of 0 only says the call was
    #    accepted, not that anything changed (validation-discipline.md
    #    RULE: verify-the-feature-not-the-crash).
    err = AXUIElementSetAttributeValue(element, SELECTED_TEXT, "")
    time.sleep(0.08)
    shortened = attr(element, VALUE)
    deleted = isinstance(shortened, str) and isinstance(text, str) and len(
        shortened) == len(text) - 1

    print(f"  delete accepted : {'yes' if err == 0 else f'NO (AXError {err})'}")
    print(f"  document shrank : {'yes' if deleted else 'NO — write was a no-op'}")

    # 3. Put it back, whatever happened, and restore the original selection.
    restored = False
    if deleted:
        AXUIElementSetAttributeValue(element, SELECTED_TEXT, doomed or "")
        time.sleep(0.08)
        restored = attr(element, VALUE) == text
        print(f"  restored        : {'yes' if restored else 'NO — LEFT A CHANGE'}")
    write_range(element, before[0], before[1])

    if deleted and restored:
        print("  VERDICT         : MODIFY WORKS — backwards edit available and reversible")
    elif deleted:
        print("  VERDICT         : modify works but restore failed — check this app by hand")
    elif err == 0:
        print("  VERDICT         : write silently ignored — insert-only in practice")
    else:
        print("  VERDICT         : write refused — insert-only app")


def activate(pid):
    for app in NSWorkspace.sharedWorkspace().runningApplications():
        if app.processIdentifier() == pid:
            app.activateWithOptions_(1 << 1)  # activateIgnoringOtherApps
            return True
    return False


if __name__ == "__main__":
    targets = sys.argv[1:] or [
        "Slack", "Google Chrome", "Discord", "ChatGPT", "Notes", "TextEdit",
        "Mail", "Sublime Text", "Notion",
    ]
    apps = running_apps(targets)
    if not apps:
        print("none of the target apps are running")
        raise SystemExit(1)

    # A background app reports no focused element, so each target has to be
    # frontmost for the length of its probe. The founder's app is put back at
    # the end.
    NSWorkspace.sharedWorkspace().runningApplications()
    original = NSWorkspace.sharedWorkspace().frontmostApplication()
    original_pid = original.processIdentifier() if original else None
    print(f"Probing {len(apps)} apps. Focus returns to {original.localizedName()} at the end.")

    for pid, name in sorted(apps, key=lambda p: p[1]):
        try:
            activate(pid)
            time.sleep(0.8)
            probe(pid, name)
        except Exception as exc:
            print(f"\n{name}  (pid {pid})\n  probe error: {type(exc).__name__}: {exc}")

    if original_pid:
        activate(original_pid)
