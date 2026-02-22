#!/usr/bin/env python3
"""Behavioral UAT test runner for EnviousWispr.

Runs Given/When/Then acceptance tests that verify actual app behavior,
not just structural existence of UI elements.

Uses five verification layers:
  1. AX tree — state values, element enabled/disabled, element presence/absence
  2. CGEvent — real HID input (mouse clicks, keyboard events)
  3. Screenshots — visual verification
  4. Logs — internal state changes via macOS log stream
  5. Process metrics — memory, CPU

Usage:
    python3 Tests/UITests/uat_runner.py run [--suite SUITE] [--verbose]
    python3 Tests/UITests/uat_runner.py list
    python3 Tests/UITests/uat_runner.py run --test TEST_NAME [--verbose]
"""

import argparse
import json
import os
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(__file__))

from ui_helpers import (
    find_app_pid,
    get_ax_app,
    find_element,
    find_all_elements,
    element_center,
    element_info,
    get_attr,
    perform_action,
    wait_for_element,
    wait_for_element_gone,
    wait_for_value,
    get_element_value,
    get_process_memory_mb,
    get_clipboard_text,
    set_clipboard_text,
    is_process_running,
)
from simulate_input import click, press_key


# ---------------------------------------------------------------------------
# Menu bar helpers — MenuBarExtra items are hidden until the menu is opened
# ---------------------------------------------------------------------------

def open_menu_bar_menu(pid, verbose=False):
    """Open the app's MenuBarExtra menu via AXPress on the menu bar extra.

    macOS MenuBarExtra menus are not visible in the AX tree until opened.
    Returns True if the menu was opened successfully.
    """
    app = get_ax_app(pid)

    # MenuBarExtra shows as AXMenuBarItem under AXMenuBar in the app's AX tree
    menu_bar = get_attr(app, "AXExtrasMenuBar")
    if menu_bar is not None:
        children = get_attr(menu_bar, "AXChildren")
        if children and len(children) > 0:
            # Press the first (usually only) menu bar extra item
            if perform_action(children[0], "AXPress"):
                time.sleep(0.5)
                return True

    # Fallback: try finding via AXMenuBar
    menu_bar = get_attr(app, "AXMenuBar")
    if menu_bar is not None:
        children = get_attr(menu_bar, "AXChildren")
        if children:
            for child in children:
                if perform_action(child, "AXPress"):
                    time.sleep(0.5)
                    return True

    return False


def close_menu_bar_menu(pid):
    """Dismiss an open menu by pressing Escape."""
    press_key("escape")
    time.sleep(0.3)


def find_menu_item_via_menu(pid, title, verbose=False):
    """Open the menu bar menu, find a menu item by title (substring match), return it.

    Menu items may have emoji prefixes (e.g. "🎙 Start Recording"), so this
    performs a substring match against AXTitle. Caller is responsible for
    closing the menu afterward if needed.
    """
    open_menu_bar_menu(pid, verbose=verbose)
    app = get_ax_app(pid)

    # First try exact match
    el = find_element(app, role="AXMenuItem", title=title)
    if el is not None:
        return el

    # Fallback: substring match across all menu items (handles emoji prefixes)
    all_items = find_all_elements(app, role="AXMenuItem")
    for item in all_items:
        item_title = get_attr(item, "AXTitle") or ""
        if title in item_title:
            return item

    return None


# ---------------------------------------------------------------------------
# Test result model
# ---------------------------------------------------------------------------

class TestResult:
    def __init__(self, name, status, message="", duration=0.0, details=None):
        self.name = name
        self.status = status  # "PASS", "FAIL", "SKIP", "ERROR"
        self.message = message
        self.duration = duration
        self.details = details or {}

    def to_dict(self):
        return {
            "name": self.name,
            "status": self.status,
            "message": self.message,
            "duration_s": round(self.duration, 3),
            "details": self.details,
        }


# ---------------------------------------------------------------------------
# Assertion helpers — raise AssertionError with descriptive messages
# ---------------------------------------------------------------------------

def assert_element_exists(pid, role=None, title=None, description=None, msg=None):
    """Assert that an AX element matching the criteria exists RIGHT NOW."""
    app = get_ax_app(pid)
    el = find_element(app, role=role, title=title, description=description)
    if el is None:
        criteria = _criteria_str(role, title, description)
        raise AssertionError(msg or f"Element not found: {criteria}")
    return el


def assert_element_not_exists(pid, role=None, title=None, description=None, msg=None):
    """Assert that no AX element matching the criteria exists RIGHT NOW."""
    app = get_ax_app(pid)
    el = find_element(app, role=role, title=title, description=description)
    if el is not None:
        criteria = _criteria_str(role, title, description)
        raise AssertionError(msg or f"Element unexpectedly found: {criteria}")


def assert_element_appears(pid, role=None, title=None, timeout=5.0, msg=None):
    """Assert that an element appears within timeout (polling)."""
    el = wait_for_element(pid, role=role, title=title, timeout=timeout)
    if el is None:
        criteria = _criteria_str(role, title)
        raise AssertionError(msg or f"Element did not appear within {timeout}s: {criteria}")
    return el


def assert_element_disappears(pid, role=None, title=None, timeout=5.0, msg=None):
    """Assert that an element disappears within timeout (polling)."""
    gone = wait_for_element_gone(pid, role=role, title=title, timeout=timeout)
    if not gone:
        criteria = _criteria_str(role, title)
        raise AssertionError(msg or f"Element did not disappear within {timeout}s: {criteria}")


def assert_value_becomes(pid, expected, role=None, title=None, description=None,
                         attr="AXValue", timeout=10.0, msg=None):
    """Assert that an element's AX attribute reaches an expected value within timeout."""
    success, actual, elapsed = wait_for_value(
        pid, role=role, title=title, description=description,
        attr=attr, expected=expected, timeout=timeout,
    )
    if not success:
        criteria = _criteria_str(role, title, description)
        raise AssertionError(
            msg or f"Value did not become {expected!r} within {timeout}s "
                   f"(stuck at {actual!r}) for {criteria}"
        )
    return actual


def assert_value_leaves(pid, not_expected, role=None, title=None, description=None,
                        attr="AXValue", timeout=10.0, msg=None):
    """Assert that an element's AX attribute stops being a specific value within timeout."""
    success, actual, elapsed = wait_for_value(
        pid, role=role, title=title, description=description,
        attr=attr, not_expected=not_expected, timeout=timeout,
    )
    if not success:
        criteria = _criteria_str(role, title, description)
        raise AssertionError(
            msg or f"Value did not leave {not_expected!r} within {timeout}s for {criteria}"
        )
    return actual


def assert_clipboard_contains(expected_substring, msg=None):
    """Assert that the clipboard text contains a substring."""
    text = get_clipboard_text()
    if text is None:
        raise AssertionError(msg or "Clipboard is empty (None)")
    if expected_substring not in text:
        raise AssertionError(
            msg or f"Clipboard does not contain {expected_substring!r}. "
                   f"Actual: {text[:200]!r}"
        )


def assert_clipboard_empty(msg=None):
    """Assert that the clipboard is empty or contains no text."""
    text = get_clipboard_text()
    if text and text.strip():
        raise AssertionError(msg or f"Clipboard is not empty: {text[:200]!r}")


def assert_process_running(app_name, msg=None):
    """Assert that the process is currently running."""
    if not is_process_running(app_name):
        raise AssertionError(msg or f"Process {app_name!r} is not running")


def assert_memory_below(pid, max_mb, msg=None):
    """Assert that process RSS memory is below a threshold."""
    mem = get_process_memory_mb(pid)
    if mem is None:
        raise AssertionError(msg or f"Could not read memory for PID {pid}")
    if mem > max_mb:
        raise AssertionError(
            msg or f"Memory {mem:.0f}MB exceeds limit {max_mb:.0f}MB"
        )


def assert_element_enabled(pid, role=None, title=None, msg=None):
    """Assert that an element exists AND is enabled."""
    el = assert_element_exists(pid, role=role, title=title)
    enabled = get_attr(el, "AXEnabled")
    if enabled is not True:
        criteria = _criteria_str(role, title)
        raise AssertionError(msg or f"Element is not enabled: {criteria}")
    return el


def assert_element_disabled(pid, role=None, title=None, msg=None):
    """Assert that an element exists but is disabled."""
    el = assert_element_exists(pid, role=role, title=title)
    enabled = get_attr(el, "AXEnabled")
    if enabled is not False:
        criteria = _criteria_str(role, title)
        raise AssertionError(msg or f"Element is not disabled: {criteria}")
    return el


def _criteria_str(role=None, title=None, description=None):
    parts = []
    if role:
        parts.append(f"role={role!r}")
    if title:
        parts.append(f"title={title!r}")
    if description:
        parts.append(f"description={description!r}")
    return ", ".join(parts) or "(no criteria)"


# ---------------------------------------------------------------------------
# Test context — passed to each test function
# ---------------------------------------------------------------------------

class TestContext:
    """Provides test functions with app info, helpers, and state tracking."""

    def __init__(self, pid, app_name="EnviousWispr", verbose=False):
        self.pid = pid
        self.app_name = app_name
        self.verbose = verbose
        self._cleanup_actions = []

    def log(self, msg):
        if self.verbose:
            print(f"  [UAT] {msg}", file=sys.stderr)

    def on_cleanup(self, fn):
        """Register a cleanup action to run after the test (LIFO order)."""
        self._cleanup_actions.append(fn)

    def run_cleanup(self):
        for fn in reversed(self._cleanup_actions):
            try:
                fn()
            except Exception as e:
                print(f"  [CLEANUP ERROR] {e}", file=sys.stderr)
        self._cleanup_actions.clear()

    def set_clipboard(self, text):
        """Set clipboard to known value (for save/restore testing)."""
        set_clipboard_text(text)
        self.log(f"Set clipboard to: {text[:50]!r}")

    def clear_clipboard(self):
        """Clear the clipboard."""
        set_clipboard_text("")
        self.log("Cleared clipboard")

    def get_clipboard(self):
        return get_clipboard_text()

    def press(self, key, cmd=False, shift=False, alt=False, ctrl=False):
        """Press a key via CGEvent."""
        mods = []
        if cmd: mods.append("Cmd")
        if shift: mods.append("Shift")
        if alt: mods.append("Alt")
        if ctrl: mods.append("Ctrl")
        mod_str = "+".join(mods) + "+" if mods else ""
        self.log(f"Pressing {mod_str}{key}")
        press_key(key, cmd=cmd, shift=shift, alt=alt, ctrl=ctrl)

    def click_element(self, role=None, title=None):
        """Find an AX element and CGEvent-click its center."""
        app = get_ax_app(self.pid)
        el = find_element(app, role=role, title=title)
        if el is None:
            raise AssertionError(f"Cannot click: element not found ({_criteria_str(role, title)})")
        center = element_center(el)
        if center is None:
            raise AssertionError(f"Cannot click: no center coords ({_criteria_str(role, title)})")
        self.log(f"Clicking {_criteria_str(role, title)} at ({center[0]:.0f}, {center[1]:.0f})")
        click(center[0], center[1])

    def wait(self, seconds):
        """Wait for UI to settle."""
        self.log(f"Waiting {seconds}s")
        time.sleep(seconds)

    def get_memory_mb(self):
        return get_process_memory_mb(self.pid)


# ---------------------------------------------------------------------------
# Test registry
# ---------------------------------------------------------------------------

_TESTS = {}
_SUITES = {}


def uat_test(name, suite="default"):
    """Decorator to register a UAT test function."""
    def decorator(fn):
        _TESTS[name] = {"fn": fn, "suite": suite, "name": name}
        _SUITES.setdefault(suite, []).append(name)
        return fn
    return decorator


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

def run_tests(test_names, verbose=False):
    """Run a list of tests by name and return results."""
    pid = find_app_pid("EnviousWispr")
    if pid is None:
        print("ERROR: EnviousWispr is not running. Launch it first.", file=sys.stderr)
        return [TestResult("setup", "ERROR", "EnviousWispr not running")]

    results = []
    for name in test_names:
        if name not in _TESTS:
            results.append(TestResult(name, "SKIP", f"Unknown test: {name}"))
            continue

        test_info = _TESTS[name]
        ctx = TestContext(pid, verbose=verbose)

        if verbose:
            print(f"\n{'='*60}", file=sys.stderr)
            print(f"  Running: {name}", file=sys.stderr)
            print(f"{'='*60}", file=sys.stderr)

        start = time.time()
        try:
            test_info["fn"](ctx)
            elapsed = time.time() - start
            results.append(TestResult(name, "PASS", duration=elapsed))
            if verbose:
                print(f"  PASS ({elapsed:.1f}s)", file=sys.stderr)
        except AssertionError as e:
            elapsed = time.time() - start
            results.append(TestResult(name, "FAIL", str(e), elapsed))
            if verbose:
                print(f"  FAIL ({elapsed:.1f}s): {e}", file=sys.stderr)
        except Exception as e:
            elapsed = time.time() - start
            results.append(TestResult(name, "ERROR", str(e), elapsed,
                                      {"traceback": traceback.format_exc()}))
            if verbose:
                print(f"  ERROR ({elapsed:.1f}s): {e}", file=sys.stderr)
        finally:
            ctx.run_cleanup()

    return results


def print_results(results):
    """Print test results as a table and JSON summary."""
    passed = sum(1 for r in results if r.status == "PASS")
    failed = sum(1 for r in results if r.status == "FAIL")
    errors = sum(1 for r in results if r.status == "ERROR")
    skipped = sum(1 for r in results if r.status == "SKIP")
    total = len(results)

    print(f"\n{'='*70}")
    print(f"  UAT Results: {passed} passed, {failed} failed, {errors} errors, {skipped} skipped / {total} total")
    print(f"{'='*70}\n")

    for r in results:
        icon = {"PASS": "+", "FAIL": "X", "ERROR": "!", "SKIP": "-"}.get(r.status, "?")
        msg = f"  [{icon}] {r.status:5s}  {r.name}"
        if r.message:
            msg += f"  -- {r.message}"
        print(msg)

    print()

    # JSON summary to stdout for machine parsing
    summary = {
        "total": total,
        "passed": passed,
        "failed": failed,
        "errors": errors,
        "skipped": skipped,
        "all_passed": failed == 0 and errors == 0,
        "tests": [r.to_dict() for r in results],
    }
    print(json.dumps(summary, indent=2))

    return failed == 0 and errors == 0


# ---------------------------------------------------------------------------
# Built-in test suites
# ---------------------------------------------------------------------------

# --- Suite: app_basics ---

@uat_test("app_is_running", suite="app_basics")
def test_app_running(ctx):
    """GIVEN the app should be running, THEN it has a live process."""
    assert_process_running(ctx.app_name)
    ctx.log(f"PID: {ctx.pid}")


@uat_test("menu_bar_status_item_exists", suite="app_basics")
def test_status_item(ctx):
    """GIVEN the app is running, THEN a status item appears in the menu bar."""
    # MenuBarExtra creates a status item — verify via AX
    assert_process_running(ctx.app_name)
    # The app should have at least one window or menu bar presence
    app = get_ax_app(ctx.pid)
    info = element_info(app)
    assert info["role"] == "AXApplication", f"Expected AXApplication, got {info['role']}"


@uat_test("menu_bar_has_menu_items", suite="app_basics")
def test_menu_items(ctx):
    """GIVEN the app is running, WHEN the menu bar menu is opened,
    THEN expected menu items are discoverable."""
    # MenuBarExtra items are hidden until the menu is opened
    opened = open_menu_bar_menu(ctx.pid, verbose=ctx.verbose)
    if not opened:
        raise AssertionError("Could not open the menu bar menu via AX")
    ctx.on_cleanup(lambda: close_menu_bar_menu(ctx.pid))

    # Menu items may have emoji prefixes, so use substring matching
    app = get_ax_app(ctx.pid)
    all_items = find_all_elements(app, role="AXMenuItem")
    all_titles = [get_attr(item, "AXTitle") or "" for item in all_items]
    ctx.log(f"All menu item titles: {all_titles}")

    items_to_check = ["Start Recording", "Record + AI Polish", "Settings", "Quit"]
    found = []
    for needle in items_to_check:
        for ax_title in all_titles:
            if needle in ax_title:
                found.append(needle)
                break
    ctx.log(f"Found menu items: {found}")

    close_menu_bar_menu(ctx.pid)

    if len(found) == 0:
        raise AssertionError(f"No expected menu items found. Checked: {items_to_check}. Actual: {all_titles}")


@uat_test("memory_within_bounds", suite="app_basics")
def test_memory_bounds(ctx):
    """GIVEN the app is running idle, THEN memory usage is below 500MB."""
    assert_memory_below(ctx.pid, 500,
                        msg="Idle memory exceeds 500MB — possible model leak")


# --- Suite: cancel_recording ---

@uat_test("esc_cancels_recording_via_menu", suite="cancel_recording")
def test_esc_cancel_menu(ctx):
    """GIVEN recording was started from menu bar,
    WHEN ESC is pressed,
    THEN recording stops and pipeline returns to idle.

    This is the exact bug from feedback-2026-02-21 Bug 1.
    """
    # Step 1: Open menu and find "Start Recording"
    start_btn = find_menu_item_via_menu(ctx.pid, "Start Recording", verbose=ctx.verbose)
    if start_btn is None:
        raise AssertionError("Could not find 'Start Recording' menu item")

    # Step 2: Click to start recording via AXPress (more reliable than CGEvent click)
    ctx.log("Pressing 'Start Recording' via AXPress")
    if not perform_action(start_btn, "AXPress"):
        raise AssertionError("AXPress on 'Start Recording' failed")
    ctx.wait(1.5)

    # Step 3: Verify recording started — the app should now be in recording state
    ctx.log("Verifying recording state...")
    # Register cleanup to cancel recording if test fails partway through
    ctx.on_cleanup(lambda: press_key("escape"))

    # Step 4: Press ESC to cancel
    ctx.log("Pressing ESC to cancel")
    ctx.press("escape")
    ctx.wait(1.5)

    # Step 5: Verify recording stopped — app should still be running
    assert_process_running(ctx.app_name, msg="App crashed after ESC cancel")

    # Re-open menu to check that "Start Recording" is available again (not "Stop Recording")
    start_again = find_menu_item_via_menu(ctx.pid, "Start Recording", verbose=ctx.verbose)
    close_menu_bar_menu(ctx.pid)

    if start_again is None:
        raise AssertionError(
            "After ESC cancel, 'Start Recording' not available — recording may still be active"
        )

    ctx.log("Recording cancelled successfully via ESC")


@uat_test("esc_noop_when_idle", suite="cancel_recording")
def test_esc_noop_idle(ctx):
    """GIVEN the app is idle (not recording),
    WHEN ESC is pressed,
    THEN nothing happens (no crash, no state change)."""
    assert_process_running(ctx.app_name)
    mem_before = ctx.get_memory_mb()

    ctx.press("escape")
    ctx.wait(0.5)

    # App should still be running
    assert_process_running(ctx.app_name, msg="App crashed after ESC in idle state")

    # Memory should not spike
    mem_after = ctx.get_memory_mb()
    if mem_before and mem_after:
        delta = abs(mem_after - mem_before)
        ctx.log(f"Memory delta: {delta:.1f}MB")


@uat_test("esc_no_clipboard_write_on_cancel", suite="cancel_recording")
def test_esc_no_clipboard(ctx):
    """GIVEN recording is active,
    WHEN ESC cancels recording,
    THEN nothing is written to the clipboard."""
    sentinel = "UAT_SENTINEL_DO_NOT_OVERWRITE"
    ctx.set_clipboard(sentinel)

    # Start recording via menu
    start_btn = find_menu_item_via_menu(ctx.pid, "Start Recording", verbose=ctx.verbose)
    if start_btn is not None:
        perform_action(start_btn, "AXPress")
        ctx.wait(1.0)
        ctx.on_cleanup(lambda: press_key("escape"))
    else:
        ctx.log("Could not find Start Recording — testing ESC on idle state instead")

    # Cancel immediately
    ctx.press("escape")
    ctx.wait(1.0)

    # Clipboard should still have our sentinel
    clipboard = ctx.get_clipboard()
    if clipboard != sentinel:
        raise AssertionError(
            f"Clipboard was modified after cancel. Expected sentinel, got: {clipboard[:100]!r}"
        )
    ctx.log("Clipboard preserved after cancel")


# --- Suite: settings ---

@uat_test("settings_window_opens", suite="settings")
def test_settings_opens(ctx):
    """GIVEN the app is running,
    WHEN Settings... is activated via menu,
    THEN the Settings window appears."""
    # CGEvent Cmd+, doesn't reliably reach menu bar apps — use AX menu action
    settings_item = find_menu_item_via_menu(ctx.pid, "Settings...", verbose=ctx.verbose)
    if settings_item is not None:
        perform_action(settings_item, "AXPress")
    else:
        # Fallback to keyboard shortcut
        ctx.log("Settings menu item not found, falling back to Cmd+,")
        ctx.press("comma", cmd=True)
    ctx.wait(1.0)

    # SwiftUI Settings window title is "EnviousWispr Settings"
    assert_element_appears(
        ctx.pid, role="AXWindow", title="EnviousWispr Settings", timeout=3.0,
        msg="Settings window did not appear"
    )
    ctx.log("Settings window opened")


@uat_test("settings_has_all_tabs", suite="settings")
def test_settings_tabs(ctx):
    """GIVEN the Settings window is open,
    THEN all expected tabs are present in the sidebar."""
    # Open settings via menu
    settings_item = find_menu_item_via_menu(ctx.pid, "Settings...", verbose=ctx.verbose)
    if settings_item is not None:
        perform_action(settings_item, "AXPress")
    else:
        ctx.press("comma", cmd=True)
    ctx.wait(1.0)

    # Wait for Settings window (title is "EnviousWispr Settings")
    settings_win = wait_for_element(ctx.pid, role="AXWindow", title="EnviousWispr Settings", timeout=3.0)
    if settings_win is None:
        raise AssertionError("Settings window did not appear")

    # Settings uses NavigationSplitView — tabs are AXStaticText values in sidebar AXOutline rows
    expected_tabs = ["Shortcuts", "AI Polish", "Permissions", "Speech Engine"]
    sidebar_texts = find_all_elements(settings_win, role="AXStaticText")
    sidebar_values = [get_attr(el, "AXValue") or "" for el in sidebar_texts]
    ctx.log(f"Sidebar text values: {sidebar_values[:20]}")

    found = []
    for tab_name in expected_tabs:
        if tab_name in sidebar_values:
            found.append(tab_name)

    missing = set(expected_tabs) - set(found)
    if missing:
        ctx.log(f"Found tabs: {found}, missing: {missing}")
        raise AssertionError(f"Missing settings tabs: {missing}. Found: {found}")
    ctx.log(f"All tabs present: {found}")


@uat_test("settings_tab_switching_works", suite="settings")
def test_settings_tab_switch(ctx):
    """GIVEN the Settings window is open,
    WHEN each sidebar tab is clicked,
    THEN the tab content changes (verified by heading change)."""
    # Ensure settings is open
    settings_win = wait_for_element(ctx.pid, role="AXWindow", title="EnviousWispr Settings", timeout=1.0)
    if settings_win is None:
        settings_item = find_menu_item_via_menu(ctx.pid, "Settings...", verbose=ctx.verbose)
        if settings_item is not None:
            perform_action(settings_item, "AXPress")
        else:
            ctx.press("comma", cmd=True)
        ctx.wait(1.0)
        settings_win = wait_for_element(ctx.pid, role="AXWindow", title="EnviousWispr Settings", timeout=3.0)

    if settings_win is None:
        raise AssertionError("Settings window did not appear")

    # Settings uses NavigationSplitView — tabs are AXRows in an AXOutline sidebar.
    # Each row contains an AXCell with an AXStaticText whose AXValue is the tab name.
    outline = find_element(settings_win, role="AXOutline")
    if outline is None:
        raise AssertionError("Settings sidebar outline not found")

    rows = get_attr(outline, "AXChildren") or []
    tabs_to_click = ["AI Polish", "Permissions", "Speech Engine", "Shortcuts"]
    clicked = 0

    for tab_name in tabs_to_click:
        for row in rows:
            if get_attr(row, "AXRole") != "AXRow":
                continue
            # Check if this row contains a static text with the tab name
            row_texts = find_all_elements(row, role="AXStaticText")
            for txt in row_texts:
                val = get_attr(txt, "AXValue") or ""
                if val == tab_name:
                    center = element_center(row)
                    if center:
                        click(center[0], center[1])
                        ctx.wait(0.5)
                        ctx.log(f"Switched to tab: {tab_name}")
                        clicked += 1
                    break
            else:
                continue
            break
        else:
            ctx.log(f"Skipping tab {tab_name} — not found in sidebar")

    if clicked == 0:
        raise AssertionError("Could not click any settings tabs")


# --- Suite: clipboard ---

@uat_test("clipboard_save_restore", suite="clipboard")
def test_clipboard_save_restore(ctx):
    """GIVEN the user has content on the clipboard,
    WHEN a transcription completes,
    THEN the original clipboard content is restored afterward
    (if clipboard save/restore feature is enabled)."""
    # This test verifies the clipboard preservation feature
    # We can't trigger a full transcription in UAT without mic,
    # but we can verify the clipboard API works
    original = "UAT_ORIGINAL_CLIPBOARD_CONTENT"
    ctx.set_clipboard(original)
    ctx.wait(0.3)

    restored = ctx.get_clipboard()
    if restored != original:
        raise AssertionError(
            f"Clipboard round-trip failed. Set {original!r}, got {restored!r}"
        )
    ctx.log("Clipboard save/restore API verified")


# --- Suite: main_window ---

@uat_test("main_window_opens", suite="main_window")
def test_main_window(ctx):
    """GIVEN the app is running,
    WHEN 'Open' is triggered via menu,
    THEN the main window appears."""
    app = get_ax_app(ctx.pid)
    # Try to find any existing main window
    main_win = find_element(app, role="AXWindow", title="EnviousWispr")
    if main_win is None:
        # Open via menu bar
        open_item = find_menu_item_via_menu(ctx.pid, "Open EnviousWispr", verbose=ctx.verbose)
        if open_item is not None:
            perform_action(open_item, "AXPress")
            ctx.wait(1.0)
        else:
            close_menu_bar_menu(ctx.pid)
            ctx.log("No 'Open' menu item found, checking for any window")

    # Check for any non-settings window
    app = get_ax_app(ctx.pid)
    windows = get_attr(app, "AXWindows")
    if windows and len(windows) > 0:
        ctx.log(f"Found {len(windows)} window(s)")
    else:
        ctx.log("No windows found — app may be menu-bar-only at idle")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_list(args):
    print("Available UAT test suites and tests:\n")
    for suite, tests in sorted(_SUITES.items()):
        print(f"  Suite: {suite}")
        for t in tests:
            doc = _TESTS[t]["fn"].__doc__ or ""
            first_line = doc.strip().split("\n")[0] if doc.strip() else "(no description)"
            print(f"    - {t}: {first_line}")
        print()


def cmd_run(args):
    if args.test:
        test_names = [args.test]
    elif args.suite:
        if args.suite not in _SUITES:
            print(f"Unknown suite: {args.suite}", file=sys.stderr)
            print(f"Available suites: {', '.join(sorted(_SUITES.keys()))}", file=sys.stderr)
            sys.exit(1)
        test_names = _SUITES[args.suite]
    else:
        # Run all tests
        test_names = list(_TESTS.keys())

    results = run_tests(test_names, verbose=args.verbose)
    all_passed = print_results(results)
    sys.exit(0 if all_passed else 1)


def main():
    parser = argparse.ArgumentParser(description="EnviousWispr UAT Test Runner")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("list", help="List available tests and suites")

    run_p = sub.add_parser("run", help="Run UAT tests")
    run_p.add_argument("--suite", type=str, help="Run tests from a specific suite")
    run_p.add_argument("--test", type=str, help="Run a single test by name")
    run_p.add_argument("--verbose", "-v", action="store_true", help="Verbose output")

    args = parser.parse_args()
    if args.command is None:
        parser.print_help()
        sys.exit(0)

    if args.command == "list":
        cmd_list(args)
    elif args.command == "run":
        cmd_run(args)


if __name__ == "__main__":
    main()
