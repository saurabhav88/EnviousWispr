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
    kAXNumberOfCharactersAttribute,
    kAXRoleAttribute,
    kAXValueAttribute,
)

# Roles that can carry an editable payload. `AXGroup` and `AXWebArea` are included
# because WebKit and Chromium wrap page fields in them; the dedupe below removes the
# mirrors this inclusiveness drags in.
TEXT_ROLES = frozenset({"AXTextArea", "AXTextField", "AXStaticText", "AXWebArea", "AXGroup"})

# A scan this small in a windowed app means the window contents were not in the tree —
# almost always because the app was not frontmost yet. Menus alone reach ~250 nodes.
MIN_PLAUSIBLE_NODES = 40


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
    """Bring the target forward. Trap 1 above is why every scan needs this first.

    The wait below is not the wait that matters: `settled_scan` gates on the text
    signature going quiet, and this only covers the window-server handoff, which
    exposes no completion signal to a foreign process.
    """
    for app in NSWorkspace.sharedWorkspace().runningApplications():
        if app.bundleIdentifier() == bundle_id:
            app.activateWithOptions_(_ACTIVATE_IGNORING)
            time.sleep(handoff)  # settle: window-server activation has no foreign-process signal
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


def scan(bundle_id: str, max_nodes: int = 6000, max_depth: int = 45) -> Scan:
    if not AXIsProcessTrusted():
        raise OracleUntrusted("harness process is not Accessibility-trusted")
    pid = pid_for_bundle(bundle_id)
    if pid is None:
        return Scan(ok=False, why="app_not_running")

    root = AXUIElementCreateApplication(pid)
    found: list[Field] = []
    visited = 0
    stack: list[tuple[Any, int]] = [(root, 0)]
    while stack and visited < max_nodes:
        element, depth = stack.pop()
        visited += 1
        role = _attr(element, kAXRoleAttribute)
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
    return Scan(ok=True, nodes_visited=visited, fields=_dedupe(found))


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
    result = settled_scan(bundle_id)
    if not result.ok:
        return False, f"precondition_scan_failed:{result.why}"
    if not result.carrying(sentinel):
        return False, "precondition_sentinel_not_found"
    return True, "ok"
