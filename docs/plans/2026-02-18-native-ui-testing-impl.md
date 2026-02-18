# Native macOS UI Testing Toolkit — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Python + pyobjc UI testing toolkit for EnviousWispr that uses AX tree inspection to discover elements, CGEvent to simulate real human input, and screenshot diffing to verify results — packaged as four Claude skills.

**Architecture:** Three Python scripts (ax_inspect, simulate_input, screenshot_verify) share a common helpers module (ui_helpers.py). A fourth SKILL.md provides orchestration instructions. Each script is CLI-invocable with JSON output for automation.

**Tech Stack:** Python 3.9.6, pyobjc 11.1 (ApplicationServices, Quartz), Pillow, screencapture CLI

---

### Task 1: Install Pillow and set up directory structure

**Files:**
- Create: `Tests/UITests/__init__.py` (empty)
- Create: `Tests/UITests/baselines/.gitkeep`
- Modify: `.gitignore` (add screenshots line)

**Step 1: Install Pillow**

Run:
```bash
pip3 install Pillow
```
Expected: `Successfully installed Pillow-...`

**Step 2: Verify Pillow import**

Run:
```bash
python3 -c "from PIL import Image; print('OK')"
```
Expected: `OK`

**Step 3: Create directory structure**

Run:
```bash
mkdir -p Tests/UITests/baselines Tests/UITests/screenshots
touch Tests/UITests/__init__.py Tests/UITests/baselines/.gitkeep
```

**Step 4: Add screenshots to .gitignore**

Append to `.gitignore`:
```
# UI test screenshots (captured at runtime)
Tests/UITests/screenshots/
```

**Step 5: Commit**

```bash
git add Tests/UITests/__init__.py Tests/UITests/baselines/.gitkeep .gitignore
git commit -m "chore: scaffold UI test directory structure"
```

---

### Task 2: Build `ui_helpers.py` — shared AX utilities

**Files:**
- Create: `Tests/UITests/ui_helpers.py`

**Step 1: Write ui_helpers.py**

```python
"""Shared utilities for native macOS UI testing via Accessibility API."""

import time
import subprocess
from ApplicationServices import (
    AXUIElementCreateApplication,
    AXUIElementCreateSystemWide,
    AXUIElementCopyAttributeValue,
    AXUIElementCopyAttributeNames,
    AXUIElementCopyActionNames,
    AXUIElementPerformAction,
    kAXErrorSuccess,
)
from CoreFoundation import CFRange


def find_app_pid(app_name):
    """Find PID of a running app by process name.

    Args:
        app_name: Process name (e.g., 'EnviousWispr')

    Returns:
        int PID or None if not found
    """
    result = subprocess.run(
        ["pgrep", "-x", app_name], capture_output=True, text=True
    )
    if result.returncode == 0:
        return int(result.stdout.strip().split("\n")[0])
    return None


def get_ax_app(pid):
    """Create an AXUIElement for the app with the given PID.

    Args:
        pid: Process ID

    Returns:
        AXUIElement for the application
    """
    return AXUIElementCreateApplication(pid)


def get_attr(element, attr):
    """Get a single AX attribute value from an element.

    Args:
        element: AXUIElement
        attr: Attribute name string (e.g., 'AXRole', 'AXTitle')

    Returns:
        Attribute value, or None on error
    """
    err, value = AXUIElementCopyAttributeValue(element, attr, None)
    if err == kAXErrorSuccess:
        return value
    return None


def get_attr_names(element):
    """Get all attribute names for an element.

    Returns:
        List of attribute name strings, or empty list
    """
    err, names = AXUIElementCopyAttributeNames(element, None)
    if err == kAXErrorSuccess:
        return list(names)
    return []


def get_actions(element):
    """Get available actions for an element.

    Returns:
        List of action name strings, or empty list
    """
    err, actions = AXUIElementCopyActionNames(element, None)
    if err == kAXErrorSuccess:
        return list(actions)
    return []


def perform_action(element, action):
    """Perform an AX action on an element (e.g., 'AXPress').

    Args:
        element: AXUIElement
        action: Action name string

    Returns:
        True if successful, False otherwise
    """
    err = AXUIElementPerformAction(element, action)
    return err == kAXErrorSuccess


def element_info(element):
    """Extract key attributes from an AX element as a dict.

    Returns:
        dict with role, title, value, description, position, size, enabled, focused
    """
    info = {}
    info["role"] = get_attr(element, "AXRole") or ""
    info["subrole"] = get_attr(element, "AXSubrole") or ""
    info["title"] = get_attr(element, "AXTitle") or ""
    info["value"] = get_attr(element, "AXValue")
    info["description"] = get_attr(element, "AXDescription") or ""
    info["role_description"] = get_attr(element, "AXRoleDescription") or ""
    info["enabled"] = get_attr(element, "AXEnabled")
    info["focused"] = get_attr(element, "AXFocused")

    pos = get_attr(element, "AXPosition")
    if pos is not None:
        info["position"] = {"x": pos.x, "y": pos.y}
    else:
        info["position"] = None

    size = get_attr(element, "AXSize")
    if size is not None:
        info["size"] = {"w": size.width, "h": size.height}
    else:
        info["size"] = None

    info["actions"] = get_actions(element)
    return info


def element_center(element):
    """Get screen coordinates of the center of an element.

    Returns:
        (x, y) tuple, or None if position/size unavailable
    """
    pos = get_attr(element, "AXPosition")
    size = get_attr(element, "AXSize")
    if pos is None or size is None:
        return None
    return (pos.x + size.width / 2, pos.y + size.height / 2)


def walk_tree(element, max_depth=10, _depth=0):
    """Recursively walk the AX tree and return a nested dict.

    Args:
        element: AXUIElement root
        max_depth: Maximum recursion depth
        _depth: Current depth (internal)

    Returns:
        dict with element info and 'children' list
    """
    if _depth > max_depth:
        return {"truncated": True}

    node = element_info(element)
    children_ref = get_attr(element, "AXChildren")
    node["children"] = []
    if children_ref:
        for child in children_ref:
            node["children"].append(walk_tree(child, max_depth, _depth + 1))
    return node


def find_element(element, role=None, title=None, description=None, max_depth=10, _depth=0):
    """Search the AX tree for an element matching the given criteria.

    Args:
        element: AXUIElement root to search from
        role: AX role to match (e.g., 'AXButton', 'AXMenuItem')
        title: AX title to match
        description: AX description to match
        max_depth: Maximum search depth

    Returns:
        First matching AXUIElement, or None
    """
    if _depth > max_depth:
        return None

    matches = True
    if role and get_attr(element, "AXRole") != role:
        matches = False
    if title and get_attr(element, "AXTitle") != title:
        matches = False
    if description and get_attr(element, "AXDescription") != description:
        matches = False

    if matches and (role or title or description):
        return element

    children = get_attr(element, "AXChildren")
    if children:
        for child in children:
            result = find_element(child, role, title, description, max_depth, _depth + 1)
            if result is not None:
                return result
    return None


def find_all_elements(element, role=None, title=None, max_depth=10, _depth=0):
    """Find ALL elements matching criteria (not just the first).

    Returns:
        List of matching AXUIElements
    """
    if _depth > max_depth:
        return []

    results = []
    matches = True
    if role and get_attr(element, "AXRole") != role:
        matches = False
    if title and get_attr(element, "AXTitle") != title:
        matches = False

    if matches and (role or title):
        results.append(element)

    children = get_attr(element, "AXChildren")
    if children:
        for child in children:
            results.extend(find_all_elements(child, role, title, max_depth, _depth + 1))
    return results


def wait_for_element(pid, role=None, title=None, timeout=5.0, poll_interval=0.3):
    """Poll until an element matching criteria appears in the app's AX tree.

    Args:
        pid: App process ID
        role: AX role to match
        title: AX title to match
        timeout: Max seconds to wait
        poll_interval: Seconds between polls

    Returns:
        Matching AXUIElement, or None if timeout
    """
    app = get_ax_app(pid)
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = find_element(app, role=role, title=title)
        if result is not None:
            return result
        time.sleep(poll_interval)
    return None
```

**Step 2: Verify it loads**

Run:
```bash
cd Tests/UITests && python3 -c "from ui_helpers import find_app_pid, walk_tree; print('helpers OK')"
```
Expected: `helpers OK`

**Step 3: Commit**

```bash
git add Tests/UITests/ui_helpers.py
git commit -m "feat(test): add shared AX tree helpers for UI testing"
```

---

### Task 3: Build `ax_inspect.py` — AX tree inspection CLI

**Files:**
- Create: `Tests/UITests/ax_inspect.py`

**Step 1: Write ax_inspect.py**

```python
#!/usr/bin/env python3
"""Inspect the Accessibility tree of a running macOS application.

Usage:
    python3 ax_inspect.py --app EnviousWispr dump          # Full tree JSON
    python3 ax_inspect.py --app EnviousWispr find --role AXButton --title "Start Recording"
    python3 ax_inspect.py --app EnviousWispr diff old.json  # Diff against saved snapshot
    python3 ax_inspect.py --pid 12345 dump --depth 5       # By PID, limited depth
"""

import argparse
import json
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from ui_helpers import (
    find_app_pid,
    get_ax_app,
    walk_tree,
    find_element,
    find_all_elements,
    element_info,
    element_center,
)


def cmd_dump(args):
    """Dump the full AX tree as JSON."""
    app = get_ax_app(args.pid)
    tree = walk_tree(app, max_depth=args.depth)
    print(json.dumps(tree, indent=2, default=str))


def cmd_find(args):
    """Find elements matching criteria."""
    app = get_ax_app(args.pid)
    elements = find_all_elements(app, role=args.role, title=args.title, max_depth=args.depth)
    results = []
    for el in elements:
        info = element_info(el)
        center = element_center(el)
        info["center"] = {"x": center[0], "y": center[1]} if center else None
        results.append(info)
    print(json.dumps(results, indent=2, default=str))
    print(f"\nFound {len(results)} element(s)", file=sys.stderr)


def cmd_diff(args):
    """Diff current AX tree against a saved snapshot."""
    with open(args.snapshot_file) as f:
        old_tree = json.load(f)

    app = get_ax_app(args.pid)
    new_tree = walk_tree(app, max_depth=args.depth)

    diffs = diff_trees(old_tree, new_tree, path="root")
    if diffs:
        print(json.dumps(diffs, indent=2, default=str))
        print(f"\n{len(diffs)} difference(s) found", file=sys.stderr)
        sys.exit(1)
    else:
        print("No structural differences found.")
        sys.exit(0)


def diff_trees(old, new, path=""):
    """Compare two AX tree dicts and return list of differences."""
    diffs = []

    for key in ("role", "title", "description", "enabled"):
        old_val = old.get(key)
        new_val = new.get(key)
        if old_val != new_val:
            diffs.append({
                "path": path,
                "field": key,
                "old": old_val,
                "new": new_val,
            })

    old_children = old.get("children", [])
    new_children = new.get("children", [])

    if len(old_children) != len(new_children):
        diffs.append({
            "path": path,
            "field": "children_count",
            "old": len(old_children),
            "new": len(new_children),
        })

    for i, (oc, nc) in enumerate(zip(old_children, new_children)):
        child_path = f"{path} > [{i}] {nc.get('role', '?')}"
        if nc.get("title"):
            child_path += f" '{nc['title']}'"
        diffs.extend(diff_trees(oc, nc, child_path))

    return diffs


def main():
    parser = argparse.ArgumentParser(description="Inspect macOS app Accessibility tree")
    parser.add_argument("--app", help="App process name (e.g., EnviousWispr)")
    parser.add_argument("--pid", type=int, help="App PID (alternative to --app)")
    parser.add_argument("--depth", type=int, default=10, help="Max tree depth (default: 10)")

    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("dump", help="Dump full AX tree as JSON")

    find_parser = sub.add_parser("find", help="Find elements by role/title")
    find_parser.add_argument("--role", help="AX role (e.g., AXButton, AXMenuItem)")
    find_parser.add_argument("--title", help="AX title text")

    diff_parser = sub.add_parser("diff", help="Diff against saved snapshot")
    diff_parser.add_argument("snapshot_file", help="Path to saved JSON snapshot")

    args = parser.parse_args()

    if args.pid is None:
        if args.app is None:
            parser.error("Either --app or --pid is required")
        pid = find_app_pid(args.app)
        if pid is None:
            print(f"App '{args.app}' not found running", file=sys.stderr)
            sys.exit(1)
        args.pid = pid

    {"dump": cmd_dump, "find": cmd_find, "diff": cmd_diff}[args.command](args)


if __name__ == "__main__":
    main()
```

**Step 2: Verify it runs (help output)**

Run:
```bash
python3 Tests/UITests/ax_inspect.py --help
```
Expected: Usage text with dump/find/diff subcommands

**Step 3: Commit**

```bash
git add Tests/UITests/ax_inspect.py
git commit -m "feat(test): add AX tree inspection CLI (ax_inspect.py)"
```

---

### Task 4: Build `simulate_input.py` — CGEvent mouse/keyboard simulation

**Files:**
- Create: `Tests/UITests/simulate_input.py`

**Step 1: Write simulate_input.py**

```python
#!/usr/bin/env python3
"""Simulate real mouse and keyboard input via CGEvent.

Posts events through kCGHIDEventTap — same code path as physical hardware.
This catches bugs that AX actions miss (e.g., MenuBarExtra click-routing).

Usage:
    python3 simulate_input.py click 100 200                 # Left-click at (100, 200)
    python3 simulate_input.py click 100 200 --right          # Right-click
    python3 simulate_input.py click 100 200 --double          # Double-click
    python3 simulate_input.py move 100 200                   # Move mouse to (100, 200)
    python3 simulate_input.py key a                           # Press 'a'
    python3 simulate_input.py key v --cmd                     # Cmd+V
    python3 simulate_input.py key comma --cmd                 # Cmd+, (open settings)
    python3 simulate_input.py type "hello world"             # Type text
    python3 simulate_input.py find-click --app EnviousWispr --role AXMenuItem --title "Settings..."
"""

import argparse
import sys
import time
import os

import Quartz
from Quartz import (
    CGEventCreateMouseEvent,
    CGEventCreateKeyboardEvent,
    CGEventPost,
    CGEventSetFlags,
    CGEventSetIntegerValueField,
    kCGEventLeftMouseDown,
    kCGEventLeftMouseUp,
    kCGEventRightMouseDown,
    kCGEventRightMouseUp,
    kCGEventMouseMoved,
    kCGEventKeyDown,
    kCGEventKeyUp,
    kCGHIDEventTap,
    kCGMouseButtonLeft,
    kCGMouseButtonRight,
    kCGEventFlagMaskCommand,
    kCGEventFlagMaskShift,
    kCGEventFlagMaskAlternate,
    kCGEventFlagMaskControl,
    kCGKeyboardEventKeycode,
)

sys.path.insert(0, os.path.dirname(__file__))
from ui_helpers import find_app_pid, get_ax_app, find_element, element_center

# Common key code mapping (US keyboard layout)
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

DEFAULT_DELAY = 0.1


def move_mouse(x, y):
    """Move mouse cursor to screen coordinates."""
    point = Quartz.CGPointMake(x, y)
    event = CGEventCreateMouseEvent(None, kCGEventMouseMoved, point, kCGMouseButtonLeft)
    CGEventPost(kCGHIDEventTap, event)
    time.sleep(DEFAULT_DELAY)


def click(x, y, button="left", double=False):
    """Click at screen coordinates. Goes through HID event tap like real hardware."""
    point = Quartz.CGPointMake(x, y)

    if button == "right":
        down_type, up_type, btn = kCGEventRightMouseDown, kCGEventRightMouseUp, kCGMouseButtonRight
    else:
        down_type, up_type, btn = kCGEventLeftMouseDown, kCGEventLeftMouseUp, kCGMouseButtonLeft

    # Move first so the cursor is visible at the target
    move_mouse(x, y)

    click_count = 2 if double else 1
    for i in range(click_count):
        down = CGEventCreateMouseEvent(None, down_type, point, btn)
        CGEventSetIntegerValueField(down, Quartz.kCGMouseEventClickState, i + 1)
        CGEventPost(kCGHIDEventTap, down)
        time.sleep(0.05)

        up = CGEventCreateMouseEvent(None, up_type, point, btn)
        CGEventSetIntegerValueField(up, Quartz.kCGMouseEventClickState, i + 1)
        CGEventPost(kCGHIDEventTap, up)
        time.sleep(0.05)

    time.sleep(DEFAULT_DELAY)


def press_key(key_name, cmd=False, shift=False, alt=False, ctrl=False):
    """Press a key with optional modifiers."""
    key_code = KEY_CODES.get(key_name.lower())
    if key_code is None:
        print(f"Unknown key: {key_name}", file=sys.stderr)
        sys.exit(1)

    flags = 0
    if cmd:
        flags |= kCGEventFlagMaskCommand
    if shift:
        flags |= kCGEventFlagMaskShift
    if alt:
        flags |= kCGEventFlagMaskAlternate
    if ctrl:
        flags |= kCGEventFlagMaskControl

    down = CGEventCreateKeyboardEvent(None, key_code, True)
    up = CGEventCreateKeyboardEvent(None, key_code, False)
    if flags:
        CGEventSetFlags(down, flags)
        CGEventSetFlags(up, flags)

    CGEventPost(kCGHIDEventTap, down)
    time.sleep(0.05)
    CGEventPost(kCGHIDEventTap, up)
    time.sleep(DEFAULT_DELAY)


def type_text(text, delay=0.05):
    """Type a string character by character."""
    for char in text:
        key_name = char.lower()
        if char == " ":
            key_name = "space"
        elif char == "\n":
            key_name = "return"
        elif char == "\t":
            key_name = "tab"

        shift = char.isupper() or char in '!@#$%^&*()_+{}|:"<>?'
        code = KEY_CODES.get(key_name)
        if code is not None:
            press_key(key_name, shift=shift)
        time.sleep(delay)


def find_and_click(app_name=None, pid=None, role=None, title=None):
    """Find an element by AX attributes, then CGEvent-click its center.

    This is the critical function: uses AX to locate, CGEvent to click.
    If AX finds it but CGEvent click doesn't work, that's a real bug.
    """
    if pid is None:
        pid = find_app_pid(app_name)
        if pid is None:
            print(f"App '{app_name}' not found", file=sys.stderr)
            sys.exit(1)

    app = get_ax_app(pid)
    element = find_element(app, role=role, title=title)
    if element is None:
        print(f"Element not found: role={role} title={title}", file=sys.stderr)
        sys.exit(1)

    center = element_center(element)
    if center is None:
        print("Element found but has no position/size", file=sys.stderr)
        sys.exit(1)

    print(f"Found element at ({center[0]:.0f}, {center[1]:.0f}), clicking...", file=sys.stderr)
    click(center[0], center[1])
    print(f"Clicked at ({center[0]:.0f}, {center[1]:.0f})", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Simulate mouse/keyboard via CGEvent")
    sub = parser.add_subparsers(dest="command", required=True)

    # click
    click_p = sub.add_parser("click", help="Click at screen coordinates")
    click_p.add_argument("x", type=float, help="Screen X coordinate")
    click_p.add_argument("y", type=float, help="Screen Y coordinate")
    click_p.add_argument("--right", action="store_true", help="Right-click")
    click_p.add_argument("--double", action="store_true", help="Double-click")

    # move
    move_p = sub.add_parser("move", help="Move mouse to coordinates")
    move_p.add_argument("x", type=float, help="Screen X coordinate")
    move_p.add_argument("y", type=float, help="Screen Y coordinate")

    # key
    key_p = sub.add_parser("key", help="Press a key")
    key_p.add_argument("key_name", help="Key name (e.g., a, return, comma, f1)")
    key_p.add_argument("--cmd", action="store_true", help="Hold Command")
    key_p.add_argument("--shift", action="store_true", help="Hold Shift")
    key_p.add_argument("--alt", action="store_true", help="Hold Option/Alt")
    key_p.add_argument("--ctrl", action="store_true", help="Hold Control")

    # type
    type_p = sub.add_parser("type", help="Type a string")
    type_p.add_argument("text", help="Text to type")

    # find-click
    fc_p = sub.add_parser("find-click", help="Find element by AX attributes, then CGEvent-click it")
    fc_p.add_argument("--app", help="App process name")
    fc_p.add_argument("--pid", type=int, help="App PID")
    fc_p.add_argument("--role", help="AX role (e.g., AXButton)")
    fc_p.add_argument("--title", help="AX title text")

    args = parser.parse_args()

    if args.command == "click":
        click(args.x, args.y, button="right" if args.right else "left", double=args.double)
    elif args.command == "move":
        move_mouse(args.x, args.y)
    elif args.command == "key":
        press_key(args.key_name, cmd=args.cmd, shift=args.shift, alt=args.alt, ctrl=args.ctrl)
    elif args.command == "type":
        type_text(args.text)
    elif args.command == "find-click":
        find_and_click(app_name=args.app, pid=args.pid, role=args.role, title=args.title)


if __name__ == "__main__":
    main()
```

**Step 2: Verify it runs (help output)**

Run:
```bash
python3 Tests/UITests/simulate_input.py --help
```
Expected: Usage text with click/move/key/type/find-click subcommands

**Step 3: Commit**

```bash
git add Tests/UITests/simulate_input.py
git commit -m "feat(test): add CGEvent mouse/keyboard simulation CLI"
```

---

### Task 5: Build `screenshot_verify.py` — capture and pixel-diff

**Files:**
- Create: `Tests/UITests/screenshot_verify.py`

**Step 1: Write screenshot_verify.py**

```python
#!/usr/bin/env python3
"""Capture screenshots and compare against baselines for visual regression.

Uses macOS screencapture CLI for capture and Pillow for pixel diffing.

Usage:
    python3 screenshot_verify.py capture --name settings     # Capture and save
    python3 screenshot_verify.py capture --name menu --window EnviousWispr  # Specific window
    python3 screenshot_verify.py compare --name settings     # Compare against baseline
    python3 screenshot_verify.py baseline --name settings    # Save current as baseline
    python3 screenshot_verify.py compare-files a.png b.png   # Compare two arbitrary files
"""

import argparse
import json
import os
import subprocess
import sys
import time

from PIL import Image
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCREENSHOTS_DIR = os.path.join(SCRIPT_DIR, "screenshots")
BASELINES_DIR = os.path.join(SCRIPT_DIR, "baselines")

DEFAULT_TOLERANCE = 0.02  # 2% pixel difference allowed


def ensure_dirs():
    """Create screenshots and baselines dirs if needed."""
    os.makedirs(SCREENSHOTS_DIR, exist_ok=True)
    os.makedirs(BASELINES_DIR, exist_ok=True)


def capture_screenshot(name, window_name=None, region=None):
    """Capture a screenshot using macOS screencapture.

    Args:
        name: Base name for the file (e.g., 'settings')
        window_name: If set, capture only this window (by title match)
        region: If set, tuple (x, y, w, h) for region capture

    Returns:
        Path to the captured screenshot
    """
    ensure_dirs()
    timestamp = int(time.time())
    filepath = os.path.join(SCREENSHOTS_DIR, f"{name}_{timestamp}.png")

    cmd = ["screencapture"]

    if window_name:
        # -l flag captures a specific window by ID
        # We use -w for interactive window select in manual mode,
        # but for automation, capture full screen and crop later
        # or use CGWindowListCreateImage via python
        cmd.extend(["-x", filepath])  # -x suppresses sound
    elif region:
        x, y, w, h = region
        cmd.extend(["-x", "-R", f"{x},{y},{w},{h}", filepath])
    else:
        cmd.extend(["-x", filepath])

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"screencapture failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    print(f"Captured: {filepath}", file=sys.stderr)
    return filepath


def capture_window_by_pid(name, pid):
    """Capture a specific window using CGWindowListCreateImage via pyobjc.

    More reliable than screencapture for targeting specific app windows.
    """
    ensure_dirs()
    timestamp = int(time.time())
    filepath = os.path.join(SCREENSHOTS_DIR, f"{name}_{timestamp}.png")

    import Quartz
    # Get window list for the target PID
    window_list = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID,
    )

    target_window_id = None
    for window in window_list:
        if window.get("kCGWindowOwnerPID") == pid:
            target_window_id = window.get("kCGWindowNumber")
            break

    if target_window_id is None:
        print(f"No on-screen window found for PID {pid}", file=sys.stderr)
        sys.exit(1)

    image = Quartz.CGWindowListCreateImage(
        Quartz.CGRectNull,
        Quartz.kCGWindowListOptionIncludingWindow,
        target_window_id,
        Quartz.kCGWindowImageBoundsIgnoreFraming,
    )

    if image is None:
        print("Failed to capture window image", file=sys.stderr)
        sys.exit(1)

    # Convert CGImage to PNG via NSBitmapImageRep
    from AppKit import NSBitmapImageRep, NSPNGFileType
    rep = NSBitmapImageRep.alloc().initWithCGImage_(image)
    png_data = rep.representationUsingType_properties_(NSPNGFileType, {})
    png_data.writeToFile_atomically_(filepath, True)

    print(f"Captured window: {filepath}", file=sys.stderr)
    return filepath


def compare_images(path_a, path_b, tolerance=DEFAULT_TOLERANCE):
    """Compare two images pixel-by-pixel.

    Args:
        path_a: Path to first image (e.g., baseline)
        path_b: Path to second image (e.g., current screenshot)
        tolerance: Maximum fraction of differing pixels allowed (0.0-1.0)

    Returns:
        dict with pass/fail, diff_percent, diff_image_path
    """
    img_a = Image.open(path_a).convert("RGB")
    img_b = Image.open(path_b).convert("RGB")

    # Resize to match if dimensions differ
    if img_a.size != img_b.size:
        img_b = img_b.resize(img_a.size, Image.LANCZOS)

    arr_a = np.array(img_a, dtype=np.int16)
    arr_b = np.array(img_b, dtype=np.int16)

    # Per-pixel difference (sum of abs channel diffs)
    diff = np.abs(arr_a - arr_b)
    pixel_diff = diff.sum(axis=2)  # Sum RGB channels

    # A pixel is "different" if channel diff exceeds threshold (per channel)
    changed_mask = pixel_diff > 30  # ~12% per-channel tolerance
    diff_count = changed_mask.sum()
    total_pixels = changed_mask.size
    diff_percent = diff_count / total_pixels

    # Generate diff image: red overlay on changed pixels
    diff_img = img_b.copy()
    diff_arr = np.array(diff_img)
    diff_arr[changed_mask] = [255, 0, 0]  # Red for changed pixels
    diff_img = Image.fromarray(diff_arr)

    diff_path = path_b.replace(".png", "_diff.png")
    diff_img.save(diff_path)

    passed = diff_percent <= tolerance
    result = {
        "passed": passed,
        "diff_percent": round(diff_percent * 100, 3),
        "diff_pixels": int(diff_count),
        "total_pixels": int(total_pixels),
        "tolerance_percent": round(tolerance * 100, 3),
        "diff_image": diff_path,
        "image_a": path_a,
        "image_b": path_b,
    }
    return result


def cmd_capture(args):
    """Capture a screenshot."""
    if args.pid:
        path = capture_window_by_pid(args.name, args.pid)
    else:
        path = capture_screenshot(args.name)
    print(json.dumps({"path": path}))


def cmd_compare(args):
    """Compare current screenshot against baseline."""
    # Find latest screenshot with this name
    ensure_dirs()
    baseline = os.path.join(BASELINES_DIR, f"{args.name}.png")
    if not os.path.exists(baseline):
        print(f"No baseline found: {baseline}", file=sys.stderr)
        sys.exit(1)

    # Capture fresh screenshot
    if args.pid:
        current = capture_window_by_pid(args.name, args.pid)
    else:
        current = capture_screenshot(args.name)

    result = compare_images(baseline, current, tolerance=args.tolerance)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result["passed"] else 1)


def cmd_baseline(args):
    """Save current screenshot as baseline."""
    ensure_dirs()
    if args.pid:
        src = capture_window_by_pid(args.name, args.pid)
    else:
        src = capture_screenshot(args.name)

    dest = os.path.join(BASELINES_DIR, f"{args.name}.png")
    import shutil
    shutil.copy2(src, dest)
    print(f"Baseline saved: {dest}", file=sys.stderr)
    print(json.dumps({"baseline": dest}))


def cmd_compare_files(args):
    """Compare two arbitrary image files."""
    result = compare_images(args.file_a, args.file_b, tolerance=args.tolerance)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result["passed"] else 1)


def main():
    parser = argparse.ArgumentParser(description="Screenshot capture and visual regression")
    sub = parser.add_subparsers(dest="command", required=True)

    cap_p = sub.add_parser("capture", help="Capture a screenshot")
    cap_p.add_argument("--name", required=True, help="Screenshot name (e.g., 'settings')")
    cap_p.add_argument("--pid", type=int, help="Capture specific app window by PID")

    cmp_p = sub.add_parser("compare", help="Compare against baseline")
    cmp_p.add_argument("--name", required=True, help="Screenshot/baseline name")
    cmp_p.add_argument("--pid", type=int, help="Capture specific app window by PID")
    cmp_p.add_argument("--tolerance", type=float, default=DEFAULT_TOLERANCE, help="Max diff fraction (default: 0.02)")

    base_p = sub.add_parser("baseline", help="Save current as baseline")
    base_p.add_argument("--name", required=True, help="Baseline name")
    base_p.add_argument("--pid", type=int, help="Capture specific app window by PID")

    cf_p = sub.add_parser("compare-files", help="Compare two image files")
    cf_p.add_argument("file_a", help="First image path")
    cf_p.add_argument("file_b", help="Second image path")
    cf_p.add_argument("--tolerance", type=float, default=DEFAULT_TOLERANCE, help="Max diff fraction (default: 0.02)")

    args = parser.parse_args()
    {"capture": cmd_capture, "compare": cmd_compare, "baseline": cmd_baseline, "compare-files": cmd_compare_files}[args.command](args)


if __name__ == "__main__":
    main()
```

**Step 2: Verify it runs (help output)**

Run:
```bash
python3 Tests/UITests/screenshot_verify.py --help
```
Expected: Usage text with capture/compare/baseline/compare-files subcommands

**Step 3: Commit**

```bash
git add Tests/UITests/screenshot_verify.py
git commit -m "feat(test): add screenshot capture and pixel-diff CLI"
```

---

### Task 6: Create `ui-ax-inspect` SKILL.md

**Files:**
- Create: `.claude/skills/ui-ax-inspect/SKILL.md`

**Step 1: Write the skill file**

```markdown
---
name: ui-ax-inspect
description: "Use when inspecting the Accessibility tree of the running EnviousWispr app — discovering UI elements, getting positions, dumping tree structure, or diffing tree snapshots for regression."
---

# Inspect UI Accessibility Tree

## Prerequisites

- EnviousWispr must be running (`swift run EnviousWispr` or built binary)
- Terminal/IDE must have Accessibility permission (System Settings > Privacy > Accessibility)
- Python deps: pyobjc (installed)

## Commands

### Dump full AX tree
```bash
python3 Tests/UITests/ax_inspect.py --app EnviousWispr dump
```
Returns JSON tree. Pipe to file to save a snapshot:
```bash
python3 Tests/UITests/ax_inspect.py --app EnviousWispr dump > Tests/UITests/snapshots/tree_$(date +%s).json
```

### Find elements by role/title
```bash
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXButton --title "Start Recording"
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXTabGroup
```
Returns JSON array of matching elements with positions and center coordinates.

### Diff against saved snapshot
```bash
python3 Tests/UITests/ax_inspect.py --app EnviousWispr diff Tests/UITests/snapshots/baseline.json
```
Exit code 0 = no differences. Exit code 1 = differences found (printed as JSON).

## Common AX Roles in EnviousWispr

| Role | Where |
|------|-------|
| `AXMenuBar` | System menu bar |
| `AXStatusItem` | Menu bar icon |
| `AXMenu`, `AXMenuItem` | Menu bar dropdown items |
| `AXWindow` | Settings, Main, Onboarding windows |
| `AXTabGroup` | Settings tabs (General, Shortcuts, AI Polish, Permissions) |
| `AXButton` | Buttons, toggles |
| `AXTextField`, `AXSecureTextField` | Text inputs, API key fields |

## Output Format

All commands output JSON to stdout. Diagnostic messages go to stderr. Parse stdout for automation.
```

**Step 2: Commit**

```bash
mkdir -p .claude/skills/ui-ax-inspect
git add .claude/skills/ui-ax-inspect/SKILL.md
git commit -m "feat(test): add ui-ax-inspect skill"
```

---

### Task 7: Create `ui-simulate-input` SKILL.md

**Files:**
- Create: `.claude/skills/ui-simulate-input/SKILL.md`

**Step 1: Write the skill file**

```markdown
---
name: ui-simulate-input
description: "Use when simulating real human mouse clicks or keyboard input on the running EnviousWispr app. Uses CGEvent (HID event tap) — same code path as physical hardware. Critical for catching bugs that AX actions miss."
---

# Simulate Human Input via CGEvent

## Prerequisites

- EnviousWispr must be running
- Terminal/IDE must have Accessibility permission
- Python deps: pyobjc (installed)

## CRITICAL: Why CGEvent, Not AX Actions

AX actions (like AXPress) bypass the actual hit-testing path. A button can respond to
programmatic AXPress but be unclickable by a real mouse — this happened with SwiftUI
MenuBarExtra (commit fb6c254). Always use CGEvent for interaction testing.

## Commands

### Click at coordinates
```bash
python3 Tests/UITests/simulate_input.py click 100 200              # Left-click
python3 Tests/UITests/simulate_input.py click 100 200 --right       # Right-click
python3 Tests/UITests/simulate_input.py click 100 200 --double       # Double-click
```

### Move mouse
```bash
python3 Tests/UITests/simulate_input.py move 100 200
```

### Press keys
```bash
python3 Tests/UITests/simulate_input.py key return
python3 Tests/UITests/simulate_input.py key v --cmd                  # Cmd+V (paste)
python3 Tests/UITests/simulate_input.py key comma --cmd              # Cmd+, (settings)
python3 Tests/UITests/simulate_input.py key q --cmd                  # Cmd+Q (quit)
```

### Type text
```bash
python3 Tests/UITests/simulate_input.py type "hello world"
```

### Find element then click (AX locate → CGEvent click)
```bash
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXMenuItem --title "Settings..."
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXButton --title "Start Recording"
```
This is the **most important command** — it uses AX to find the element position, then posts
a real CGEvent click at those coordinates. If the click doesn't work but AX found the element,
you've found a real UI bug.

## Typical Test Flow

1. Use `ui-ax-inspect` to find the element and get its position
2. Use `simulate_input.py click` at those coordinates
3. Use `ui-screenshot-verify` to capture and verify the result
4. Use `ui-ax-inspect` again to verify state change in the AX tree
```

**Step 2: Commit**

```bash
mkdir -p .claude/skills/ui-simulate-input
git add .claude/skills/ui-simulate-input/SKILL.md
git commit -m "feat(test): add ui-simulate-input skill"
```

---

### Task 8: Create `ui-screenshot-verify` SKILL.md

**Files:**
- Create: `.claude/skills/ui-screenshot-verify/SKILL.md`

**Step 1: Write the skill file**

```markdown
---
name: ui-screenshot-verify
description: "Use when capturing screenshots of the running EnviousWispr app and comparing them against baselines for visual regression testing. Supports full-screen, per-window, and region capture."
---

# Screenshot Capture and Visual Regression

## Prerequisites

- EnviousWispr must be running (for app-specific captures)
- Python deps: pyobjc, Pillow (`pip3 install Pillow`)
- Screen recording permission may be needed (System Settings > Privacy > Screen Recording)

## Commands

### Capture a screenshot
```bash
python3 Tests/UITests/screenshot_verify.py capture --name settings
python3 Tests/UITests/screenshot_verify.py capture --name menu --pid $(pgrep -x EnviousWispr)
```
Saves to `Tests/UITests/screenshots/{name}_{timestamp}.png`. Using `--pid` captures only that app's window.

### Save as baseline
```bash
python3 Tests/UITests/screenshot_verify.py baseline --name settings --pid $(pgrep -x EnviousWispr)
```
Captures and copies to `Tests/UITests/baselines/{name}.png`. Baselines are committed to git.

### Compare against baseline
```bash
python3 Tests/UITests/screenshot_verify.py compare --name settings --pid $(pgrep -x EnviousWispr)
```
Exit code 0 = PASS (within tolerance). Exit code 1 = FAIL (too many pixels differ).
Outputs JSON with `diff_percent`, `diff_pixels`, `diff_image` path.

### Compare two arbitrary files
```bash
python3 Tests/UITests/screenshot_verify.py compare-files before.png after.png --tolerance 0.05
```

## Tolerance

Default: 2% pixel difference allowed. Adjust with `--tolerance`:
- `0.0` — exact match (very strict)
- `0.02` — 2% (default, handles minor anti-aliasing)
- `0.05` — 5% (loose, for layout-only checks)

## Storage

- `Tests/UITests/screenshots/` — captured during test runs (gitignored)
- `Tests/UITests/baselines/` — golden images (committed to git)

## Diff Image

On comparison, a `{name}_{timestamp}_diff.png` is generated with changed pixels highlighted in red.
```

**Step 2: Commit**

```bash
mkdir -p .claude/skills/ui-screenshot-verify
git add .claude/skills/ui-screenshot-verify/SKILL.md
git commit -m "feat(test): add ui-screenshot-verify skill"
```

---

### Task 9: Create `run-ui-test` SKILL.md — orchestration

**Files:**
- Create: `.claude/skills/run-ui-test/SKILL.md`

**Step 1: Write the skill file**

```markdown
---
name: run-ui-test
description: "Use when running full UI test scenarios for EnviousWispr — chains AX inspection, CGEvent simulation, and screenshot verification into automated test flows covering menu bar, settings, main window, and onboarding."
---

# Run UI Test Scenarios

## Prerequisites

- EnviousWispr must be **running** (`swift run EnviousWispr &` or built binary)
- Accessibility permission granted to terminal/IDE
- Screen recording permission granted (for screenshots)
- Python deps: pyobjc, Pillow

## Test Flow Pattern

Every test follows this sequence:

1. **AX inspect** — verify the target element exists
2. **CGEvent click** — simulate real human click
3. **Wait** — allow UI to settle (0.3-1s)
4. **Screenshot** — capture current state
5. **AX inspect** — verify expected state change
6. **Compare** — diff screenshot against baseline (if baseline exists)

If step 2 (CGEvent click) fails to produce the expected state change but step 1 confirmed the element exists, that's a **real UI bug** (like the MenuBarExtra click-routing issue in commit fb6c254).

## Test Scenarios

### 1. Menu Bar Status Item

```bash
# Verify status item exists
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuBar

# Click the status item to open menu
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXStatusItem

# Wait for menu to appear
sleep 0.5

# Verify menu items exist
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem --title "Start Recording"
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem --title "Settings..."
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem --title "Open VibeWhisper"
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem --title "Quit VibeWhisper"

# Screenshot the menu
python3 Tests/UITests/screenshot_verify.py capture --name menu_bar_open
```

### 2. Settings Window (4 Tabs)

```bash
# Open settings via menu item click
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXMenuItem --title "Settings..."
sleep 1

# Verify settings window appeared
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXWindow --title "Settings"

# Screenshot settings
python3 Tests/UITests/screenshot_verify.py capture --name settings_general --pid $(pgrep -x EnviousWispr)

# Verify all 4 tabs exist
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXRadioButton --title "General"
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXRadioButton --title "Shortcuts"
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXRadioButton --title "AI Polish"
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXRadioButton --title "Permissions"

# Click each tab and verify
for tab in "Shortcuts" "AI Polish" "Permissions" "General"; do
    python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXRadioButton --title "$tab"
    sleep 0.5
    python3 Tests/UITests/screenshot_verify.py capture --name "settings_${tab// /_}" --pid $(pgrep -x EnviousWispr)
done
```

### 3. Main Window

```bash
# Open main window
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXMenuItem --title "Open VibeWhisper"
sleep 1

# Verify main window appeared
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXWindow --title "VibeWhisper"

# Screenshot
python3 Tests/UITests/screenshot_verify.py capture --name main_window --pid $(pgrep -x EnviousWispr)

# Verify key UI elements exist
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXButton --title "Start Recording"
```

### 4. Full Regression Suite

Run all scenarios in sequence. For each step:
- If screenshot baseline exists → compare against it
- If no baseline → capture and save as baseline (first run)

```bash
# Check if baselines exist
if [ ! -f Tests/UITests/baselines/menu_bar_open.png ]; then
    echo "No baselines found — this run will create them"
    BASELINE_MODE=true
fi
```

## Interpreting Results

| AX says element exists | CGEvent click works | Screenshot matches | Verdict |
|------------------------|--------------------|--------------------|---------|
| Yes | Yes | Yes | PASS |
| Yes | No | No | UI BUG — element exists but not clickable |
| Yes | Yes | No | VISUAL REGRESSION — functionality OK but appearance changed |
| No | N/A | N/A | STRUCTURAL REGRESSION — element missing |

## Reporting

After running scenarios, summarize:
- Total steps run
- Pass/fail count
- For each failure: which step, what was expected, what happened
- Screenshots on failure (path to diff image if visual regression)
- AX tree dump on failure (save with `ax_inspect.py dump > failure_tree.json`)
```

**Step 2: Commit**

```bash
mkdir -p .claude/skills/run-ui-test
git add .claude/skills/run-ui-test/SKILL.md
git commit -m "feat(test): add run-ui-test orchestration skill"
```

---

### Task 10: Update testing agent and CLAUDE.md

**Files:**
- Modify: `.claude/agents/testing.md` (add UI test skills to owned skills list)
- Modify: `CLAUDE.md` (no change needed — skills auto-discovered)

**Step 1: Add UI test skills to testing agent**

In `.claude/agents/testing.md`, add to the Skills section:

```markdown
## Skills

- `run-smoke-test`
- `run-benchmarks`
- `validate-api-contracts`
- `ui-ax-inspect`
- `ui-simulate-input`
- `ui-screenshot-verify`
- `run-ui-test`
```

**Step 2: Commit**

```bash
git add .claude/agents/testing.md
git commit -m "docs: add UI test skills to testing agent"
```

---

### Task 11: Smoke-test the full toolkit against the running app

**Step 1: Build and launch EnviousWispr in background**

```bash
swift build && swift run EnviousWispr &
sleep 3
```

**Step 2: Test ax_inspect dump**

```bash
python3 Tests/UITests/ax_inspect.py --app EnviousWispr dump --depth 3 | head -50
```
Expected: JSON output with AXApplication root, children visible

**Step 3: Test ax_inspect find**

```bash
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem
```
Expected: JSON array of menu items (may be empty if menu not open)

**Step 4: Test simulate_input — click the status item**

```bash
python3 Tests/UITests/simulate_input.py find-click --app EnviousWispr --role AXStatusItem
sleep 0.5
python3 Tests/UITests/ax_inspect.py --app EnviousWispr find --role AXMenuItem
```
Expected: Menu items now visible after click

**Step 5: Test screenshot capture**

```bash
python3 Tests/UITests/screenshot_verify.py capture --name smoke_test
```
Expected: PNG file created in `Tests/UITests/screenshots/`

**Step 6: Clean up**

```bash
kill $(pgrep -x EnviousWispr) 2>/dev/null || true
```

**Step 7: Commit any fixes needed**

If any scripts needed adjustments during smoke testing, commit the fixes:
```bash
git add Tests/UITests/
git commit -m "fix(test): adjustments from UI test smoke run"
```
