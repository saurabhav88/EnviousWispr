#!/usr/bin/env python3
"""CLI tool for simulating real human input via CGEvent (kCGHIDEventTap).

AX actions bypass hit-testing — a prior bug (MenuBarExtra click-routing,
commit fb6c254) was only caught by real mouse simulation.  This tool uses
CGEvent posting so the OS treats every event as genuine HID input.

Subcommands
-----------
click       — Click at screen coordinates.
move        — Move the mouse cursor.
key         — Press a key with optional modifiers.
type        — Type a string character by character.
find-click  — Find an AX element, then CGEvent-click its center.
"""

import argparse
import os
import sys
import time

# Allow importing ui_helpers from the same directory regardless of cwd.
sys.path.insert(0, os.path.dirname(__file__))

from Quartz import (
    CGEventCreateMouseEvent,
    CGEventCreateKeyboardEvent,
    CGEventCreateScrollWheelEvent,
    CGEventPost,
    CGEventSetFlags,
    CGEventSetType,
    CGEventSetIntegerValueField,
    CGPointMake,
    kCGEventLeftMouseDown,
    kCGEventLeftMouseUp,
    kCGEventRightMouseDown,
    kCGEventRightMouseUp,
    kCGEventMouseMoved,
    kCGEventKeyDown,
    kCGEventKeyUp,
    kCGEventFlagsChanged,
    kCGScrollEventUnitLine,
    kCGHIDEventTap,
    kCGMouseButtonLeft,
    kCGMouseButtonRight,
    kCGEventFlagMaskCommand,
    kCGEventFlagMaskShift,
    kCGEventFlagMaskAlternate,
    kCGEventFlagMaskControl,
    kCGKeyboardEventKeycode,
    kCGMouseEventClickState,
)

from ui_helpers import (
    find_app_pid,
    get_ax_app,
    find_element,
    element_center,
)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_DELAY = 0.1  # seconds between actions

# US keyboard layout — virtual key codes for macOS.
KEY_CODES = {
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
    "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
    "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
    "y": 16, "z": 6,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
    "8": 28, "9": 25,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "escape": 53,
    "delete": 51, "backspace": 51,
    "up": 126, "down": 125, "left": 123, "right": 124,
    "comma": 43, "period": 47, "slash": 44, "semicolon": 41,
    "minus": 27, "equal": 24, "bracket_left": 33, "bracket_right": 30,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
}

# Characters that require Shift on US layout.
_SHIFT_CHARS = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal",
    "{": "bracket_left", "}": "bracket_right", "|": "\\",
    ":": "semicolon", '"': "'", "<": "comma", ">": "period", "?": "slash",
    "~": "`",
}

# Extra mappings for punctuation that don't require Shift.
_PUNCT_CHARS = {
    " ": "space", "\n": "return", "\t": "tab",
    ",": "comma", ".": "period", "/": "slash", ";": "semicolon",
    "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
}


# ---------------------------------------------------------------------------
# Low-level event helpers
# ---------------------------------------------------------------------------

def move_mouse(x, y):
    """Move the mouse cursor to (x, y) via CGEvent."""
    point = CGPointMake(x, y)
    event = CGEventCreateMouseEvent(None, kCGEventMouseMoved, point, kCGMouseButtonLeft)
    CGEventPost(kCGHIDEventTap, event)
    time.sleep(DEFAULT_DELAY)


def click(x, y, button="left", double=False):
    """Click at (x, y).  Moves the cursor first, then posts down/up events.

    For double-click, kCGMouseEventClickState is set appropriately.
    """
    # Move cursor to target position first.
    move_mouse(x, y)

    point = CGPointMake(x, y)

    if button == "right":
        down_type = kCGEventRightMouseDown
        up_type = kCGEventRightMouseUp
        cg_button = kCGMouseButtonRight
    else:
        down_type = kCGEventLeftMouseDown
        up_type = kCGEventLeftMouseUp
        cg_button = kCGMouseButtonLeft

    # First click.
    down_event = CGEventCreateMouseEvent(None, down_type, point, cg_button)
    up_event = CGEventCreateMouseEvent(None, up_type, point, cg_button)
    CGEventSetIntegerValueField(down_event, kCGMouseEventClickState, 1)
    CGEventSetIntegerValueField(up_event, kCGMouseEventClickState, 1)
    CGEventPost(kCGHIDEventTap, down_event)
    CGEventPost(kCGHIDEventTap, up_event)
    time.sleep(DEFAULT_DELAY)

    if double:
        # Second click with click-state = 2.
        down_event2 = CGEventCreateMouseEvent(None, down_type, point, cg_button)
        up_event2 = CGEventCreateMouseEvent(None, up_type, point, cg_button)
        CGEventSetIntegerValueField(down_event2, kCGMouseEventClickState, 2)
        CGEventSetIntegerValueField(up_event2, kCGMouseEventClickState, 2)
        CGEventPost(kCGHIDEventTap, down_event2)
        CGEventPost(kCGHIDEventTap, up_event2)
        time.sleep(DEFAULT_DELAY)


def press_key(key_name, cmd=False, shift=False, alt=False, ctrl=False):
    """Press and release a key by name, with optional modifier flags."""
    key_lower = key_name.lower()
    if key_lower not in KEY_CODES:
        print(f"Error: unknown key '{key_name}'", file=sys.stderr)
        print(f"Available keys: {', '.join(sorted(KEY_CODES))}", file=sys.stderr)
        sys.exit(1)

    keycode = KEY_CODES[key_lower]

    # Build modifier flags.
    flags = 0
    if cmd:
        flags |= kCGEventFlagMaskCommand
    if shift:
        flags |= kCGEventFlagMaskShift
    if alt:
        flags |= kCGEventFlagMaskAlternate
    if ctrl:
        flags |= kCGEventFlagMaskControl

    # Key down.
    down_event = CGEventCreateKeyboardEvent(None, keycode, True)
    if flags:
        CGEventSetFlags(down_event, flags)
    CGEventPost(kCGHIDEventTap, down_event)

    # Key up.
    up_event = CGEventCreateKeyboardEvent(None, keycode, False)
    if flags:
        CGEventSetFlags(up_event, flags)
    CGEventPost(kCGHIDEventTap, up_event)

    time.sleep(DEFAULT_DELAY)


def type_text(text, delay=None):
    """Type *text* character by character, handling shift for uppercase."""
    if delay is None:
        delay = DEFAULT_DELAY

    for ch in text:
        needs_shift = False
        key_name = None

        if ch in _SHIFT_CHARS:
            # Shifted punctuation / symbol.
            needs_shift = True
            key_name = _SHIFT_CHARS[ch]
        elif ch in _PUNCT_CHARS:
            key_name = _PUNCT_CHARS[ch]
        elif ch.isalpha():
            if ch.isupper():
                needs_shift = True
            key_name = ch.lower()
        elif ch.isdigit():
            key_name = ch
        else:
            # Fallback — skip unsupported characters with a warning.
            print(f"Warning: skipping unsupported character {ch!r}", file=sys.stderr)
            continue

        if key_name not in KEY_CODES:
            print(f"Warning: no key code for {key_name!r} (char {ch!r})", file=sys.stderr)
            continue

        keycode = KEY_CODES[key_name]
        flags = kCGEventFlagMaskShift if needs_shift else 0

        down = CGEventCreateKeyboardEvent(None, keycode, True)
        up = CGEventCreateKeyboardEvent(None, keycode, False)
        if flags:
            CGEventSetFlags(down, flags)
            CGEventSetFlags(up, flags)

        CGEventPost(kCGHIDEventTap, down)
        CGEventPost(kCGHIDEventTap, up)
        time.sleep(delay)


# Modifier keycodes → flag masks (for flagsChanged events)
_MODIFIER_FLAGS = {
    54: kCGEventFlagMaskCommand,   # Right Command
    55: kCGEventFlagMaskCommand,   # Left Command
    58: kCGEventFlagMaskAlternate, # Left Option
    61: kCGEventFlagMaskAlternate, # Right Option
    56: kCGEventFlagMaskShift,     # Left Shift
    60: kCGEventFlagMaskShift,     # Right Shift
    59: kCGEventFlagMaskControl,   # Left Control
    62: kCGEventFlagMaskControl,   # Right Control
}

# Friendly names for modifier keys
MODIFIER_KEYS = {
    "rcmd": 54, "lcmd": 55, "lopt": 58, "ropt": 61,
    "lshift": 56, "rshift": 60, "lctrl": 59, "rctrl": 62,
}


def modifier_down(keycode):
    """Post a flagsChanged event with the modifier flag set (key press)."""
    flag = _MODIFIER_FLAGS.get(keycode, 0)
    event = CGEventCreateKeyboardEvent(None, keycode, True)
    CGEventSetType(event, kCGEventFlagsChanged)
    CGEventSetFlags(event, flag)
    # Ensure keycode survives the type change
    CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, keycode)
    CGEventPost(kCGHIDEventTap, event)


def modifier_up(keycode):
    """Post a flagsChanged event with flags cleared (key release)."""
    event = CGEventCreateKeyboardEvent(None, keycode, False)
    CGEventSetType(event, kCGEventFlagsChanged)
    CGEventSetFlags(event, 0)
    # Ensure keycode survives the type change
    CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, keycode)
    CGEventPost(kCGHIDEventTap, event)


def hold_modifier(keycode, duration=2.0):
    """Press a modifier key, hold for *duration* seconds, then release."""
    modifier_down(keycode)
    time.sleep(duration)
    modifier_up(keycode)


def scroll(dx=0, dy=0, x=None, y=None):
    """Scroll by (dx, dy) line units. Positive dy = scroll up, negative = down.

    If x, y are provided, moves the cursor there first (scroll targets the
    window under the cursor).
    """
    if x is not None and y is not None:
        move_mouse(x, y)
    event = CGEventCreateScrollWheelEvent(None, kCGScrollEventUnitLine, 2, int(dy), int(dx))
    CGEventPost(kCGHIDEventTap, event)
    time.sleep(DEFAULT_DELAY)


def hold_key(key_name, duration=2.0, cmd=False, shift=False, alt=False, ctrl=False):
    """Press and hold any key for *duration* seconds, then release.

    Works for both regular keys (space, a, return) and modifiers.
    For PTT testing: hold_key('space', duration=3.0)
    For modifier-only holds: hold_key('rcmd', duration=2.0)
    """
    key_lower = key_name.lower()

    # Check if it's a modifier key first
    if key_lower in MODIFIER_KEYS:
        hold_modifier(MODIFIER_KEYS[key_lower], duration)
        return

    if key_lower not in KEY_CODES:
        print(f"Error: unknown key '{key_name}'", file=sys.stderr)
        return

    keycode = KEY_CODES[key_lower]
    flags = 0
    if cmd:
        flags |= kCGEventFlagMaskCommand
    if shift:
        flags |= kCGEventFlagMaskShift
    if alt:
        flags |= kCGEventFlagMaskAlternate
    if ctrl:
        flags |= kCGEventFlagMaskControl

    # Key down
    down_event = CGEventCreateKeyboardEvent(None, keycode, True)
    if flags:
        CGEventSetFlags(down_event, flags)
    CGEventPost(kCGHIDEventTap, down_event)

    time.sleep(duration)

    # Key up
    up_event = CGEventCreateKeyboardEvent(None, keycode, False)
    if flags:
        CGEventSetFlags(up_event, flags)
    CGEventPost(kCGHIDEventTap, up_event)
    time.sleep(DEFAULT_DELAY)


def right_click(x, y):
    """Right-click at (x, y) via CGEvent."""
    move_mouse(x, y)
    point = CGPointMake(x, y)
    down = CGEventCreateMouseEvent(None, kCGEventRightMouseDown, point, kCGMouseButtonRight)
    up = CGEventCreateMouseEvent(None, kCGEventRightMouseUp, point, kCGMouseButtonRight)
    CGEventSetIntegerValueField(down, kCGMouseEventClickState, 1)
    CGEventSetIntegerValueField(up, kCGMouseEventClickState, 1)
    CGEventPost(kCGHIDEventTap, down)
    CGEventPost(kCGHIDEventTap, up)
    time.sleep(DEFAULT_DELAY)


def find_and_click(app_name, pid, role, title):
    """Locate an AX element and CGEvent-click its center.

    Uses ui_helpers for AX lookup, then falls through to click() for
    genuine HID simulation.
    """
    if pid is None and app_name is not None:
        pid = find_app_pid(app_name)
        if pid is None:
            print(f"Error: could not find running process '{app_name}'", file=sys.stderr)
            sys.exit(1)
    elif pid is None:
        print("Error: provide --app or --pid for find-click", file=sys.stderr)
        sys.exit(1)

    app = get_ax_app(pid)
    element = find_element(app, role=role, title=title)

    if element is None:
        print(f"Error: element not found (role={role!r}, title={title!r})", file=sys.stderr)
        sys.exit(1)

    center = element_center(element)
    if center is None:
        print("Error: could not determine element center coordinates", file=sys.stderr)
        sys.exit(1)

    x, y = center
    print(f"Found element at center ({x:.0f}, {y:.0f}), clicking...")
    click(x, y)


# ---------------------------------------------------------------------------
# Subcommand handlers
# ---------------------------------------------------------------------------

def cmd_click(args):
    button = "right" if args.right else "left"
    click(args.x, args.y, button=button, double=args.double)
    print(f"Clicked ({args.x}, {args.y}) button={button} double={args.double}")


def cmd_move(args):
    move_mouse(args.x, args.y)
    print(f"Moved cursor to ({args.x}, {args.y})")


def cmd_key(args):
    press_key(args.key_name, cmd=args.cmd, shift=args.shift, alt=args.alt, ctrl=args.ctrl)
    mods = []
    if args.cmd:
        mods.append("Cmd")
    if args.shift:
        mods.append("Shift")
    if args.alt:
        mods.append("Alt")
    if args.ctrl:
        mods.append("Ctrl")
    mod_str = "+".join(mods) + "+" if mods else ""
    print(f"Pressed {mod_str}{args.key_name}")


def cmd_type(args):
    type_text(args.text, delay=args.delay)
    print(f"Typed {len(args.text)} character(s)")


def cmd_find_click(args):
    find_and_click(args.app, args.pid, args.role, args.title)


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        description="Simulate real human input via CGEvent (kCGHIDEventTap).",
    )
    sub = parser.add_subparsers(dest="command")

    # click
    click_p = sub.add_parser("click", help="Click at screen coordinates")
    click_p.add_argument("x", type=float, help="X screen coordinate")
    click_p.add_argument("y", type=float, help="Y screen coordinate")
    click_p.add_argument("--right", action="store_true", help="Right-click instead of left")
    click_p.add_argument("--double", action="store_true", help="Double-click")

    # move
    move_p = sub.add_parser("move", help="Move mouse cursor")
    move_p.add_argument("x", type=float, help="X screen coordinate")
    move_p.add_argument("y", type=float, help="Y screen coordinate")

    # key
    key_p = sub.add_parser("key", help="Press a key with optional modifiers")
    key_p.add_argument("key_name", type=str, help="Key name (e.g. return, a, f1)")
    key_p.add_argument("--cmd", action="store_true", help="Hold Command")
    key_p.add_argument("--shift", action="store_true", help="Hold Shift")
    key_p.add_argument("--alt", action="store_true", help="Hold Option/Alt")
    key_p.add_argument("--ctrl", action="store_true", help="Hold Control")

    # type
    type_p = sub.add_parser("type", help="Type a string character by character")
    type_p.add_argument("text", type=str, help="Text to type")
    type_p.add_argument("--delay", type=float, default=None,
                        help=f"Delay between characters in seconds (default: {DEFAULT_DELAY})")

    # find-click
    fc_p = sub.add_parser("find-click", help="Find AX element and CGEvent-click its center")
    fc_p.add_argument("--app", type=str, help="Process name (resolved via pgrep -x)")
    fc_p.add_argument("--pid", type=int, help="Process ID")
    fc_p.add_argument("--role", type=str, required=True, help="AX role (e.g. AXButton)")
    fc_p.add_argument("--title", type=str, required=True, help="AX title to match")

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(0)

    if args.command == "click":
        cmd_click(args)
    elif args.command == "move":
        cmd_move(args)
    elif args.command == "key":
        cmd_key(args)
    elif args.command == "type":
        cmd_type(args)
    elif args.command == "find-click":
        cmd_find_click(args)


if __name__ == "__main__":
    main()
