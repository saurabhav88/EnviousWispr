"""Shared AX (Accessibility) tree helpers for UI testing."""

import json
import logging
import re
import subprocess
import time

from ApplicationServices import (
    AXUIElementCreateApplication,
    AXUIElementCreateSystemWide,
    AXUIElementCopyAttributeValue,
    AXUIElementCopyAttributeNames,
    AXUIElementCopyActionNames,
    AXUIElementPerformAction,
    AXUIElementSetAttributeValue,
    AXValueGetValue,
    kAXErrorSuccess,
    kAXValueTypeCGPoint,
    kAXValueTypeCGSize,
)


# =============================================================================
# Knowledge Files (for test generation context)
# =============================================================================
# These project knowledge files provide codebase context without reading source:
#   .claude/knowledge/architecture.md  — app structure, views, pipeline states
#   .claude/knowledge/file-index.md    — every Swift file, types, purpose
#   .claude/knowledge/type-index.md    — type → file reverse lookup
#   .claude/knowledge/gotchas.md       — known pitfalls and patterns
# The uat-generator agent should receive summaries from these files
# instead of exploring the codebase from scratch each run.
# =============================================================================


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


def set_attr(element, attr, value):
    """Set an AX attribute on *element*. Returns True on success."""
    err = AXUIElementSetAttributeValue(element, attr, value)
    return err == kAXErrorSuccess


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


def activate_app(pid):
    """Bring the app with *pid* to the foreground safely.

    Uses NSRunningApplication.activate — targets only the specified PID.
    Never touches other apps. Safe to call before any CGEvent keystroke
    that must land on the target app.
    """
    from AppKit import NSRunningApplication, NSApplicationActivateIgnoringOtherApps
    nsa = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
    if nsa is not None:
        nsa.activateWithOptions_(NSApplicationActivateIgnoringOtherApps)
        return True
    return False


# ---------------------------------------------------------------------------
# Element introspection
# ---------------------------------------------------------------------------

def _extract_point(element):
    """Unwrap AXPosition into (x, y) tuple, or None."""
    pos_ref = get_attr(element, "AXPosition")
    if pos_ref is None:
        return None
    success, point = AXValueGetValue(pos_ref, kAXValueTypeCGPoint, None)
    if success and point is not None:
        return (point.x, point.y)
    return None


def _extract_size(element):
    """Unwrap AXSize into (width, height) tuple, or None."""
    size_ref = get_attr(element, "AXSize")
    if size_ref is None:
        return None
    success, sz = AXValueGetValue(size_ref, kAXValueTypeCGSize, None)
    if success and sz is not None:
        return (sz.width, sz.height)
    return None


def element_info(element):
    """Extract a dict of common attributes from *element*."""
    point = _extract_point(element)
    size = _extract_size(element)

    return {
        "role": get_attr(element, "AXRole"),
        "subrole": get_attr(element, "AXSubrole"),
        "title": get_attr(element, "AXTitle"),
        "value": get_attr(element, "AXValue"),
        "description": get_attr(element, "AXDescription"),
        "role_description": get_attr(element, "AXRoleDescription"),
        "enabled": get_attr(element, "AXEnabled"),
        "focused": get_attr(element, "AXFocused"),
        "position": {"x": point[0], "y": point[1]} if point else None,
        "size": {"w": size[0], "h": size[1]} if size else None,
        "actions": get_actions(element),
    }


def element_center(element):
    """Return (x, y) center of the element, or None."""
    point = _extract_point(element)
    size = _extract_size(element)
    if point is None or size is None:
        return None
    return (point[0] + size[0] / 2.0, point[1] + size[1] / 2.0)


def element_position(element):
    """Return (x, y) top-left of element in points, or None."""
    return _extract_point(element)


def element_frame(element):
    """Return {x, y, width, height} of element in points, or None.

    ALL size/position assertions should use this -- never pixel-based measurements.
    Points are display-independent (no Retina scaling issues).
    """
    point = _extract_point(element)
    size = _extract_size(element)
    if point is None or size is None:
        return None
    return {"x": point[0], "y": point[1], "width": size[0], "height": size[1]}


def is_above(element_a, element_b):
    """True if element_a's y-center < element_b's y-center (points).

    In macOS screen coordinates, lower y = higher on screen.
    """
    center_a = element_center(element_a)
    center_b = element_center(element_b)
    if center_a is None or center_b is None:
        return False
    return center_a[1] < center_b[1]


def is_left_of(element_a, element_b):
    """True if element_a's x-center < element_b's x-center (points)."""
    center_a = element_center(element_a)
    center_b = element_center(element_b)
    if center_a is None or center_b is None:
        return False
    return center_a[0] < center_b[0]


def get_element_order(parent, role=None):
    """Return children of parent matching role, sorted by y-position (top-to-bottom).

    Uses element_frame for positioning, NOT AX tree order (which may differ for ZStack).
    """
    children_ref = get_attr(parent, "AXChildren")
    if not children_ref:
        return []

    matched = []
    for child in children_ref:
        if role is not None and get_attr(child, "AXRole") != role:
            continue
        frame = element_frame(child)
        if frame is not None:
            matched.append((frame["y"], child))

    matched.sort(key=lambda pair: pair[0])
    return [child for _, child in matched]


# ---------------------------------------------------------------------------
# Tree walking / searching
# ---------------------------------------------------------------------------

def _matches_criteria(element, role=None, title=None, description=None, value=None):
    """Return True if element matches all non-None criteria."""
    if role is not None and get_attr(element, "AXRole") != role:
        return False
    if title is not None and get_attr(element, "AXTitle") != title:
        return False
    if description is not None and get_attr(element, "AXDescription") != description:
        return False
    if value is not None and get_attr(element, "AXValue") != value:
        return False
    return True


def _iter_children_with_menubars(element):
    """Yield AXChildren plus AXMenuBar/AXExtrasMenuBar for AXApplication elements."""
    if get_attr(element, "AXRole") == "AXApplication":
        for bar_attr in ("AXExtrasMenuBar", "AXMenuBar"):
            bar = get_attr(element, bar_attr)
            if bar is not None:
                yield bar

    children_ref = get_attr(element, "AXChildren")
    if children_ref:
        yield from children_ref


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


def find_element(element, role=None, title=None, description=None, value=None,
                 max_depth=10, _depth=0):
    """DFS search returning the first AX element matching the criteria.

    At the application level, also traverses AXMenuBar and AXExtrasMenuBar
    which are separate attributes (not under AXChildren).
    """
    if _depth > max_depth:
        return None

    if _matches_criteria(element, role=role, title=title, description=description, value=value):
        return element

    for child in _iter_children_with_menubars(element):
        result = find_element(
            child, role=role, title=title, description=description,
            value=value, max_depth=max_depth, _depth=_depth + 1,
        )
        if result is not None:
            return result

    return None


def get_all_visible_text(element, max_depth=10, _depth=0):
    """Walk AX tree, return all non-empty AXValue, AXTitle, and AXDescription strings."""
    if _depth > max_depth:
        return []

    texts = []
    for attr_name in ("AXValue", "AXTitle", "AXDescription"):
        val = get_attr(element, attr_name)
        if val and isinstance(val, str) and val.strip():
            texts.append(val.strip())

    children_ref = get_attr(element, "AXChildren")
    if children_ref:
        for child in children_ref:
            texts.extend(get_all_visible_text(child, max_depth=max_depth, _depth=_depth + 1))

    return texts


def find_control_for_label(element, label_text, control_role,
                           search_direction="right_or_below", max_distance=200):
    """Find a control near a label using spatial proximity.

    1. Find AXStaticText with matching value/title
    2. Get its frame
    3. Search for nearest element of control_role within max_distance points
    4. Prefer elements to the right (same row) or below (next row)

    Returns the control element or None.
    """
    label_el = find_element(element, role="AXStaticText", value=label_text)
    if label_el is None:
        label_el = find_element(element, role="AXStaticText", title=label_text)
    if label_el is None:
        return None

    label_frame = element_frame(label_el)
    if label_frame is None:
        return None
    label_cx = label_frame["x"] + label_frame["width"] / 2.0
    label_cy = label_frame["y"] + label_frame["height"] / 2.0

    candidates = find_all_elements(element, role=control_role)
    if not candidates:
        return None

    best = None
    best_dist = float("inf")

    for cand in candidates:
        cand_frame = element_frame(cand)
        if cand_frame is None:
            continue
        cand_cx = cand_frame["x"] + cand_frame["width"] / 2.0
        cand_cy = cand_frame["y"] + cand_frame["height"] / 2.0

        dx = cand_cx - label_cx
        dy = cand_cy - label_cy

        if search_direction == "right_or_below":
            if dx < -label_frame["width"] and dy < -label_frame["height"]:
                continue

        dist = (dx ** 2 + dy ** 2) ** 0.5
        if dist > max_distance:
            continue
        if dist < best_dist:
            best_dist = dist
            best = cand

    return best


def find_all_elements(element, role=None, title=None, description=None,
                      value=None, max_depth=10, _depth=0):
    """Return a list of all AX elements matching the criteria.

    At the application level, also traverses AXMenuBar and AXExtrasMenuBar
    which are separate attributes (not under AXChildren).
    """
    if _depth > max_depth:
        return []

    results = []
    if _matches_criteria(element, role=role, title=title, description=description, value=value):
        results.append(element)

    for child in _iter_children_with_menubars(element):
        results.extend(
            find_all_elements(
                child, role=role, title=title, description=description,
                value=value, max_depth=max_depth, _depth=_depth + 1,
            )
        )

    return results


def wait_for_condition(predicate, timeout=3.0, interval=0.2, description="condition"):
    """Poll predicate until True or timeout. Returns True/False.

    Default interval=0.2s (not 0.1s) to avoid CPU spikes during parallel runs.
    Default timeout=3.0s (not 5.0s) to stay within 30s test budget.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def wait_for_element(pid, role=None, title=None, value=None, timeout=3.0, poll_interval=0.2):
    """Poll until an element matching the criteria appears, or timeout."""
    app = get_ax_app(pid)
    result_holder = [None]

    def _check():
        result_holder[0] = find_element(app, role=role, title=title, value=value)
        return result_holder[0] is not None

    wait_for_condition(_check, timeout=timeout, interval=poll_interval,
                       description=f"wait_for_element(role={role}, title={title}, value={value})")
    return result_holder[0]


# ---------------------------------------------------------------------------
# Behavioral verification — state polling, process metrics, clipboard, logs
# ---------------------------------------------------------------------------

def wait_for_value(pid, role=None, title=None, description=None,
                   attr="AXValue", expected=None, not_expected=None,
                   timeout=5.0, poll_interval=0.2):
    """Poll an AX element's attribute until it matches (or stops matching) an expected value.

    Returns (success: bool, final_value, elapsed_seconds).

    Use *expected* to wait until attr == expected.
    Use *not_expected* to wait until attr != not_expected (e.g., wait for state to leave 'Recording').
    """
    if expected is None and not_expected is None:
        raise ValueError("wait_for_value: at least one of 'expected' or 'not_expected' must be provided")

    app = get_ax_app(pid)
    start = time.time()
    final_value_holder = [None]

    def _check():
        el = find_element(app, role=role, title=title, description=description)
        if el is not None:
            final_value_holder[0] = get_attr(el, attr)
            if expected is not None and final_value_holder[0] == expected:
                return True
            if not_expected is not None and final_value_holder[0] != not_expected:
                return True
        return False

    success = wait_for_condition(
        _check, timeout=timeout, interval=poll_interval,
        description=f"wait_for_value(attr={attr}, expected={expected}, not_expected={not_expected})")
    return (success, final_value_holder[0], time.time() - start)


def wait_for_element_gone(pid, role=None, title=None, value=None, timeout=3.0, poll_interval=0.2):
    """Poll until an element matching the criteria disappears, or timeout.

    Returns True if the element disappeared, False if still present at timeout.
    """
    app = get_ax_app(pid)

    def _check():
        return find_element(app, role=role, title=title, value=value) is None

    return wait_for_condition(
        _check, timeout=timeout, interval=poll_interval,
        description=f"wait_for_element_gone(role={role}, title={title}, value={value})")


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
    lines = capture_app_logs(subsystem=subsystem, duration=duration)
    return any(re.search(pattern, line, re.IGNORECASE) for line in lines)


def is_process_running(app_name):
    """Check if a process with the given name is currently running."""
    return find_app_pid(app_name) is not None


def validate_app_ready(pid, timeout=10.0):
    """Validate the app is ready for UAT testing.

    Checks:
    1. Process is alive and responding (not hung)
    2. AX tree is accessible (Accessibility permission works)
    3. App has at least one AX element (UI is loaded)

    Returns (ready: bool, message: str).
    """
    # 1. Check process is alive
    try:
        result = subprocess.run(
            ["kill", "-0", str(pid)],
            capture_output=True, timeout=5,
        )
        if result.returncode != 0:
            return (False, f"Process {pid} is not alive")
    except subprocess.TimeoutExpired:
        return (False, f"Process {pid} not responding to signal check")

    # 2. Check AX tree is accessible (polls until timeout)
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        try:
            app = AXUIElementCreateApplication(pid)
            err, role = AXUIElementCopyAttributeValue(app, "AXRole", None)
            if err == kAXErrorSuccess and role == "AXApplication":
                # 3. Check we can read at least one child or menu bar
                err2, children = AXUIElementCopyAttributeValue(app, "AXChildren", None)
                err3, menubar = AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar", None)
                if (err2 == kAXErrorSuccess and children) or (err3 == kAXErrorSuccess and menubar):
                    return (True, "App is ready")
                # App exists but no children yet — UI still loading
                last_error = "AX tree accessible but no UI elements yet"
            else:
                last_error = f"AXRole query returned error code {err}"
        except Exception as e:
            last_error = str(e)
        time.sleep(0.5)

    return (False, f"App not ready after {timeout}s: {last_error}")


def validate_test_environment(pid):
    """Check environment preconditions. Returns dict of checks.

    - screen_resolution: current display resolution
    - app_frontmost: is the app the frontmost app?
    - window_count: number of app windows
    - accessibility_granted: can we read AX tree?

    Logs warnings for unexpected conditions, does not fail.
    """
    logger = logging.getLogger("uat")

    result = {
        "screen_resolution": None,
        "app_frontmost": False,
        "window_count": 0,
        "accessibility_granted": False,
    }

    # Screen resolution
    try:
        out = subprocess.check_output(
            ["system_profiler", "SPDisplaysDataType", "-json"],
            text=True, timeout=5,
        )
        data = json.loads(out)
        displays = data.get("SPDisplaysDataType", [])
        for gpu in displays:
            for display in gpu.get("spdisplays_ndrvs", []):
                res = display.get("_spdisplays_resolution")
                if res:
                    result["screen_resolution"] = res
                    break
    except Exception:
        logger.warning("validate_test_environment: could not determine screen resolution")

    # App frontmost
    try:
        from AppKit import NSRunningApplication
        nsa = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
        if nsa is not None:
            result["app_frontmost"] = bool(nsa.isActive())
            if not result["app_frontmost"]:
                logger.warning("validate_test_environment: app is not frontmost")
    except Exception:
        logger.warning("validate_test_environment: could not check frontmost state")

    # AX tree checks (window count + accessibility)
    app = get_ax_app(pid)

    try:
        windows = get_attr(app, "AXWindows")
        if windows:
            result["window_count"] = len(windows)
        if result["window_count"] == 0:
            logger.warning("validate_test_environment: app has no windows")
    except Exception:
        logger.warning("validate_test_environment: could not count windows")

    try:
        role = get_attr(app, "AXRole")
        result["accessibility_granted"] = role == "AXApplication"
        if not result["accessibility_granted"]:
            logger.warning("validate_test_environment: accessibility not granted or app not responding")
    except Exception:
        logger.warning("validate_test_environment: could not check accessibility")

    return result
