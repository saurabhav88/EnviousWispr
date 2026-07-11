#!/usr/bin/env python3
"""Render marketing-friendly GitHub release notes from the in-app What's New copy.

Single source of truth: Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift
(the same copy users see in Settings > What's New). This script extracts the entries
for one version and emits a flat, plain-English markdown list for the GitHub release body.

Entries render in SOURCE ORDER: whatever order the author placed them in the Swift
`entries` array is the order the reader gets, here and in the app. There is no category
grouping (removed 2026-07-11 — the six generic headings repeated down every release and
carried no information). Source order IS the hierarchy, so a version must be authored
headline-feature-first.

Parse contract: `title`, `description`, and `version` must be direct, ordinary
double-quoted Swift literals. This script reads Swift source TEXT, it does not compile it.
A raw string or a named constant makes the entry fail to parse (--self-test catches that,
because it asserts the parsed count matches the number of `version:` fields). Concatenation
silently captures only the first segment, and interpolation emits unresolved Swift source:
NEITHER is caught by the count check, so both would ship wrong text. Validate by comparing
parsed values against expected strings, not by counting items alone.

Used by .github/workflows/release.yml. Designed to fail SAFELY: if it cannot produce
notes for the requested version, it exits non-zero and the workflow falls back to
GitHub's auto-generated notes, so a release is never blocked or shipped blank.

Usage:
  render-release-notes.py --version 2.1.4 [--swift-file PATH] [--out FILE]
  render-release-notes.py --list
  render-release-notes.py --self-test   # parse + assert currentContentVersion renders
"""
import argparse
import collections
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_SWIFT = os.path.join(
    REPO_ROOT, "Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift"
)
CONSTANTS_SWIFT = os.path.join(
    REPO_ROOT, "Sources/EnviousWisprCore/WhatsNewConstants.swift"
)

def parse_entries(swift_path):
    with open(swift_path, encoding="utf-8") as fh:
        text = fh.read()
    # Split on `Entry(` boundaries: each chunk after the first holds exactly one
    # entry's fields at its start. This is robust to the `// MARK:` comments
    # between version sections (a previous lookahead-based regex over-extended
    # across those comments and silently swallowed the first entry of each older
    # version section).
    entries = []
    for chunk in text.split("Entry(")[1:]:
        t = re.search(r'title:\s*\n?\s*"((?:[^"\\]|\\.)*)"', chunk, re.DOTALL)
        d = re.search(r'description:\s*\n?\s*"((?:[^"\\]|\\.)*)"', chunk, re.DOTALL)
        v = re.search(r'version:\s*"([\d.]+)"', chunk)
        if not (t and d and v):
            continue
        title = t.group(1).replace('\\"', '"')
        title = re.sub(r"\s*\\\s*\n\s*", " ", title)
        title = re.sub(r"\s+", " ", title).strip()
        desc = d.group(1).replace('\\"', '"')
        desc = re.sub(r"\s*\\\s*\n\s*", " ", desc)
        desc = re.sub(r"\s+", " ", desc).strip()
        entries.append({"title": title, "desc": desc, "version": v.group(1)})
    return entries


def version_key(v):
    return tuple(int(x) for x in v.split("."))


def render(entries, version):
    # Flat list in SOURCE ORDER — `parse_entries` walks the Swift file top-to-bottom,
    # and `filter` preserves that order, so the author's sequence is the reader's.
    # No sorting or grouping happens here by design.
    es = [e for e in entries if e["version"] == version]
    if not es:
        return None
    out = []
    for e in es:
        title = e["title"].rstrip()
        if title and title[-1] not in ".!?":
            title += "."
        out.append(f"- **{title}** {e['desc']}")
    rendered = "\n".join(out).strip()
    return rendered or None


def current_content_version():
    try:
        with open(CONSTANTS_SWIFT, encoding="utf-8") as fh:
            m = re.search(r'currentContentVersion\s*=\s*"([\d.]+)"', fh.read())
            return m.group(1) if m else None
    except OSError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version")
    ap.add_argument("--swift-file", default=DEFAULT_SWIFT)
    ap.add_argument("--out")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    entries = parse_entries(args.swift_file)
    if not entries:
        print("error: parsed 0 entries from What's New source", file=sys.stderr)
        return 2

    if args.list:
        versions = sorted({e["version"] for e in entries}, key=version_key, reverse=True)
        print("\n".join(versions))
        return 0

    if args.self_test:
        # Integrity check: every entry has exactly one `version:` field, so the
        # number of parsed entries must equal the number of version fields in the
        # source. A mismatch means the parser dropped entries (e.g. the MARK-comment
        # swallowing bug), even if individual versions still render.
        with open(args.swift_file, encoding="utf-8") as fh:
            field_count = len(re.findall(r'version:\s*"[\d.]+"', fh.read()))
        if len(entries) != field_count:
            print(
                f"error: parsed {len(entries)} entries but the source has {field_count} "
                "version fields; the parser dropped entries (drift)",
                file=sys.stderr,
            )
            return 2
        cv = current_content_version()
        if not cv:
            print("error: could not read currentContentVersion", file=sys.stderr)
            return 2
        body = render(entries, cv)
        if not body:
            print(
                f"error: no What's New entries render for currentContentVersion {cv}; "
                "the parser or the content may have drifted",
                file=sys.stderr,
            )
            return 2
        print(
            f"self-test OK: {len(entries)} entries parsed (matches source); "
            f"{cv} renders {body.count('- **')} item(s)"
        )
        return 0

    if not args.version:
        print("error: --version is required", file=sys.stderr)
        return 2

    body = render(entries, args.version)
    if not body:
        print(
            f"error: no What's New entries for version {args.version}", file=sys.stderr
        )
        return 2

    text = f"## What's new in v{args.version}\n\n{body}\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"wrote {args.out} ({body.count('- **')} item(s))", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
