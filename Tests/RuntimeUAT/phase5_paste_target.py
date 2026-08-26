"""Somewhere harmless for a UAT dictation's transcript to land.

Delivery targets the FRONTMOST app, so an unattended run pastes its transcript
into whatever the operator happened to have focused. Observed 2026-08-25: a run's
transcript typed itself into a live terminal's prompt box, one keypress away from
being submitted as a command.

**`open -a TextEdit` IS NOT A PASTE TARGET AND LOOKS LIKE ONE.** Measured on this
machine: with no document argument, TextEdit launches and puts up an **Open file
dialog** — the window list shows `Open` and `Save Panel Accessory View` and no
document window at all — and it does NOT take focus. `frontmostApplication`
stayed on the terminal. So the app appears in the Dock, nothing can be typed into
it, and the paste still lands where it always did.

That is the whole failure: the call SUCCEEDS, the app IS running, and none of the
three things the caller wanted is true. A `pgrep` for TextEdit confirms it, which
is exactly the check a caller would reach for.

So: open a REAL FILE, then report whether the app is frontmost and owns an
on-screen document window.

**BEST EFFORT, NEVER A GATE (founder, 2026-08-25: "i'm fine if it posts into
terminal").** An earlier version aborted the row when no target came forward.
That is the wrong trade: the transcript landing in a terminal is a tidiness
question the founder has settled, while a refused row costs a run. `ensure()`
returns its verdict for the report and callers ignore it.
"""

import pathlib
import subprocess
import time

SCRATCH = pathlib.Path.home() / "Library/Caches/EnviousWispr-uat-scratch.txt"
BUNDLE_ID = "com.apple.TextEdit"


def _frontmost():
    from AppKit import NSWorkspace

    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    return app.bundleIdentifier() if app else None


def _document_windows():
    """On-screen TextEdit windows that are NOT a panel or dialog."""
    import Quartz

    info = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
    out = []
    for x in info or []:
        if (x.get("kCGWindowOwnerName") or "") != "TextEdit":
            continue
        name = x.get("kCGWindowName") or ""
        b = x.get("kCGWindowBounds") or {}
        # A document window is titled after its file and is a real size; the Open
        # dialog is titled "Open" and the accessory view is a strip.
        if name in ("Open", "Save", "Save Panel Accessory View") or b.get("Height", 0) < 120:
            continue
        out.append({"id": x.get("kCGWindowNumber"), "name": name,
                    "w": round(b.get("Width", 0)), "h": round(b.get("Height", 0))})
    return out


def ensure(timeout=10.0):
    """Bring a real scratch document to the front. Returns (ok, detail)."""
    if not SCRATCH.exists():
        SCRATCH.write_text("EnviousWispr UAT scratch. Dictation transcripts land here.\n")

    subprocess.run(["open", "-a", "TextEdit", str(SCRATCH)], capture_output=True)

    deadline = time.time() + timeout
    while time.time() < deadline:
        docs = _document_windows()
        if docs and _frontmost() == BUNDLE_ID:
            return True, {"frontmost": BUNDLE_ID, "windows": docs}
        time.sleep(0.2)  # test-fixture-timer: waiting for the document to come forward

    return False, {"frontmost": _frontmost(), "windows": _document_windows(),
                   "why": "no frontmost TextEdit document window; a paste would land "
                          "in whatever IS frontmost"}
