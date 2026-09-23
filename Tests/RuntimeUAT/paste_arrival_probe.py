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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bundle", default="com.tinyspeck.slackmacgap")
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--limit", type=float, default=3.0, help="seconds to wait per paste")
    ap.add_argument("--focus-wait", type=float, default=60.0)
    args = ap.parse_args()

    simulate_input.DEFAULT_DELAY = 0  # no sleep after the key: the clock starts at the post
    enable_manual_ax(args.bundle)
    print(f"Waiting up to {args.focus_wait:.0f}s for a focused text box in {args.bundle}...", flush=True)
    if not wait_for_focus(args.bundle, args.focus_wait):
        print("ABORT: that app is not frontmost with a readable focused text box", flush=True)
        return 2
    snap = pasteboard_snapshot()
    results = []
    try:
        for i in range(args.reps):
            pid = ax_oracle.pid_for_bundle(args.bundle)
            if not (pid and ax_oracle.is_frontmost(pid)):
                print("ABORT: the app lost the front; stopping", flush=True)
                break
            r = one_trial(args.bundle, args.limit)
            results.append(r)
            print(f"paste {i + 1}: {r}", flush=True)
            # settle: spacing between trials so one paste's rendering cannot overlap the next clock
            time.sleep(0.8)
    finally:
        ok = pasteboard_restore(snap)
        print(f"clipboard restored: {ok}", flush=True)
    arrived = sorted(r["arrived_ms"] for r in results if r["verdict"] == "arrived")
    if arrived:
        print(f"SUMMARY {args.bundle}: {len(arrived)}/{len(results)} arrived; "
              f"min={arrived[0]} ms median={arrived[len(arrived) // 2]} ms max={arrived[-1]} ms", flush=True)
    else:
        print(f"SUMMARY {args.bundle}: nothing arrived in {len(results)} pastes", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
