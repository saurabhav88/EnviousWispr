"""Shared AX (Accessibility) tree helpers for UI testing."""

import subprocess
import time

from ApplicationServices import (
    AXUIElementCreateApplication,
    AXUIElementCreateSystemWide,
    AXUIElementCopyAttributeValue,
    AXUIElementCopyAttributeNames,
    AXUIElementCopyActionNames,
    AXUIElementPerformAction,
    AXValueGetValue,
    kAXErrorSuccess,
    kAXValueTypeCGPoint,
    kAXValueTypeCGSize,
)


# ---------------------------------------------------------------------------
# Process helpers
# ---------------------------------------------------------------------------

def find_app_pid(app_name):
    """Return the PID (int) of a running process by exact name, or None."""
    try:
        out = subprocess.check_output(
            ["pgrep", "-x", app_name], text=True
        ).strip()
        # pgrep may return multiple PIDs; take the first one
        return int(out.splitlines()[0])
    except (subprocess.CalledProcessError, ValueError, IndexError):
        return None


# ---------------------------------------------------------------------------
# Low-level AX wrappers
# ---------------------------------------------------------------------------

def get_ax_app(pid):
    """Return an AXUIElement for the application with the given PID."""
    return AXUIElementCreateApplication(pid)


def get_attr(element, attr):
    """Return the value of *attr* on *element*, or None on failure."""
    err, value = AXUIElementCopyAttributeValue(element, attr, None)
    if err == kAXErrorSuccess:
        return value
    return None


def get_attr_names(element):
    """Return a list of attribute names supported by *element*."""
    err, names = AXUIElementCopyAttributeNames(element, None)
    if err == kAXErrorSuccess:
        return list(names)
    return []


def get_actions(element):
    """Return a list of action names supported by *element*."""
    err, names = AXUIElementCopyActionNames(element, None)
    if err == kAXErrorSuccess:
        return list(names)
    return []


def perform_action(element, action):
    """Perform *action* on *element*. Returns True on success."""
    err = AXUIElementPerformAction(element, action)
    return err == kAXErrorSuccess


# ---------------------------------------------------------------------------
# Element introspection
# ---------------------------------------------------------------------------

def element_info(element):
    """Extract a dict of common attributes from *element*."""
    info = {}

    info["role"] = get_attr(element, "AXRole")
    info["subrole"] = get_attr(element, "AXSubrole")
    info["title"] = get_attr(element, "AXTitle")
    info["value"] = get_attr(element, "AXValue")
    info["description"] = get_attr(element, "AXDescription")
    info["role_description"] = get_attr(element, "AXRoleDescription")
    info["enabled"] = get_attr(element, "AXEnabled")
    info["focused"] = get_attr(element, "AXFocused")

    # Position — AXValueRef wrapping CGPoint, extract via AXValueGetValue
    pos_ref = get_attr(element, "AXPosition")
    if pos_ref is not None:
        success, point = AXValueGetValue(pos_ref, kAXValueTypeCGPoint, None)
        if success and point is not None:
            info["position"] = {"x": point.x, "y": point.y}
        else:
            info["position"] = None
    else:
        info["position"] = None

    # Size — AXValueRef wrapping CGSize, extract via AXValueGetValue
    size_ref = get_attr(element, "AXSize")
    if size_ref is not None:
        success, sz = AXValueGetValue(size_ref, kAXValueTypeCGSize, None)
        if success and sz is not None:
            info["size"] = {"w": sz.width, "h": sz.height}
        else:
            info["size"] = None
    else:
        info["size"] = None

    info["actions"] = get_actions(element)

    return info


def element_center(element):
    """Return (x, y) center of the element, or None."""
    pos_ref = get_attr(element, "AXPosition")
    size_ref = get_attr(element, "AXSize")
    if pos_ref is None or size_ref is None:
        return None
    success_p, point = AXValueGetValue(pos_ref, kAXValueTypeCGPoint, None)
    success_s, sz = AXValueGetValue(size_ref, kAXValueTypeCGSize, None)
    if not success_p or not success_s or point is None or sz is None:
        return None
    return (point.x + sz.width / 2.0, point.y + sz.height / 2.0)


# ---------------------------------------------------------------------------
# Tree walking / searching
# ---------------------------------------------------------------------------

def walk_tree(element, max_depth=10, _depth=0):
    """Recursively walk the AX tree and return a nested dict."""
    node = element_info(element)

    if _depth >= max_depth:
        node["children"] = []
        return node

    children_ref = get_attr(element, "AXChildren")
    children = []
    if children_ref:
        for child in children_ref:
            children.append(walk_tree(child, max_depth=max_depth, _depth=_depth + 1))
    node["children"] = children
    return node


def find_element(element, role=None, title=None, description=None,
                 max_depth=10, _depth=0):
    """DFS search returning the first AX element matching the criteria.

    At the application level, also traverses AXMenuBar and AXExtrasMenuBar
    which are separate attributes (not under AXChildren).
    """
    if _depth > max_depth:
        return None

    match = True
    if role is not None and get_attr(element, "AXRole") != role:
        match = False
    if title is not None and get_attr(element, "AXTitle") != title:
        match = False
    if description is not None and get_attr(element, "AXDescription") != description:
        match = False

    if match:
        return element

    # At the application level, menu bars are separate attributes, not children.
    if get_attr(element, "AXRole") == "AXApplication":
        for bar_attr in ("AXExtrasMenuBar", "AXMenuBar"):
            bar = get_attr(element, bar_attr)
            if bar is not None:
                result = find_element(
                    bar, role=role, title=title, description=description,
                    max_depth=max_depth, _depth=_depth + 1,
                )
                if result is not None:
                    return result

    children_ref = get_attr(element, "AXChildren")
    if children_ref:
        for child in children_ref:
            result = find_element(
                child, role=role, title=title, description=description,
                max_depth=max_depth, _depth=_depth + 1,
            )
            if result is not None:
                return result
    return None


def find_all_elements(element, role=None, title=None, max_depth=10, _depth=0):
    """Return a list of all AX elements matching the criteria.

    At the application level, also traverses AXMenuBar and AXExtrasMenuBar
    which are separate attributes (not under AXChildren).
    """
    results = []

    if _depth > max_depth:
        return results

    match = True
    if role is not None and get_attr(element, "AXRole") != role:
        match = False
    if title is not None and get_attr(element, "AXTitle") != title:
        match = False

    if match:
        results.append(element)

    # At the application level, menu bars are separate attributes, not children.
    if get_attr(element, "AXRole") == "AXApplication":
        for bar_attr in ("AXExtrasMenuBar", "AXMenuBar"):
            bar = get_attr(element, bar_attr)
            if bar is not None:
                results.extend(
                    find_all_elements(
                        bar, role=role, title=title,
                        max_depth=max_depth, _depth=_depth + 1,
                    )
                )

    children_ref = get_attr(element, "AXChildren")
    if children_ref:
        for child in children_ref:
            results.extend(
                find_all_elements(
                    child, role=role, title=title,
                    max_depth=max_depth, _depth=_depth + 1,
                )
            )
    return results


def wait_for_element(pid, role=None, title=None, timeout=5.0, poll_interval=0.3):
    """Poll until an element matching the criteria appears, or timeout."""
    app = get_ax_app(pid)
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = find_element(app, role=role, title=title)
        if result is not None:
            return result
        time.sleep(poll_interval)
    return None


# ---------------------------------------------------------------------------
# Behavioral verification — state polling, process metrics, clipboard, logs
# ---------------------------------------------------------------------------

def wait_for_value(pid, role=None, title=None, description=None,
                   attr="AXValue", expected=None, not_expected=None,
                   timeout=10.0, poll_interval=0.3):
    """Poll an AX element's attribute until it matches (or stops matching) an expected value.

    Returns (success: bool, final_value, elapsed_seconds).

    Use *expected* to wait until attr == expected.
    Use *not_expected* to wait until attr != not_expected (e.g., wait for state to leave 'Recording').
    """
    if expected is None and not_expected is None:
        raise ValueError("wait_for_value: at least one of 'expected' or 'not_expected' must be provided")

    app = get_ax_app(pid)
    start = time.time()
    deadline = start + timeout
    final_value = None

    while time.time() < deadline:
        el = find_element(app, role=role, title=title, description=description)
        if el is not None:
            final_value = get_attr(el, attr)
            if expected is not None and final_value == expected:
                return (True, final_value, time.time() - start)
            if not_expected is not None and final_value != not_expected:
                return (True, final_value, time.time() - start)
        time.sleep(poll_interval)

    return (False, final_value, time.time() - start)


def wait_for_element_gone(pid, role=None, title=None, timeout=5.0, poll_interval=0.3):
    """Poll until an element matching the criteria disappears, or timeout.

    Returns True if the element disappeared, False if still present at timeout.
    """
    app = get_ax_app(pid)
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = find_element(app, role=role, title=title)
        if result is None:
            return True
        time.sleep(poll_interval)
    return False


def get_element_value(pid, role=None, title=None, description=None, attr="AXValue"):
    """Get a single AX attribute value from the first matching element. Returns None if not found."""
    app = get_ax_app(pid)
    el = find_element(app, role=role, title=title, description=description)
    if el is None:
        return None
    return get_attr(el, attr)


def get_process_memory_mb(pid):
    """Return resident memory (RSS) in MB for a process, or None on error."""
    try:
        result = subprocess.run(
            ["ps", "-o", "rss=", "-p", str(pid)],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            return int(result.stdout.strip()) / 1024.0
    except (subprocess.TimeoutExpired, ValueError):
        pass
    return None


def get_process_cpu(pid):
    """Return CPU usage percentage for a process, or None on error."""
    try:
        result = subprocess.run(
            ["ps", "-o", "%cpu=", "-p", str(pid)],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            return float(result.stdout.strip())
    except (subprocess.TimeoutExpired, ValueError):
        pass
    return None


def get_clipboard_text():
    """Return the current clipboard text content via pbpaste, or None."""
    try:
        result = subprocess.run(
            ["pbpaste"], capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout
    except subprocess.TimeoutExpired:
        pass
    return None


def set_clipboard_text(text):
    """Set the clipboard text content via pbcopy."""
    try:
        result = subprocess.run(
            ["pbcopy"], input=text.encode("utf-8"), timeout=5,
        )
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        return False


def capture_app_logs(subsystem="com.enviouswispr.app", duration=3.0, level="default"):
    """Capture structured log output from the app for *duration* seconds.

    Returns a list of log line strings. Uses macOS `log` command.
    """
    try:
        proc = subprocess.Popen(
            ["log", "stream", "--predicate",
             f'subsystem == "{subsystem}"',
             "--level", level,
             "--style", "compact"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        time.sleep(duration)
        proc.terminate()
        try:
            stdout, _ = proc.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, _ = proc.communicate()
        return [line for line in stdout.strip().split("\n") if line]
    except Exception:
        return []


def check_logs_for_pattern(subsystem="com.enviouswispr.app", duration=3.0, pattern=""):
    """Capture logs and return True if any line matches *pattern* (case-insensitive)."""
    import re
    lines = capture_app_logs(subsystem=subsystem, duration=duration)
    for line in lines:
        if re.search(pattern, line, re.IGNORECASE):
            return True
    return False


def is_process_running(app_name):
    """Check if a process with the given name is currently running."""
    return find_app_pid(app_name) is not None
