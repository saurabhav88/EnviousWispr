"""How often does a burst of backspaces lose one?

The founder has now reported the same failure twice: the deletion stops one
character short and the pasted sentence arrives welded to a leftover letter. The
count is not the cause — the run on 2026-07-25 counted 46 characters, posted 46
backspaces, and 45 landed.

Terminals are the only surface still using backspace at all, because they expose
no caret to select against. So this measures the drop rate there directly rather
than reasoning about it: type a known line, post exactly as many backspaces as
it has characters, and read back how much survived.

Reports the distribution, not an average. One drop in twenty is a bug the user
meets weekly; one in two is a different problem entirely.
"""

import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import join_hotkey as J  # noqa: E402
import probe_replace_routes as R  # noqa: E402

# The exact sentence that failed for real, at its exact length. A longer line
# wraps inside a text box that has a border, and the wrap changes what reading
# the screen returns — which would measure the reader rather than the keystrokes.
LINE = "I am going to be very impressed if this works."


def read_line():
    element, _, problem = J.focused()
    if problem:
        return None
    value = J.attr(element, "AXValue")
    if not isinstance(value, str):
        return None
    return J.terminal_text(value).strip()


def clear():
    for _ in range(5):
        current = read_line() or ""
        if not current:
            return True
        for _ in range(len(current) + 6):
            R.post_key(R.DELETE_KEY, settle=0.006)
        time.sleep(0.3)
    return not (read_line() or "")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=20)
    parser.add_argument("--settle", type=float, default=0.004,
                        help="seconds between key down and key up, as shipped")
    parser.add_argument("--wait", type=float, default=6.0,
                        help="seconds to click into the window being tested")
    args = parser.parse_args()

    # Test the window the failure actually happened in, rather than a fresh
    # shell. A plain prompt and a full-screen text UI read keystrokes through
    # completely different paths, and only the second one has misbehaved.
    print(f"\nClick into the terminal to test. Starting in {args.wait} seconds.")
    print("Nothing is ever submitted: no Return is sent at any point.")
    time.sleep(args.wait)
    _, front = R.frontmost()
    if front not in ("Ghostty", "Terminal", "iTerm2", "Warp", "kitty", "WezTerm"):
        print(f"frontmost is {front}, which is not a terminal — aborting")
        return 1

    print(f"\n{args.runs} runs, {len(LINE)} characters each, "
          f"{args.settle * 1000:.0f} ms between key events\n")

    leftovers = []
    for run in range(1, args.runs + 1):
        if not clear():
            print(f"  run {run}: could not clear the line, skipping")
            continue
        R.type_text(LINE)
        time.sleep(0.4)
        staged = read_line()
        if staged != LINE:
            print(f"  run {run}: staged wrong, skipping ({staged!r})")
            continue

        for _ in range(len(LINE)):
            R.post_key(R.DELETE_KEY, settle=args.settle)
        time.sleep(0.4)
        after = read_line()
        if after is None:
            print(f"  run {run}: could not read back")
            continue
        leftovers.append(len(after))
        if after:
            print(f"  run {run}: {len(after)} character(s) survived  {after!r}")

    clear()
    if not leftovers:
        print("\nno usable runs")
        return 1

    clean = sum(1 for n in leftovers if n == 0)
    print(f"\n  {clean}/{len(leftovers)} bursts deleted everything")
    print(f"  worst leftover: {max(leftovers)} character(s)")
    print("  leftovers:", " ".join(str(n) for n in leftovers))
    return 0


if __name__ == "__main__":
    sys.exit(main())
