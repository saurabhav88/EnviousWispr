#!/usr/bin/env python3
"""Debug-only test inventory: generate, and validate, from two result bundles (#3013).

The PR gate runs the Release suite; the only hosted Debug run is post-merge. Before
that Debug run can ever be narrowed to "the tests that exist only in Debug", the
set has to be KNOWN, and a difference of totals (8,061 Debug vs 7,371 Release on
2026-09-16) is not a set: a test whose identifier exists in both configurations
can still carry a `#if DEBUG` body that only Debug executes, and a stale list
runs green while omitting a test added yesterday.

So the inventory file has two sections with two different contracts:

    ## generated
    <identifier>            one per line; MUST equal (Debug ids − Release ids) exactly
    ## reviewed
    <identifier> | <reason> a test present in BOTH configurations whose Debug
                            execution protects something Release cannot see; must
                            resolve in Debug; the reason is mandatory

Execution selection for a narrowed Debug run is the UNION of both sections.
Release-only identifiers are reported, never silently accepted. Missing or
malformed data fails validation (exit 1); this is a measurement authority and it
fails closed.

Identifiers are taken from `xcrun xcresulttool get test-results tests` JSON:
`<bundle>/<nodeIdentifier>` for every "Test Case" node, plus `#<argument>` for
each "Arguments" child of a parameterized case, so bundle and case identity
survive (a display name does not: the console prints one line per parameterized
test and undercounts by thousands).

Usage:
  debug-only-inventory.py generate --debug <d.xcresult|d.json> --release <r.xcresult|r.json> --out scripts/ci/debug-only-tests.txt
      writes the `## generated` section from the live difference and PRESERVES the
      existing `## reviewed` section of --out (if any)
  debug-only-inventory.py validate --debug ... --release ... --inventory scripts/ci/debug-only-tests.txt
      exit 0 iff generated == Debug−Release AND every reviewed id resolves in Debug
  debug-only-inventory.py selectors --inventory scripts/ci/debug-only-tests.txt
      prints `-only-testing:` arguments for the union (for a narrowed run)
  debug-only-inventory.py --self-test
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote, unquote

GENERATED = "## generated"
REVIEWED = "## reviewed"

# One argument description embeds a value that differs on every run and carries
# no identity. Measured on the first real generation (2026-09-16): six
# `everyTextColourIsLegible(entry:)` cases read as "Debug-only" and eight as
# "Release-only" solely because `AppKitPlatformColorProvider(platformColor:
# Catalog color: #$customDynamic <UUID>)` minted a new UUID per process.
# Normalise THAT token only, anchored on its prefix: a bare UUID regex would also
# erase a real argument that happens to be a UUID (two cases ending 0001 and
# 0002 would collapse), and a real argument difference must stay a difference.
# Extend only for a value that is provably per-process.
_DYNAMIC_COLOUR_UUID = re.compile(
    r"(Catalog color: #\$customDynamic\s+)"
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)


def normalise(argument: str) -> str:
    return _DYNAMIC_COLOUR_UUID.sub(lambda m: m.group(1) + "<uuid>", argument)


def load_results(path: str) -> dict:
    """A .json file is read as-is; an .xcresult is read through xcresulttool."""
    if path.endswith(".json"):
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    if not os.path.isdir(path):
        raise SystemExit(f"ERROR: result bundle not found: {path}")
    out = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", path, "--compact"],
        check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def identifiers(payload: dict) -> set[str]:
    roots = payload.get("testNodes")
    if not isinstance(roots, list):
        raise SystemExit("ERROR: result payload has no testNodes array")
    ids: set[str] = set()

    def walk(node: object, bundle: str | None) -> None:
        if not isinstance(node, dict):
            return
        kind = node.get("nodeType")
        if kind == "Unit test bundle":
            bundle = node.get("name")
            if not isinstance(bundle, str) or not bundle.strip():
                raise SystemExit("ERROR: test bundle lacks a name")
        if kind == "Test Case":
            identifier = node.get("nodeIdentifier")
            # Fail closed on a malformed node: a `None/None` identity would let
            # two broken payloads validate an empty inventory as equal.
            if not isinstance(bundle, str) or not bundle.strip() \
                    or not isinstance(identifier, str) or not identifier.strip():
                raise SystemExit("ERROR: test case lacks bundle or nodeIdentifier")
            base = f"{bundle}/{identifier}"
            args = [c for c in node.get("children") or [] if isinstance(c, dict) and c.get("nodeType") == "Arguments"]
            if args:
                for a in args:
                    argument = a.get("name")
                    if not isinstance(argument, str) or not argument:
                        raise SystemExit("ERROR: parameterized case lacks argument identity")
                    # URL-encoded so an argument containing `|`, a newline or
                    # whitespace round-trips through the line-based inventory.
                    ids.add(f"{base}#{quote(normalise(argument), safe='')}")
            else:
                ids.add(base)
            return
        for child in node.get("children") or []:
            walk(child, bundle)

    for root in roots:
        walk(root, None)
    if not ids:
        raise SystemExit("ERROR: result payload contains ZERO test cases")
    return ids


def parse_inventory(path: str) -> tuple[list[str], list[tuple[str, str]]]:
    if not os.path.isfile(path):
        raise SystemExit(f"ERROR: inventory not found: {path}")
    generated: list[str] = []
    reviewed: list[tuple[str, str]] = []
    section = None
    with open(path, encoding="utf-8") as fh:
        for ln, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#") and not line.startswith("## "):
                continue
            if line.strip() == GENERATED:
                section = "g"; continue
            if line.strip() == REVIEWED:
                section = "r"; continue
            if section == "g":
                if "|" in line:
                    raise SystemExit(f"ERROR: {path}:{ln}: a generated row carries a reason; reasons belong to ## reviewed")
                generated.append(line.strip())
            elif section == "r":
                if "|" not in line:
                    raise SystemExit(f"ERROR: {path}:{ln}: a reviewed row needs `<identifier> | <reason>`")
                ident, reason = (p.strip() for p in line.split("|", 1))
                if not ident or not reason:
                    raise SystemExit(f"ERROR: {path}:{ln}: empty identifier or reason")
                reviewed.append((ident, reason))
            else:
                raise SystemExit(f"ERROR: {path}:{ln}: content before the first section header")
    if section is None:
        raise SystemExit(f"ERROR: {path}: no `{GENERATED}` / `{REVIEWED}` sections")
    return generated, reviewed


def write_inventory(path: str, generated: set[str], reviewed: list[tuple[str, str]]) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# Debug-only test inventory (#3013). Regenerate the generated section with\n"
                 "#   scripts/ci/debug-only-inventory.py generate --debug <d.xcresult> --release <r.xcresult> --out scripts/ci/debug-only-tests.txt\n"
                 "# from two result bundles at the SAME revision. Hand-edit only the reviewed section.\n")
        fh.write(f"{GENERATED}\n")
        for ident in sorted(generated):
            fh.write(f"{ident}\n")
        fh.write(f"{REVIEWED}\n")
        for ident, reason in reviewed:
            fh.write(f"{ident} | {reason}\n")


def validate(debug: set[str], release: set[str], generated: list[str], reviewed: list[tuple[str, str]]) -> int:
    rc = 0
    live = debug - release
    gen = set(generated)
    if len(gen) != len(generated):
        print("ERROR: duplicate rows in ## generated", file=sys.stderr); rc = 1
    missing = sorted(live - gen)
    stale = sorted(gen - live)
    for ident in missing:
        print(f"ERROR: Debug-only test not in the inventory (new or renamed): {ident}", file=sys.stderr); rc = 1
    for ident in stale:
        print(f"ERROR: inventory row is no longer Debug-only (removed, renamed, or now in Release): {ident}", file=sys.stderr); rc = 1
    for ident, _ in reviewed:
        if ident not in debug:
            print(f"ERROR: reviewed selector does not resolve in Debug: {ident}", file=sys.stderr); rc = 1
    release_only = sorted(release - debug)
    for ident in release_only:
        print(f"NOTE: Release-only test (exists in Release, not Debug): {ident}")
    print(f"==> inventory: generated {len(gen)} (live Debug−Release {len(live)}), reviewed {len(reviewed)}, "
          f"release-only {len(release_only)}, debug {len(debug)}, release {len(release)}")
    return rc


def selectors(generated: list[str], reviewed: list[tuple[str, str]]) -> list[str]:
    # `-only-testing:` takes Bundle/Suite/test (no argument suffix); dedupe. The
    # encoded argument suffix is dropped, so `unquote` is only needed by readers
    # that want the human form of an argument.
    seen, out = set(), []
    for ident in list(generated) + [i for i, _ in reviewed]:
        base = ident.split("#", 1)[0]
        if base not in seen:
            seen.add(base); out.append(f"-only-testing:{base}")
    return out


def self_test() -> int:
    fails = 0

    def payload(bundle: str, cases: dict[str, list[str] | None]) -> dict:
        children = []
        for ident, args in cases.items():
            node = {"nodeType": "Test Case", "nodeIdentifier": ident, "name": ident.split("/")[-1]}
            if args:
                node["children"] = [{"nodeType": "Arguments", "name": a} for a in args]
            children.append(node)
        return {"testNodes": [{"nodeType": "Unit test bundle", "name": bundle,
                               "children": [{"nodeType": "Test Suite", "name": "S", "children": children}]}]}

    def expect(label: str, got: int, want: int) -> None:
        nonlocal fails
        if got == want:
            print(f"ok   [{label}] rc={got}")
        else:
            print(f"FAIL [{label}] wanted rc={want}, got {got}"); fails += 1

    dbg = identifiers(payload("T", {"S/a()": None, "S/b()": None, "S/p()": ["x", "y"], "S/shared()": None}))
    rel = identifiers(payload("T", {"S/a()": None, "S/p()": ["x", "y"], "S/shared()": None, "S/relonly()": None}))
    expect("identifiers keep bundle and argument identity",
           0 if {"T/S/b()", "T/S/p()#x"} <= dbg and "T/S/p()" not in dbg else 1, 0)
    u1 = identifiers(payload("T", {"S/c()": ["colour: Catalog color: #$customDynamic 45AAE5DD-5F21-4292-A3D9-02276E013C8C"]}))
    u2 = identifiers(payload("T", {"S/c()": ["colour: Catalog color: #$customDynamic 5EF61EC9-7935-43FE-81F5-9453FF0236DE"]}))
    expect("a per-process dynamic-colour UUID does not change identity", 0 if u1 == u2 else 1, 0)
    u3 = identifiers(payload("T", {"S/c()": ["colour: red"]}))
    expect("a real argument difference stays a difference", 1 if u1 == u3 else 0, 0)
    r1 = identifiers(payload("T", {"S/c()": ["id: 00000000-0000-0000-0000-000000000001"]}))
    r2 = identifiers(payload("T", {"S/c()": ["id: 00000000-0000-0000-0000-000000000002"]}))
    expect("a bare UUID argument keeps its identity (two real ids stay two)", 1 if r1 == r2 else 0, 0)
    odd = identifiers(payload("T", {"S/c()": ["a|b", "x\ny", " lead"]}))
    expect("pipe, newline and whitespace inside an argument are encoded", 0 if all("|" not in i and "\n" not in i for i in odd) and len(odd) == 3 else 1, 0)
    for bad in ({"testNodes": [{"nodeType": "Test Case"}]},
                {"testNodes": [{"nodeType": "Unit test bundle", "name": "", "children": [{"nodeType": "Test Case", "nodeIdentifier": "S/a()"}]}]}):
        try:
            identifiers(bad); expect("a malformed node fails closed", 0, 1)
        except SystemExit:
            expect("a malformed node fails closed", 1, 1)
    with tempfile.TemporaryDirectory() as tmp:
        inv = os.path.join(tmp, "inv.txt")
        write_inventory(inv, dbg - rel, [("T/S/shared()", "Debug body asserts the DEBUG-only pulse")])
        g, r = parse_inventory(inv)
        expect("(control) generated == Debug−Release and reviewed resolves -> pass", validate(dbg, rel, g, r), 0)
        # a newly added Debug-only case not in the list
        dbg2 = dbg | {"T/S/new()"}
        expect("a new Debug-only case missing from the inventory fails", validate(dbg2, rel, g, r), 1)
        # a removed case still listed
        expect("a removed case still listed fails", validate(dbg - {"T/S/b()"}, rel, g, r), 1)
        # a same-identifier reviewed addition must NOT fail merely because it is absent from Debug−Release
        g2, r2 = g, r + [("T/S/a()", "Debug-only assertion inside a shared test body")]
        expect("a same-identifier reviewed selector does not fail the generated comparison", validate(dbg, rel, g2, r2), 0)
        # a reviewed selector that resolves to nothing
        expect("a reviewed selector that resolves to nothing fails", validate(dbg, rel, g, r + [("T/S/ghost()", "gone")]), 1)
        # regenerate preserves the reviewed section
        write_inventory(inv, dbg2 - rel, r)
        g3, r3 = parse_inventory(inv)
        expect("regenerate preserves the reviewed section", 0 if r3 == r and "T/S/new()" in g3 else 1, 0)
        # round-trip: an encoded odd argument written and parsed back is unchanged
        write_inventory(inv, odd, [])
        expect("encoded arguments round-trip through the file", 0 if set(parse_inventory(inv)[0]) == odd else 1, 0)
        # generate with a dead reviewed selector must NOT rewrite the file
        with open(inv, "w", encoding="utf-8") as fh:
            fh.write(f"{GENERATED}\nT/S/b()\n{REVIEWED}\nT/S/ghost() | gone\n")
        before = open(inv, encoding="utf-8").read()
        dj, rj = os.path.join(tmp, "d.json"), os.path.join(tmp, "r.json")
        json.dump(payload("T", {"S/a()": None, "S/b()": None}), open(dj, "w"))
        json.dump(payload("T", {"S/a()": None}), open(rj, "w"))
        rc = main(["x", "generate", "--debug", dj, "--release", rj, "--out", inv])
        after = open(inv, encoding="utf-8").read()
        expect("generate with a dead reviewed selector fails and leaves the file byte-identical", 0 if rc == 1 and after == before else 1, 0)
        # malformed rows
        with open(inv, "w", encoding="utf-8") as fh:
            fh.write(f"{GENERATED}\nT/S/b() | not allowed here\n{REVIEWED}\n")
        try:
            parse_inventory(inv); expect("a reason on a generated row fails", 0, 1)
        except SystemExit:
            expect("a reason on a generated row fails", 1, 1)
        with open(inv, "w", encoding="utf-8") as fh:
            fh.write(f"{GENERATED}\n{REVIEWED}\nT/S/shared()\n")
        try:
            parse_inventory(inv); expect("a reviewed row without a reason fails", 0, 1)
        except SystemExit:
            expect("a reviewed row without a reason fails", 1, 1)
        sel = selectors(["T/S/p()#x", "T/S/p()#y", "T/S/b()"], [("T/S/shared()", "r")])
        expect("selectors dedupe parameterized cases and take the union",
               0 if sel == ["-only-testing:T/S/p()", "-only-testing:T/S/b()", "-only-testing:T/S/shared()"] else 1, 0)
    try:
        identifiers({"testNodes": []}); expect("zero cases fails closed", 0, 1)
    except SystemExit:
        expect("zero cases fails closed", 1, 1)
    print("== debug-only-inventory self-test PASS ==" if not fails else f"== debug-only-inventory self-test FAIL ({fails}) ==")
    return 1 if fails else 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--self-test"]:
        return self_test()
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate"); g.add_argument("--debug", required=True); g.add_argument("--release", required=True); g.add_argument("--out", required=True)
    v = sub.add_parser("validate"); v.add_argument("--debug", required=True); v.add_argument("--release", required=True); v.add_argument("--inventory", required=True)
    s = sub.add_parser("selectors"); s.add_argument("--inventory", required=True)
    a = ap.parse_args(argv[1:])
    if a.cmd == "selectors":
        gen, rev = parse_inventory(a.inventory)
        print("\n".join(selectors(gen, rev)))
        return 0
    debug = identifiers(load_results(a.debug))
    release = identifiers(load_results(a.release))
    if a.cmd == "generate":
        # Validate BEFORE writing, then replace atomically: a reviewed selector
        # that no longer resolves must not leave a half-regenerated file behind,
        # and a write failure must not truncate the authoritative list.
        reviewed = parse_inventory(a.out)[1] if os.path.isfile(a.out) else []
        generated = debug - release
        rc = validate(debug, release, sorted(generated), reviewed)
        if rc:
            return rc
        directory = os.path.dirname(os.path.abspath(a.out))
        fd, temporary = tempfile.mkstemp(prefix=".debug-inventory-", dir=directory)
        os.close(fd)
        try:
            write_inventory(temporary, generated, reviewed)
            os.replace(temporary, a.out)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        print(f"==> wrote {a.out}: generated {len(generated)}, reviewed {len(reviewed)} preserved")
        return 0
    gen, rev = parse_inventory(a.inventory)
    return validate(debug, release, gen, rev)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
