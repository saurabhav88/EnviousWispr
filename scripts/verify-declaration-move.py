#!/usr/bin/env python3
"""Prove that declarations moved between files rather than changing.

**Why this exists rather than `verify-view-split.py`.** That tool reconstructs the
original by CONCATENATING destination files in declaration order, which requires
each destination to hold a CONTIGUOUS run of declarations and to have been empty
before the move. #2375 C1a satisfies neither, measured before this file was
written:

  - the three destinations interleave — `PillDefinition` occupies three separate
    runs in declaration order and `PillExpiry` two, because placement and expiry
    declarations sit between the presentation ones;
  - `OverlayPlacementState.swift` is a pre-existing 208-line file with its own
    declaration, so concatenating it would feed the reconstruction content the
    original never had.

Either alone defeats concatenation. So this tool asks an ORDER-INDEPENDENT
question instead, which is the right question for a move that regroups rather
than merely splits:

  1. **Line conservation.** The multiset of non-blank, non-import lines ADDED to
     the destinations equals the multiset of non-blank, non-import lines in the
     original at `--base`. Every line moved; none was added, lost, or edited.
  2. **Supported declaration accounting.** Every top-level class, struct, enum,
     actor, extension or protocol declaration in the original appears in exactly
     ONE destination, exactly once, and no destination gained a supported
     declaration the original did not have.

     **"Supported" is load-bearing, not hedging.** The parser reads those six
     forms and no others, so a top-level `typealias`, `func`, `var` or `macro`
     is invisible to check 2 — it would still be caught by check 1, which counts
     lines, but it would not be ACCOUNTED to a declaration. Measured for #2375
     C1a before relying on this: the original and all three destinations contain
     ZERO such forms. A file that has them needs the parser widened, not this
     comment reread.
  3. **Per-declaration ownership and order.** Each declaration's SIGNIFICANT
     lines, including its leading comment and attribute run, stay attached to
     that declaration and occur in their base order. Blank lines and imports are
     excluded and declared access widenings are normalised first, so this is not
     a byte-identity claim — an earlier version of this sentence said "byte-
     identical", which overclaims in the direction that matters.
  4. **Pre-existing declarations in a destination are untouched**, checked the
     same way. A reorder inside one adds and removes nothing, so every count
     above stays green and only this catches it.
  5. **No survivor.** The original path is gone from the working tree.

**Check 3 exists because checks 1 and 2 are not sufficient, and this is measured
rather than anticipated.** The first run of this chunk moved two `// MARK:`
section headers onto the wrong neighbouring declaration: every line was still
present exactly once, every declaration had exactly one home, and the verdict was
MOVE-ONLY while `Screens and geometry` labelled the presentation types. A
whole-file multiset cannot see WHICH declaration a line belongs to. Review caught
it; check 3 is what makes it catchable.

So the tool is blind to the ORDER OF DECLARATIONS, deliberately — regrouping is
what this chunk does — and NOT blind to which declaration a line belongs to, nor
to content.

FAILS CLOSED. A missing file, an unreadable revision, a destination whose base
version cannot be read, or a zero-declaration parse exits nonzero. A measurement
authority that prints a number after a half-failed read looks exactly like a real
result.

Usage:
  scripts/verify-declaration-move.py \
      --base <sha> --original Sources/.../OverlayVocabulary.swift \
      --dest Sources/.../PillDefinition.swift \
      --dest Sources/.../PillExpiry.swift \
      --dest Sources/.../OverlayPlacementState.swift \
      [--allow-widen TypeName] [--json out.json]

The oracle is `git show <base>:<path>`, never a working-tree path: a path pins a
LOCATION and a revision pins CONTENT.
"""
from __future__ import annotations

import argparse
import collections
import json
import pathlib
import re
import subprocess
import sys

DECL = re.compile(
    r"^(?:public |internal |private |fileprivate |package )?"
    r"(?:final class|class|struct|enum|actor|extension|protocol) +([A-Za-z_][A-Za-z0-9_]*)",
)


def die(msg: str) -> None:
    print(f"BLOCKED: {msg}", file=sys.stderr)
    raise SystemExit(2)


def git_show(base: str, path: str) -> str | None:
    proc = subprocess.run(
        ["git", "show", f"{base}:{path}"], capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    return proc.stdout


def significant(text: str, widened: list[str]) -> list[str]:
    """Non-blank, non-import lines, with permitted access widenings undone."""
    for name in widened:
        # Must stay in step with DECL's form list above. Adding a form to one and
        # not the other makes an allowed widening on that form fail the check it
        # was explicitly permitted by — which is the shape review caught when
        # `actor` was added to DECL alone.
        for kind in ("struct", "class", "enum", "actor", "extension", "protocol"):
            text = text.replace(f"private {kind} {name}", f"{kind} {name}")
    out = []
    for line in text.split("\n"):
        s = line.strip()
        if not s:
            continue
        if s.startswith("import ") or s.startswith("@testable import "):
            continue
        out.append(line)
    return out


def declarations(text: str) -> list[str]:
    return [m.group(1) for line in text.split("\n") if (m := DECL.match(line))]


def declaration_chunks(text: str, widened: list[str]) -> dict[str, tuple[str, ...]]:
    """Each declaration's ordered significant lines, including its leading comment/attribute run.

    **This is what a line multiset alone cannot see.** Comparing multisets across
    whole files is blind to WHICH declaration a line belongs to, so a section
    header attached to the wrong neighbour, or two properties swapped between two
    types, keeps every line present exactly once and passes. Measured on this
    chunk's first attempt: two `// MARK:` headers travelled with the wrong block
    and the multiset check reported MOVE-ONLY.

    Comparing per declaration closes that, because a line that changed owner is
    now missing from one chunk and extra in another.
    """
    lines = text.split("\n")
    starts = [(i, m.group(1)) for i, line in enumerate(lines) if (m := DECL.match(line))]
    prefixes: list[int] = []
    for i, _ in starts:
        j = i
        while j > 0:
            prev = lines[j - 1].strip()
            if prev.startswith("//") or prev.startswith("@"):
                j -= 1
            elif not prev and j - 2 >= 0 and lines[j - 2].strip().startswith("//"):
                # a blank line INSIDE a comment run still belongs to that run
                j -= 1
            else:
                break
        prefixes.append(j)
    out: dict[str, tuple[str, ...]] = {}
    for n, (_, name) in enumerate(starts):
        end = prefixes[n + 1] if n + 1 < len(prefixes) else len(lines)
        out[name] = tuple(significant("\n".join(lines[prefixes[n]:end]), widened))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--original", required=True)
    ap.add_argument("--dest", action="append", required=True)
    ap.add_argument("--allow-widen", action="append", default=[])
    ap.add_argument("--json")
    args = ap.parse_args()

    original_raw = git_show(args.base, args.original)
    if original_raw is None or not original_raw.strip():
        die(f"{args.base}:{args.original} is missing or empty — "
            "refusing to compare against nothing")

    if pathlib.Path(args.original).exists():
        die(f"{args.original} still exists in the working tree — "
            "a move that leaves the original behind is a copy")

    original_lines = significant(original_raw, args.allow_widen)
    original_decls = declarations(original_raw)
    if not original_decls:
        die(f"{args.base}:{args.original} parsed to ZERO declarations — "
            "the parse is wrong, not the file")

    added_lines: list[str] = []
    added_decls: list[str] = []
    gained_chunks: dict[str, tuple[str, ...]] = {}
    per_dest: dict[str, dict] = {}

    for rel in args.dest:
        p = pathlib.Path(rel)
        if not p.is_file():
            die(f"{rel} does not exist — the destination list is wrong")
        now = p.read_text(encoding="utf-8")
        # `git_show(...) or ""` would treat an unreadable revision as a NEW file,
        # which is the permissive direction and contradicts this tool's own
        # fail-closed claim. Ask whether the path EXISTS at base first, so
        # "absent" and "could not be read" stop being the same answer.
        listed = subprocess.run(
            ["git", "ls-tree", "--name-only", args.base, "--", rel],
            capture_output=True, text=True)
        if listed.returncode != 0:
            die(f"git ls-tree {args.base} -- {rel} failed: {listed.stderr.strip()}")
        exists_at_base = listed.stdout.strip() != ""
        before = git_show(args.base, rel) if exists_at_base else ""
        if exists_at_base and before is None:
            die(f"{args.base}:{rel} exists but could not be read")

        now_lines = significant(now, args.allow_widen)
        before_lines = significant(before, args.allow_widen)

        delta = list((collections.Counter(now_lines)
                      - collections.Counter(before_lines)).elements())
        removed = list((collections.Counter(before_lines)
                        - collections.Counter(now_lines)).elements())
        if removed:
            die(f"{rel} LOST {len(removed)} pre-existing line(s); a move must only "
                f"add. First: {removed[0].strip()!r}")

        d_now = set(declarations(now))
        d_before = set(declarations(before))
        gained = sorted(d_now - d_before)

        now_chunks = declaration_chunks(now, args.allow_widen)
        for name in gained:
            gained_chunks[name] = now_chunks[name]

        # A destination's PRE-EXISTING declarations must be untouched too. The
        # whole-file multiset cannot see a reorder inside one of them: no line is
        # added and none removed, so both the LOST check and the conservation
        # check stay green. Only comparing that declaration's own ordered lines
        # against its base version catches it.
        before_chunks = declaration_chunks(before, args.allow_widen)
        changed_existing = sorted(
            name for name, body in before_chunks.items()
            if now_chunks.get(name) != body)
        if changed_existing:
            die(f"{rel} changed pre-existing declaration(s): "
                f"{', '.join(changed_existing)}")

        added_lines.extend(delta)
        added_decls.extend(gained)
        per_dest[rel] = {"added_lines": len(delta), "gained_declarations": gained}

    # --- 1. line conservation -------------------------------------------------
    orig_c = collections.Counter(original_lines)
    add_c = collections.Counter(added_lines)
    only_original = list((orig_c - add_c).elements())
    only_added = list((add_c - orig_c).elements())

    # --- 2. declaration accounting -------------------------------------------
    dup = [n for n, k in collections.Counter(added_decls).items() if k > 1]
    missing = sorted(set(original_decls) - set(added_decls))
    extra = sorted(set(added_decls) - set(original_decls))

    # Per-declaration comparison: a line that changed OWNER is invisible to the
    # multiset above and visible here.
    original_chunks = declaration_chunks(original_raw, args.allow_widen)
    reassigned = sorted(
        name for name, body in original_chunks.items()
        if name in gained_chunks and gained_chunks[name] != body)

    ok = not (only_original or only_added or dup or missing or extra or reassigned)

    receipt = {
        "base": args.base,
        "original": args.original,
        "original_significant_lines": len(original_lines),
        "added_significant_lines": len(added_lines),
        "original_declarations": original_decls,
        "destinations": per_dest,
        "lines_only_in_original": len(only_original),
        "lines_only_in_destinations": len(only_added),
        "declarations_in_two_destinations": dup,
        "declarations_missing": missing,
        "declarations_not_in_original": extra,
        "declarations_whose_lines_changed_owner": reassigned,
        "allowed_widenings": args.allow_widen,
        "verdict": "MOVE-ONLY" if ok else "CONTENT CHANGED",
    }
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(receipt, indent=2) + "\n")

    print(f"base                     {args.base}")
    print(f"original                 {args.original} ({len(original_lines)} significant lines,"
          f" {len(original_decls)} declarations)")
    for rel, info in per_dest.items():
        print(f"  -> {rel}: +{info['added_lines']} lines, "
              f"{', '.join(info['gained_declarations']) or 'no new declarations'}")
    print(f"allowed widenings        {args.allow_widen or 'none'}")
    print(f"lines only in original   {len(only_original)}")
    print(f"lines only in new files  {len(only_added)}")
    print(f"declarations missing     {missing or 'none'}")
    print(f"declarations duplicated  {dup or 'none'}")
    print(f"declarations unexpected  {extra or 'none'}")
    print(f"declarations reassigned  {reassigned or 'none'}")
    print()
    print(f"VERDICT: {receipt['verdict']}")

    if not ok:
        for line in only_original[:5]:
            print(f"  only in original:  {line.strip()[:100]}")
        for line in only_added[:5]:
            print(f"  only in new files: {line.strip()[:100]}")
        for name in reassigned[:5]:
            was = set(original_chunks[name])
            now_ = set(gained_chunks[name])
            for line in sorted(was - now_)[:2]:
                print(f"  {name} LOST:   {line.strip()[:90]}")
            for line in sorted(now_ - was)[:2]:
                print(f"  {name} GAINED: {line.strip()[:90]}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
