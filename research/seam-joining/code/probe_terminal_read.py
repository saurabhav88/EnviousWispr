"""What does reading a terminal's input line actually return? Read only.

The stress test refused to start because its "is the line empty" check never
became true, and a check like that is worth understanding before posting
another keystroke — a clear loop that cannot tell empty from full is a loop
that deletes things it was not asked to delete.

This posts NOTHING. It waits for the window to be focused, then prints the raw
screen tail, the same text after the chrome stripper, and again after the shell
prompt anchor, so it is obvious which stage is wrong.
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import join_hotkey as J  # noqa: E402
import probe_replace_routes as R  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wait", type=float, default=6.0)
    parser.add_argument("--type", default="",
                        help="a line to type, read back, and delete again")
    args = parser.parse_args()

    print(f"\nClick into the terminal. Starting in {args.wait} seconds. "
          f"Nothing is ever submitted.")
    time.sleep(args.wait)

    element, name, problem = J.focused()
    print(f"\nfrontmost: {name}")
    if problem:
        print(f"  {problem}")
        return 1
    print(f"  role: {R.attr(element, 'AXRole')}  caret: {J.caret_position(element)}")

    value = R.attr(element, "AXValue")
    if not isinstance(value, str):
        print("  no text value")
        return 1

    report(element, "empty box")

    if args.type:
        # A wrapped sentence is the case that broke: the reader lost the prompt
        # marker off the top of its window and handed back the whole screen.
        # Reproducing it needs a line long enough to wrap, in the real box.
        R.type_text(args.type)
        time.sleep(0.6)
        report(element, "after typing a line long enough to wrap")
        current = read_parsed(element)
        for _ in range(len(current) + 8):
            R.post_key(R.DELETE_KEY, settle=0.004)
        time.sleep(0.4)
        report(element, "after clearing again")
    return 0


def read_parsed(element):
    value = R.attr(element, "AXValue")
    if not isinstance(value, str):
        return ""
    return J.terminal_text(value)


def report(element, label):
    value = R.attr(element, "AXValue")
    if not isinstance(value, str):
        print(f"\n  {label}: no text value")
        return
    tail = value[-J.TERMINAL_WINDOW:]
    parsed = read_parsed(element)
    print(f"\n  {label}")
    print(f"    raw screen tail: {len(tail)} chars")
    print(f"    reads back as ({len(parsed)} chars): {parsed!r}")


if __name__ == "__main__":
    sys.exit(main())
