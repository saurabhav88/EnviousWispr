#!/usr/bin/env python3
"""paste_arrival_probe.py: how long after Cmd+V does pasted text appear in the focused field? (#3106)

The landing check's negative wait needs a MEASURED per-app arrival time, not a remembered one. The
#996 app matrix recorded Slack and Word text absent 25 ms after a paste and present about a second
later, sampled every 150 ms, which bounds arrival loosely. This probe samples every 5 ms.

It does not involve EnviousWispr. It puts a unique phrase on the clipboard, posts Cmd+V to the
frontmost app, and polls that app's focused element (`ax_oracle.read_focused`, the same reader the
paste bake-off trusts) until the phrase appears or the limit passes. It never presses Return and
restores the full clipboard (every item, every type) on every exit.

Usage: click into an EMPTY message box (a DM to yourself in Slack), then run
    python3 paste_arrival_probe.py --bundle com.tinyspeck.slackmacgap --reps 5
Tour mode measures each app the person clicks into, in turn, until --apps apps are done:
    python3 paste_arrival_probe.py --tour --apps 6 --reps 5
Terminals are refused in tour mode: the session running the probe usually lives in one.
The pasted phrases stay in the box; clear the box yourself afterwards.
"""

from __future__ import annotations

import argparse
import pathlib
import signal
import sys
import time
import uuid

HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "paste_oracles"))

import ax_oracle  # noqa: E402
import simulate_input  # noqa: E402
from last_dictation_uat import pasteboard_restore, pasteboard_snapshot, set_clipboard_text  # noqa: E402

POLL_S = 0.005
TOUR_REFUSED = {"com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2"}


def frontmost_app() -> tuple[str, int] | None:
    """(bundle, pid) of the app that owns focus, asked of each on-screen app's OWN `AXFrontmost`.

    Both `NSWorkspace.frontmostApplication()` and `runningApplications()` are maintained by
    workspace notifications that need a run loop this process does not spin: the first never
    moves, and the second never learns of an app launched after the probe started (measured
    2026-09-23: Word, opened mid-tour, was never found). The window server's on-screen list is a
    live query, so its owners are the candidates, and the pid found here is carried everywhere.
    """
    from AppKit import NSRunningApplication
    from Quartz import CGWindowListCopyWindowInfo, kCGNullWindowID, kCGWindowListOptionOnScreenOnly
    seen: set[int] = set()
    for window in CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID) or []:
        pid = int(window.get("kCGWindowOwnerPID", 0))
        if pid in seen or window.get("kCGWindowLayer", 1) != 0:
            continue
        seen.add(pid)
        if ax_oracle.is_frontmost(pid):
            app = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
            bundle = None if app is None else app.bundleIdentifier()
            return None if bundle is None else (str(bundle), pid)
    return None


def focused_element(pid: int):
    from ApplicationServices import AXUIElementCopyAttributeValue, AXUIElementCreateApplication
    err, value = AXUIElementCopyAttributeValue(
        AXUIElementCreateApplication(pid), "AXFocusedUIElement", None)
    return value if err == 0 else None


def require_target(pid: int, chosen) -> None:
    """The chosen app is still in front AND the chosen field still has focus, checked immediately
    before every paste: a focus move must never paste into a field the person did not choose."""
    from CoreFoundation import CFEqual
    if not ax_oracle.is_frontmost(pid):
        raise RuntimeError("target app lost the front before paste")
    current = focused_element(pid)
    if current is None or not CFEqual(current, chosen):
        raise RuntimeError("chosen field lost focus before paste")


def enable_manual_ax(pid: int) -> None:
    """Electron hosts expose their text only after AXManualAccessibility, as the app itself sets."""
    from ApplicationServices import AXUIElementCreateApplication, AXUIElementSetAttributeValue
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility", True)


def wait_for_next_app(done: set[str], timeout: float) -> tuple[str, int] | None:
    """The next frontmost app, not yet measured and not a terminal, with a readable focused box."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        front = frontmost_app()
        if front and front[0] not in done and front[0] not in TOUR_REFUSED:
            bundle, pid = front
            enable_manual_ax(pid)
            if ax_oracle.read_focused(bundle, pid=pid).ok:
                # The person must STAY in that box for 2 s: passing through an app on the way to
                # another (Cmd+Tab) must never paste into whatever that app had focused.
                print(f"  {bundle}: starting in 2 s unless you leave it", flush=True)
                stable_until = time.monotonic() + 2.0
                while time.monotonic() < stable_until and frontmost_app() == front:
                    time.sleep(0.1)  # settle: poll interval of the 2 s stay-put signal wait
                if frontmost_app() == front and ax_oracle.read_focused(bundle, pid=pid).ok:
                    return front
                continue
        time.sleep(0.25)  # settle: poll interval of a signal wait (focus state) bounded by `timeout`
    return None


def wait_for_focus(bundle: str, timeout: float) -> tuple[str, int] | None:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        front = frontmost_app()
        if front and front[0] == bundle:
            enable_manual_ax(front[1])
            if ax_oracle.read_focused(bundle, pid=front[1]).ok:
                return front
        time.sleep(0.25)  # settle: poll interval of a signal wait (focus state) bounded by `timeout`
    return None


def find_paste_menu_item(pid: int):
    """The menu bar item whose shortcut is plain Cmd+V: the app's Edit > Paste, found by shortcut
    rather than title so a localized menu still matches (the app's own Tier 2c route presses
    the same item through AX)."""
    from ApplicationServices import AXUIElementCreateApplication, AXUIElementCopyAttributeValue

    def attr(el, name):
        err, value = AXUIElementCopyAttributeValue(el, name, None)
        return value if err == 0 else None

    bar = attr(AXUIElementCreateApplication(pid), "AXMenuBar")
    for top in attr(bar, "AXChildren") or []:
        for menu in attr(top, "AXChildren") or []:
            for item in attr(menu, "AXChildren") or []:
                if attr(item, "AXMenuItemCmdChar") == "V" and attr(item, "AXMenuItemCmdModifiers") == 0:
                    return item
    return None


def one_trial(bundle: str, pid: int, chosen, limit_s: float, route: str = "key") -> dict:
    phrase = f"probe {uuid.uuid4().hex[:8]} "
    before = ax_oracle.read_focused(bundle, pid=pid)
    if not before.ok:
        return {"verdict": "unreadable", "why": before.why}
    # The menu item is found BEFORE the clock starts, so lookup time is never counted as arrival.
    item = find_paste_menu_item(pid) if route == "menu" else None
    if route == "menu" and item is None:
        raise RuntimeError(f"{bundle}: no Cmd+V menu item found")
    set_clipboard_text(phrase)
    # settle: the app's own cascade leaves the same gap between its board write and the key
    time.sleep(0.15)
    require_target(pid, chosen)
    samples = 0
    t0 = time.monotonic()
    if route == "key":
        simulate_input.press_key("v", cmd=True)
    else:
        from ApplicationServices import AXUIElementPerformAction
        if AXUIElementPerformAction(item, "AXPress") != 0:
            raise RuntimeError(f"{bundle}: AXPress on Paste failed")
    posted_ms = (time.monotonic() - t0) * 1000
    first_change_ms = None
    while True:
        elapsed = time.monotonic() - t0
        scan = ax_oracle.read_focused(bundle, pid=pid)
        samples += 1
        value = scan.fields[0].value if scan.ok and scan.fields else None
        if value is not None and first_change_ms is None and value != before.fields[0].value:
            first_change_ms = elapsed * 1000
        if value is not None and phrase.strip() in value:
            # The first AX observation after dispatch: an UPPER bound on arrival. A 5 ms sleep
            # between reads is not a guaranteed 5 ms sample period (each read takes its own time).
            return {"verdict": "arrived", "arrived_ms": round(elapsed * 1000, 1),
                    "first_change_ms": None if first_change_ms is None else round(first_change_ms, 1),
                    "post_ms": round(posted_ms, 1), "samples": samples}
        if elapsed > limit_s:
            return {"verdict": "not_seen", "limit_ms": limit_s * 1000,
                    "last_read": scan.why if not scan.ok else "readable", "samples": samples}
        time.sleep(POLL_S)  # settle: the probe's sampling interval IS the measurement resolution


def measure(bundle: str, pid: int, reps: int, limit: float, route: str = "key") -> list[dict]:
    chosen = focused_element(pid)  # the field the person chose, held for every repetition
    if chosen is None:
        raise RuntimeError(f"{bundle}: no focused field")
    results = []
    for i in range(reps):
        try:
            r = one_trial(bundle, pid, chosen, limit, route)
        except RuntimeError as error:
            # A safety refusal is incomplete evidence: the run fails rather than report a
            # shorter sample as if it were the requested one.
            raise RuntimeError(f"{bundle}: paste {i + 1}/{reps} aborted: {error}") from error
        results.append(r)
        print(f"  paste {i + 1}: {r}", flush=True)
        # settle: spacing between trials so one paste's rendering cannot overlap the next clock
        time.sleep(0.8)
    arrived = sorted(r["arrived_ms"] for r in results if r["verdict"] == "arrived")
    if arrived:
        print(f"SUMMARY {bundle} route={route}: {len(arrived)}/{len(results)} arrived; min={arrived[0]} ms "
              f"median={arrived[len(arrived) // 2]} ms max={arrived[-1]} ms", flush=True)
    else:
        print(f"SUMMARY {bundle} route={route}: nothing arrived in {len(results)} pastes", flush=True)
    return results


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bundle", default="com.tinyspeck.slackmacgap")
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--limit", type=float, default=3.0, help="seconds to wait per paste")
    ap.add_argument("--focus-wait", type=float, default=60.0)
    ap.add_argument("--route", choices=("key", "menu"), default="key",
                    help="key = synthetic Cmd+V; menu = AXPress on the app's Cmd+V menu item")
    ap.add_argument("--tour", action="store_true", help="measure each app the person clicks into")
    ap.add_argument("--apps", type=int, default=6, help="tour mode: how many apps to measure")
    args = ap.parse_args()
    if args.reps < 1 or args.apps < 1 or args.limit <= 0 or args.focus_wait <= 0:
        ap.error("reps, apps, limit, and focus-wait must be positive")

    from wispr_eyes import clear_modifier_flags, modifier_flags

    def stop(_signum, _frame):
        raise KeyboardInterrupt

    # Installed BEFORE the snapshot: SIGTERM (TaskStop) must run the restore below, not kill it.
    signal.signal(signal.SIGTERM, stop)
    simulate_input.DEFAULT_DELAY = 0  # no sleep after the key: the clock starts at the post
    snap = pasteboard_snapshot()
    try:
        if args.tour:
            done: set[str] = set()
            while len(done) < args.apps:
                print(f"Click into an empty text box in the next app ({len(done) + 1}/{args.apps})...",
                      flush=True)
                front = wait_for_next_app(done, args.focus_wait)
                if front is None:
                    print("No new app within the wait; ending the tour", flush=True)
                    break
                print(f"Measuring {front[0]}", flush=True)
                measure(front[0], front[1], args.reps, args.limit, args.route)
                done.add(front[0])
            if len(done) != args.apps:
                return 2
        else:
            print(f"Waiting up to {args.focus_wait:.0f}s for a focused text box in {args.bundle}...",
                  flush=True)
            front = wait_for_focus(args.bundle, args.focus_wait)
            if front is None:
                print("ABORT: that app is not frontmost with a readable focused text box", flush=True)
                return 2
            measure(front[0], front[1], args.reps, args.limit, args.route)
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            clear_modifier_flags()
            flags = modifier_flags()
            if flags is None or any(flags.values()):
                raise RuntimeError(f"modifiers remain held: {flags}")
        finally:
            ok = pasteboard_restore(snap)
            print(f"clipboard restored: {ok}", flush=True)
            if not ok:
                raise RuntimeError("clipboard restore failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
