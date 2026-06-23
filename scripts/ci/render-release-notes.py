#!/usr/bin/env python3
"""Render marketing-friendly GitHub release notes from the in-app What's New copy.

Single source of truth: Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift
(the same copy users see in Settings > What's New). This script extracts the entries
for one version and emits grouped, plain-English markdown for the GitHub release body.

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

# Mirror of WhatsNewContent.Category raw values, in display order.
CATEGORY_RAW = {
    "newFeatures": "New Features",
    "smarterAIPolish": "Smarter AI Polish",
    "betterOllamaSupport": "Better Ollama Support",
    "fasterAndMoreReliable": "Faster and More Reliable",
    "qualityOfLife": "Quality of Life",
    "privacyAndSecurity": "Privacy and Security",
}
CATEGORY_ORDER = list(CATEGORY_RAW.values())

ENTRY_RE = re.compile(r"Entry\(\s*(.*?)\)\s*,?\s*(?=Entry\(|\]\s*\n)", re.DOTALL)


def parse_entries(swift_path):
    with open(swift_path, encoding="utf-8") as fh:
        text = fh.read()
    entries = []
    for m in ENTRY_RE.finditer(text):
        body = m.group(1)
        t = re.search(r'title:\s*\n?\s*"((?:[^"\\]|\\.)*)"', body, re.DOTALL)
        d = re.search(r'description:\s*\n?\s*"((?:[^"\\]|\\.)*)"', body, re.DOTALL)
        c = re.search(r"category:\s*\.(\w+)", body)
        v = re.search(r'version:\s*"([\d.]+)"', body)
        if not (t and d and c and v):
            continue
        title = t.group(1).replace('\\"', '"')
        title = re.sub(r"\s*\\\s*\n\s*", " ", title)
        title = re.sub(r"\s+", " ", title).strip()
        desc = d.group(1).replace('\\"', '"')
        desc = re.sub(r"\s*\\\s*\n\s*", " ", desc)
        desc = re.sub(r"\s+", " ", desc).strip()
        entries.append(
            {
                "title": title,
                "desc": desc,
                "category": CATEGORY_RAW.get(c.group(1), c.group(1)),
                "version": v.group(1),
            }
        )
    return entries


def version_key(v):
    return tuple(int(x) for x in v.split("."))


def render(entries, version):
    es = [e for e in entries if e["version"] == version]
    if not es:
        return None
    # Known categories first in canonical display order, then any category present
    # in the entries but not in CATEGORY_ORDER (e.g. a new WhatsNewContent.Category
    # case added in Swift) appended in first-appearance order, so an entry is never
    # silently dropped from release notes.
    ordered = list(CATEGORY_ORDER)
    for e in es:
        if e["category"] not in ordered:
            ordered.append(e["category"])
    out = []
    for cat in ordered:
        ces = [e for e in es if e["category"] == cat]
        if not ces:
            continue
        out.append(f"### {cat}\n")
        for e in ces:
            title = e["title"].rstrip()
            if title and title[-1] not in ".!?":
                title += "."
            out.append(f"- **{title}** {e['desc']}")
        out.append("")
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
        print(f"self-test OK: {cv} renders {body.count('- **')} item(s)")
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
