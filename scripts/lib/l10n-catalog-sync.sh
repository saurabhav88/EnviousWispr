#!/bin/bash
# #3142: the single writer of the app's interface String Catalog
# (Sources/EnviousWispr/Resources/Localizable.xcstrings).
#
# The compiler extracts every localizable literal into per-file `.stringsdata`
# (SWIFT_EMIT_LOC_STRINGS). A normal CLI build does NOT rewrite the committed
# catalog (measured 2026-09-24), so this script is how the catalog follows the code:
#
#   l10n-catalog-sync.sh --update --derived-data <dir> --configuration Release
#       syncs the committed catalog from that build's production `.stringsdata`.
#   l10n-catalog-sync.sh --check  --derived-data <dir> --configuration Release
#       syncs a scratch copy and fails (exit 1) if it differs from the committed
#       catalog, printing the added, removed and changed keys. Exit 2: could not run.
#
# Release is the only accepted configuration: the catalog holds the text that
# SHIPS. A Debug build also extracts copy from `#if DEBUG` screens (13 keys when
# measured 2026-09-24), which would then read as drift against the Release check
# CI runs, and would hand translators text no customer sees.
#
# Inputs are an EXPLICIT production-target list, never a directory sweep: the same
# derived-data tree also holds third-party and test-target `.stringsdata`, and a test
# string in the shipped catalog would be a translation nobody needs. A production
# target with no `.stringsdata`, or a first-party target the list does not know,
# stops the run.
#
# `xcstringstool sync` resets manual entries to extracted/new (measured). The three
# Phase 1 semantic keys are manual on purpose; each is restored from the committed
# catalog only after its extracted English default is verified against the entry.
#
# Toolchain: catalog serialization can change between Xcode builds, so the script
# refuses to run under any build but the pinned one (CI pins the same build in
# .github/actions/xcode-ci-setup/action.yml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

exec python3 - "$REPO_ROOT" "$@" <<'PY'
import argparse, json, os, pathlib, shutil, subprocess, sys, tempfile

REPO = pathlib.Path(sys.argv[1])
PINNED_XCODE_BUILD = "17F113"  # Xcode 26.6; keep equal to .github/actions/xcode-ci-setup/action.yml

# Production targets whose code ships in the app, in Project.swift order. A new
# first-party module must be added here (or to NON_PRODUCTION) or the run stops.
PRODUCTION_TARGETS = [
    "EnviousWisprCore", "EnviousWisprObservabilityCore", "EnviousWisprStorage",
    "EnviousWisprModelDelivery", "EnviousWisprPostProcessing", "EnviousWisprAudio",
    "EnviousWisprServices", "EnviousWisprFluidAudioBridge", "EnviousWisprASR",
    "EnviousWisprLLM", "EnviousWisprPipeline", "EnviousWisprContacts",
    "EnviousWisprLivePreview", "EnviousWisprWhisperPreviewAdapter", "EnviousWisprAppKit",
    "EnviousWisprDesktopEffects", "EnviousWisprAppLive", "EnviousWispr",
]
NON_PRODUCTION = {
    "EnviousWisprAppKitTestSupport", "EnviousWisprTests", "EnviousWisprASRTests",
    "EnviousWisprDesktopEffectsTests",
}
# Tuist-generated resource-bundle targets: recognized so they are not "unknown", never
# read (they hold resources, not compiled Swift).
GENERATED_RESOURCE_TARGETS = {
    "EnviousWispr_EnviousWisprAppKit", "EnviousWispr_EnviousWisprPostProcessing",
}
# Phase 1 semantic keys: kept manual (translator comments, extraction state) after
# their extracted English default is verified.
MANUAL_KEYS = {
    "settings.aiPolish.enable.title": "Enable AI Polish",
    "menu.setupRequired.continue": "Setup Required: Continue Setup…",
    "notification.update.ready.body": "Version %@ is ready. Click to install.",
}
CATALOG = REPO / "Sources/EnviousWispr/Resources/Localizable.xcstrings"


class Refused(Exception):
    pass


def xcode_build():
    out = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True)
    if out.returncode != 0:
        raise Refused(f"xcodebuild -version failed: {out.stderr.strip()}")
    for line in out.stdout.splitlines():
        if line.startswith("Build version "):
            return line.split()[-1]
    raise Refused(f"no build version in xcodebuild -version output: {out.stdout!r}")


def collect_inputs(derived, configuration):
    base = derived / "Build/Intermediates.noindex/EnviousWispr.build" / configuration
    if not base.is_dir():
        raise Refused(f"no build intermediates at {base}")
    present = {p.name[: -len(".build")] for p in base.glob("*.build") if p.is_dir()}
    first_party = {t for t in present if t.startswith("EnviousWispr")}
    unknown = sorted(first_party - set(PRODUCTION_TARGETS) - NON_PRODUCTION - GENERATED_RESOURCE_TARGETS)
    if unknown:
        raise Refused(f"first-party targets the production list does not know: {unknown}")
    files, missing = [], []
    for target in PRODUCTION_TARGETS:
        # Xcode writes ExtractedAppShortcutsMetadata.stringsdata into every target even with
        # extraction OFF, so it cannot count as compiler output.
        found = sorted(
            p for p in (base / f"{target}.build").glob("Objects-normal/*/*.stringsdata")
            if p.name != "ExtractedAppShortcutsMetadata.stringsdata"
        )
        if not found:
            missing.append(target)
        files.extend(found)
    if missing:
        raise Refused(f"production targets with no .stringsdata (extraction off or not built): {missing}")
    return files


def extracted_defaults(files):
    """key -> set of extracted English values (None when the key is the English)."""
    seen = {}
    for f in files:
        data = json.loads(f.read_text())
        for entry in data.get("tables", {}).get("Localizable", []):
            seen.setdefault(entry["key"], set()).add(entry.get("value"))
    return seen


def english(entry):
    unit = entry.get("localizations", {}).get("en", {}).get("stringUnit", {})
    return unit.get("value")


def xcstringstool_sync(start, files, work):
    """Run `xcstringstool sync` over a copy of `start` (a catalog object) and return the result."""
    work.mkdir()
    scratch = work / "Localizable.xcstrings"  # sync matches the table by FILE NAME
    scratch.write_text(json.dumps(start))
    args = ["xcrun", "xcstringstool", "sync", str(scratch)]
    for f in files:
        args += ["--stringsdata", str(f)]
    run = subprocess.run(args, capture_output=True, text=True)
    if run.returncode != 0:
        raise Refused(f"xcstringstool sync failed: {run.stderr.strip() or run.stdout.strip()}")
    return json.loads(scratch.read_text())


def sync(committed_path, files, work):
    committed = json.loads(committed_path.read_text())
    synced = xcstringstool_sync(committed, files, work / "incremental")
    # An incremental sync KEEPS an English value already in the catalog when the
    # code carries none (key-only literals) or when the entry is marked translated
    # (measured 2026-09-24), so a hand-edited English value would pass as in sync.
    # English for every extracted key therefore comes from a sync of an EMPTY
    # catalog: the code alone decides it. The incremental result only contributes
    # what a later phase adds beside English (translations).
    fresh = xcstringstool_sync({k: v for k, v in committed.items() if k != "strings"} | {"strings": {}},
                               files, work / "fresh")
    for key, entry in fresh["strings"].items():
        if key in MANUAL_KEYS:
            continue
        others = {lang: unit for lang, unit in synced["strings"].get(key, {}).get("localizations", {}).items()
                  if lang != committed.get("sourceLanguage", "en")}
        merged = dict(entry)
        if others:
            merged["localizations"] = dict(entry.get("localizations", {})) | others
        synced["strings"][key] = merged
    extracted = extracted_defaults(files)
    for key, expected in MANUAL_KEYS.items():
        if key not in extracted:
            raise Refused(f"manual key {key!r} is not extracted from any production source")
        if extracted[key] != {expected}:
            raise Refused(f"manual key {key!r}: extracted default {sorted(map(str, extracted[key]))} != {expected!r}")
        if key not in committed["strings"]:
            raise Refused(f"manual key {key!r} missing from the committed catalog")
        if english(committed["strings"][key]) != expected:
            raise Refused(f"manual key {key!r}: committed English != {expected!r}")
        synced["strings"][key] = committed["strings"][key]
    # English-only phase: a key no longer in code is removed, not kept as stale.
    synced["strings"] = {k: v for k, v in synced["strings"].items() if v.get("extractionState") != "stale"}
    return committed, synced


def diff(committed, synced):
    a, b = committed["strings"], synced["strings"]
    added = sorted(set(b) - set(a))
    removed = sorted(set(a) - set(b))
    changed = sorted(k for k in set(a) & set(b) if a[k] != b[k])
    return added, removed, changed


def write_catalog(path, obj):
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n")


def main(argv):
    parser = argparse.ArgumentParser(prog="l10n-catalog-sync.sh")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--update", action="store_true")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--derived-data", required=True, type=pathlib.Path)
    parser.add_argument("--configuration", required=True, choices=["Release"])
    parser.add_argument("--catalog", type=pathlib.Path, default=CATALOG)
    args = parser.parse_args(argv)
    try:
        build = xcode_build()
        if build != PINNED_XCODE_BUILD:
            raise Refused(f"Xcode build {build} is not the pinned {PINNED_XCODE_BUILD}")
        files = collect_inputs(args.derived_data, args.configuration)
        with tempfile.TemporaryDirectory() as tmp:
            committed, synced = sync(args.catalog, files, pathlib.Path(tmp))
        added, removed, changed = diff(committed, synced)
        print(f"inputs: {len(files)} .stringsdata from {len(PRODUCTION_TARGETS)} production targets")
        print(f"keys: committed {len(committed['strings'])}, synced {len(synced['strings'])}")
        for label, keys in (("added", added), ("removed", removed), ("changed", changed)):
            for k in keys:
                print(f"  {label}: {k!r}")
        if args.update:
            if added or removed or changed:
                write_catalog(args.catalog, synced)
                print(f"updated {args.catalog}")
            else:
                print("catalog already in sync")
            return 0
        if added or removed or changed:
            print(f"DRIFT: {len(added)} added, {len(removed)} removed, {len(changed)} changed. "
                  "Run scripts/lib/l10n-catalog-sync.sh --update and commit the catalog.")
            return 1
        print("catalog in sync")
        return 0
    except Refused as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2


sys.exit(main(sys.argv[2:]))
PY
