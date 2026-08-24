#!/usr/bin/env python3
"""Prove that a file split moved code rather than changed it.

Phase 2 of the pill refactor relocates 18 declarations out of one 1,448-line file
into thirteen. A diff of that is unreadable, which is the entire risk: a behavioural
change riding inside a wall of moved lines is invisible to a human reviewer.

So the proof is mechanical. Reconstruct the original file by concatenating the new
files in the original declaration order, strip what is EXPECTED to differ, and diff
against the base revision. The expected difference is enumerated in advance, in
`--expect`, so a fourth kind of difference is a finding rather than a judgment call.

FAILS CLOSED. A missing file, an unreadable revision, a declaration it cannot locate,
or a reconstruction shorter than the original exits nonzero. A measurement authority
that prints a number after a half-failed read looks exactly like a real result.

Usage:
  scripts/verify-view-split.py \
      --base <sha> --original Sources/.../OverlayLegacyViews.swift \
      --new Sources/.../A.swift --new Sources/.../B.swift ... \
      [--allow-widen OverlayCapsuleBackground --allow-widen DistressCapsuleBackground] \
      [--json <out>]

The oracle is `git show <base>:<path>`, never a working-tree path: a path pins a
LOCATION and a revision pins CONTENT, and with several worktrees on this machine the
working tree is not a stable identity.
"""
from __future__ import annotations

import argparse
import difflib
import json
import pathlib
import re
import subprocess
import sys

DECL = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s*\n)*"
    r"(?:public |internal |private |fileprivate |package )?"
    r"(?:final class|class|struct|enum|extension|protocol) ",
    re.MULTILINE,
)


def die(msg: str) -> "None":
    print(f"BLOCKED: {msg}", file=sys.stderr)
    raise SystemExit(2)


def git_show(base: str, path: str) -> str:
    proc = subprocess.run(
        ["git", "show", f"{base}:{path}"], capture_output=True, text=True)
    if proc.returncode != 0:
        die(f"git show {base}:{path} failed: {proc.stderr.strip()}")
    if not proc.stdout.strip():
        die(f"{base}:{path} is empty — refusing to compare against nothing")
    return proc.stdout


def strip_imports(text: str, path_label: str) -> str:
    """Drop the leading `import` block and nothing else.

    Imports are the one region expected to differ — each new file needs its own —
    and stripping anything more would silently discard content. An earlier version
    dropped everything before the first declaration, which also ate each file's
    doc comment; its own two-way control caught that, which is the argument for
    having one.

    Doc comments and MARKs are content and must survive, because a comment that
    records why a view exists is exactly what a relocation loses.
    """
    lines = text.split("\n")
    i = 0
    while i < len(lines) and (
            not lines[i].strip()
            or lines[i].startswith("import ")
            or lines[i].startswith("@testable import ")):
        i += 1
    if i == 0 and not any(l.startswith("import ") for l in lines[:20]):
        die(f"{path_label}: no import block found in the first 20 lines — "
            "the parse is wrong, not the file")
    return "\n".join(lines[i:])


def drop_blank_lines(text: str) -> str:
    """Remove every blank line, from BOTH sides of the diff.

    A file split inserts and loses blank lines at every seam, and there are as many
    seams as files. Left in, they flood the diff with a noise class that trains the
    reader to skim the one artifact that has to be read line by line.

    Blank lines carry no behaviour in Swift, and formatting has its own authority —
    though NOT the one an earlier version of this docstring named. It said
    `swift-format` runs in CI; measured 2026-08-24, no workflow mentions it. What
    actually exists is `.claude/scripts/swift-format-hook.sh`, a PostToolUse hook on
    `Edit|Write` that runs `swift-format format --in-place` on every Swift file the
    assistant edits. That is a stronger reformat pressure than a CI check, not a
    weaker one, because it REWRITES rather than complains — and it is why a verbatim
    relocation must be written through Bash rather than the Edit/Write tools, which
    would reformat the moved code between the write and this check.

    **Stated limit:** this tool deliberately ignores added, removed, or relocated
    blank lines. Whitespace changes on nonblank lines remain differences and produce
    `CONTENT CHANGED`. An earlier version of this sentence said "blind to
    whitespace-only changes", which overclaims in the dangerous direction — a reader
    would conclude a reindent of moved code passes unreported, and it does not. The
    claim is now two-way controlled: harness arms 11 and 12 add a blank line
    (MOVE-ONLY) and indent one nonblank line (CONTENT CHANGED).

    It answers "did any code or comment change", which is the question a relocation
    must answer.
    """
    return "\n".join(l for l in text.split("\n") if l.strip())


def normalise(text: str, widened: list[str]) -> str:
    """Undo the ONE difference a split legitimately forces.

    File-private access cannot survive a file split, so a type consumed across the
    new boundary must widen to internal. Each such type is named on the command
    line: an unlisted widening stays in the diff and is reported.
    """
    for name in widened:
        for kind in ("struct", "class", "enum", "extension"):
            text = text.replace(f"private {kind} {name}", f"{kind} {name}")
    return drop_blank_lines(text).rstrip("\n") + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="revision holding the original file")
    ap.add_argument("--original", required=True, help="repo-relative path at --base")
    ap.add_argument("--new", action="append", required=True,
                    help="repo-relative path of a destination file, in ORIGINAL "
                         "declaration order; repeat once per file")
    ap.add_argument("--allow-widen", action="append", default=[],
                    help="type name permitted to lose `private`; repeat per type")
    ap.add_argument("--drop-original-lines", default=None, metavar="A-B",
                    help="1-based inclusive line range of the ORIGINAL that is "
                         "deliberately deleted rather than moved — the file-level "
                         "narration block. Declared on the command line so it is in "
                         "the receipt; an undeclared deletion still fails.")
    ap.add_argument("--json", help="write the receipt here")
    args = ap.parse_args()

    original_raw = git_show(args.base, args.original)

    dropped: list[str] = []
    if args.drop_original_lines:
        try:
            lo, hi = (int(x) for x in args.drop_original_lines.split("-", 1))
        except ValueError:
            die(f"--drop-original-lines must be A-B, got {args.drop_original_lines!r}")
        lines = original_raw.split("\n")
        if not (1 <= lo <= hi <= len(lines)):
            die(f"--drop-original-lines {lo}-{hi} is outside the original's "
                f"1-{len(lines)} lines")
        dropped = lines[lo - 1:hi]
        if any(l.strip() and not l.lstrip().startswith("//") for l in dropped):
            die(f"--drop-original-lines {lo}-{hi} covers CODE, not only comments: "
                + next(l.strip() for l in dropped
                       if l.strip() and not l.lstrip().startswith("//")))
        original_raw = "\n".join(lines[:lo - 1] + lines[hi:])

    pieces: list[str] = []
    for rel in args.new:
        p = pathlib.Path(rel)
        if not p.is_file():
            die(f"{rel} does not exist — the file list is wrong")
        body = strip_imports(p.read_text(encoding="utf-8"), rel)
        if not body.strip():
            die(f"{rel} contributed nothing after its import block")
        pieces.append(body)

    # Joined with a single newline and blank-run-collapsed on BOTH sides: a seam
    # must not manufacture a blank line the original did not have, nor lose one
    # it did.
    rebuilt = normalise("\n".join(pieces), args.allow_widen)
    baseline = normalise(strip_imports(original_raw, args.original), args.allow_widen)

    rebuilt_lines = rebuilt.splitlines()
    baseline_lines = baseline.splitlines()

    # A reconstruction that lost code is the failure this exists to catch, and it
    # would otherwise present as a short, clean-looking diff.
    if len(rebuilt_lines) < len(baseline_lines):
        die(f"reconstruction is SHORTER than the original "
            f"({len(rebuilt_lines)} vs {len(baseline_lines)} lines) — "
            "declarations were lost, not moved")

    diff = list(difflib.unified_diff(
        baseline_lines, rebuilt_lines,
        fromfile=f"{args.base}:{args.original}", tofile="reconstruction",
        lineterm="", n=2))

    changed = [d for d in diff
               if (d.startswith("+") or d.startswith("-"))
               and not d.startswith("+++") and not d.startswith("---")]

    receipt = {
        "base": args.base,
        "original": args.original,
        "new_files": args.new,
        "allowed_widenings": args.allow_widen,
        "dropped_original_lines": args.drop_original_lines,
        "dropped_text": dropped,
        "original_lines": len(baseline_lines),
        "reconstruction_lines": len(rebuilt_lines),
        "residual_changed_lines": len(changed),
        "verdict": "MOVE-ONLY" if not changed else "CONTENT CHANGED",
        "diff": diff,
    }
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(receipt, indent=2))

    if changed:
        print("\n".join(diff))
        print(f"\nCONTENT CHANGED: {len(changed)} line(s) differ beyond imports, the "
              "file header, and the declared widenings. Each one is a real edit "
              "inside a move.")
        return 1

    print(f"MOVE-ONLY: {len(baseline_lines)} lines reconstructed exactly from "
          f"{len(args.new)} files.")
    print(f"Allowed widenings applied: {args.allow_widen or 'none'}")
    if dropped:
        print(f"Declared deletion: {len(dropped)} comment line(s) at "
              f"{args.drop_original_lines}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
