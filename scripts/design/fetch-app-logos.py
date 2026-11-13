#!/usr/bin/env python3
"""Fetch the closing film's real app logos from SVGL and bundle them as PDFs (#4528).

The founder asked for real brand logos only (2026-11-13). SVGL (https://svgl.app, MIT,
https://github.com/pheralb/svgl) publishes each brand's own SVG logo. This script downloads the
18 apps below at one pinned SVGL commit, checks each file against its pinned SHA-256, renders
it to a 128-pixel PNG with rsvg-convert, and writes:

  Sources/EnviousWisprAppKit/Resources/app-logo-<slug>.png (and -dark.png where SVGL has one)

PNG, not PDF: rsvg-convert's PDF output loses SVG masks, filters and some gradients once AppKit
draws it (VS Code drew nothing, Obsidian lost its shading), and macOS 14 has no public SVG
image loader. 128 pixels is more than four times the film's largest logo (24 points).
  Sources/EnviousWisprAppKit/Resources/svgl-LICENSE.txt
  Sources/EnviousWisprAppKit/Views/Onboarding/Film/FilmAppLogos.generated.swift

The marks belong to their owners; SVGL's MIT license covers its collection.

  python3 scripts/design/fetch-app-logos.py            # fetch, verify, convert, write
  python3 scripts/design/fetch-app-logos.py --pin      # print the SHA-256 of each fetched file
Needs network and `rsvg-convert` (Homebrew librsvg).
"""
import argparse
import hashlib
import pathlib
import subprocess
import sys
import tempfile
import urllib.request

REPO = pathlib.Path(__file__).resolve().parents[2]
COMMIT = "90f6de7026c5e75a9014dbf1f422792bd40b1802"
RAW = f"https://raw.githubusercontent.com/pheralb/svgl/{COMMIT}"
RESOURCES = REPO / "Sources/EnviousWisprAppKit/Resources"
SWIFT = REPO / "Sources/EnviousWisprAppKit/Views/Onboarding/Film/FilmAppLogos.generated.swift"

# (name, slug, SVGL light file, SVGL dark file or None). Order is the film's wall order.
APPS = [
    ("Slack", "slack", "slack.svg", None),
    ("Gmail", "gmail", "gmail.svg", None),
    ("Visual Studio Code", "vscode", "vscode.svg", None),
    ("Notion", "notion", "notion.svg", None),
    ("Discord", "discord", "discord.svg", None),
    ("Linear", "linear", "linear.svg", None),
    ("Figma", "figma", "figma.svg", None),
    ("Obsidian", "obsidian", "obsidian.svg", None),
    ("Arc", "arc", "arc_browser.svg", None),
    ("Safari", "safari", "safari.svg", None),
    ("Chrome", "chrome", "chrome.svg", None),
    ("WhatsApp", "whatsapp", "whatsapp-icon.svg", None),
    ("Telegram", "telegram", "telegram.svg", None),
    ("Microsoft Word", "word", "microsoft-word.svg", None),
    ("Microsoft Outlook", "outlook", "microsoft-outlook.svg", None),
    ("Microsoft Teams", "teams", "microsoft-teams.svg", None),
    ("ChatGPT", "chatgpt", "openai.svg", "openai_dark.svg"),
    ("Cursor", "cursor", "cursor_light.svg", "cursor_dark.svg"),
]

# SHA-256 of each SVGL file at COMMIT (run --pin to print them after changing APPS or COMMIT).
PINS = {
    "slack.svg": "29734796b3a85f9d0e03150d53142fab0b7f994ae80c7e3e1efd0bef52c12f5d",
    "gmail.svg": "6e0a1db3ce3893a809c3293bf0780902cad270ed443bb118cfcbc40647e272ab",
    "vscode.svg": "0c3dbeed85a5881f0e778a941f6033b8b42022587187f1e23e6f1c31a91ed3a0",
    "notion.svg": "0d94471649fb9badd434394846079c279876fdd224cf49ed46b6c09fbd3a041f",
    "discord.svg": "6634cc2f915db66df7a5237cac0c1b98016289e86a2bb4b7bf6408ec2b95265c",
    "linear.svg": "e669549bf9917d616f3ae10ace5ba9af6e84966ec12cadd13459489cded34ccf",
    "figma.svg": "5bcdea3417293412845b8298fe357fce3b192e8ff112d9b3fef315bc5cd127f6",
    "obsidian.svg": "410068dcd81b6bf0bd003668eeef348ca6e09418b70b41a82da96c81a37bbf5e",
    "arc_browser.svg": "604ef79ed79c2f17a23e34f1c640c166b3c8ab39a8ba29c59e1261c244c9e9e1",
    "safari.svg": "07e28cf4b39de197861debb8a6ae44904cd4aaa485bb3a7cec66c01bde1a9243",
    "chrome.svg": "fa70a8395db5875747df112606379788854a86ac0d39d06914d5fd0c7ba7dc76",
    "whatsapp-icon.svg": "a4b676938ab2392d5755b2f9c99bf465587b72c984558e5e798d203645f9a0e7",
    "telegram.svg": "05f6898c0c087f84c8bcf65e93721bde65abe34093045d4e9ecddbb8dc9f6a18",
    "microsoft-word.svg": "4bfaa245bbc7840d81d2506eb248a01e26aa64dce0e48333fa88177c02aca0f5",
    "microsoft-outlook.svg": "334bf1a0ef366570a80d62faa0dc9c34de094cbc18c4935f2ceb26a140875d5b",
    "microsoft-teams.svg": "4062cb6a318a51966278983171dae4a207d42ea9454c1fc5df75ff3bfb6cb4db",
    "openai.svg": "71eba8e11d265af0e3375ad610db95b4a5fedf9f07c40e5252e73942b8c5982e",
    "openai_dark.svg": "4dac62f014aac76e15be7d681776cda434ce540beaa22410e9f7a87806a91f5a",
    "cursor_light.svg": "c483c02f78eb2619778fdd959e72a9adfac4844854472cd2653d4cbfd60e4d71",
    "cursor_dark.svg": "cd0e3e5d8991a4cdd4577f8896cd063105207665165c73e25a1ff918dd367eb7",
}


def fetch(path: str) -> bytes:
    with urllib.request.urlopen(f"{RAW}/{path}", timeout=30) as response:
        return response.read()


def files():
    for _, slug, light, dark in APPS:
        yield slug, light
        if dark:
            yield f"{slug}-dark", dark


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--pin", action="store_true", help="print each file's SHA-256 and stop")
    args = parser.parse_args()

    fetched = {name: fetch(f"static/library/{name}") for _, name in files()}
    if args.pin:
        for name, data in fetched.items():
            print(f'    "{name}": "{hashlib.sha256(data).hexdigest()}",')
        return 0
    for name, data in fetched.items():
        digest = hashlib.sha256(data).hexdigest()
        if PINS.get(name) != digest:
            print(f"refused: {name} is {digest}, pinned {PINS.get(name)}", file=sys.stderr)
            return 1

    with tempfile.TemporaryDirectory() as tmp:
        for resource, name in files():
            svg = pathlib.Path(tmp) / name
            svg.write_bytes(fetched[name])
            png = RESOURCES / f"app-logo-{resource}.png"
            subprocess.run(
                ["rsvg-convert", "-w", "128", "-h", "128", "--keep-aspect-ratio", "-o", str(png), str(svg)],
                check=True,
            )
    (RESOURCES / "svgl-LICENSE.txt").write_bytes(fetch("LICENSE"))

    lines = [
        "// GENERATED by scripts/design/fetch-app-logos.py from SVGL",
        f"// (https://github.com/pheralb/svgl at {COMMIT[:8]}). Do not edit.",
        "",
        "extension FilmAppLogo {",
        "  static let all: [FilmAppLogo] = [",
    ]
    for name, slug, _, dark in APPS:
        lines.append(
            f'    FilmAppLogo(name: "{name}", resource: "app-logo-{slug}", '
            f"hasDark: {'true' if dark else 'false'}),"
        )
    lines += ["  ]", "}", ""]
    SWIFT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {len(list(files()))} PNGs, the license and {SWIFT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
