#!/usr/bin/env python3
"""Generate the closing film's app logos from the website's app list (#4528).

The one owner of the 18 app logos is website/src/data/home/compatibleApps.json (the website's
"works in" strip, which the approved Setup mockup used as-is). This writes
Sources/EnviousWisprAppKit/Views/Onboarding/Film/FilmAppLogos.generated.swift from it.
FilmAppLogosSyncTests fails when the two disagree.

  python3 scripts/design/generate-app-logos.py           # rewrite the Swift file
  python3 scripts/design/generate-app-logos.py --check   # exit 1 if it is out of date
"""
import argparse
import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
SOURCE = REPO / "website/src/data/home/compatibleApps.json"
OUTPUT = REPO / "Sources/EnviousWisprAppKit/Views/Onboarding/Film/FilmAppLogos.generated.swift"
# The mockup draws these near-black marks in the text colour so they read in dark mode.
INK = {"Notion", "Craft", "TextEdit"}


def swift_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render() -> str:
    apps = json.loads(SOURCE.read_text(encoding="utf-8"))
    lines = [
        "// GENERATED from website/src/data/home/compatibleApps.json by",
        "// scripts/design/generate-app-logos.py. Do not edit.",
        "",
        "extension FilmAppLogo {",
        "  static let all: [FilmAppLogo] = [",
    ]
    for app in apps:
        lines.append(
            "    FilmAppLogo(name: %s, hex: %s, ink: %s, path: %s),"
            % (
                swift_string(app["name"]),
                swift_string(app["color"]),
                "true" if app["name"] in INK else "false",
                swift_string(app["icon"]),
            )
        )
    lines += ["  ]", "}", ""]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="exit 1 if the Swift file is out of date")
    args = parser.parse_args()
    text = render()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != text:
            print(f"{OUTPUT.relative_to(REPO)} is out of date; run {pathlib.Path(__file__).name}")
            return 1
        return 0
    OUTPUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
