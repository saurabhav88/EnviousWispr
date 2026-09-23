#!/usr/bin/env python3
"""Live UAT for Paste and Copy Last Dictation (#3106), driven synthetically.

    python3 Tests/RuntimeUAT/last_dictation_uat.py            # every phase
    python3 Tests/RuntimeUAT/last_dictation_uat.py probe      # Carbon ingress probe only

Run with the screen UNLOCKED and THIS worktree's Debug build running with Debug Mode on (the
`last dictation reuse:` and `Carbon hotkey event:` lines are DEBUG `app.log` lines).

WHAT EACH VERDICT READS
-----------------------
- Ingress: `Carbon hotkey event: id=5` (Paste Last) or `id=6` (Copy Last) in `app.log`. A 2026-09-23
  probe showed synthetic CGEvents reach `RegisterEventHotKey` in a standalone NSApplication on
  macOS 27.0; phase `probe` re-measures that against THIS app before any chord phase counts.
- Outcome: `last dictation reuse: action=<a> source=<s> outcome=<o>`, one per invocation.
- Arrival: the TextEdit document's AXValue, read through accessibility. `outcome=dispatched` means
  Cmd+V was POSTED; only the document proves the words arrived, and exactly once.
- Clipboard: the pasteboard itself, snapshotted in full (every item, every type) before the run and
  put back afterwards.

THE EXPECTED TEXT IS NOT THE SUBJECT'S OWN READER
-------------------------------------------------
The dictation is created here from a known sentence; its token ("Maya") is the independent check.
The exact text pastes are compared against is what the dictation DELIVERED into document A, read
through AX: the row's text as the pipeline produced it, not as the reuse path reads it. Delivery
appends ONE separating space after the sentence (measured 2026-09-23: document A read
'Send the draft to Maya tomorrow morning. '); History keeps the text without it, and reuse pastes
History's text, exactly as History's own Paste button does. So the oracle is document A minus that
one trailing space, and a paste carrying the space would fail.

DATA THIS TOUCHES
-----------------
It adds one dictation to the real History (the dev build shares the shipped app's store) and
never deletes any row. It changes no setting. The clipboard is restored from the snapshot.
"""
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import simulate_input as si  # noqa: E402
import wispr_eyes as w  # noqa: E402
from escape_recovery_uat import field_text, new_textedit_doc, screen_is_locked  # noqa: E402

LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
SENTENCE = "Send the draft to Maya tomorrow morning."
TOKEN = "Maya"
# Every document this run opens is new: TextEdit REOPENS an already-open path with its old text,
# which made a second run read the first run's paste plus its own (measured 2026-09-23).
RUN_ID = time.strftime("%H%M%S")
APP_BUNDLE = os.path.join(os.path.dirname(os.path.dirname(HERE)), "build", "EnviousWispr Local.app")
REUSE = re.compile(r"last dictation reuse: action=(\w+) source=(\w+) outcome=(\w+)")
CARBON = re.compile(r"Carbon hotkey event: id=(\d+), isRelease=(\w+)")

results = []


class Aborted(Exception):
    """The run cannot produce a meaningful verdict; stop rather than report vacuous passes."""


def record(name, status, detail=""):
    results.append((name, status, detail))
    print(f"  {status}  {name}{('  :: ' + detail) if detail else ''}")


def check(name, ok, detail=""):
    record(name, "PASS" if ok else "FAIL", detail)
    return ok


def skip(name, detail):
    record(name, "SKIP", detail)


def wait_for(what, predicate, deadline=10.0, poll=0.1):
    """Wait on a signal the subject produces; the deadline is the fallback, never the mechanism."""
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(poll)  # settle: poll interval between reads of the signal
    print(f"    (no signal: {what} within {deadline:.0f}s)")
    return False


# ── Log ──────────────────────────────────────────────────────────────────────

def log_size():
    return os.path.getsize(LOG)


def log_since(offset):
    with open(LOG, "rb") as fh:
        fh.seek(offset)
        return fh.read().decode("utf-8", "replace")


def reuse_lines(offset):
    return REUSE.findall(log_since(offset))


def carbon_ids(offset):
    return CARBON.findall(log_since(offset))


# ── Pasteboard: every item, every type ───────────────────────────────────────

def pasteboard_snapshot():
    """Every item and every type on the general pasteboard, or an ABORT before anything touches it.

    A type whose data cannot be read (a lazily promised type whose owner is gone) would be dropped
    silently by the restore, so the run refuses to start instead.
    """
    from AppKit import NSPasteboard
    board = NSPasteboard.generalPasteboard()
    items = []
    for item in board.pasteboardItems() or []:
        entry = {}
        for kind in item.types():
            data = item.dataForType_(kind)
            if data is None:
                raise Aborted(f"the clipboard holds a type this run cannot capture ({kind}); "
                              "refusing to touch a clipboard it could not put back")
            entry[str(kind)] = data
        items.append(entry)
    return items


def pasteboard_restore(items):
    """Put the snapshot back and verify it: the exact type set of every item, and every byte.

    Every replacement item is BUILT before the board is cleared, so a type that cannot be set
    leaves the current clipboard as it is instead of empty.
    """
    from AppKit import NSPasteboard, NSPasteboardItem
    rebuilt = []
    for entry in items:
        item = NSPasteboardItem.alloc().init()
        for kind, data in entry.items():
            if not item.setData_forType_(data, kind):
                return False
        rebuilt.append(item)
    board = NSPasteboard.generalPasteboard()
    board.clearContents()
    if rebuilt and not board.writeObjects_(rebuilt):
        return False
    after = board.pasteboardItems() or []
    if len(after) != len(items):
        return False
    for item, entry in zip(after, items):
        if {str(t) for t in item.types()} != set(entry):
            return False
        for kind, data in entry.items():
            got = item.dataForType_(kind)
            if got is None or bytes(got) != bytes(data):
                return False
    return True


def clipboard_text():
    from AppKit import NSPasteboard, NSPasteboardTypeString
    value = NSPasteboard.generalPasteboard().stringForType_(NSPasteboardTypeString)
    return None if value is None else str(value)


def set_clipboard_text(text):
    from AppKit import NSPasteboard, NSPasteboardTypeString
    board = NSPasteboard.generalPasteboard()
    board.clearContents()
    board.setString_forType_(text, NSPasteboardTypeString)


# ── Keys ─────────────────────────────────────────────────────────────────────

def framed_press(key, ctrl=False, alt=False, cmd=False, shift=False):
    """One press framed like a human's: each modifier's flagsChanged down, the key down/up with
    exactly those flags, then each modifier up. The Keybinds recorder tracks the modifiers it sees
    go DOWN; a flags-only key event (`simulate_input.press_key`) is ignored by it (measured
    2026-09-23: the box stayed listening)."""
    from Quartz import (CGEventCreateKeyboardEvent, CGEventPost, CGEventSetFlags,
                        kCGEventFlagMaskAlternate, kCGEventFlagMaskCommand,
                        kCGEventFlagMaskControl, kCGEventFlagMaskShift, kCGHIDEventTap)
    held = [(59, kCGEventFlagMaskControl, ctrl), (58, kCGEventFlagMaskAlternate, alt),
            (56, kCGEventFlagMaskShift, shift), (55, kCGEventFlagMaskCommand, cmd)]
    flags = 0
    for code, mask, on in held:
        if on:
            flags |= mask
            si.modifier_down(code)
    time.sleep(0.03)  # settle: gap between physical key transitions
    for is_down in (True, False):
        event = CGEventCreateKeyboardEvent(None, si.KEY_CODES[key], is_down)
        CGEventSetFlags(event, flags)
        CGEventPost(kCGHIDEventTap, event)
        time.sleep(0.05)  # settle: gap between physical key transitions
    for code, _, on in reversed(held):
        if on:
            si.modifier_up(code)


def _post_key(key, is_down, option=False, shift=False):
    from Quartz import (CGEventCreateKeyboardEvent, CGEventPost, CGEventSetFlags,
                        kCGEventFlagMaskAlternate, kCGEventFlagMaskCommand,
                        kCGEventFlagMaskControl, kCGEventFlagMaskShift, kCGHIDEventTap)
    flags = kCGEventFlagMaskControl | kCGEventFlagMaskCommand
    if option:
        flags |= kCGEventFlagMaskAlternate
    if shift:
        flags |= kCGEventFlagMaskShift
    event = CGEventCreateKeyboardEvent(None, si.KEY_CODES[key], is_down)
    CGEventSetFlags(event, flags)
    CGEventPost(kCGHIDEventTap, event)


def chord(key, hold=0.08, repeats=0, option=False, shift=False):
    """Control+Command(+Option/+Shift)+<key>, framed like a human press: modifiers down, key down
    (plus `repeats` auto-repeat key-downs), key up, modifiers up."""
    si.modifier_down(59)  # left Control
    si.modifier_down(55)  # left Command
    if option:
        si.modifier_down(58)  # left Option
    if shift:
        si.modifier_down(56)  # left Shift
    time.sleep(0.03)  # settle: gap between physical key transitions
    _post_key(key, True, option, shift)
    for _ in range(repeats):
        time.sleep(0.05)  # settle: macOS key-repeat interval, roughly
        _post_key(key, True, option, shift)
    time.sleep(hold)  # settle: how long the chord's key stays down
    _post_key(key, False, option, shift)
    time.sleep(0.03)  # settle: gap between physical key transitions
    if shift:
        si.modifier_up(56)
    if option:
        si.modifier_up(58)
    si.modifier_up(55)
    si.modifier_up(59)


def frontmost_bundle():
    """The frontmost app's bundle id, read TWO ways that must agree; None when they do not.

    `NSWorkspace.frontmostApplication` is kept current by run-loop notifications, and a plain
    script has no run loop: unpumped it returns whatever was true at first touch, forever
    (uat-testing.md). It made five working activations read as failures here (2026-09-23). The
    run loop is pumped first, and System Events is asked independently.
    """
    import subprocess
    from AppKit import NSDate, NSDefaultRunLoopMode, NSRunLoop, NSWorkspace
    NSRunLoop.currentRunLoop().runMode_beforeDate_(
        NSDefaultRunLoopMode, NSDate.dateWithTimeIntervalSinceNow_(0.05))
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    workspace = str(app.bundleIdentifier()) if app else None
    events = subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to get bundle identifier of '
         'first process whose frontmost is true'], capture_output=True, text=True).stdout.strip()
    return workspace if workspace == events else None


def require_front(bundle, label):
    if not wait_for(f"{bundle} frontmost", lambda: frontmost_bundle() == bundle, deadline=5.0):
        raise Aborted(f"{label}: {bundle} is not frontmost (got {frontmost_bundle()}); a key "
                      "posted now would go elsewhere")


def doc_text(path):
    return field_text(path) or ""


def visible_point_in_sidebar(pid):
    """A screen point in our standard window's left strip that no other window covers, or None."""
    from Quartz import (CGWindowListCopyWindowInfo, kCGNullWindowID,
                        kCGWindowListOptionOnScreenOnly)
    if pid is None:
        from AppKit import NSRunningApplication
        apps = NSRunningApplication.runningApplicationsWithBundleIdentifier_("com.enviouswispr.app.dev")
        pid = apps[0].processIdentifier() if apps and len(apps) == 1 else None
    if pid is None:
        return None
    windows = [x for x in CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
               if x.get("kCGWindowLayer", 0) == 0]  # front to back

    def owner_at(x, y):
        for wd in windows:
            b = wd["kCGWindowBounds"]
            if b["X"] <= x < b["X"] + b["Width"] and b["Y"] <= y < b["Y"] + b["Height"]:
                return wd["kCGWindowOwnerPID"]
        return None

    ours = [wd for wd in windows if wd["kCGWindowOwnerPID"] == pid]
    if not ours:
        return None
    b = ours[0]["kCGWindowBounds"]
    for fy in (i / 20 for i in range(3, 19)):
        for fx in (0.03, 0.06, 0.09, 0.12):
            x, y = b["X"] + b["Width"] * fx, b["Y"] + b["Height"] * fy
            if owner_at(x, y) == pid:
                return (x, y)
    return None


# ── Phases ───────────────────────────────────────────────────────────────────

def phase_probe():
    """Does a synthetic Control+Command+C reach THIS app's Carbon chord? Every chord phase
    depends on the answer, so it is asked first and on its own. Copy rather than Paste: it
    writes only the clipboard, which is snapshotted and restored."""
    print("\n== probe: Carbon ingress for Copy Last (id=6)")
    base = log_size()
    chord("c")
    got = wait_for("Carbon id=6 and a copy outcome",
                   lambda: any(i == "6" for i, _ in carbon_ids(base))
                   and any(a == "copy" for a, _, _ in reuse_lines(base)), deadline=5.0)
    check("probe: synthetic chord reaches the Carbon hotkey (id=6)", got,
          f"carbon={carbon_ids(base)} reuse={reuse_lines(base)}")
    return got


def phase_dictate():
    print("\n== dictate: create a known last dictation in document A (silently, through BlackHole)")
    from silent_audio import AudioRoute, take_was_virtual
    route = AudioRoute()
    route.install_restore_handlers()
    try:
        route.apply()  # inside the try: a partial apply is restored by the finally below
        path = new_textedit_doc(f"3106-a-{RUN_ID}")
        require_front("com.apple.TextEdit", "dictate")
        # Push-to-talk (`record_tts`, a trusted recipe), not the menu-driven `test_recording`: on the
        # silent route a menu Start/Stop pair was followed at once by a SECOND take nobody asked
        # for, which transcribed noise ("What?") into the document; a PTT hold gave exactly one take
        # (measured 2026-09-23, #3107). Windows are closed so the hold's key goes to
        # document A.
        for _ in range(4):
            if not w.close_window():
                break
        require_front("com.apple.TextEdit", "dictate")
        base = log_size()
        w.record_tts(SENTENCE)
        # settle: a second, unrequested take would start inside this window (see above)
        time.sleep(2.0)
        virtual, transports = take_was_virtual(base)
        starts = log_since(base).count("Recording started")
        check("dictate: exactly one take", starts == 1, f"{starts} takes started")
        check("dictate: the take captured through the virtual device", virtual, str(transports))
    finally:
        try:
            stopped = stop_any_live_take(base_offset=None)
        except Exception as exc:  # the teardown below must still run
            print(f"    (stopping the take raised {exc!r})")
            stopped = False
        end_take_then_restore(route, "dictate", stopped)
    ok = wait_for("the dictation to land in document A", lambda: TOKEN in doc_text(path),
                  deadline=20.0)
    delivered = doc_text(path)
    check("dictate: the take landed in document A", ok, repr(delivered[:80]))
    if not ok:
        raise Aborted("no dictation landed; every reuse check below would test a stale row")
    return delivered[:-1] if delivered.endswith(" ") else delivered


def phase_menu(expected):
    print("\n== menu: real clicks on Paste Last Dictation, target carried from menu open")
    path = new_textedit_doc(f"3106-menu-{RUN_ID}")
    require_front("com.apple.TextEdit", "menu")
    rows = w.status_menu_snapshot_real()
    if rows is None:
        check("menu: the status menu opened", False, "no rows read")
        return
    titles = [r["title"] for r in rows]
    idx = next((i for i, t in enumerate(titles) if t.startswith("Paste Last Dictation")), None)
    check("menu: Paste Last Dictation is present and enabled",
          idx is not None and rows[idx]["enabled"], str(titles))
    if idx is not None and idx + 1 < len(rows):
        preview = rows[idx + 1]["title"]
        first_line = expected.strip().split("\n")[0]
        want = first_line if len(first_line) <= 30 else first_line[:30] + "…"
        check("menu: disabled preview row, first line bounded at 30",
              not rows[idx + 1]["enabled"] and preview == want,
              f"preview={preview!r} want={want!r}")
        check("menu: the item's accessibility label carries the preview",
              preview in rows[idx]["description"] or preview in rows[idx]["title"],
              f"description={rows[idx]['description']!r}")
    require_front("com.apple.TextEdit", "menu, after the snapshot")
    sentinel = "ew-uat-sentinel-menu"
    set_clipboard_text(sentinel)
    base = log_size()
    clicked = w.click_status_menu_item_real("Paste Last Dictation")
    check("menu: the item was clicked with real clicks", clicked.get("clicked", False), str(clicked))
    ok = wait_for("a menu paste outcome", lambda: reuse_lines(base), deadline=5.0)
    lines = reuse_lines(base)
    check("menu: one outcome, dispatched", ok and lines == [("paste", "menu", "dispatched")],
          str(lines))
    wait_for("the paste to arrive", lambda: doc_text(path) != "", deadline=5.0)
    check("menu: the document holds the dictation exactly once", doc_text(path) == expected,
          repr(doc_text(path)[:80]))
    check("menu: the previous clipboard is back",
          wait_for("the clipboard restore", lambda: clipboard_text() == sentinel, deadline=5.0),
          repr(clipboard_text()))


def phase_copy_chord(expected):
    print("\n== copy chord: Control+Command+C, then an ordinary Cmd+V")
    set_clipboard_text("ew-uat-sentinel-before-copy")
    base = log_size()
    chord("c")
    ok = wait_for("a copy outcome", lambda: reuse_lines(base), deadline=5.0)
    lines = reuse_lines(base)
    check("copy chord: one outcome, copied", ok and lines == [("copy", "chord", "copied")],
          str(lines))
    check("copy chord: the clipboard holds the dictation", clipboard_text() == expected,
          repr((clipboard_text() or "")[:80]))
    path = new_textedit_doc(f"3106-copy-{RUN_ID}")
    require_front("com.apple.TextEdit", "copy chord")
    si.press_key("v", cmd=True)
    wait_for("the manual paste to arrive", lambda: doc_text(path) != "", deadline=5.0)
    check("copy chord: Cmd+V pastes it exactly once", doc_text(path) == expected,
          repr(doc_text(path)[:80]))


def phase_paste_chord(expected):
    print("\n== paste chord: Control+Command+V into a fresh document, clipboard restored")
    path = new_textedit_doc(f"3106-chord-{RUN_ID}")
    require_front("com.apple.TextEdit", "paste chord")
    sentinel = "ew-uat-sentinel-paste-chord"
    set_clipboard_text(sentinel)
    base = log_size()
    chord("v")
    ok = wait_for("a paste outcome", lambda: reuse_lines(base), deadline=5.0)
    lines = reuse_lines(base)
    check("paste chord: Carbon id=5 received", any(i == "5" for i, _ in carbon_ids(base)),
          str(carbon_ids(base)))
    check("paste chord: one outcome, dispatched",
          ok and lines == [("paste", "chord", "dispatched")], str(lines))
    wait_for("the paste to arrive", lambda: doc_text(path) != "", deadline=5.0)
    check("paste chord: the document holds the dictation exactly once",
          doc_text(path) == expected, repr(doc_text(path)[:80]))
    check("paste chord: the previous clipboard is back",
          wait_for("the clipboard restore", lambda: clipboard_text() == sentinel, deadline=5.0),
          repr(clipboard_text()))


def phase_held_chord(expected):
    print("\n== held chord: key-repeat before one release acts once")
    path = new_textedit_doc(f"3106-held-{RUN_ID}")
    require_front("com.apple.TextEdit", "held chord")
    base = log_size()
    chord("v", hold=0.3, repeats=6)
    wait_for("a paste outcome", lambda: reuse_lines(base), deadline=5.0)
    # settle: a duplicate paste would land inside this window; there is no signal for "none came"
    time.sleep(1.5)
    lines = reuse_lines(base)
    check("held chord: exactly one outcome", len(lines) == 1, str(lines))
    check("held chord: the document holds the dictation once", doc_text(path) == expected,
          repr(doc_text(path)[:80]))


def phase_keys_held():
    print("\n== keys held: Control and Command stay down past the 1 s deadline")
    path = new_textedit_doc(f"3106-keysheld-{RUN_ID}")
    require_front("com.apple.TextEdit", "keys held")
    base = log_size()
    si.modifier_down(59)
    si.modifier_down(55)
    time.sleep(0.03)  # settle: gap between physical key transitions
    _post_key("v", True)
    time.sleep(0.05)  # settle: gap between physical key transitions
    _post_key("v", False)
    try:
        ok = wait_for("a keys_held outcome", lambda: reuse_lines(base), deadline=3.0)
    finally:
        si.modifier_up(55)
        si.modifier_up(59)
    lines = reuse_lines(base)
    check("keys held: outcome keys_held and nothing written",
          ok and lines == [("paste", "chord", "keys_held")] and doc_text(path) == "",
          f"{lines} doc={doc_text(path)!r}")


def phase_own_window(expected):
    print("\n== own window: our Settings in front; Paste refuses, Copy works")
    w.nav("Keybinds")
    # Bring our window forward the way a user does: a real click on a VISIBLE part of it. Measured
    # 2026-09-23: `NSRunningApplication.activate`, `open <bundle>` with Settings already open, and a
    # real click on the menu's Settings... item all left TextEdit frontmost. The click lands in the
    # sidebar strip (the left 12%), where the worst it can do is switch the Settings page; the
    # content area holds toggles a click would flip.
    point = None
    wait_for("a visible point on our Settings window",
             lambda: (point := visible_point_in_sidebar(None)) is not None, deadline=5.0)
    point = visible_point_in_sidebar(None)
    if point is not None:
        si.click(*point)
    if not wait_for("our app frontmost", lambda: "enviouswispr" in (frontmost_bundle() or ""),
                    deadline=5.0):
        skip("own window", f"could not bring our window forward (front={frontmost_bundle()}, "
             f"clicked={point})")
        return
    base = log_size()
    chord("v")
    wait_for("a paste outcome", lambda: reuse_lines(base), deadline=5.0)
    check("own window: paste refuses", reuse_lines(base) == [("paste", "chord", "own_window")],
          str(reuse_lines(base)))
    set_clipboard_text("ew-uat-sentinel-own")
    base = log_size()
    chord("c")
    wait_for("a copy outcome", lambda: reuse_lines(base), deadline=5.0)
    check("own window: copy works", reuse_lines(base) == [("copy", "chord", "copied")]
          and clipboard_text() == expected, f"{reuse_lines(base)} clip={clipboard_text()!r}")
    w.close_window()


def bring_settings_forward(page):
    """Open Settings on `page` and make OUR app frontmost with a real click on its sidebar."""
    w.nav(page)
    point = None
    if wait_for("a visible point on our Settings window",
                lambda: visible_point_in_sidebar(None) is not None, deadline=5.0):
        point = visible_point_in_sidebar(None)
        si.click(*point)
    return wait_for("our app frontmost", lambda: "enviouswispr" in (frontmost_bundle() or ""),
                    deadline=5.0)


def keybind_box(label):
    from ui_helpers import find_all_elements, get_attr
    for el in find_all_elements(w._app, role="AXButton"):
        if get_attr(el, "AXDescription") == label:
            return el
    return None


def box_value(label):
    from ui_helpers import get_attr
    box = keybind_box(label)
    return str(get_attr(box, "AXValue") or "") if box is not None else None


def reset_button_for(label):
    """The 'Reset keybind to default' button on the same row as `label`'s box (nearest by y)."""
    from ui_helpers import element_center, find_all_elements, get_attr
    box = keybind_box(label)
    if box is None:
        return None
    by = element_center(box)[1]
    resets = [el for el in find_all_elements(w._app, role="AXButton")
              if get_attr(el, "AXDescription") == "Reset keybind to default"
              and element_center(el) is not None]
    return min(resets, key=lambda el: abs(element_center(el)[1] - by)) if resets else None


def visible_text(fragment):
    from ui_helpers import find_all_elements, get_attr
    return any(fragment in str(get_attr(el, "AXValue") or "")
               for el in find_all_elements(w._app, role="AXStaticText"))


def scroll_into_view(label):
    """Wheel-scroll the Settings content until `label`'s box is inside the window. The Last
    Dictation card sits below the fold (measured: y 1017 in an 863-point window), and a click there
    lands on nothing; `AXScrollToVisible` answered OK and moved nothing."""
    from ui_helpers import element_frame
    for _ in range(10):
        box = keybind_box(label)
        frame = element_frame(box) if box is not None else None
        if frame is None:
            return False
        if 60 < frame["y"] and frame["y"] + frame["height"] < 860:
            return True
        si.scroll(dy=-5 if frame["y"] + frame["height"] >= 860 else 5, x=900, y=500)
        time.sleep(0.3)  # settle: the scroll view animates; the frame is read after it lands
    return False


def capture_into(label, key, **mods):
    """Real click on the row's box (it starts listening), then one synthetic chord."""
    from ui_helpers import element_center
    if not scroll_into_view(label):
        return False
    box = keybind_box(label)
    point = element_center(box) if box is not None else None
    if point is None:
        return False
    si.click(*point)
    if not wait_for("the box to listen", lambda: box_value(label) == "Recording, press a key combination",
                    deadline=3.0):
        return False
    framed_press(key, **mods)
    return True


PASTE_BOX = "Paste last dictation keybind"
# The four keys' state before the keybinds phase touched them; `main` restores it EXACTLY (an
# absent key is deleted again, with the app down, since a running app writes its values back).
KEYBIND_STATE_BEFORE = {}
COPY_BOX = "Copy last dictation keybind"
DEFAULT_KEYS = ("pasteLastKeyCode", "pasteLastModifiersRaw", "copyLastKeyCode", "copyLastModifiersRaw")


def phase_keybinds(expected):
    """Rebind Paste Last and prove the NEW chord pastes and the OLD one no longer does; a duplicate
    and a standard Mac shortcut are refused before anything is saved; Reset puts the default back.

    These are the founder's real, shared settings. Before the run the four keys were ABSENT
    (defaults apply). Reset writes the default values back, which the app reads the same way; the
    run then deletes the four keys again only if they were absent, with the app's own values
    verified first.
    """
    print("\n== keybinds: rebind, prove it, refuse a duplicate and a system shortcut, reset")
    before = {k: defaults_value(k) for k in DEFAULT_KEYS}
    shipped = {"pasteLastKeyCode": "9", "pasteLastModifiersRaw": "1310720",
               "copyLastKeyCode": "8", "copyLastModifiersRaw": "1310720"}
    # Only on untouched settings: a user's own binding would be replaced by Reset's default.
    if any(before[k] not in (None, shipped[k]) for k in DEFAULT_KEYS):
        skip("keybinds", f"the saved bindings are customised ({before}); not touching them")
        return
    KEYBIND_STATE_BEFORE.update(before)
    if not bring_settings_forward("Keybinds"):
        skip("keybinds", f"could not bring our window forward (front={frontmost_bundle()})")
        return
    try:
        # 1. A combination holding the recording keybind's own modifier is refused: the founder's
        #    record key is a bare Option, and Control+Option+Command+V contains it.
        check("keybinds: capture 1 started", capture_into(PASTE_BOX, "v", ctrl=True, alt=True, cmd=True))
        clash = wait_for("the clash refusal", lambda: visible_text("Clashes with the recording keybind"),
                         deadline=3.0)
        check("keybinds: a combination using the recording keybind's modifier is refused",
              clash and box_value(PASTE_BOX) == "\u2303\u2318 V",
              f"refusal={clash} paste box={box_value(PASTE_BOX)!r}")
        # 2. Rebind Paste Last to Control+Shift+Command+V.
        check("keybinds: capture 2 started", capture_into(PASTE_BOX, "v", ctrl=True, shift=True, cmd=True))
        rebound = wait_for("the new keys", lambda: box_value(PASTE_BOX) == "\u2303\u21e7\u2318 V",
                           deadline=3.0)
        check("keybinds: Paste Last rebound to Control+Shift+Command+V", rebound,
              repr(box_value(PASTE_BOX)))
        # 3. A duplicate of that, into Copy Last: refused, nothing saved.
        check("keybinds: capture 3 started", capture_into(COPY_BOX, "v", ctrl=True, shift=True, cmd=True))
        refused = wait_for("the refusal", lambda: visible_text("Already used by Paste last dictation"),
                           deadline=3.0)
        check("keybinds: a duplicate is refused before saving",
              refused and box_value(COPY_BOX) == "\u2303\u2318 C",
              f"refusal={refused} copy box={box_value(COPY_BOX)!r}")
        # A standard Mac shortcut (Command+C) into Copy Last: refused.
        check("keybinds: capture 4 started", capture_into(COPY_BOX, "c", cmd=True))
        system = wait_for("the refusal", lambda: visible_text("standard Mac shortcut"), deadline=3.0)
        check("keybinds: a standard Mac shortcut is refused",
              system and box_value(COPY_BOX) == "\u2303\u2318 C",
              f"refusal={system} copy box={box_value(COPY_BOX)!r}")
        # 4. The new chord pastes; the old one does nothing.
        w.close_window()
        path = new_textedit_doc(f"3106-rebound-{RUN_ID}")
        require_front("com.apple.TextEdit", "keybinds")
        base = log_size()
        chord("v")
        # settle: an old chord that still worked would log its outcome inside this window
        time.sleep(1.5)
        check("keybinds: the OLD chord no longer pastes", reuse_lines(base) == [] and doc_text(path) == "",
              f"{reuse_lines(base)} doc={doc_text(path)!r}")
        base = log_size()
        chord("v", shift=True)
        wait_for("a paste outcome", lambda: reuse_lines(base), deadline=5.0)
        wait_for("the paste to arrive", lambda: doc_text(path) != "", deadline=5.0)
        check("keybinds: the NEW chord pastes exactly once",
              reuse_lines(base) == [("paste", "chord", "dispatched")] and doc_text(path) == expected,
              f"{reuse_lines(base)} doc={doc_text(path)!r}")
    finally:
        # 5. Reset, verified on the box and in the shared defaults.
        if bring_settings_forward("Keybinds"):
            from ui_helpers import perform_action
            scroll_into_view(PASTE_BOX)
            reset = reset_button_for(PASTE_BOX)
            if reset is not None:
                perform_action(reset, "AXPress")
        back = wait_for("the default keys", lambda: box_value(PASTE_BOX) == "\u2303\u2318 V",
                        deadline=3.0)
        check("keybinds: Reset restores Control+Command+V", back, repr(box_value(PASTE_BOX)))
        after = {k: defaults_value(k) for k in DEFAULT_KEYS}
        check("keybinds: Copy Last's saved keys never changed",
              after["copyLastKeyCode"] == before["copyLastKeyCode"]
              and after["copyLastModifiersRaw"] == before["copyLastModifiersRaw"], f"{before} -> {after}")
        w.close_window()


def defaults_value(key):
    import subprocess
    out = subprocess.run(["defaults", "read", "com.enviouswispr.app", key], capture_output=True,
                         text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def menu_rows():
    rows = w.status_menu_snapshot_real() or []
    titles = [r["title"] for r in rows]
    idx = next((i for i, t in enumerate(titles) if t.startswith("Paste Last Dictation")), None)
    item = rows[idx] if idx is not None else None
    after = titles[idx + 1] if idx is not None and idx + 1 < len(titles) else None
    return item, after


def phase_imported_only(expected):
    """History holding only imported transcripts: the item is disabled with no preview, and both
    chords refuse. Staged by the DEBUG input seam (`force_reuse_imported_only`), which makes the
    REAL eligibility check read every row as imported; the founder's History is not touched."""
    print("\n== imported-only History: nothing to reuse")
    item, _ = menu_rows()
    if not check("imported-only: positive control, the item is enabled before the fault",
                 bool(item and item["enabled"]), str(item)):
        return
    if not check("imported-only: fault armed", fault("force_reuse_imported_only") == "OK"):
        return
    try:
        item, after = menu_rows()
        check("imported-only: item disabled, no preview row",
              bool(item) and not item["enabled"] and after == "Transcribe a File...",
              f"item={item} next={after!r}")
        path = new_textedit_doc(f"3106-imported-{RUN_ID}")
        require_front("com.apple.TextEdit", "imported-only")
        set_clipboard_text("ew-uat-sentinel-imported")
        base = log_size()
        chord("v")
        wait_for("a paste outcome", lambda: reuse_lines(base), deadline=5.0)
        chord("c")
        wait_for("a copy outcome", lambda: len(reuse_lines(base)) >= 2, deadline=5.0)
        check("imported-only: both chords refuse with no_dictation, nothing written",
              reuse_lines(base) == [("paste", "chord", "no_dictation"), ("copy", "chord", "no_dictation")]
              and doc_text(path) == "" and clipboard_text() == "ew-uat-sentinel-imported",
              f"{reuse_lines(base)} doc={doc_text(path)!r} clip={clipboard_text()!r}")
    finally:
        cleared = fault("clear_reuse_fault") == "OK"
        item, _ = menu_rows()
        check("imported-only: cleared, the item is enabled again", cleared and bool(item and item["enabled"]),
              str(item))


def phase_deleted_after_render(expected):
    """The row the menu rendered is gone when the item is clicked: nothing is pasted. Staged by
    the one-shot DEBUG input seam (`force_reuse_drop_next_sampled_row`): the menu's own sample
    arms it, and the action's read by id then misses that row once."""
    print("\n== deleted after render: the clicked row is gone")
    path = new_textedit_doc(f"3106-deleted-{RUN_ID}")
    require_front("com.apple.TextEdit", "deleted after render")
    if not check("deleted-after-render: fault armed", fault("force_reuse_drop_next_sampled_row") == "OK"):
        return
    try:
        base = log_size()
        clicked = w.click_status_menu_item_real("Paste Last Dictation")
        wait_for("a menu outcome", lambda: reuse_lines(base), deadline=5.0)
        check("deleted-after-render: the rendered item was clickable, and the paste refused",
              clicked.get("clicked") and reuse_lines(base) == [("paste", "menu", "no_dictation")]
              and doc_text(path) == "", f"{clicked} {reuse_lines(base)} doc={doc_text(path)!r}")
        # Positive control: the seam is one-shot, so the next click pastes.
        require_front("com.apple.TextEdit", "deleted after render, control")
        base = log_size()
        w.click_status_menu_item_real("Paste Last Dictation")
        wait_for("a menu outcome", lambda: reuse_lines(base), deadline=5.0)
        wait_for("the paste to arrive", lambda: doc_text(path) != "", deadline=5.0)
        check("deleted-after-render: control, the next click pastes once",
              reuse_lines(base) == [("paste", "menu", "dispatched")] and doc_text(path) == expected,
              f"{reuse_lines(base)} doc={doc_text(path)!r}")
    finally:
        check("deleted-after-render: fault cleared", fault("clear_reuse_fault") == "OK")


def restore_keybind_state():
    """Put the four binding keys back EXACTLY as they were before the keybinds phase. A key that
    was ABSENT is deleted with the app DOWN (a running app writes its values back), then the app
    is relaunched with the endpoint. Values that were present are left as Reset wrote them only
    when equal; anything else is reported."""
    import subprocess
    if not KEYBIND_STATE_BEFORE:
        return True
    now = {k: defaults_value(k) for k in DEFAULT_KEYS}
    absent_again = [k for k, v in KEYBIND_STATE_BEFORE.items() if v is None and now[k] is not None]
    differing = [k for k, v in KEYBIND_STATE_BEFORE.items() if v is not None and now[k] != v]
    if differing:
        print(f"    (keybind keys differ from before and were NOT changed back: {differing})")
        return False
    if not absent_again:
        return True
    if not terminate_verified_dev_app("restore the keybind keys with the app down"):
        return False
    for key in absent_again:
        subprocess.run(["defaults", "delete", "com.enviouswispr.app", key], capture_output=True)
    ok = all(defaults_value(k) is None for k in absent_again)
    relaunched = launch_dev_app_with_endpoint()
    print(f"    (keybind keys {absent_again} deleted again: {ok}; app relaunched: {relaunched})")
    return ok and relaunched


def restore_toggle():
    from ui_helpers import find_all_elements, get_attr
    w.nav("Clipboard")
    for el in find_all_elements(w._app, role="AXCheckBox"):
        if get_attr(el, "AXDescription") == "Restore clipboard after paste":
            return el
    return None


def phase_restore_off(expected):
    """Restore OFF: the dictation stays on the clipboard. The toggle is the user's real setting
    (shared defaults domain), flipped through its own control and flipped back in `finally`."""
    print("\n== restore off: the dictation stays on the clipboard")
    from ui_helpers import get_attr, perform_action
    toggle = restore_toggle()
    if toggle is None or get_attr(toggle, "AXValue") != 1:
        skip("restore off", f"toggle missing or not ON to start (value={get_attr(toggle, 'AXValue') if toggle else None})")
        return
    perform_action(toggle, "AXPress")
    try:
        if not wait_for("the toggle to read OFF", lambda: get_attr(restore_toggle(), "AXValue") == 0,
                        deadline=3.0):
            skip("restore off", "the toggle did not turn off")
            return
        w.close_window()
        path = new_textedit_doc(f"3106-restoreoff-{RUN_ID}")
        require_front("com.apple.TextEdit", "restore off")
        set_clipboard_text("ew-uat-sentinel-restore-off")
        base = log_size()
        chord("v")
        wait_for("a paste outcome", lambda: reuse_lines(base), deadline=5.0)
        wait_for("the paste to arrive", lambda: doc_text(path) != "", deadline=5.0)
        # settle: restore would run 200 ms after the paste; wait past it before reading the board
        time.sleep(1.0)
        check("restore off: pasted once, and the dictation is still on the clipboard",
              doc_text(path) == expected and clipboard_text() == expected,
              f"doc={doc_text(path)!r} clip={clipboard_text()!r} lines={reuse_lines(base)}")
    finally:
        toggle = restore_toggle()
        if toggle is not None and get_attr(toggle, "AXValue") == 0:
            perform_action(toggle, "AXPress")
        check("restore off: the setting is back ON",
              wait_for("the toggle to read ON", lambda: get_attr(restore_toggle(), "AXValue") == 1,
                       deadline=3.0))
        w.close_window()


def phase_clipboard_manager(expected):
    """Another app writes the clipboard inside the restore window: our restore must stand down."""
    print("\n== clipboard manager: a write during the restore window survives")
    from AppKit import NSPasteboard
    path = new_textedit_doc(f"3106-manager-{RUN_ID}")
    require_front("com.apple.TextEdit", "clipboard manager")
    set_clipboard_text("ew-uat-sentinel-before-manager")
    board = NSPasteboard.generalPasteboard()
    start = board.changeCount()
    base = log_size()
    chord("v")
    # A manager records what was copied once the paste has been consumed; writing sooner races the
    # target app's own read of Cmd+V and pastes the manager's text instead (measured 2026-09-23).
    # So: see the app's write, see the paste land, then write inside the 200 ms restore window.
    if not wait_for("our paste's clipboard write", lambda: board.changeCount() > start, deadline=3.0,
                    poll=0.005):
        check("clipboard manager: staged", False, "never saw the app's clipboard write")
        return
    landed = wait_for("the paste to land", lambda: doc_text(path) != "", deadline=0.15, poll=0.005)
    set_clipboard_text("ew-uat-manager-write")
    if not landed:
        skip("clipboard manager", "the paste did not land inside the 200 ms restore window, so the "
             "manager write could not be staged between the paste and the restore")
        return
    wait_for("a restore decision", lambda: "Clipboard cleanup: op=restore" in log_since(base),
             deadline=3.0)
    tail = [l for l in log_since(base).splitlines() if "Clipboard cleanup: op=restore" in l]
    check("clipboard manager: restore stood down and the manager's write survived",
          clipboard_text() == "ew-uat-manager-write" and any("applied=false" in l for l in tail),
          f"clip={clipboard_text()!r} cleanup={tail}")
    check("clipboard manager: the paste still landed once", doc_text(path) == expected,
          repr(doc_text(path)[:80]))


def phase_recording_in_flight():
    """A chord pressed while recording is refused. Silent: the mic is BlackHole and nothing plays."""
    print("\n== recording in flight: Paste Last refuses while a take runs")
    from silent_audio import AudioRoute
    route = AudioRoute()
    route.install_restore_handlers()
    base = log_size()
    started = False
    try:
        route.apply()  # inside the try: a partial apply is restored by the finally below
        path = new_textedit_doc(f"3106-recording-{RUN_ID}")
        require_front("com.apple.TextEdit", "recording in flight")
        base = log_size()
        # The hands-free gesture on the record key (the harness's working primitive), not the
        # menu's Start/Stop, which on this route started an extra take (see `phase_dictate`).
        w.double_press_record_key()
        if not wait_for("recording to start", lambda: "Recording started" in log_since(base),
                        deadline=10.0):
            skip("recording in flight", "no Recording started line")
            return
        started = True
        mark = log_size()
        chord("v")
        wait_for("a paste outcome", lambda: reuse_lines(mark), deadline=5.0)
        # Read the document NOW, while the take is still running. Once it stops, the take itself
        # delivers: on this silent route the mic hears the app's own chime through the loopback,
        # and the recogniser has written it as "What?" (measured 2026-09-23). That text is the
        # recording's, not a paste this chord made.
        doc_at_refusal = doc_text(path)
        check("recording in flight: outcome recording, nothing pasted",
              reuse_lines(mark) == [("paste", "chord", "recording")] and doc_at_refusal == "",
              f"{reuse_lines(mark)} doc={doc_at_refusal!r}")
    finally:
        stopped = True
        try:
            if started:
                # settle: HotkeyService ignores a stop within 500 ms of locking (#2410)
                time.sleep(0.8)
                w.single_press_record_key()
                wait_for("the take to end", lambda: "dictation_terminal" in log_since(base),
                         deadline=30.0)
                check("recording in flight: exactly one take",
                      log_since(base).count("Recording started") == 1,
                      f"{log_since(base).count('Recording started')} takes")
            stopped = stop_any_live_take(base_offset=base)
        except Exception as exc:  # the teardown below must still run
            print(f"    (stopping the take raised {exc!r})")
            stopped = False
        end_take_then_restore(route, "recording in flight", stopped)


def end_take_then_restore(route, label, stopped):
    """Restore the REAL microphone only once no take can be listening. `stopped` says whether the
    take was confirmed ended. If not, the verified dev app is terminated; after a confirmed exit it
    is relaunched on the STILL-virtual route, so its microphone picker exists to be restored and
    read back. If neither is confirmed, the virtual route is LEFT in place and the run aborts with
    the recovery step, rather than handing a live take the founder's microphone."""
    if not stopped:
        exited = terminate_verified_dev_app(f"{label}: a take would not stop")
        if not exited:
            raise Aborted(f"{label}: a take may still be live and the dev app did not exit; the "
                          "virtual microphone is LEFT in place. Recover: quit the dev app, then "
                          "`python3 Tests/RuntimeUAT/silent_audio.py restore`.")
        if not launch_dev_app_with_endpoint():
            raise Aborted(f"{label}: the dev app did not relaunch; the virtual route is left in "
                          "place. Recover: `python3 Tests/RuntimeUAT/silent_audio.py restore`.")
    check(f"{label}: no take left running", True)
    if not check(f"{label}: all three audio devices restored", route.restore()):
        raise Aborted(f"{label}: the audio devices were not restored")


def dev_app_pid():
    """This worktree's running dev app, verified by executable path, or None. Never by name:
    the shipped app and other worktrees' builds share names (tools-and-apps.md)."""
    import subprocess
    exe = os.path.join(APP_BUNDLE, "Contents", "MacOS", "EnviousWispr")
    out = subprocess.run(["ps", "-eww", "-o", "pid=,command="], capture_output=True,
                         text=True).stdout
    pids = [int(line.split(None, 1)[0]) for line in out.splitlines()
            if line.strip() and line.split(None, 1)[1:] == [exe]]
    return pids[0] if len(pids) == 1 else None


def terminate_verified_dev_app(why):
    """TERM exactly this worktree's dev app (re-verified by path), wait for it to exit."""
    import signal as _signal
    pid = dev_app_pid()
    if pid is None:
        print(f"    (cannot stop the dev app for '{why}': not exactly one instance at {APP_BUNDLE})")
        return False
    print(f"    (terminating dev app pid {pid}: {why})")
    os.kill(pid, _signal.SIGTERM)
    return wait_for("the dev app to exit", lambda: dev_app_pid() is None, deadline=15.0)


def launch_dev_app_with_endpoint():
    """Open this worktree's dev app with the DEBUG fault endpoint on, and wait for it."""
    import subprocess
    import faultInjection as fi
    subprocess.run(["open", "--env", "EW_FAULT_INJECTION=1", APP_BUNDLE], check=False)
    up = wait_for("the fault endpoint", lambda: _endpoint_answers(fi), deadline=30.0)
    if up:
        w.connect()
    return up


def _endpoint_answers(fi):
    try:
        return fi.send("query_state").startswith("OK")
    except Exception:
        return False


def fault(command):
    import faultInjection as fi
    return fi.send(command)


def modifiers_cleared():
    """Post the clearing event, then READ the machine's modifier state back from both event
    sources (`wispr_eyes.modifier_flags`): any Control, Option, Shift or Command still down fails."""
    w.clear_modifier_flags()
    flags = w.modifier_flags()
    held = {source: value for source, value in (flags or {}).items() if value}
    if held:
        print(f"    (modifiers still down after clearing: {held})")
    return flags is not None and not held


def stop_any_live_take(base_offset):
    """Leave no recording running, whatever path got here (uat-testing.md RULE:
    prefer-test-recording-over-record-tts-for-unattended: a missed key release once left one live).
    Reads the app's own markers since `base_offset` (or the whole tail when None); stops with the
    record key, which ends a push-to-talk or hands-free take alike, and reports what it did."""
    offset = base_offset if base_offset is not None else max(0, log_size() - 20000)
    text = log_since(offset)
    last = None
    for line in text.splitlines():
        if "Recording started" in line:
            last = "start"
        elif "dictation_terminal" in line:
            last = "terminal"
    if last != "start":
        return True
    print("    (a take is still live; stopping it with the record key)")
    w.single_press_record_key()
    return wait_for("the live take to end",
                    lambda: log_since(offset).rfind("dictation_terminal")
                    > log_since(offset).rfind("Recording started"), deadline=30.0)


def close_run_documents():
    """Close the TextEdit documents THIS run opened (paths carry RUN_ID) without saving, delete
    their files, and return whether that is VERIFIED: the AppleScript exited 0, no open document
    carries this run's id afterwards, and no file of this run is left. Only this run's: the founder
    may have documents of his own open. Left open, they pile up across runs and cover our own
    window (measured 2026-09-23: 38 documents)."""
    import glob
    import subprocess
    tag = f"-{RUN_ID}.txt"
    close = subprocess.run(["osascript", "-e", f"""
tell application "TextEdit"
  repeat with i from (count documents) to 1 by -1
    try
      set p to path of document i
      if p ends with "{tag}" and p contains "ew-uat-3106-" then close document i saving no
    end try
  end repeat
end tell"""], capture_output=True, text=True)
    for path in glob.glob(f"/tmp/ew-uat-3106-*{tag}"):
        os.remove(path)
    left = subprocess.run(["osascript", "-e", 'tell application "TextEdit" to get path of every document'],
                          capture_output=True, text=True)
    still_open = [p for p in left.stdout.split(", ") if p.strip().endswith(tag)]
    ok = close.returncode == 0 and left.returncode == 0 and not still_open \
        and not glob.glob(f"/tmp/ew-uat-3106-*{tag}")
    if not ok:
        print(f"    (documents not verified closed: close rc={close.returncode} "
              f"list rc={left.returncode} still open={still_open})")
    return ok


PHASES = ["menu", "copy_chord", "paste_chord", "held_chord", "keys_held", "own_window",
          "keybinds", "clipboard_manager", "restore_off", "imported_only", "deleted_after_render",
          "recording_in_flight"]


# A phase that records plays the app's OWN start and stop sounds (the Sounds setting), which
# measure -41.9 dB here against -20.8 dB for one macOS alert beep and -91 dB for silence
# (2026-09-23). Only those phases get a ceiling between the two; every other phase must be silent.
RECORDING_PHASE_CEILING_DB = -30.0


def run_metered(name, fn, *args):
    """Run one phase with every sound going to BlackHole and fail it if macOS beeped: a beep
    means one of this phase's keys or clicks reached something that refused it."""
    from silent_audio import BeepMeter
    meter = BeepMeter(f"/tmp/ew-uat-3106-beep-{name}-{RUN_ID}.wav")
    with meter:
        fn(*args)
    db = meter.max_db()
    ceiling = (RECORDING_PHASE_CEILING_DB if name == "recording_in_flight"
               else BeepMeter.QUIET_CEILING_DB)
    check(f"{name}: no alert beep while it ran", db is not None and db < ceiling,
          f"max {db} dB, ceiling {ceiling} (silence -91, app chime -42, alert beep -21)")


def main():
    """`last_dictation_uat.py [probe | <phase> ...]`: no argument runs every phase."""
    if screen_is_locked():
        print("ABORT: the screen is locked; every verdict would be about the lock screen")
        return 2
    from silent_audio import AlertSink
    w._INPUT_WARN = False  # the harness's warning chime would read as a beep on the meter
    w.connect()
    try:
        snapshot = pasteboard_snapshot()
    except Aborted as e:
        print(f"ABORT: {e}")
        return 2
    wanted = sys.argv[1:] or ["all"]
    unknown = [a for a in wanted if a not in PHASES + ["all", "probe"]]
    if unknown:
        print(f"unknown phase(s) {unknown}; choose from probe, all, {', '.join(PHASES)}")
        return 2
    sink = AlertSink()
    if not sink.apply():
        restored = sink.restore()
        print("ABORT: the alert and output devices did not switch to BlackHole; the beep meter "
              "would hear nothing and a beep would reach the speakers. Devices restored: "
              f"{restored}" + ("" if restored else
                               " (NOT restored: run `python3 Tests/RuntimeUAT/silent_audio.py restore`)"))
        return 2
    try:
        if not _endpoint_answers(__import__("faultInjection")):
            print("    (the DEBUG fault endpoint is not up: relaunching this worktree's dev app with it)")
            if not (terminate_verified_dev_app("relaunch with EW_FAULT_INJECTION=1")
                    and launch_dev_app_with_endpoint()):
                raise Aborted("could not relaunch the dev app with the fault endpoint")
        # The meter's own control, before anything acts: it must read quiet, or no later
        # "no beep" verdict means anything.
        run_metered("control", lambda: None)
        probe = {}
        run_metered("probe", lambda: probe.setdefault("ok", phase_probe()))
        chords = probe.get("ok", False)
        if not chords:
            skip("chord phases", "synthetic chords do not reach this app's Carbon hotkey")
        if wanted != ["probe"]:
            expected = phase_dictate()
            chosen = PHASES if "all" in wanted else [p for p in PHASES if p in wanted]
            for name in chosen:
                if name != "menu" and not chords:
                    continue
                fn = globals()[f"phase_{name}"]
                if name in ("keys_held", "recording_in_flight"):
                    run_metered(name, fn)
                else:
                    run_metered(name, fn, expected)
    except Aborted as e:
        record("run", "ABORT", str(e))
    finally:
        # Each cleanup is attempted on its own and recorded; a failure in one never skips the
        # next, and the audio restore always runs last.
        for name, step in [
            ("DEBUG reuse fault cleared", lambda: fault("clear_reuse_fault") == "OK"),
            ("clipboard restored byte for byte", lambda: pasteboard_restore(snapshot)),
            ("keybind settings restored exactly", restore_keybind_state),
            ("modifier flags cleared", modifiers_cleared),
            ("run documents closed", close_run_documents),
        ]:
            try:
                check(name, bool(step()))
            except Exception as exc:
                check(name, False, repr(exc))
        try:
            check("devices restored", sink.restore())
        except Exception as exc:
            check("devices restored", False, repr(exc))
    passed = sum(1 for _, s, _ in results if s == "PASS")
    failed = [r for r in results if r[1] in ("FAIL", "ABORT")]
    skipped = sum(1 for _, s, _ in results if s == "SKIP")
    print(f"\n{passed} passed, {len(failed)} failed, {skipped} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
