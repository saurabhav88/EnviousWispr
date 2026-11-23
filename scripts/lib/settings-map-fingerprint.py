#!/usr/bin/env python3
"""Is reference/settings-map.json's catalog fingerprint current? (#4618)

  settings-map-fingerprint.py check [--root DIR]
  settings-map-fingerprint.py --self-test

The committed Settings Map records the SHA-256 of the interface String Catalog
(`fingerprints.uiCatalogSHA256`). SettingsMapExportSyncTests (`sourceIdentity`)
owns that contract and fails a full run whenever the catalog changed without a
fresh export. This is the same comparison, run before the long lane by
scripts/xcode-test.sh, so a catalog edit costs a re-export instead of a wasted
15-minute run. Exit 0 current, 1 stale (prints the fix), 2 could not tell.
"""

import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile

CATALOG = "Sources/EnviousWispr/Resources/Localizable.xcstrings"
MAP = "reference/settings-map.json"


def check(root):
    catalog, document = root / CATALOG, root / MAP
    try:
        recorded = json.loads(document.read_text())["fingerprints"]["uiCatalogSHA256"]
        actual = hashlib.sha256(catalog.read_bytes()).hexdigest()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"==> settings-map fingerprint: COULD NOT CHECK ({error})", file=sys.stderr)
        return 2
    if recorded == actual:
        print("==> settings-map fingerprint: current")
        return 0
    print(f"ERROR: {MAP} records catalog SHA-256 {recorded[:12]}..., but {CATALOG} is "
          f"{actual[:12]}...; SettingsMapExportSyncTests would fail the full run.", file=sys.stderr)
    print("       Fix: scripts/settings-map/export.sh   (re-exports the map; commit both reference/settings-map.* files)",
          file=sys.stderr)
    return 1


def self_test():
    with tempfile.TemporaryDirectory(prefix="ew-map-fingerprint-") as name:
        root = Path(name)
        (root / CATALOG).parent.mkdir(parents=True)
        (root / MAP).parent.mkdir(parents=True)
        (root / CATALOG).write_text('{"strings":{}}\n')
        digest = hashlib.sha256((root / CATALOG).read_bytes()).hexdigest()
        cases = []
        (root / MAP).write_text(json.dumps({"fingerprints": {"uiCatalogSHA256": digest}}))
        cases.append(("current", check(root), 0))
        (root / CATALOG).write_text('{"strings":{"new":{}}}\n')
        cases.append(("catalog changed", check(root), 1))
        (root / MAP).write_text(json.dumps({"fingerprints": {}}))
        cases.append(("no fingerprint", check(root), 2))
        (root / MAP).unlink()
        cases.append(("no map", check(root), 2))
    failed = [f"{label}: exit {got}, expected {want}" for label, got, want in cases if got != want]
    for line in failed:
        print("SELF-TEST FAIL: " + line, file=sys.stderr)
    print(f"==> settings-map-fingerprint self-test: {len(cases) - len(failed)}/{len(cases)} passed")
    return 1 if failed else 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("check")
    run.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent.parent)
    opts = parser.parse_args()
    return check(opts.root)


if __name__ == "__main__":
    sys.exit(main())
