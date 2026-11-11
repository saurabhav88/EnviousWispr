#!/usr/bin/env python3
"""Compare two design render runs pixel by pixel (#4506).

Usage:
  python3 scripts/design/pixel-diff.py <before-dir> <after-dir> --manifest <render-manifest.json> [--diff-dir <dir>]

The comparison itself lives in pixel-diff.swift beside this file, because Python's standard
library cannot decode PNG and the macOS SDK can (ImageIO). This launcher replaces itself with
`xcrun swift pixel-diff.swift <same arguments>`, so arguments, output and the exit status
(0 identical, 1 differing, 2 input or usage problem) are the Swift program's own.
"""

import os
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().with_name("pixel-diff.swift")

if not SCRIPT.is_file():
    sys.stderr.write(f"pixel-diff: {SCRIPT} is missing\n")
    sys.exit(2)

os.execv("/usr/bin/xcrun", ["xcrun", "swift", str(SCRIPT), *sys.argv[1:]])
