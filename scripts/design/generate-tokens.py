#!/usr/bin/env python3
"""Generate the app's design tokens from DESIGN.md (#4506).

DESIGN.md's fenced ```json design-tokens block is the only hand-edited source of
token values. This script writes
Sources/EnviousWisprAppKit/Views/Design/DesignTokens.generated.swift from it and
formats the result with the repository's swift-format configuration, so the
editor's format-on-save hook finds nothing to change.

Usage:
  python3 scripts/design/generate-tokens.py           # write the generated file
  python3 scripts/design/generate-tokens.py --check   # exit 1 if it is out of date

Fails (exit 2) on: no or several values blocks, invalid JSON, a duplicate key, an
unknown family or field, a color without both a light and a dark value, a value
out of range, an unknown font weight or design, or a bad identifier. Never
substitutes a default for a missing value.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BOOK = REPO / "DESIGN.md"
OUTPUT = REPO / "Sources/EnviousWisprAppKit/Views/Design/DesignTokens.generated.swift"
FORMAT_CONFIG = REPO / ".swift-format"

HEADER = (
    "// GENERATED from DESIGN.md by scripts/design/generate-tokens.py. Do not edit.\n"
    "// Edit the values block in DESIGN.md, then run: python3 scripts/design/generate-tokens.py\n"
)

FENCE = re.compile(r"^```json design-tokens\n(.*?)^```$", re.MULTILINE | re.DOTALL)
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
WEIGHTS = {"ultraLight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"}
DESIGNS = {"default", "rounded", "serif", "monospaced"}
FAMILIES = {"reasons", "colors", "fonts", "layout", "motion"}
COLOR_FIELDS = {"light", "dark", "group", "usage", "note"}
FONT_FIELDS = {"size", "weight", "design", "usage", "note"}
LAYOUT_FIELDS = {"value", "usage", "note"}
MOTION_FIELDS = {"curve", "points", "duration", "usage", "note"}
CURVES = {"easeIn", "easeOut", "easeInOut", "linear", "timingCurve"}
REASON_SECTIONS = {"colors", "fonts"}


class BookError(Exception):
    pass


def reject_duplicates(pairs):
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise BookError(f"duplicate key {key!r}")
        seen[key] = value
    return seen


def load_block(text: str) -> dict:
    blocks = FENCE.findall(text)
    if len(blocks) != 1:
        raise BookError(f"expected exactly one ```json design-tokens block, found {len(blocks)}")
    try:
        data = json.loads(blocks[0], object_pairs_hook=reject_duplicates)
    except json.JSONDecodeError as error:
        raise BookError(f"values block is not valid JSON: {error}") from error
    if not isinstance(data, dict):
        raise BookError("values block must be a JSON object")
    unknown = set(data) - FAMILIES
    if unknown:
        raise BookError(f"unknown token families: {sorted(unknown)}")
    missing = FAMILIES - set(data)
    if missing:
        raise BookError(f"missing token families: {sorted(missing)}")
    return data


def split_name(key: str, expected_namespace: str | None) -> tuple[str, str]:
    parts = key.split(".")
    if len(parts) != 2 or not all(IDENT.match(p) for p in parts):
        raise BookError(f"{key!r} must be Namespace.member")
    if expected_namespace and parts[0] != expected_namespace:
        raise BookError(f"{key!r} must start with {expected_namespace}.")
    return parts[0], parts[1]


def number(value, where: str) -> str:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise BookError(f"{where}: {value!r} is not a number")
    return repr(value)


def check_fields(entry, allowed: set[str], required: set[str], key: str) -> None:
    if not isinstance(entry, dict):
        raise BookError(f"{key}: entry must be an object")
    extra = set(entry) - allowed
    if extra:
        raise BookError(f"{key}: unknown fields {sorted(extra)}")
    absent = required - set(entry)
    if absent:
        raise BookError(f"{key}: missing {sorted(absent)}")
    for field in ("group", "usage", "note"):
        if field in entry and not isinstance(entry[field], str):
            raise BookError(f"{key}: {field} must be text")


def rgba(value, where: str) -> str:
    if not isinstance(value, list) or len(value) != 4:
        raise BookError(f"{where}: must be [r, g, b, a]")
    parts = []
    for component in value:
        text = number(component, where)
        if not 0 <= component <= 1:
            raise BookError(f"{where}: {component} is outside 0...1")
        parts.append(text)
    return "(" + ", ".join(parts) + ")"


def doc_lines(entry: dict, indent: str) -> list[str]:
    lines = []
    if entry.get("usage"):
        lines.append(f"{indent}/// {entry['usage']}")
    if entry.get("note"):
        if lines:
            lines.append(f"{indent}///")
        lines.append(f"{indent}/// {entry['note']}")
    return lines


def reason_lines(data: dict, section: str) -> list[str]:
    reasons = data["reasons"]
    if not isinstance(reasons, dict) or set(reasons) - REASON_SECTIONS:
        raise BookError(f"reasons may only hold {sorted(REASON_SECTIONS)}")
    entries = reasons.get(section, [])
    if not isinstance(entries, list) or not all(isinstance(e, str) and e for e in entries):
        raise BookError(f"reasons.{section} must be a list of text")
    lines = []
    for entry in entries:
        lines += ["//", f"// {entry}"]
    return lines


def render(data: dict) -> str:
    out = [HEADER, "import SwiftUI", ""]

    out += ["// MARK: - Colors (light and dark pairs, resolved per appearance by Color.stDynamic)"]
    out += reason_lines(data, "colors")
    out += ["", "extension Color {"]
    group = None
    colors = data["colors"]
    if not isinstance(colors, dict) or not colors:
        raise BookError("colors must be a non-empty object")
    for key, entry in colors.items():
        _, member = split_name(key, "Color")
        check_fields(entry, COLOR_FIELDS, {"light", "dark"}, key)
        if entry.get("group") != group:
            group = entry.get("group")
            if group:
                out.append(f"  // {group}")
        out += doc_lines(entry, "  ")
        light = rgba(entry["light"], f"{key}.light")
        dark = rgba(entry["dark"], f"{key}.dark")
        out.append(f"  static let {member} = stDynamic(")
        out.append(f"    lightRGB: {light}, darkRGB: {dark})")
    out += ["}", ""]

    out += ["// MARK: - Fonts (SF Pro)"]
    out += reason_lines(data, "fonts")
    out += ["", "extension Font {"]
    fonts = data["fonts"]
    if not isinstance(fonts, dict) or not fonts:
        raise BookError("fonts must be a non-empty object")
    for key, entry in fonts.items():
        _, member = split_name(key, "Font")
        check_fields(entry, FONT_FIELDS, {"size"}, key)
        size = number(entry["size"], f"{key}.size")
        arguments = [f"size: {size}"]
        if "weight" in entry:
            if entry["weight"] not in WEIGHTS:
                raise BookError(f"{key}: unknown weight {entry['weight']!r}")
            arguments.append(f"weight: .{entry['weight']}")
        if "design" in entry:
            if entry["design"] not in DESIGNS:
                raise BookError(f"{key}: unknown design {entry['design']!r}")
            if "weight" not in entry:
                raise BookError(f"{key}: a design needs an explicit weight")
            arguments.append(f"design: .{entry['design']}")
        out += doc_lines(entry, "  ")
        out.append(f"  static let {member} = Font.system({', '.join(arguments)})")
    out += ["}", ""]

    layout = data["layout"]
    if not isinstance(layout, dict) or not layout:
        raise BookError("layout must be a non-empty object")
    namespaces: dict[str, list[tuple[str, dict]]] = {}
    for key, entry in layout.items():
        namespace, member = split_name(key, None)
        if namespace in {"Color", "Font", "DesignMotion"}:
            raise BookError(f"{key}: layout cannot use the {namespace} namespace")
        check_fields(entry, LAYOUT_FIELDS, {"value"}, key)
        number(entry["value"], f"{key}.value")
        namespaces.setdefault(namespace, []).append((member, entry))
    out += ["// MARK: - Layout (points)", ""]
    for namespace, members in namespaces.items():
        out.append(f"enum {namespace} {{")
        for member, entry in members:
            out += doc_lines(entry, "  ")
            out.append(f"  static let {member}: CGFloat = {number(entry['value'], member)}")
        out += ["}", ""]

    motion = data["motion"]
    if not isinstance(motion, dict) or not motion:
        raise BookError("motion must be a non-empty object")
    out += ["// MARK: - Motion", "", "enum DesignMotion {"]
    for key, entry in motion.items():
        _, member = split_name(key, "DesignMotion")
        check_fields(entry, MOTION_FIELDS, {"curve", "duration"}, key)
        if entry["curve"] not in CURVES:
            raise BookError(f"{key}: unknown curve {entry['curve']!r}")
        duration = number(entry["duration"], f"{key}.duration")
        if not 0 < entry["duration"] <= 5:
            raise BookError(f"{key}: duration {entry['duration']} is outside 0...5 seconds")
        out += doc_lines(entry, "  ")
        if entry["curve"] == "timingCurve":
            # A cubic Bezier like CSS cubic-bezier(x1, y1, x2, y2): the points live in DESIGN.md.
            points = entry.get("points")
            if not isinstance(points, list) or len(points) != 4:
                raise BookError(f"{key}: timingCurve needs points [x1, y1, x2, y2]")
            values = [number(p, f"{key}.points") for p in points]
            if not (0 <= points[0] <= 1 and 0 <= points[2] <= 1):
                raise BookError(f"{key}: timingCurve x1 and x2 must be within 0...1")
            out.append(
                f"  static let {member} = Animation.timingCurve("
                f"{', '.join(values)}, duration: {duration})")
        else:
            if "points" in entry:
                raise BookError(f"{key}: points apply only to timingCurve")
            out.append(f"  static let {member} = Animation.{entry['curve']}(duration: {duration})")
    out += ["}", ""]
    return "\n".join(out).rstrip("\n") + "\n"


def swift_format(source: str) -> str:
    tool = shutil.which("swift-format")
    if tool is None:
        raise BookError("swift-format is not on PATH; it is needed so the output matches the format hook")
    result = subprocess.run(
        [tool, "format", "--configuration", str(FORMAT_CONFIG)],
        input=source, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise BookError(f"swift-format failed: {result.stderr.strip()}")
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="exit 1 if the generated file is out of date")
    args = parser.parse_args()
    try:
        generated = swift_format(render(load_block(BOOK.read_text(encoding="utf-8"))))
    except (BookError, OSError) as error:
        print(f"generate-tokens: {error}", file=sys.stderr)
        return 2
    if args.check:
        try:
            current = OUTPUT.read_text(encoding="utf-8")
        except OSError as error:
            print(f"generate-tokens: cannot read {OUTPUT}: {error}", file=sys.stderr)
            return 1
        if current != generated:
            print(f"generate-tokens: {OUTPUT.relative_to(REPO)} is out of date; run python3 scripts/design/generate-tokens.py",
                  file=sys.stderr)
            return 1
        print("generate-tokens: up to date")
        return 0
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(generated, encoding="utf-8")
    print(f"generate-tokens: wrote {OUTPUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
