"""Independent destination oracle for the paste bake-off (#2652).

**Why an oracle at all.** The defect under test is that EnviousWispr's own verdict
about its own write is wrong. So EnviousWispr's logs cannot score delivery; only the
destination application's text can. This module reads that text out of a foreign app
through the Accessibility API, from a DIFFERENT process, after a settle the app
itself could never afford.

That last clause is why an AX-based oracle is legitimate here even though the
suspected mechanism is AX lag: the app must decide in microseconds, this oracle may
wait seconds and re-read until the value stops moving.

## Two traps found while building this, both measured on 2026-09-04

**1. A scan taken before the target is frontmost returns `ok: True` with an EMPTY
field list.** Measured against Safari: 541 nodes visited, zero sentinel matches, no
error — and the page was there the whole time. That is a silent-empty read that means
"nothing landed" in the scorer's vocabulary, which is the answer that would make every
variant look like it drops text.
**Defence, mandatory:** `assert_precondition()` must find the pre-image sentinel BEFORE
the trial runs. A cell whose pre-image cannot be found is `invalid`, never `fail`.
(`validation-discipline.md`: before believing any sweep's silence, run the pattern
against a case you KNOW is present.)

**2. One web field appears TWICE in the tree.** A Safari `<textarea>` yields an
`AXTextArea` carrying the value AND a child `AXStaticText` mirroring the same string
with `AXNumberOfCharacters` of `None`. A scorer counting matches would read one
insertion as two — a fabricated duplicate, in the exact direction of the defect we are
hunting. **Defence:** `_dedupe()` keeps only elements reporting a real character count
and collapses identical (role, value) pairs.

## What this module does NOT do

It does not decide pass or fail. It returns what it read plus why a read is
untrustworthy, and the harness classifies. Anything it cannot establish comes back as
`invalid` with a reason, never as a verdict.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any

from AppKit import NSWorkspace

# The constant is a module-level symbol in pyobjc, NOT a class attribute on
# NSRunningApplication — reading it off the class raises AttributeError at call time,
# which is a runtime failure inside the harness rather than an import error. Bind it
# once here so a missing symbol fails loudly at import instead of mid-run.
try:
    from AppKit import NSApplicationActivateIgnoringOtherApps as _ACTIVATE_IGNORING
except ImportError:  # pragma: no cover - platform constant, present on every macOS
    _ACTIVATE_IGNORING = 1 << 1
from ApplicationServices import (
    AXIsProcessTrusted,
    AXUIElementCopyAttributeValue,
    AXUIElementCreateApplication,
    kAXChildrenAttribute,
    kAXFocusedAttribute,
    kAXFocusedUIElementAttribute,
    kAXWindowsAttribute,
    kAXNumberOfCharactersAttribute,
    kAXRoleAttribute,
    kAXValueAttribute,
)

# Roles that can carry an editable payload. `AXGroup` and `AXWebArea` are included
# because WebKit and Chromium wrap page fields in them; the dedupe below removes the
# mirrors this inclusiveness drags in.
TEXT_ROLES = frozenset({"AXTextArea", "AXTextField", "AXStaticText", "AXWebArea", "AXGroup"})

# A scan this small means the window subtree was not readable. The walk now starts at the
# windows rather than the application root, so the menu bar no longer inflates this count
# and a genuine document reaches dozens of nodes on its own.
MIN_PLAUSIBLE_NODES = 5

# Subtrees that can never hold the field under test and can be enormous. TextEdit's
# Open Recent menu alone grew past the whole node budget once 38 fixture files had
# accumulated, and the walk exhausted its cap before reaching the document — returning
# SUCCESS with an empty field list, which the scorer reads as "nothing landed".
SKIP_ROLES = frozenset({"AXMenuBar", "AXMenu", "AXMenuItem", "AXMenuBarItem"})


def screen_is_locked() -> bool:
    """Whether the login window owns the screen.

    **A locked Mac makes every reading in this file worthless, and every one of them
    fails SILENTLY into a verdict.** No app can be brought forward, so `activate` reports
    failure, `AXFocusedUIElement` returns nothing, the precondition finds no sentinel, and
    a trial that never ran is recorded as one that did.

    Measured 2026-09-04, and this function exists because of the cost rather than the
    theory: a full 100-trial run degraded into precondition failures partway through, and
    the next forty minutes went into rewriting the tree walk, adding a cycle guard, and
    re-rooting the traversal — three changes made to explain readings that a locked screen
    fully accounts for. The tell was one line: the frontmost application was
    `com.apple.loginwindow`.
    """
    import Quartz

    session = Quartz.CGSessionCopyCurrentDictionary()
    return bool(session.get("CGSSessionScreenIsLocked", 0)) if session else False


class ScreenLocked(RuntimeError):
    """The Mac is locked. Never a trial failure, and never a finding about a variant."""


class OracleUntrusted(RuntimeError):
    """The harness process lacks Accessibility permission. Never a trial failure."""


@dataclass(frozen=True)
class Field:
    role: str
    depth: int
    chars: int | None
    focused: bool
    value: str


@dataclass
class Scan:
    ok: bool
    why: str | None = None
    nodes_visited: int = 0
    fields: list[Field] = field(default_factory=list)

    def carrying(self, needle: str) -> list[Field]:
        return [f for f in self.fields if needle in f.value]


def _attr(element: Any, name: str) -> Any:
    err, value = AXUIElementCopyAttributeValue(element, name, None)
    return value if err == 0 else None


def pid_for_bundle(bundle_id: str) -> int | None:
    for app in NSWorkspace.sharedWorkspace().runningApplications():
        if app.bundleIdentifier() == bundle_id:
            return app.processIdentifier()
    return None


def activate(bundle_id: str, handoff: float = 1.0) -> bool:
    """Bring the target to the FRONT, and verify it got there.

    **`NSRunningApplication.activateWithOptions_` is deprecated on macOS 26 and did
    nothing here.** Measured 2026-09-04: every target reported `no_focused_element` or an
    `AXApplication` as its focused element — the shape a BACKGROUND app returns — while the
    call reported success. Every earlier probe that worked had gone through AppleScript
    without anyone noticing that was the load-bearing difference.

    So this tries the modern API, then AppleScript, and then CHECKS. An activation helper
    that returns True without the app being frontmost poisons every trial downstream, and
    the poison looks like "the variant dropped the text".
    """
    if pid_for_bundle(bundle_id) is None:
        return False
    for app in NSWorkspace.sharedWorkspace().runningApplications():
        if app.bundleIdentifier() == bundle_id:
            try:
                app.activate()
            except AttributeError:
                app.activateWithOptions_(_ACTIVATE_IGNORING)
            break
    # Ten seconds, not three. Measured 2026-09-04: Slack took longer than three to come
    # forward from a minimised state and every Slack trial was recorded
    # `would_not_come_forward` — honest, and useless. An activation deadline is a
    # PARAMETER, and a parameter that is too small turns a slow app into an unmeasured one.
    deadline = time.monotonic() + max(handoff, 10.0)
    while time.monotonic() < deadline:
        # settle: poll gap between two reads of the signal this loop gates on
        time.sleep(0.25)
        front = NSWorkspace.sharedWorkspace().frontmostApplication()
        if front is not None and front.bundleIdentifier() == bundle_id:
            time.sleep(handoff)  # settle: window-server handoff has no foreign-process signal
            return True
    return False


def _dedupe(found: list[Field]) -> list[Field]:
    """Collapse a web field's AXStaticText mirror into the element that owns the text.

    Trap 2. Drops an entry with no character count whose value duplicates one that has
    a count, then keeps the first occurrence of each (role, value) pair.
    """
    counted = {f.value for f in found if f.chars is not None}
    kept: list[Field] = []
    seen: set[tuple[str, str]] = set()
    for f in found:
        if f.chars is None and f.value in counted:
            continue
        key = (f.role, f.value)
        if key in seen:
            continue
        seen.add(key)
        kept.append(f)
    return kept


def scan(bundle_id: str, max_nodes: int = 20000, max_depth: int = 45) -> Scan:
    """Walk the app's AX tree and return every text-bearing element.

    **The tree is a GRAPH, not a tree, and walking it as a tree does not terminate.**
    Measured 2026-09-04 against TextEdit: an unguarded walk visited 3,000 nodes and found
    `AXApplication` NINE times and 2,646 menu items — menu subtrees link back to the
    application root, so the walk cycled through menus forever and never reached the open
    document. The scan then returned SUCCESS with an empty field list, which the scorer
    reads as "nothing landed". Two independent guards, because either alone is thin: an
    identity set so no element is expanded twice, and skipping menu subtrees outright.
    """
    if not AXIsProcessTrusted():
        raise OracleUntrusted("harness process is not Accessibility-trusted")
    pid = pid_for_bundle(bundle_id)
    if pid is None:
        return Scan(ok=False, why="app_not_running")

    root = AXUIElementCreateApplication(pid)

    # **Walk from the APPLICATION root, and skip menu subtrees.**
    #
    # A window-rooted walk was tried and reverted the same hour. It fixed TextEdit and
    # broke Safari, Chrome and every chat app — Safari fell from finding both page fields
    # to finding none, because a browser's page content is not reached through
    # `AXWindows` the way a document window's is. The change was made to rescue ONE target
    # that is not even in the matrix, and it silently cost the targets that mattered.
    #
    # What remains is the guard that was actually needed: `SKIP_ROLES` prunes the menu bar,
    # which is where TextEdit's cycle lived (an unguarded walk found `AXApplication` nine
    # times and 2,646 menu items before reaching any document). Pruning the cycle's source
    # needs no equality semantics to be correct — an identity set was also tried, and
    # pyobjc collapsed every AX element into one, visiting two nodes total while reporting
    # success.
    found: list[Field] = []
    visited = 0
    stack: list[tuple[Any, int]] = [(root, 0)]
    while stack and visited < max_nodes:
        element, depth = stack.pop()
        visited += 1
        role = _attr(element, kAXRoleAttribute)
        if role in SKIP_ROLES:
            continue
        if role in TEXT_ROLES:
            value = _attr(element, kAXValueAttribute)
            if isinstance(value, str) and value.strip():
                found.append(
                    Field(
                        role=role,
                        depth=depth,
                        chars=_attr(element, kAXNumberOfCharactersAttribute),
                        focused=bool(_attr(element, kAXFocusedAttribute)),
                        value=value,
                    )
                )
        if depth < max_depth:
            for child in _attr(element, kAXChildrenAttribute) or []:
                stack.append((child, depth + 1))

    if visited < MIN_PLAUSIBLE_NODES:
        return Scan(
            ok=False,
            why="tree_too_small_target_probably_not_frontmost",
            nodes_visited=visited,
        )
    # A TRUNCATED walk is not a completed one, and the difference is invisible in the
    # result: both return a field list, and a truncated walk's list can be empty. Measured
    # 2026-09-04 against TextEdit — 6000 nodes visited, zero fields found, the document
    # sitting there the whole time. Reporting that as a successful empty scan is how an
    # oracle tells the scorer that nothing landed.
    if visited >= max_nodes and not found:
        return Scan(ok=False, why="scan_truncated_at_node_cap", nodes_visited=visited)
    return Scan(ok=True, nodes_visited=visited, fields=_dedupe(found))


def read_focused(bundle_id: str) -> Scan:
    """Read the FOCUSED element only. One call, no tree walk.

    **This is the oracle that works, and the tree walk is the one that did not.** The
    harness puts the caret in the field under test, so the focused element IS that field;
    everything the walk was for — finding it among siblings — is a question the system
    already answers.

    The walk failed three different ways on three different apps and each failure returned
    an EMPTY field list rather than an error, which the scorer reads as "nothing landed":
    TextEdit's menus link back to the application root, so an unguarded walk cycled through
    2,646 menu items and never reached the document; pruning menus then left 91 reachable
    nodes with no text in them; and a browser with forty accumulated tabs exceeded any node
    budget. Every fix traded one app's failure for another's.

    `scan()` is kept for the WRONG-FIELD question — did the text land somewhere it should
    not have — where enumerating siblings is the actual question. It is never the primary
    verdict source.
    """
    if not AXIsProcessTrusted():
        raise OracleUntrusted("harness process is not Accessibility-trusted")
    if screen_is_locked():
        raise ScreenLocked("the Mac is locked; no reading here means anything")
    pid = pid_for_bundle(bundle_id)
    if pid is None:
        return Scan(ok=False, why="app_not_running")
    application = AXUIElementCreateApplication(pid)
    element = _attr(application, kAXFocusedUIElementAttribute)
    if element is None:
        return Scan(ok=False, why="no_focused_element")
    role = _attr(element, kAXRoleAttribute)
    value = _attr(element, kAXValueAttribute)
    if not isinstance(value, str):
        return Scan(ok=False, why=f"focused_element_has_no_text_value:{role}")
    return Scan(
        ok=True,
        nodes_visited=1,
        fields=[Field(role=role or "unknown", depth=0,
                      chars=_attr(element, kAXNumberOfCharactersAttribute),
                      focused=True, value=value)],
    )


def settled_focused(
    bundle_id: str,
    *,
    poll_interval: float = 0.4,
    max_wait: float = 4.0,
    stable_polls: int = 2,
) -> Scan:
    """Read the focused element until its text stops changing.

    Gates on STABILITY, never on elapsed time: "unchanged across N polls" has no parameter
    to get wrong, and `max_wait` is a deadline around the signal rather than the signal.
    """
    deadline = time.monotonic() + max_wait
    previous: str | None = None
    stable = 0
    last = Scan(ok=False, why="never_read")
    while time.monotonic() < deadline:
        time.sleep(poll_interval)  # settle: poll gap between two reads of the gating signal
        last = read_focused(bundle_id)
        if not last.ok:
            continue
        signature = f"{last.fields[0].chars}:{last.fields[0].value}"
        if signature == previous:
            stable += 1
            if stable >= stable_polls:
                return last
        else:
            stable = 0
            previous = signature
    return last


def settled_scan(
    bundle_id: str,
    *,
    poll_interval: float = 0.4,
    max_wait: float = 3.0,
    stable_polls: int = 2,
) -> Scan:
    """Scan until the readable text stops changing.

    **Gates on STABILITY, never on elapsed time.** A fixed wait is a parameter that can
    be wrong, and wrong in the silent direction; "unchanged across N polls" has no
    parameter to get wrong. `max_wait` is a deadline AROUND the signal, not the signal.
    """
    deadline = time.monotonic() + max_wait
    previous: str | None = None
    stable = 0
    last = Scan(ok=False, why="never_scanned")
    while time.monotonic() < deadline:
        time.sleep(poll_interval)  # settle: poll gap between two reads of the gating signal
        last = scan(bundle_id)
        if not last.ok:
            continue
        signature = "\x00".join(f"{f.role}:{f.chars}:{f.value}" for f in last.fields)
        if signature == previous:
            stable += 1
            if stable >= stable_polls:
                return last
        else:
            stable = 0
            previous = signature
    return last


def assert_precondition(bundle_id: str, sentinel: str) -> tuple[bool, str]:
    """Positive control. MUST pass before a trial is allowed to run.

    A False here makes the trial `invalid`, never `fail` — the difference between "the
    variant dropped the text" and "the oracle was blind" is the whole value of this
    function.
    """
    result = settled_focused(bundle_id)
    if not result.ok:
        return False, f"precondition_read_failed:{result.why}"
    if not result.carrying(sentinel):
        return False, "precondition_sentinel_not_in_focused_field"
    return True, "ok"
