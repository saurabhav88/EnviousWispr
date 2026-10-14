#!/usr/bin/env python3
"""Bind Sentry's runtime release name to the app, source and first-party dSYM (#3687)."""
import argparse
import json
import plistlib
import re
import struct
import sys
import tempfile
import uuid
from pathlib import Path

PACKAGE = "com.enviouswispr.app"
BINDING = "sentry-release-binding.json"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def image_uuid(path):
    """Read LC_UUID from the supported arm64 Mach-O; no platform tool or executable runs."""
    with Path(path).open("rb") as source:
        header = source.read(32)
        require(len(header) == 32, "missing Mach-O header")
        magic, cpu, _, _, count, size, _, _ = struct.unpack("<IiiIIIII", header)
        require(magic == 0xFEEDFACF and cpu == 0x0100000C, "expected arm64 Mach-O")
        require(0 < count <= size // 8 and size <= 1024 * 1024, "invalid load-command bounds")
        commands = source.read(size)
        require(len(commands) == size, "truncated load commands")
        offset = 0
        identifiers = []
        for _ in range(count):
            require(offset + 8 <= size, "truncated load command")
            kind, length = struct.unpack_from("<II", commands, offset)
            require(length >= 8 and offset + length <= size, "invalid load-command length")
            if kind == 0x1B:
                require(length == 24, "invalid UUID command")
                identifiers.append(str(uuid.UUID(bytes=commands[offset + 8:offset + 24])).upper())
            offset += length
        require(offset == size and len(identifiers) == 1, "expected exactly one image UUID")
        return identifiers[0]


def validate(binding, version, commit, dsyms):
    require(isinstance(binding, dict), "expected release-binding object")
    require(re.fullmatch(r"\d+\.\d+\.\d+", version), "expected release semver")
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "expected source commit")
    require(type(binding.get("schema")) is int and binding["schema"] == 1,
            "missing or unsupported release binding")
    require(binding.get("version") == version and binding.get("build") == version, "wrong bound version/build")
    require(binding.get("package") == PACKAGE, "wrong runtime package")
    name = f"{PACKAGE}@{version}"
    require(binding.get("release") == name, "wrong runtime Sentry release")
    require(binding.get("source_commit") == commit, "wrong bound source commit")
    dwarf = Path(dsyms) / "EnviousWispr.app.dSYM/Contents/Resources/DWARF/EnviousWispr"
    require(binding.get("app_uuid") == image_uuid(dwarf), "app/dSYM UUID mismatch")
    return name


def create(app, version, commit, dsyms):
    app = Path(app)
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    require(info.get("CFBundleIdentifier") == PACKAGE, "expected production app bundle")
    require(info.get("CFBundleExecutable") == "EnviousWispr", "unexpected app executable")
    binding = {
        "schema": 1, "package": info["CFBundleIdentifier"],
        "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
        "release": info.get("SentryReleaseName"), "source_commit": commit,
        "app_uuid": image_uuid(app / "Contents/MacOS/EnviousWispr"),
    }
    validate(binding, version, commit, dsyms)
    with (Path(dsyms) / BINDING).open("x") as output:
        json.dump(binding, output, indent=2)
        output.write("\n")
    return binding["release"]


def self_test():
    with tempfile.TemporaryDirectory(prefix="ew-sentry-binding-") as directory:
        root = Path(directory)
        identifier = uuid.UUID("01234567-89ab-4cde-8123-456789abcdef")
        macho = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
        macho += struct.pack("<II", 0x1B, 24) + identifier.bytes
        app = root / "EnviousWispr.app"
        executable = app / "Contents/MacOS/EnviousWispr"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(macho)
        info = {"CFBundleIdentifier": PACKAGE, "CFBundleExecutable": "EnviousWispr",
                "CFBundleShortVersionString": "2.6.0", "CFBundleVersion": "2.6.0",
                "SentryReleaseName": "com.enviouswispr.app@2.6.0"}
        with (app / "Contents/Info.plist").open("wb") as output:
            plistlib.dump(info, output)
        dwarf = root / "symbols/EnviousWispr.app.dSYM/Contents/Resources/DWARF/EnviousWispr"
        dwarf.parent.mkdir(parents=True)
        dwarf.write_bytes(macho)
        commit = "a" * 40
        require(create(app, "2.6.0", commit, root / "symbols") == "com.enviouswispr.app@2.6.0", "producer failed")
        good = json.loads((root / "symbols" / BINDING).read_text())
        require(validate(good, "2.6.0", commit, root / "symbols") == "com.enviouswispr.app@2.6.0", "rerun binding failed")
        cases = [("schema", 0), ("version", "2.5.3"), ("build", "2.5.3"),
                 ("package", "wrong"), ("release", "v2.6.0"), ("source_commit", "b" * 40),
                 ("app_uuid", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")]
        for key, bad in cases:
            broken = {**good, key: bad}
            try:
                validate(broken, "2.6.0", commit, root / "symbols")
            except ValueError:
                continue
            raise AssertionError(f"accepted invalid {key}")
        for broken in [b"", macho[:35], struct.pack("<I", 0xDEADBEEF) + macho[4:]]:
            executable.write_bytes(broken)
            try:
                image_uuid(executable)
            except ValueError:
                continue
            raise AssertionError("accepted malformed Mach-O")
    print("Sentry release binding self-test: PASS (producer, rerun, 7 binding and 3 image negatives)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--create", metavar="APP")
    parser.add_argument("--verify", metavar="BINDING")
    parser.add_argument("--version")
    parser.add_argument("--source")
    parser.add_argument("--dsyms")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    require(bool(args.create) != bool(args.verify), "choose create or verify")
    require(args.version and args.source and args.dsyms, "version/source/dsyms are required")
    if args.create:
        print(create(args.create, args.version, args.source, args.dsyms))
    else:
        with Path(args.verify).open() as source:
            binding = json.load(source)
        print(validate(binding, args.version, args.source, args.dsyms))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, TypeError, KeyError, json.JSONDecodeError) as error:
        print(f"Sentry release binding rejected: {error}", file=sys.stderr)
        sys.exit(1)
