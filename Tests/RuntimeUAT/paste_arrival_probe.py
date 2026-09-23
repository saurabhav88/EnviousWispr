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


def frontmost_bundle() -> str | None:
    """Asked of each regular app's OWN `AXFrontmost` (`ax_oracle.is_frontmost`).
    `NSWorkspace.frontmostApplication()` never moves in a process without a run loop; see
    `ax_oracle.is_frontmost` for the measurement."""
    from AppKit import NSApplicationActivationPolicyRegular, NSWorkspace
    for app in NSWorkspace.sharedWorkspace().runningApplications():
        if app.activationPolicy() == NSApplicationActivationPolicyRegular \
                and ax_oracle.is_frontmost(app.processIdentifier()):
            return None if app.bundleIdentifier() is None else str(app.bundleIdentifier())
    return None


def wait_for_next_app(done: set[str], timeout: float) -> str | None:
    """The next frontmost app, not yet measured and not a terminal, with a readable focused box."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        bundle = frontmost_bundle()
        if bundle and bundle not in done and bundle not in TOUR_REFUSED:
            enable_manual_ax(bundle)
            if ax_oracle.read_focused(bundle).ok:
                # The person must STAY in that box for 2 s: passing through an app on the way to
                # another (Cmd+Tab) must never paste into whatever that app had focused.
                print(f"  {bundle}: starting in 2 s unless you leave it", flush=True)
                stable_until = time.monotonic() + 2.0
                while time.monotonic() < stable_until and frontmost_bundle() == bundle:
                    time.sleep(0.1)  # settle: poll interval of the 2 s stay-put signal wait
                if frontmost_bundle() == bundle and ax_oracle.read_focused(bundle).ok:
                    return bundle
                continue
        time.sleep(0.25)  # settle: poll interval of a signal wait (focus state) bounded by `timeout`
    return None


def wait_for_focus(bundle: str, timeout: float) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        pid = ax_oracle.pid_for_bundle(bundle)
        if pid and ax_oracle.is_frontmost(pid) and ax_oracle.read_focused(bundle).ok:
            return True
        time.sleep(0.25)  # settle: poll interval of a signal wait (focus state) bounded by `timeout`
    return False


def enable_manual_ax(bundle: str) -> None:
    """Electron hosts expose their text only after AXManualAccessibility, as the app itself sets."""
    from ApplicationServices import AXUIElementCreateApplication, AXUIElementSetAttributeValue
    pid = ax_oracle.pid_for_bundle(bundle)
    if pid:
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility", True)


def one_trial(bundle: str, limit_s: float) -> dict:
    phrase = f"probe {uuid.uuid4().hex[:8]} "
    before = ax_oracle.read_focused(bundle)
    if not before.ok:
        return {"verdict": "unreadable", "why": before.why}
    set_clipboard_text(phrase)
    # settle: the app's own cascade leaves the same gap between its board write and the key
    time.sleep(0.15)
    samples = 0
    t0 = time.monotonic()
    simulate_input.press_key("v", cmd=True)
    posted_ms = (time.monotonic() - t0) * 1000
    first_change_ms = None
    while True:
        elapsed = time.monotonic() - t0
        scan = ax_oracle.read_focused(bundle)
        samples += 1
        value = scan.fields[0].value if scan.ok and scan.fields else None
        if value is not None and first_change_ms is None and value != before.fields[0].value:
            first_change_ms = elapsed * 1000
        if value is not None and phrase.strip() in value:
            return {"verdict": "arrived", "arrived_ms": round(elapsed * 1000, 1),
                    "first_change_ms": None if first_change_ms is None else round(first_change_ms, 1),
                    "post_ms": round(posted_ms, 1), "samples": samples}
        if elapsed > limit_s:
            return {"verdict": "not_seen", "limit_ms": limit_s * 1000,
                    "last_read": scan.why if not scan.ok else "readable", "samples": samples}
        time.sleep(POLL_S)  # settle: the probe's sampling interval IS the measurement resolution


def measure(bundle: str, reps: int, limit: float) -> list[dict]:
    results = []
    for i in range(reps):
        pid = ax_oracle.pid_for_bundle(bundle)
        if not (pid and ax_oracle.is_frontmost(pid)):
            print(f"  {bundle} lost the front; stopping this app", flush=True)
            break
        r = one_trial(bundle, limit)
        results.append(r)
        print(f"  paste {i + 1}: {r}", flush=True)
        # settle: spacing between trials so one paste's rendering cannot overlap the next clock
        time.sleep(0.8)
    arrived = sorted(r["arrived_ms"] for r in results if r["verdict"] == "arrived")
    if arrived:
        print(f"SUMMARY {bundle}: {len(arrived)}/{len(results)} arrived; min={arrived[0]} ms "
              f"median={arrived[len(arrived) // 2]} ms max={arrived[-1]} ms", flush=True)
    else:
        print(f"SUMMARY {bundle}: nothing arrived in {len(results)} pastes", flush=True)
    return results


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bundle", default="com.tinyspeck.slackmacgap")
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--limit", type=float, default=3.0, help="seconds to wait per paste")
    ap.add_argument("--focus-wait", type=float, default=60.0)
    ap.add_argument("--tour", action="store_true", help="measure each app the person clicks into")
    ap.add_argument("--apps", type=int, default=6, help="tour mode: how many apps to measure")
    args = ap.parse_args()

    simulate_input.DEFAULT_DELAY = 0  # no sleep after the key: the clock starts at the post
    snap = pasteboard_snapshot()
    try:
        if args.tour:
            done: set[str] = set()
            while len(done) < args.apps:
                print(f"Click into an empty text box in the next app ({len(done) + 1}/{args.apps})...",
                      flush=True)
                bundle = wait_for_next_app(done, args.focus_wait)
                if bundle is None:
                    print("No new app within the wait; ending the tour", flush=True)
                    break
                print(f"Measuring {bundle}", flush=True)
                measure(bundle, args.reps, args.limit)
                done.add(bundle)
        else:
            enable_manual_ax(args.bundle)
            print(f"Waiting up to {args.focus_wait:.0f}s for a focused text box in {args.bundle}...",
                  flush=True)
            if not wait_for_focus(args.bundle, args.focus_wait):
                print("ABORT: that app is not frontmost with a readable focused text box", flush=True)
                return 2
            measure(args.bundle, args.reps, args.limit)
    finally:
        ok = pasteboard_restore(snap)
        print(f"clipboard restored: {ok}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
