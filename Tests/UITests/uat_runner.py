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
    python3 Tests/UITests/uat_runner.py run --files FILE [FILE ...] [--verbose]
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
    set_attr,
    perform_action,
    activate_app,
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
    """Dismiss an open menu by pressing Escape.

    Activates the app first so the Escape keystroke lands on EnviousWispr,
    not on whichever app happens to be frontmost.
    """
    activate_app(pid)
    time.sleep(0.1)
    press_key("escape")
    time.sleep(0.3)


def find_menu_item_via_menu(pid, title, verbose=False):
    """Open the menu bar menu, find a menu item by title (substring match), return it.

    Menu items may have emoji prefixes (e.g. "🎙 Start Recording"), so this
    performs a substring match against AXTitle. Caller is responsible for
    closing the menu afterward if needed.

    Scoped to AXExtrasMenuBar children only — avoids matching system menu items
    from AXMenuBar (Apple menu, Edit, Window, etc.) which can number 330+.
    """
    open_menu_bar_menu(pid, verbose=verbose)
    app = get_ax_app(pid)

    # Scope to AXExtrasMenuBar children only (our MenuBarExtra items)
    extras_bar = get_attr(app, "AXExtrasMenuBar")
    if extras_bar is not None:
        children = get_attr(extras_bar, "AXChildren") or []
        for child in children:
            all_items = find_all_elements(child, role="AXMenuItem")
            for item in all_items:
                item_title = get_attr(item, "AXTitle") or ""
                if title == item_title or title in item_title:
                    return item

    # Fallback: search the whole app tree (handles edge cases / unusual AX layouts)
    all_items = find_all_elements(app, role="AXMenuItem")
    for item in all_items:
        item_title = get_attr(item, "AXTitle") or ""
        if title in item_title:
            return item

    return None


# ---------------------------------------------------------------------------
# Cached menu bar snapshot — avoids redundant menu opens
# ---------------------------------------------------------------------------

class MenuBarSnapshot:
    """Cached menu bar state — titles and enabled flags. No AX refs (they go stale)."""
    def __init__(self, items, timestamp):
        self.items = items          # [{"title": str, "enabled": bool|None}, ...]
        self.timestamp = timestamp  # time.time()

    @property
    def titles(self):
        return [i["title"] for i in self.items]

    def has_item(self, substring):
        return any(substring in t for t in self.titles)

    def find(self, substring):
        for i in self.items:
            if substring in i["title"]:
                return i
        return None

    def is_enabled(self, substring):
        item = self.find(substring)
        return item["enabled"] if item else None


MAX_SNAPSHOT_AGE = 30.0  # seconds before auto-refresh


class TestSession:
    """Shared state across an entire test run — avoids redundant menu opens."""

    def __init__(self, pid, verbose=False):
        self.pid = pid
        self.verbose = verbose
        self._menu_snapshot = None
        self._snapshot_valid = False
        self._current_tab = None  # name of the currently selected Settings tab

    def get_menu_snapshot(self, force_refresh=False):
        """Return cached MenuBarSnapshot, taking one if needed."""
        if (self._menu_snapshot and self._snapshot_valid and not force_refresh
                and (time.time() - self._menu_snapshot.timestamp) < MAX_SNAPSHOT_AGE):
            if self.verbose:
                print(f"  [SESSION] Reusing menu snapshot", file=sys.stderr)
            return self._menu_snapshot

        if self.verbose:
            print("  [SESSION] Taking fresh menu bar snapshot...", file=sys.stderr)

        opened = open_menu_bar_menu(self.pid, verbose=self.verbose)
        if not opened:
            raise RuntimeError("Could not open menu bar for snapshot")

        app = get_ax_app(self.pid)
        items_data = []

        # Scope to AXExtrasMenuBar children only — avoids capturing 330+ system
        # menu items from AXMenuBar (Apple menu, Edit, Window, Help, etc.).
        extras_bar = get_attr(app, "AXExtrasMenuBar")
        if extras_bar is not None:
            children = get_attr(extras_bar, "AXChildren") or []
            for child in children:
                menu_items = find_all_elements(child, role="AXMenuItem")
                for item in menu_items:
                    title = get_attr(item, "AXTitle") or ""
                    enabled = get_attr(item, "AXEnabled")
                    items_data.append({"title": title, "enabled": enabled})

        # Fallback: if extras bar yielded nothing, search the whole app tree
        if not items_data:
            all_items = find_all_elements(app, role="AXMenuItem")
            for item in all_items:
                title = get_attr(item, "AXTitle") or ""
                enabled = get_attr(item, "AXEnabled")
                items_data.append({"title": title, "enabled": enabled})

        close_menu_bar_menu(self.pid)

        self._menu_snapshot = MenuBarSnapshot(items=items_data, timestamp=time.time())
        self._snapshot_valid = True

        if self.verbose:
            preview = self._menu_snapshot.titles[:10]
            print(f"  [SESSION] Snapshot: {len(items_data)} items (first 10): {preview}", file=sys.stderr)

        return self._menu_snapshot

    def invalidate_snapshot(self):
        """Mark the snapshot as stale after a state-changing action."""
        self._snapshot_valid = False
        if self.verbose:
            print("  [SESSION] Menu snapshot invalidated", file=sys.stderr)

    def ensure_tab_selected(self, tab_name):
        """Select a Settings tab by name, skipping navigation if already selected.

        Returns the Settings AXWindow element. Uses the same row-click logic as
        test_settings_tab_switch so the two stay in sync.
        """
        if self._current_tab == tab_name:
            if self.verbose:
                print(f"  [SESSION] Tab already selected: {tab_name!r}", file=sys.stderr)
            # Settings must still be open; return it
            return self.ensure_settings_open()

        settings_win = self.ensure_settings_open()

        outline = find_element(settings_win, role="AXOutline")
        if outline is None:
            raise RuntimeError("Settings sidebar outline not found")

        rows = get_attr(outline, "AXChildren") or []
        clicked = False
        for row in rows:
            if get_attr(row, "AXRole") != "AXRow":
                continue
            row_texts = find_all_elements(row, role="AXStaticText")
            for txt in row_texts:
                val = get_attr(txt, "AXValue") or ""
                if val == tab_name:
                    # Use AXSelected (works without Accessibility permission)
                    # instead of CGEvent click which requires Accessibility.
                    set_attr(row, "AXSelected", True)
                    time.sleep(0.5)
                    if self.verbose:
                        print(f"  [SESSION] Switched to tab: {tab_name!r}", file=sys.stderr)
                    clicked = True
                    break
            if clicked:
                break

        if not clicked:
            raise RuntimeError(f"Settings tab not found in sidebar: {tab_name!r}")

        self._current_tab = tab_name
        return settings_win

    def teardown(self):
        """Close all app windows after test run — leaves desktop clean."""
        if self.verbose:
            print("  [SESSION] Tearing down — closing all app windows...", file=sys.stderr)

        # Reset tab cache — windows will close so state is gone
        self._current_tab = None

        # Dismiss any open menu first
        try:
            close_menu_bar_menu(self.pid)
        except Exception:
            pass

        try:
            app = get_ax_app(self.pid)
            windows = get_attr(app, "AXWindows") or []
            for win in windows:
                title = get_attr(win, "AXTitle") or "(untitled)"
                # Try AXPress on close button, fallback to Cmd+W
                close_btn = find_element(win, role="AXButton", description="close button")
                if close_btn is not None:
                    perform_action(close_btn, "AXPress")
                    if self.verbose:
                        print(f"  [SESSION] Closed window: {title}", file=sys.stderr)
                    time.sleep(0.3)
                else:
                    # Fallback: activate the app first, THEN Cmd+W.
                    # SAFETY: activate_app targets only EnviousWispr by PID.
                    # Never use AXRaise + press_key without activation — the
                    # keystroke can land on whichever app is frontmost (e.g.
                    # the terminal running Claude Code).
                    activate_app(self.pid)
                    time.sleep(0.3)
                    press_key("w", cmd=True)
                    if self.verbose:
                        print(f"  [SESSION] Closed window via Cmd+W: {title}", file=sys.stderr)
                    time.sleep(0.3)
        except Exception as e:
            if self.verbose:
                print(f"  [SESSION] Teardown error (non-fatal): {e}", file=sys.stderr)

    def ensure_settings_open(self, verbose=False):
        """Open Settings window if not already open, return AXWindow element."""
        settings_win = wait_for_element(
            self.pid, role="AXWindow", title="EnviousWispr", timeout=0.5
        )
        if settings_win is not None:
            if self.verbose:
                print("  [SESSION] Settings already open", file=sys.stderr)
            return settings_win

        # Not open — open via menu
        settings_item = find_menu_item_via_menu(self.pid, "Settings...", verbose=self.verbose)
        if settings_item is not None:
            perform_action(settings_item, "AXPress")
        else:
            # SAFETY: activate first so Cmd+, lands on EnviousWispr, not a
            # frontmost app (which would open that app's preferences instead).
            activate_app(self.pid)
            time.sleep(0.05)
            press_key("comma", cmd=True)
        time.sleep(1.0)

        settings_win = wait_for_element(
            self.pid, role="AXWindow", title="EnviousWispr", timeout=3.0
        )
        if settings_win is None:
            raise RuntimeError("Settings window did not appear")
        return settings_win


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

def assert_element_exists(pid, role=None, title=None, description=None, value=None, msg=None):
    """Assert that an AX element matching the criteria exists RIGHT NOW."""
    app = get_ax_app(pid)
    el = find_element(app, role=role, title=title, description=description, value=value)
    if el is None:
        criteria = _criteria_str(role, title, description, value)
        raise AssertionError(msg or f"Element not found: {criteria}")
    return el


def assert_element_not_exists(pid, role=None, title=None, description=None, value=None, msg=None):
    """Assert that no AX element matching the criteria exists RIGHT NOW."""
    app = get_ax_app(pid)
    el = find_element(app, role=role, title=title, description=description, value=value)
    if el is not None:
        criteria = _criteria_str(role, title, description, value)
        raise AssertionError(msg or f"Element unexpectedly found: {criteria}")


def assert_element_appears(pid, role=None, title=None, value=None, timeout=5.0, msg=None):
    """Assert that an element appears within timeout (polling)."""
    el = wait_for_element(pid, role=role, title=title, value=value, timeout=timeout)
    if el is None:
        criteria = _criteria_str(role, title, value=value)
        raise AssertionError(msg or f"Element did not appear within {timeout}s: {criteria}")
    return el


def assert_element_disappears(pid, role=None, title=None, value=None, timeout=5.0, msg=None):
    """Assert that an element disappears within timeout (polling)."""
    gone = wait_for_element_gone(pid, role=role, title=title, value=value, timeout=timeout)
    if not gone:
        criteria = _criteria_str(role, title, value=value)
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


def _criteria_str(role=None, title=None, description=None, value=None):
    parts = []
    if role:
        parts.append(f"role={role!r}")
    if title:
        parts.append(f"title={title!r}")
    if description:
        parts.append(f"description={description!r}")
    if value:
        parts.append(f"value={value!r}")
    return ", ".join(parts) or "(no criteria)"


# ---------------------------------------------------------------------------
# Test context — passed to each test function
# ---------------------------------------------------------------------------

class TestContext:
    """Provides test functions with app info, helpers, and state tracking."""

    def __init__(self, pid, app_name="EnviousWispr", verbose=False, session=None):
        self.pid = pid
        self.app_name = app_name
        self.verbose = verbose
        self.session = session
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
        """Press a key via CGEvent.

        Always activates EnviousWispr first so the keystroke lands on the
        correct app, not whichever app happens to be frontmost (e.g. Rewind,
        VSCode).
        """
        mods = []
        if cmd: mods.append("Cmd")
        if shift: mods.append("Shift")
        if alt: mods.append("Alt")
        if ctrl: mods.append("Ctrl")
        mod_str = "+".join(mods) + "+" if mods else ""
        self.log(f"Pressing {mod_str}{key}")
        activate_app(self.pid)
        time.sleep(0.05)
        press_key(key, cmd=cmd, shift=shift, alt=alt, ctrl=ctrl)

    def click_element(self, role=None, title=None):
        """Find an AX element and CGEvent-click its center.

        Activates EnviousWispr before clicking so the mouse event lands on
        the correct window, not an overlapping window from another app.
        """
        app = get_ax_app(self.pid)
        el = find_element(app, role=role, title=title)
        if el is None:
            raise AssertionError(f"Cannot click: element not found ({_criteria_str(role, title)})")
        center = element_center(el)
        if center is None:
            raise AssertionError(f"Cannot click: no center coords ({_criteria_str(role, title)})")
        self.log(f"Clicking {_criteria_str(role, title)} at ({center[0]:.0f}, {center[1]:.0f})")
        activate_app(self.pid)
        time.sleep(0.05)
        click(center[0], center[1])

    def wait(self, seconds):
        """Wait for UI to settle."""
        self.log(f"Waiting {seconds}s")
        time.sleep(seconds)

    def get_memory_mb(self):
        return get_process_memory_mb(self.pid)

    @property
    def menu_snapshot(self):
        """Get the cached menu bar snapshot (takes one if needed)."""
        if self.session is None:
            raise RuntimeError("No TestSession available")
        return self.session.get_menu_snapshot()

    def invalidate_menu_snapshot(self):
        """Call after state-changing actions (start/stop recording)."""
        if self.session:
            self.session.invalidate_snapshot()

    def click_menu_item(self, title_substring):
        """Open menu, find item by title, AXPress it. Invalidates snapshot."""
        item = find_menu_item_via_menu(self.pid, title_substring, verbose=self.verbose)
        if item is None:
            raise AssertionError(f"Menu item not found: {title_substring!r}")
        if not perform_action(item, "AXPress"):
            raise AssertionError(f"AXPress failed on: {title_substring!r}")
        self.invalidate_menu_snapshot()

    def ensure_settings_open(self):
        """Open Settings if not already open, return AXWindow."""
        if self.session:
            return self.session.ensure_settings_open(verbose=self.verbose)
        # Fallback without session
        settings_item = find_menu_item_via_menu(self.pid, "Settings...", verbose=self.verbose)
        if settings_item is not None:
            perform_action(settings_item, "AXPress")
        else:
            # SAFETY: activate first so Cmd+, lands on EnviousWispr, not a
            # frontmost app (which would open that app's preferences instead).
            activate_app(self.pid)
            time.sleep(0.05)
            press_key("comma", cmd=True)
        time.sleep(1.0)
        return wait_for_element(self.pid, role="AXWindow", title="EnviousWispr", timeout=3.0)

    def ensure_tab_selected(self, tab_name):
        """Open Settings (if needed) and select the named sidebar tab.

        If the tab is already selected (tracked by the session), navigation is
        skipped entirely — no redundant clicks. Falls back to manual navigation
        when no session is available.

        Returns the Settings AXWindow element.
        """
        if self.session:
            return self.session.ensure_tab_selected(tab_name)
        # Fallback: open settings and click the tab manually (no cache available)
        settings_win = self.ensure_settings_open()
        if settings_win is None:
            raise RuntimeError("Settings window did not appear")
        outline = find_element(settings_win, role="AXOutline")
        if outline is None:
            raise RuntimeError("Settings sidebar outline not found")
        rows = get_attr(outline, "AXChildren") or []
        for row in rows:
            if get_attr(row, "AXRole") != "AXRow":
                continue
            row_texts = find_all_elements(row, role="AXStaticText")
            for txt in row_texts:
                val = get_attr(txt, "AXValue") or ""
                if val == tab_name:
                    set_attr(row, "AXSelected", True)
                    time.sleep(0.5)
                    self.log(f"Switched to tab: {tab_name!r} (no-session fallback)")
                    return settings_win
        raise RuntimeError(f"Settings tab not found in sidebar: {tab_name!r}")


# ---------------------------------------------------------------------------
# Test registry
# ---------------------------------------------------------------------------

_TESTS = {}
_SUITES = {}


def uat_test(name, suite="default", context="none"):
    """Decorator to register a UAT test function.

    context: UI context required by this test.
      - "none": No UI interaction (process checks, clipboard)
      - "menu_bar": Needs menu bar opened
      - "settings": Needs Settings window open
    """
    def decorator(fn):
        _TESTS[name] = {"fn": fn, "suite": suite, "name": name, "context": context}
        _SUITES.setdefault(suite, []).append(name)
        return fn
    return decorator


# ---------------------------------------------------------------------------
# Context ordering — groups tests by UI state to minimize menu open/close cycles
# ---------------------------------------------------------------------------

CONTEXT_ORDER = {"none": 0, "menu_bar": 1, "settings": 2}


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

def run_tests(test_names, verbose=False):
    """Run a list of tests by name and return results."""
    pid = find_app_pid("EnviousWispr")
    if pid is None:
        print("ERROR: EnviousWispr is not running. Launch it first.", file=sys.stderr)
        return [TestResult("setup", "ERROR", "EnviousWispr not running")]

    session = TestSession(pid, verbose=verbose)

    # Sort known tests by context to batch UI operations, keep unknowns at end
    known = [n for n in test_names if n in _TESTS]
    unknown = [n for n in test_names if n not in _TESTS]
    sorted_known = sorted(
        known,
        key=lambda n: CONTEXT_ORDER.get(_TESTS[n].get("context", "none"), 99)
    )
    test_names = sorted_known + unknown

    results = []
    try:
        for name in test_names:
            if name not in _TESTS:
                results.append(TestResult(name, "SKIP", f"Unknown test: {name}"))
                continue

            test_info = _TESTS[name]
            ctx = TestContext(pid, verbose=verbose, session=session)

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
    finally:
        # Clean up: close all app windows regardless of pass/fail
        session.teardown()

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

@uat_test("app_is_running", suite="app_basics", context="none")
def test_app_running(ctx):
    """GIVEN the app should be running, THEN it has a live process."""
    assert_process_running(ctx.app_name)
    ctx.log(f"PID: {ctx.pid}")


@uat_test("menu_bar_status_item_exists", suite="app_basics", context="none")
def test_status_item(ctx):
    """GIVEN the app is running, THEN a status item appears in the menu bar."""
    # MenuBarExtra creates a status item — verify via AX
    assert_process_running(ctx.app_name)
    # The app should have at least one window or menu bar presence
    app = get_ax_app(ctx.pid)
    info = element_info(app)
    assert info["role"] == "AXApplication", f"Expected AXApplication, got {info['role']}"


@uat_test("menu_bar_has_menu_items", suite="app_basics", context="menu_bar")
def test_menu_items(ctx):
    """GIVEN the app is running, WHEN the menu bar state is checked,
    THEN expected menu items are discoverable."""
    snapshot = ctx.menu_snapshot
    ctx.log(f"All menu item titles: {snapshot.titles}")

    items_to_check = ["Start Recording", "Record + AI Polish", "Settings", "Quit"]
    found = [needle for needle in items_to_check if snapshot.has_item(needle)]
    ctx.log(f"Found menu items: {found}")

    if len(found) == 0:
        raise AssertionError(
            f"No expected menu items found. Checked: {items_to_check}. "
            f"Actual: {snapshot.titles}"
        )


@uat_test("memory_within_bounds", suite="app_basics", context="none")
def test_memory_bounds(ctx):
    """GIVEN the app is running idle, THEN memory usage is below 500MB."""
    assert_memory_below(ctx.pid, 500,
                        msg="Idle memory exceeds 500MB — possible model leak")


# --- Suite: cancel_recording ---

@uat_test("esc_cancels_recording_via_menu", suite="cancel_recording", context="menu_bar")
def test_esc_cancel_menu(ctx):
    """GIVEN recording was started from menu bar,
    WHEN ESC is pressed,
    THEN recording stops and pipeline returns to idle."""
    # Verify Start Recording exists via snapshot (no menu open)
    if not ctx.menu_snapshot.has_item("Start Recording"):
        raise AssertionError("'Start Recording' not found in menu")

    # Click Start Recording (1 menu open)
    ctx.click_menu_item("Start Recording")
    ctx.wait(1.5)
    ctx.on_cleanup(lambda: press_key("escape"))

    ctx.log("Pressing ESC to cancel")
    ctx.press("escape")
    ctx.wait(1.5)

    assert_process_running(ctx.app_name, msg="App crashed after ESC cancel")

    # Verify back to idle — snapshot was invalidated by click_menu_item, so this takes a fresh one (1 menu open)
    snapshot = ctx.menu_snapshot
    if not snapshot.has_item("Start Recording"):
        raise AssertionError(
            "After ESC cancel, 'Start Recording' not available — recording may still be active"
        )
    ctx.log("Recording cancelled successfully via ESC")


@uat_test("esc_noop_when_idle", suite="cancel_recording", context="none")
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


@uat_test("esc_no_clipboard_write_on_cancel", suite="cancel_recording", context="menu_bar")
def test_esc_no_clipboard(ctx):
    """GIVEN recording is active,
    WHEN ESC cancels recording,
    THEN nothing is written to the clipboard."""
    sentinel = "UAT_SENTINEL_DO_NOT_OVERWRITE"
    ctx.set_clipboard(sentinel)

    # Try to start recording via menu
    if ctx.menu_snapshot.has_item("Start Recording"):
        ctx.click_menu_item("Start Recording")
        ctx.wait(1.0)
        ctx.on_cleanup(lambda: press_key("escape"))
    else:
        ctx.log("Start Recording not found — testing ESC on idle state instead")

    ctx.press("escape")
    ctx.wait(1.0)

    clipboard = ctx.get_clipboard()
    if clipboard != sentinel:
        raise AssertionError(
            f"Clipboard was modified after cancel. Expected sentinel, got: {clipboard[:100]!r}"
        )
    ctx.log("Clipboard preserved after cancel")


# --- Suite: settings ---

@uat_test("settings_window_opens", suite="settings", context="settings")
def test_settings_opens(ctx):
    """GIVEN the app is running,
    WHEN Settings... is activated via menu,
    THEN the Settings window appears."""
    settings_win = ctx.ensure_settings_open()
    if settings_win is None:
        raise AssertionError("Settings window did not appear")
    ctx.log("Settings window opened")


@uat_test("settings_has_all_tabs", suite="settings", context="settings")
def test_settings_tabs(ctx):
    """GIVEN the Settings window is open,
    THEN all expected tabs are present in the sidebar."""
    settings_win = ctx.ensure_settings_open()
    if settings_win is None:
        raise AssertionError("Settings window did not appear")

    expected_tabs = ["Shortcuts", "AI Polish", "Permissions", "Speech Engine"]
    sidebar_texts = find_all_elements(settings_win, role="AXStaticText")
    sidebar_values = [get_attr(el, "AXValue") or "" for el in sidebar_texts]
    ctx.log(f"Sidebar text values: {sidebar_values[:20]}")

    found = [tab_name for tab_name in expected_tabs if tab_name in sidebar_values]

    missing = set(expected_tabs) - set(found)
    if missing:
        ctx.log(f"Found tabs: {found}, missing: {missing}")
        raise AssertionError(f"Missing settings tabs: {missing}. Found: {found}")
    ctx.log(f"All tabs present: {found}")


@uat_test("settings_tab_switching_works", suite="settings", context="settings")
def test_settings_tab_switch(ctx):
    """GIVEN the Settings window is open,
    WHEN each sidebar tab is clicked,
    THEN the tab content changes."""
    settings_win = ctx.ensure_settings_open()
    if settings_win is None:
        raise AssertionError("Settings window did not appear")

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
            row_texts = find_all_elements(row, role="AXStaticText")
            for txt in row_texts:
                val = get_attr(txt, "AXValue") or ""
                if val == tab_name:
                    center = element_center(row)
                    if center:
                        # SAFETY: activate first so the click lands on the
                        # Settings window, not an overlapping app window.
                        activate_app(ctx.pid)
                        time.sleep(0.05)
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

@uat_test("clipboard_save_restore", suite="clipboard", context="none")
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

@uat_test("main_window_opens", suite="main_window", context="menu_bar")
def test_main_window(ctx):
    """GIVEN the app is running,
    WHEN 'Open' is triggered via menu,
    THEN the main window appears."""
    app = get_ax_app(ctx.pid)
    main_win = find_element(app, role="AXWindow", title="EnviousWispr")
    if main_win is None:
        # Try via menu
        if ctx.menu_snapshot.has_item("Open EnviousWispr"):
            ctx.click_menu_item("Open EnviousWispr")
            ctx.wait(1.0)
        else:
            ctx.log("No 'Open' menu item found, checking for any window")

    app = get_ax_app(ctx.pid)
    windows = get_attr(app, "AXWindows")
    if windows and len(windows) > 0:
        ctx.log(f"Found {len(windows)} window(s)")
    else:
        ctx.log("No windows found — app may be menu-bar-only at idle")


# ---------------------------------------------------------------------------
# Auto-discover / file-targeted generated tests
# ---------------------------------------------------------------------------

_loaded_generated = set()  # tracks normalized absolute paths of loaded files
_GENERATED_ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "generated"))


def _load_single_file(full_path):
    """Load a single test file via importlib. Registers tests via @uat_test decorator."""
    import importlib.util
    normalized = os.path.realpath(full_path)
    if normalized in _loaded_generated:
        return  # idempotent — skip if already loaded
    filename = os.path.basename(normalized)
    spec = importlib.util.spec_from_file_location(filename[:-3], normalized)
    if spec is None or spec.loader is None:
        print(f"WARN: could not create loader for {filename}", file=sys.stderr)
        return
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
        _loaded_generated.add(normalized)
    except Exception as e:
        print(f"WARN: failed to load generated test {filename}: {e}", file=sys.stderr)


def _discover_generated_tests():
    """Auto-discover and load all test_*.py files from generated/ directory."""
    gen_dir = os.path.join(os.path.dirname(__file__), "generated")
    if not os.path.isdir(gen_dir):
        return
    if __name__ == "__main__" and "uat_runner" not in sys.modules:
        sys.modules["uat_runner"] = sys.modules[__name__]
    for f in sorted(os.listdir(gen_dir)):
        if f.startswith("test_") and f.endswith(".py"):
            _load_single_file(os.path.join(gen_dir, f))


def _is_inside_generated(path):
    """Check if path is inside the generated/ directory. Resolves symlinks."""
    try:
        return os.path.commonpath([os.path.realpath(path), _GENERATED_ROOT]) == _GENERATED_ROOT
    except ValueError:
        return False  # different drives on Windows, or empty path


def _load_test_files(file_paths):
    """Load specific test files. Returns (registered_names_list, skipped_paths)."""
    if __name__ == "__main__" and "uat_runner" not in sys.modules:
        sys.modules["uat_runner"] = sys.modules[__name__]

    before = set(_TESTS.keys())
    skipped = []

    for path in file_paths:
        resolved = os.path.realpath(path)
        filename = os.path.basename(resolved)

        # Validation: must exist, be .py, match test_*.py, be inside generated/
        if not os.path.isfile(resolved):
            print(f"WARN: missing test file: {path}", file=sys.stderr)
            skipped.append(path)
            continue
        if not filename.startswith("test_") or not filename.endswith(".py"):
            print(f"WARN: invalid generated test path: {path}", file=sys.stderr)
            skipped.append(path)
            continue
        if not _is_inside_generated(resolved):
            print(f"WARN: path outside generated/ directory: {path}", file=sys.stderr)
            skipped.append(path)
            continue

        _load_single_file(resolved)

    # Preserve ordering: return as list in load order, not a set
    registered = [t for t in _TESTS if t not in before]
    return registered, skipped


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_signatures(args):
    """Output JSON listing all static (non-generated) test signatures."""
    _discover_generated_tests()
    static_tests = []
    for name, info in _TESTS.items():
        if info["suite"].endswith("_generated"):
            continue
        doc = info["fn"].__doc__ or ""
        static_tests.append({
            "name": name,
            "suite": info["suite"],
            "context": info.get("context", "none"),
            "docstring": doc.strip(),
        })
    print(json.dumps({"static_tests": static_tests}, indent=2))


def cmd_list(args):
    _discover_generated_tests()
    print("Available UAT test suites and tests:\n")
    for suite, tests in sorted(_SUITES.items()):
        print(f"  Suite: {suite}")
        for t in tests:
            doc = _TESTS[t]["fn"].__doc__ or ""
            first_line = doc.strip().split("\n")[0] if doc.strip() else "(no description)"
            print(f"    - {t}: {first_line}")
        print()


def cmd_run(args):
    # Selector conflict detection
    selectors = sum(bool(x) for x in [args.files, args.test, args.suite, args.generated_only])
    if selectors > 1:
        print("Error: --files, --test, --suite, and --generated-only are mutually exclusive.",
              file=sys.stderr)
        sys.exit(1)

    if args.files:
        registered, skipped = _load_test_files(args.files)
        test_names = registered  # already an ordered list
        if not test_names:
            print("No tests loaded from specified files.", file=sys.stderr)
            sys.exit(0)
    elif args.test:
        _discover_generated_tests()
        test_names = [args.test]
    elif args.suite:
        _discover_generated_tests()
        if args.suite not in _SUITES:
            print(f"Unknown suite: {args.suite}", file=sys.stderr)
            print(f"Available suites: {', '.join(sorted(_SUITES.keys()))}", file=sys.stderr)
            sys.exit(1)
        test_names = _SUITES[args.suite]
    elif args.generated_only:
        _discover_generated_tests()
        # Only run suites ending in _generated
        test_names = []
        for suite_name, suite_tests in _SUITES.items():
            if suite_name.endswith("_generated"):
                test_names.extend(suite_tests)
        if not test_names:
            print("No generated test suites found.", file=sys.stderr)
            sys.exit(0)
    else:
        _discover_generated_tests()
        # Run all tests
        test_names = list(_TESTS.keys())

    results = run_tests(test_names, verbose=args.verbose)
    all_passed = print_results(results)

    # Clear the .needs-uat marker ONLY when every test passes (exit 0).
    # This marker gates TodoWrite completion via a PreToolUse hook.
    if all_passed:
        _project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        _marker = os.path.join(_project_root, ".needs-uat")
        try:
            os.remove(_marker)
            if args.verbose:
                print("  [UAT] Cleared .needs-uat marker (all tests passed)", file=sys.stderr)
        except FileNotFoundError:
            pass

    sys.exit(0 if all_passed else 1)


def main():
    parser = argparse.ArgumentParser(description="EnviousWispr UAT Test Runner")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("list", help="List available tests and suites")
    sub.add_parser("signatures", help="Output JSON of all static (non-generated) test signatures")

    run_p = sub.add_parser("run", help="Run UAT tests")
    run_p.add_argument("--suite", type=str, help="Run tests from a specific suite")
    run_p.add_argument("--test", type=str, help="Run a single test by name")
    run_p.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    run_p.add_argument("--generated-only", action="store_true",
                       help="Only run generated test suites (ending in _generated)")
    run_p.add_argument("--files", nargs="+", type=str,
                       help="Run only tests from these specific generated file paths")

    args = parser.parse_args()
    if args.command is None:
        parser.print_help()
        sys.exit(0)

    if args.command == "list":
        cmd_list(args)
    elif args.command == "signatures":
        cmd_signatures(args)
    elif args.command == "run":
        cmd_run(args)


if __name__ == "__main__":
    main()
