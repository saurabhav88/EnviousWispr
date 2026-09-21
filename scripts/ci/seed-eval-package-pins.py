#!/usr/bin/env python3
"""Seed a standalone eval package's Package.resolved from the app's tracked pins.

scripts/ci/compile-eval-packages.sh runs this once per eval package before
`swift build --only-use-versions-from-resolved-file`. The root Package.resolved
is the one source of pin truth for every dependency the app shares with a
runner. A runner may also depend on packages the app does not (#996 chunk
2b-ii: alias_runner pins huggingface/swift-transformers, runner only); those
pins cannot come from the root file, so they live in the package's TRACKED
`Package.runner-only-pins.json`, a SwiftPM v3 `{"pins": [...]}` document
holding exactly the identities absent from the root graph.

Merge rule, fail closed:
  * every root pin is copied as is;
  * every runner-only pin is appended;
  * a runner-only identity that also exists in the root file is refused (that
    pin belongs to the root truth and would silently float the app's version);
  * a pin missing identity/kind/location/state, of an unknown kind, with an empty
    location or a state naming no version/branch/revision is refused, in either
    file, as is a document that is not SwiftPM v3.

Usage: seed-eval-package-pins.py <root Package.resolved> <package dir>
Exit 0 after writing <package dir>/Package.resolved; 2 on refusal.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

RUNNER_ONLY_NAME = "Package.runner-only-pins.json"
PIN_KEYS = ("identity", "kind", "location", "state")
PIN_KINDS = {"localSourceControl", "remoteSourceControl", "registry"}
STATE_KEYS = ("version", "branch", "revision")


class SeedError(Exception):
    """A refusal; the message says what and where."""


def read_document(path: Path, *, missing_ok: bool = False) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        if missing_ok:
            return None
        raise SeedError(f"{path}: file does not exist")
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SeedError(f"{path}: cannot read pins ({exc})") from exc


def validated_pins(document: object, path: Path) -> list[dict]:
    """The `pins` list of a SwiftPM v3 document, every pin complete and well typed."""
    if not isinstance(document, dict) or document.get("version") != 3:
        raise SeedError(f"{path}: expected a SwiftPM v3 object")
    pins = document.get("pins")
    if not isinstance(pins, list):
        raise SeedError(f"{path}: expected a 'pins' list")
    seen: set[str] = set()
    for pin in pins:
        if not isinstance(pin, dict) or any(key not in pin for key in PIN_KEYS):
            raise SeedError(f"{path}: every pin needs {', '.join(PIN_KEYS)}; got {pin!r}")
        identity, kind, location, state = (pin[key] for key in PIN_KEYS)
        if not isinstance(identity, str) or not identity:
            raise SeedError(f"{path}: pin identity must be a non-empty string; got {identity!r}")
        if identity in seen:
            raise SeedError(f"{path}: '{identity}' is listed twice")
        if not isinstance(kind, str) or kind not in PIN_KINDS:
            raise SeedError(f"{path}: '{identity}' has unsupported kind {kind!r}")
        if not isinstance(location, str) or not location:
            raise SeedError(f"{path}: '{identity}' has an invalid location")
        if not isinstance(state, dict):
            raise SeedError(f"{path}: '{identity}' has an invalid state")
        for key in STATE_KEYS:
            value = state.get(key)
            if value is not None and (not isinstance(value, str) or not value):
                raise SeedError(f"{path}: '{identity}' has invalid state field {key}={value!r}")
        if not any(isinstance(state.get(key), str) and state[key] for key in STATE_KEYS):
            raise SeedError(
                f"{path}: '{identity}' has an invalid state (needs one of {', '.join(STATE_KEYS)})"
            )
        seen.add(identity)
    return pins


def load_runner_only_pins(path: Path, root_identities: set[str]) -> list[dict]:
    document = read_document(path, missing_ok=True)
    if document is None:
        return []
    pins = validated_pins(document, path)
    overlap = root_identities.intersection(pin["identity"] for pin in pins)
    if overlap:
        identity = sorted(overlap)[0]
        raise SeedError(
            f"{path}: '{identity}' is already pinned by the root Package.resolved; "
            "a shared dependency takes the app's pin, remove it from the runner-only file"
        )
    return pins


def merged_resolved(root: dict, runner_only: list[dict]) -> dict:
    out = dict(root)
    out["pins"] = list(root["pins"]) + list(runner_only)
    return out


def seed(root_resolved: Path, package_dir: Path) -> Path:
    root = read_document(root_resolved)
    assert root is not None
    root_pins = validated_pins(root, root_resolved)
    root_identities = {pin["identity"] for pin in root_pins}
    runner_only = load_runner_only_pins(package_dir / RUNNER_ONLY_NAME, root_identities)
    target = package_dir / "Package.resolved"
    try:
        target.write_text(
            json.dumps(merged_resolved(root, runner_only), indent=2) + "\n", encoding="utf-8"
        )
    except OSError as exc:
        raise SeedError(f"{target}: cannot write merged pins ({exc})") from exc
    return target


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    try:
        target = seed(Path(argv[1]), Path(argv[2]))
    except SeedError as exc:
        print(f"seed-eval-package-pins: {exc}", file=sys.stderr)
        return 2
    print(f"seeded {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
