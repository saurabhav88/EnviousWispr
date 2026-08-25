#!/usr/bin/env python3
"""Judge one Xcode test lane from its result bundle (#2401).

Owner for the STRUCTURED half of `ew_lane_verdict`; `lane-verdict.sh` owns the
count guard and the contract, and its header owns the reasoning. This file is
separate for one reason: an inline heredoc inside a shell function cannot be
imported by a test, so it could only be exercised by running a whole lane, and
in practice would never be exercised at all.

Input is the JSON from `xcrun xcresulttool get test-results tests --path <bundle>`
on stdin's named file. Exits 0 when every Test Case carries an accepted result,
1 otherwise, and 1 on any malformed input — a measurement authority fails CLOSED,
because a half-failed judge that prints a verdict looks like a real one.
"""

from __future__ import annotations

import json
import os
import sys

# Passed to us so the shell file stays the single place the accepted set is
# stated. Split on newlines, not spaces: "Expected Failure" contains one.
DEFAULT_ACCEPTED = ("Passed", "Skipped", "Expected Failure")


def _accepted() -> frozenset[str]:
    raw = os.environ.get("EW_LANE_ACCEPTED", "")
    # The shell passes a space-joined string for readability at the call site.
    # Reconstruct rather than split, because one member contains a space and a
    # naive split would silently accept the token "Expected" on its own.
    known = {value for value in DEFAULT_ACCEPTED if value in raw}
    return frozenset(known) if known else frozenset(DEFAULT_ACCEPTED)


def _test_cases(node: object, out: list[dict]) -> None:
    if not isinstance(node, dict):
        return
    if node.get("nodeType") == "Test Case":
        out.append(node)
        return
    for child in node.get("children") or []:
        _test_cases(child, out)


def _failure_messages(node: object, out: list[str]) -> None:
    if not isinstance(node, dict):
        return
    if node.get("nodeType") == "Failure Message":
        name = node.get("name")
        if name:
            out.append(str(name))
    for child in node.get("children") or []:
        _failure_messages(child, out)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: lane-verdict.py <results.json>", file=sys.stderr)
        return 1

    label = os.environ.get("EW_LANE_LABEL", "lane")
    accepted = _accepted()

    try:
        with open(argv[1], encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: {label} result payload is unreadable: {exc}", file=sys.stderr)
        return 1

    roots = payload.get("testNodes")
    if not isinstance(roots, list):
        print(f"ERROR: {label} result payload has no testNodes array", file=sys.stderr)
        return 1

    cases: list[dict] = []
    for root in roots:
        _test_cases(root, cases)

    # Zero cases is the same refusal the count guard makes, arrived at from the
    # other side. Both are kept: they can disagree, and a disagreement is itself
    # worth failing on.
    if not cases:
        print(f"ERROR: {label} result bundle contains ZERO test cases", file=sys.stderr)
        return 1

    bad: list[tuple[str, object]] = []
    for case in cases:
        identity = case.get("nodeIdentifier") or case.get("name") or "<unnamed test>"
        if case.get("result") not in accepted:
            bad.append((str(identity), case.get("result")))

    if bad:
        # Lead every line with the label, so a mutation control reading this
        # output can tell WHICH check fired rather than only that something did.
        for identity, result in bad[:20]:
            messages: list[str] = []
            for case in cases:
                if (case.get("nodeIdentifier") or case.get("name")) == identity:
                    _failure_messages(case, messages)
                    break
            detail = f" — {messages[0]}" if messages else ""
            print(f"ERROR: {label} result is {result!r}: {identity}{detail}", file=sys.stderr)
        if len(bad) > 20:
            print(f"ERROR: {label} and {len(bad) - 20} more", file=sys.stderr)
        return 1

    print(f"==> {label} result bundle: {len(cases)} test cases, all accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
