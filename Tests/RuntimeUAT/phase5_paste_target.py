"""Somewhere harmless for a UAT dictation's transcript to land.

Delivery targets the FRONTMOST app, so an unattended run pastes its transcript
into whatever the operator had focused.

**`open -a TextEdit` IS NOT A PASTE TARGET.** With no document argument TextEdit
launches, puts up an Open file DIALOG, and does NOT take focus — so the call
succeeds, `pgrep` confirms the app is running, and none of the three things the
caller wanted is true. Opening a REAL FILE is what produces a document window.

**BEST EFFORT, NEVER A GATE** (founder: "i'm fine if it posts into terminal").
`ensure()` reports whether a document window is frontmost; callers ignore it.
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
