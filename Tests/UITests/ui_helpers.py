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
    kAXErrorSuccess,
)
from CoreFoundation import CFRange


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

    # Position — AXValue with .x / .y
    pos = get_attr(element, "AXPosition")
    if pos is not None:
        try:
            info["position"] = {"x": pos.x, "y": pos.y}
        except AttributeError:
            info["position"] = None
    else:
        info["position"] = None

    # Size — AXValue with .width / .height
    size = get_attr(element, "AXSize")
    if size is not None:
        try:
            info["size"] = {"w": size.width, "h": size.height}
        except AttributeError:
            info["size"] = None
    else:
        info["size"] = None

    info["actions"] = get_actions(element)

    return info


def element_center(element):
    """Return (x, y) center of the element, or None."""
    pos = get_attr(element, "AXPosition")
    size = get_attr(element, "AXSize")
    if pos is None or size is None:
        return None
    try:
        cx = pos.x + size.width / 2.0
        cy = pos.y + size.height / 2.0
        return (cx, cy)
    except AttributeError:
        return None


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
    """DFS search returning the first AX element matching the criteria."""
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
    """Return a list of all AX elements matching the criteria."""
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
