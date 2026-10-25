#!/usr/bin/env python3
"""Retire only stale source-package parser interfaces that shadow Xcode's host modules.

Atomic rename preserves the old artifacts; it never follows a module symlink or
purges DerivedData, dependency sources, unrelated modules, or another checkout.
"""
import os
from pathlib import Path
import sys
import tempfile


def prepare(derived):
    derived = Path(derived)
    archived = None
    for configuration in ("Debug", "Release", "Dev"):
        for module in ("SwiftSyntax", "SwiftParser"):
            source = derived / "Build/Products" / configuration / (module + ".swiftmodule")
            if not source.exists() and not source.is_symlink():
                continue
            if archived is None:
                archived = Path(tempfile.mkdtemp(prefix="LegacyPackageSyntax-", dir=derived / "Build"))
            destination = archived / configuration / source.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            # rename fails across mounts instead of copying/deleting a directory tree.
            os.rename(source, destination)
            print(f"==> Retired legacy {module} interface ({configuration}): {destination}")
    return archived


def self_test():
    with tempfile.TemporaryDirectory(prefix="syntax-interface-test-") as temp:
        root = Path(temp)
        assert prepare(root / "absent") is None
        assert not (root / "absent").exists()
        products = root / "Build/Products/Debug"
        legacy = products / "SwiftSyntax.swiftmodule"
        legacy.mkdir(parents=True)
        (legacy / "module").write_text("old interface")
        other = products / "Unrelated.swiftmodule"
        other.write_text("keep")
        outside = root / "outside"
        outside.mkdir()
        (outside / "sentinel").write_text("keep")
        (products / "SwiftParser.swiftmodule").symlink_to(outside, target_is_directory=True)
        archive = prepare(root)
        assert not legacy.exists()
        assert (archive / "Debug/SwiftSyntax.swiftmodule/module").read_text() == "old interface"
        assert (archive / "Debug/SwiftParser.swiftmodule").is_symlink()
        assert (outside / "sentinel").read_text() == "keep"
        assert other.read_text() == "keep"
        assert prepare(root) is None
    print("prepare-toolchain-syntax: 4 controls PASS (empty, preserve, symlink, repeat)")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 2:
        prepare(sys.argv[1])
    else:
        raise SystemExit("usage: prepare-toolchain-syntax.py DERIVED_DATA | --self-test")
