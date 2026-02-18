#!/usr/bin/env python3
"""CLI tool for inspecting the macOS Accessibility tree.

Subcommands
-----------
dump   — Walk the AX tree and print as JSON.
find   — Find all elements matching --role / --title, print JSON array with center coords.
diff   — Compare a saved JSON snapshot against the current live tree.
"""

import argparse
import json
import os
import sys
import time

# Allow importing ui_helpers from the same directory regardless of cwd.
sys.path.insert(0, os.path.dirname(__file__))

from ui_helpers import (
    find_app_pid,
    get_ax_app,
    walk_tree,
    find_all_elements,
    element_info,
    element_center,
)


# ---------------------------------------------------------------------------
# Serialisation helpers
# ---------------------------------------------------------------------------

def _sanitize_value(v):
    """Convert values that are not JSON-serialisable into strings."""
    if v is None or isinstance(v, (bool, int, float, str)):
        return v
    if isinstance(v, (list, tuple)):
        return [_sanitize_value(i) for i in v]
    if isinstance(v, dict):
        return {k: _sanitize_value(val) for k, val in v.items()}
    return str(v)


def _sanitize_tree(node):
    """Recursively sanitize a tree dict for JSON output."""
    sanitized = {}
    for k, v in node.items():
        if k == "children":
            sanitized["children"] = [_sanitize_tree(c) for c in v]
        else:
            sanitized[k] = _sanitize_value(v)
    return sanitized


# ---------------------------------------------------------------------------
# Subcommand: dump
# ---------------------------------------------------------------------------

def cmd_dump(args):
    pid = _resolve_pid(args)
    app = get_ax_app(pid)
    tree = walk_tree(app, max_depth=args.depth)
    sanitized = _sanitize_tree(tree)
    print(json.dumps(sanitized, indent=2, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Subcommand: find
# ---------------------------------------------------------------------------

def cmd_find(args):
    pid = _resolve_pid(args)
    app = get_ax_app(pid)

    elements = find_all_elements(
        app,
        role=args.role,
        title=args.title,
        max_depth=args.depth,
    )

    results = []
    for el in elements:
        info = element_info(el)
        center = element_center(el)
        info["center"] = {"x": center[0], "y": center[1]} if center else None
        results.append(_sanitize_value(info))

    print(json.dumps(results, indent=2, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Subcommand: diff
# ---------------------------------------------------------------------------

_COMPARE_FIELDS = ("role", "title", "description", "enabled")


def _build_path(parent_path, index, node):
    """Build a human-readable path segment like 'root > [0] AXMenuBar > [1] AXMenuItem \'Settings...\''"""
    role = node.get("role") or "?"
    title = node.get("title") or ""
    label = f"[{index}] {role}"
    if title:
        label += f" '{title}'"
    if parent_path:
        return f"{parent_path} > {label}"
    return label


def diff_trees(old, new, parent_path="root", index=0):
    """Recursively compare two tree dicts, returning a list of diff strings."""
    diffs = []
    path = _build_path(parent_path, index, old)

    # Compare scalar fields
    for field in _COMPARE_FIELDS:
        old_val = old.get(field)
        new_val = new.get(field)
        if old_val != new_val:
            diffs.append(f"CHANGED {path}: {field} {old_val!r} -> {new_val!r}")

    # Compare children counts
    old_children = old.get("children", [])
    new_children = new.get("children", [])
    if len(old_children) != len(new_children):
        diffs.append(
            f"CHILDREN {path}: count {len(old_children)} -> {len(new_children)}"
        )

    # Recurse into shared children
    for i in range(min(len(old_children), len(new_children))):
        diffs.extend(diff_trees(old_children[i], new_children[i], path, i))

    return diffs


def cmd_diff(args):
    pid = _resolve_pid(args)
    snapshot_path = args.snapshot_file

    with open(snapshot_path, "r") as f:
        old_tree = json.load(f)

    app = get_ax_app(pid)
    new_tree = _sanitize_tree(walk_tree(app, max_depth=args.depth))

    diffs = diff_trees(old_tree, new_tree)
    if diffs:
        for d in diffs:
            print(d)
    else:
        print("No differences found.")


# ---------------------------------------------------------------------------
# PID resolution
# ---------------------------------------------------------------------------

def _resolve_pid(args):
    """Return a PID from --pid or --app, or exit with an error."""
    if args.pid is not None:
        return args.pid
    if args.app is not None:
        pid = find_app_pid(args.app)
        if pid is None:
            print(f"Error: could not find running process '{args.app}'", file=sys.stderr)
            sys.exit(1)
        return pid
    print("Error: provide --app or --pid", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        description="Inspect the macOS Accessibility tree of a running application.",
    )
    parser.add_argument("--app", type=str, help="Process name (resolved via pgrep -x)")
    parser.add_argument("--pid", type=int, help="Process ID")
    parser.add_argument("--depth", type=int, default=10, help="Max tree depth (default: 10)")

    sub = parser.add_subparsers(dest="command")

    # dump
    sub.add_parser("dump", help="Walk AX tree and print JSON")

    # find
    find_parser = sub.add_parser("find", help="Find elements matching criteria")
    find_parser.add_argument("--role", type=str, help="AX role to match (e.g. AXButton)")
    find_parser.add_argument("--title", type=str, help="AX title to match")

    # diff
    diff_parser = sub.add_parser("diff", help="Diff current tree against a saved snapshot")
    diff_parser.add_argument("snapshot_file", type=str, help="Path to saved JSON snapshot")

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(0)

    if args.command == "dump":
        cmd_dump(args)
    elif args.command == "find":
        cmd_find(args)
    elif args.command == "diff":
        cmd_diff(args)


if __name__ == "__main__":
    main()
