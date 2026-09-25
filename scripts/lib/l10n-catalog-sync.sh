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
# target with no `.stringsdata`, or a project target the lists do not know (any
# name: third-party packages build under their own `<Package>.build` directories),
# stops the run.
#
# `xcstringstool sync` resets manual entries to extracted/new (measured). The three
# Phase 1 semantic keys are manual on purpose (curated translator comments): each
# keeps its committed object, with its English taken from the code's single
# extracted default, so changing that default is ordinary drift, not a refusal.
#
# What's New (#3142 PR 2E) is not extracted: its English stays direct Swift literals that
# the GitHub release notes parse from source text. `scripts/ci/render-release-notes.py
# --catalog-seed-json` names every title, description and bullet (`whatsNew.<id>.title`,
# `.description`, `.bullet.<n>`) with its English, and this script writes those keys as
# manual entries whose English comes from that seed, the way extracted keys take theirs
# from the code. A seed key keeps its comment and translations; changed English flags the
# translations for review; a key gone from the seed is removed. A seed the renderer
# refuses, or one colliding with an extracted key, stops the run.
#
# Toolchain: catalog serialization can change between Xcode builds, so the script
# refuses to run under any build but the pinned one (CI pins the same build in
# .github/actions/xcode-ci-setup/action.yml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

exec python3 - "$REPO_ROOT" "$@" <<'PY'
import argparse, copy, json, pathlib, subprocess, sys, tempfile

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
# Phase 1 semantic keys: kept manual (curated translator comments). Their English
# lives in the code only; InterfaceCatalogSourceTests pins it.
MANUAL_KEYS = {
    "settings.aiPolish.enable.title",
    "menu.setupRequired.continue",
    "notification.update.ready.body",
}
CATALOG = REPO / "Sources/EnviousWispr/Resources/Localizable.xcstrings"
WHATS_NEW_SOURCE = REPO / "Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift"
RENDERER = REPO / "scripts/ci/render-release-notes.py"
WHATS_NEW_PREFIX = "whatsNew."


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
    unknown = sorted(present - set(PRODUCTION_TARGETS) - NON_PRODUCTION - GENERATED_RESOURCE_TARGETS)
    if unknown:
        raise Refused(f"project targets the target lists do not know: {unknown}")
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


def whats_new_seed(source):
    """key -> English for every What's New field, from the release-notes parser. Refuses
    rather than returning a partial seed: a missing key would be deleted from the catalog."""
    run = subprocess.run(
        [sys.executable, str(RENDERER), "--swift-file", str(source), "--catalog-seed-json"],
        capture_output=True, text=True)
    if run.returncode != 0:
        raise Refused(f"What's New seed refused by the renderer: {run.stderr.strip() or run.stdout.strip()}")
    try:
        seed = json.loads(run.stdout)
    except ValueError as error:
        raise Refused(f"What's New seed is not JSON: {error}")
    if not isinstance(seed, dict) or not seed:
        raise Refused("What's New seed is empty or not a key-to-English object")
    for key, value in seed.items():
        if not key.startswith(WHATS_NEW_PREFIX) or not isinstance(value, str) or not value.strip():
            raise Refused(f"What's New seed entry {key!r} is not a {WHATS_NEW_PREFIX}* key with English")
    return seed


def whats_new_comment(key):
    """The translator note a new What's New entry starts with; an existing entry keeps its own."""
    entry_id, field = key[len(WHATS_NEW_PREFIX):].split(".", 1)
    if field == "title":
        what = "the title of one feature announcement"
    elif field == "description":
        what = "the paragraph under one feature announcement's title"
    else:
        what = f"point {int(field.split('.')[1]) + 1} of the list under one feature announcement"
    return f"Settings > What's New: {what} (entry {entry_id})."


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


def flag_for_review(node):
    """Mark every translated stringUnit under `node` (plural/device variations and
    substitutions included) as needs_review."""
    if isinstance(node, dict):
        unit = node.get("stringUnit")
        if isinstance(unit, dict) and unit.get("state") == "translated":
            unit["state"] = "needs_review"
        for value in node.values():
            flag_for_review(value)
    elif isinstance(node, list):
        for value in node:
            flag_for_review(value)


def sync(committed_path, files, work, seed):
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
    for key in sorted(MANUAL_KEYS):
        if key not in extracted:
            raise Refused(f"manual key {key!r} is not extracted from any production source")
        defaults = extracted[key]
        if len(defaults) != 1 or None in defaults:
            raise Refused(f"manual key {key!r} needs exactly one English default in code, found {sorted(map(str, defaults))}")
        if key not in committed["strings"] or english(committed["strings"][key]) is None:
            raise Refused(f"manual key {key!r} has no English entry in the committed catalog")
        if set(committed["strings"][key]["localizations"]["en"]) != {"stringUnit"}:
            # Plural/device variations or substitutions would describe English the
            # code no longer extracts; nothing here could reconcile them.
            raise Refused(f"manual key {key!r}: English must be a plain stringUnit (no variations or substitutions)")
        # Keep the curated object (comment, manual state); English comes from the code.
        entry = copy.deepcopy(committed["strings"][key])
        entry["localizations"]["en"]["stringUnit"]["value"] = next(iter(defaults))
        synced["strings"][key] = entry
    # What's New: never extracted, so the seed alone decides its keys and English.
    colliding = sorted(k for k in fresh["strings"] if k.startswith(WHATS_NEW_PREFIX))
    if colliding:
        raise Refused(f"extracted keys use the What's New prefix {WHATS_NEW_PREFIX!r}: {colliding}")
    source_language = committed.get("sourceLanguage", "en")
    for key, value in seed.items():
        before = committed["strings"].get(key, {})
        others = {lang: copy.deepcopy(unit) for lang, unit in before.get("localizations", {}).items()
                  if lang != source_language}
        synced["strings"][key] = {
            "comment": before.get("comment") or whats_new_comment(key),
            "extractionState": "manual",
            # `translated`: only translated entries are compiled into the English table,
            # and the screen looks these keys up at run time.
            "localizations": {source_language: {"stringUnit": {"state": "translated", "value": value}}} | others,
        }
    # A translation of English that has since changed must not ship as current.
    # xcstringstool flags this itself only for entries whose English it owns
    # (measured: not for manual or `translated` English), so the rule lives here.
    source = committed.get("sourceLanguage", "en")
    for key, entry in synced["strings"].items():
        before = english(committed["strings"].get(key, {}))
        if before is None or before == english(entry):
            continue
        for lang, unit in entry.get("localizations", {}).items():
            if lang != source:
                flag_for_review(unit)
    # The code decides which keys exist: exactly the fresh extraction (which
    # includes the verified manual keys) plus the What's New seed. A key gone from
    # either is removed, never kept.
    synced["strings"] = {k: synced["strings"][k] for k in [*fresh["strings"], *seed]}
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
    parser.add_argument("--whats-new-source", type=pathlib.Path, default=WHATS_NEW_SOURCE)
    args = parser.parse_args(argv)
    try:
        build = xcode_build()
        if build != PINNED_XCODE_BUILD:
            raise Refused(f"Xcode build {build} is not the pinned {PINNED_XCODE_BUILD}")
        files = collect_inputs(args.derived_data, args.configuration)
        seed = whats_new_seed(args.whats_new_source)
        with tempfile.TemporaryDirectory() as tmp:
            committed, synced = sync(args.catalog, files, pathlib.Path(tmp), seed)
        added, removed, changed = diff(committed, synced)
        print(f"inputs: {len(files)} .stringsdata from {len(PRODUCTION_TARGETS)} production targets")
        print(f"What's New: {len(seed)} keys from {args.whats_new_source.name}")
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
            print(f"DRIFT: {len(added)} added, {len(removed)} removed, {len(changed)} changed. To fix, on Xcode "
                  f"{PINNED_XCODE_BUILD}: xcodebuild build -project EnviousWispr.xcodeproj -scheme EnviousWispr-Release "
                  "-configuration Release -derivedDataPath .derivedData/L10n -destination 'generic/platform=macOS', "
                  "then scripts/lib/l10n-catalog-sync.sh --update --derived-data .derivedData/L10n "
                  "--configuration Release, and commit Sources/EnviousWispr/Resources/Localizable.xcstrings.")
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
