#!/usr/bin/env python3
"""Recompute `manifestDigest` for a bundled delivery manifest.

WHY THIS EXISTS
`DeliveryManifest.loadBundled` recomputes the digest on every launch and THROWS
on mismatch, so any edit to a manifest — including a one-word `runtimeABI` bump
riding along with a dependency pin — bricks model loading unless the digest is
regenerated with it. #1792 shipped exactly that defect past a green local build
and a working dev app; cloud review caught it.

The algorithm mirrors `DeliveryManifest.canonicalDigest` (DeliveryManifest.swift):
    parse -> drop "manifestDigest" -> JSONSerialization(.sortedKeys,
    .withoutEscapingSlashes) -> SHA256 hex

FAILS CLOSED, and that is the point. Before writing anything it recomputes the
digest the file ALREADY declares. If this implementation cannot reproduce that,
it is not equivalent to the Swift one and it refuses to touch the file — a
reimplementation of a hashing rule is worthless without that control, because a
wrong digest looks exactly like a right one until the app refuses to launch.

    usage: regen-delivery-manifest-digest.py <manifest.json> [--write]
"""
import hashlib
import json
import subprocess
import sys


def canonical_digest(obj: dict) -> str:
    """Mirror of DeliveryManifest.canonicalDigest."""
    body = {k: v for k, v in obj.items() if k != "manifestDigest"}
    # sortedKeys -> sort_keys; compact (JSONSerialization emits no whitespace);
    # withoutEscapingSlashes and UTF-8 passthrough -> ensure_ascii=False.
    canonical = json.dumps(
        body, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def main() -> int:
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--write"):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    path, write = sys.argv[1], len(sys.argv) == 3

    raw = open(path, "rb").read()
    obj = json.loads(raw)
    declared = obj.get("manifestDigest")
    if not isinstance(declared, str):
        print("REFUSED: manifest declares no manifestDigest string", file=sys.stderr)
        return 1

    computed = canonical_digest(obj)
    print(f"declared: {declared}")
    print(f"computed: {computed}")

    if computed == declared:
        print("MATCH — manifest is already consistent; nothing to write.")
        return 0

    print("\nMISMATCH — the manifest has been edited since its digest was written.")
    if not write:
        print("(dry run — pass --write to regenerate)")
        return 1

    # THE CONTROL, and it runs here rather than being printed as advice.
    #
    # This is a reimplementation of a hashing rule defined in Swift. It is only
    # trustworthy if it reproduces the digest of the file as it stood BEFORE the
    # edit — i.e. the committed version, whose digest was written by a run that
    # the app accepted. An earlier version of this script only PRINTED those
    # instructions and then wrote anyway, which is a guard that never arms: on
    # any drift between this canonicalization and Swift's, it would have written
    # a confident wrong digest and the app would refuse to launch (Codex r1).
    if not _baseline_reproduces(path):
        return 1

    text = raw.decode("utf-8")
    if text.count(declared) != 1:
        print("REFUSED: declared digest is not a unique string in the file", file=sys.stderr)
        return 1
    open(path, "w").write(text.replace(declared, computed))
    print(f"\nWROTE {path}: {declared} -> {computed}")
    return 0


def _baseline_reproduces(path: str) -> bool:
    """True only if we can recompute the COMMITTED version's own declared digest.

    Refuses on any uncertainty — a missing git, an untracked file, a parse
    failure. "I could not check" must never read as "the check passed".
    """
    try:
        baseline = subprocess.run(
            ["git", "show", f"HEAD:{path}"],
            capture_output=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        print(
            f"REFUSED: cannot read the committed baseline for {path} ({exc}).\n"
            "Without it this tool's canonicalization is unverified, so it will "
            "not rewrite a digest the app validates on every launch.",
            file=sys.stderr,
        )
        return False

    try:
        baseline_obj = json.loads(baseline)
        baseline_declared = baseline_obj["manifestDigest"]
    except (ValueError, KeyError, TypeError) as exc:
        print(f"REFUSED: committed baseline is unreadable ({exc})", file=sys.stderr)
        return False

    baseline_computed = canonical_digest(baseline_obj)
    if baseline_computed != baseline_declared:
        print(
            "REFUSED: this implementation does not reproduce the COMMITTED digest\n"
            f"  committed declares: {baseline_declared}\n"
            f"  this tool computes: {baseline_computed}\n"
            "It has drifted from DeliveryManifest.canonicalDigest. Writing now "
            "would produce a manifest the app rejects at launch.",
            file=sys.stderr,
        )
        return False

    print(f"control OK: reproduced the committed baseline digest ({baseline_declared[:12]}…)")
    return True


if __name__ == "__main__":
    sys.exit(main())
