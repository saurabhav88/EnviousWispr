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
# Permission prompts and the Services menu (#3142 Phase 3) live in Info.plist, the English
# source. The same seeded-entry rules write InfoPlist.xcstrings (every NS...UsageDescription
# plus NSHumanReadableCopyright, keyed by the plist key) and ServicesMenu.xcstrings (each
# NSServices item's default title, keyed by that title, so a changed title starts untranslated).
# All three catalogs are computed and validated before --update writes any of them.
#
# Completeness (#3142 Phase 4): every language other than English present in the three
# catalogs must be complete. Each key has a value in it, every string unit is `translated`
# (not `new` or `needs_review`), and each carries the English placeholders (position and type;
# reordering is fine). --check fails on it (INCOMPLETE); --update reports it and never supplies
# a translation. With English only there is nothing to check. Key "" is exempt.
#
# Toolchain: catalog serialization can change between Xcode builds, so the script
# refuses to run under any build but the pinned one (CI pins the same build in
# .github/actions/xcode-ci-setup/action.yml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

exec python3 - "$REPO_ROOT" "$@" <<'PY'
import argparse, copy, json, pathlib, plistlib, re, subprocess, sys, tempfile

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
# Permission prompts and the Services menu (#3142 Phase 3): Info.plist is their English
# source; these two catalogs are written from it and compiled to InfoPlist.strings and
# ServicesMenu.strings, which macOS reads in the user's language.
INFO_PLIST = REPO / "Sources/EnviousWispr/Resources/Info.plist"
INFOPLIST_CATALOG = REPO / "Sources/EnviousWispr/Resources/InfoPlist.xcstrings"
SERVICESMENU_CATALOG = REPO / "Sources/EnviousWispr/Resources/ServicesMenu.xcstrings"


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


def info_plist_seeds(path):
    """(InfoPlist seed, ServicesMenu seed) from the app's Info.plist: every top-level key with
    the NS prefix and UsageDescription suffix plus NSHumanReadableCopyright, keyed by the plist
    key; every NSServices item's NSMenuItem default title, keyed by that title. Refuses a
    value that is not a nonempty string, an unexpected NSServices shape, or two Services items
    with one title (their catalog entries would collapse into one)."""
    with open(path, "rb") as fh:
        plist = plistlib.load(fh)
    if not isinstance(plist, dict):
        raise Refused(f"{path.name} is not a dictionary")
    info = {}
    for key in sorted(plist):
        if (key.startswith("NS") and key.endswith("UsageDescription")) or key == "NSHumanReadableCopyright":
            value = plist[key]
            if not isinstance(value, str) or not value.strip():
                raise Refused(f"{path.name} {key} is not a nonempty string")
            info[key] = value
    if not any(key.endswith("UsageDescription") for key in info):
        raise Refused(f"{path.name} has no permission prompts; is this the app's Info.plist?")
    services = {}
    items = plist.get("NSServices", [])
    if not isinstance(items, list):
        raise Refused(f"{path.name} NSServices is not an array")
    for item in items:
        menu = item.get("NSMenuItem") if isinstance(item, dict) else None
        title = menu.get("default") if isinstance(menu, dict) else None
        if not isinstance(title, str) or not title.strip():
            raise Refused(f"{path.name} has a Services item without an NSMenuItem default title")
        if title in services:
            raise Refused(f"{path.name} has two Services items titled {title!r}")
        services[title] = title
    return info, services


def info_plist_comment(key):
    if key == "NSHumanReadableCopyright":
        return "About box: the copyright line. Legal text: keep the company name and the years exactly."
    return (f"macOS permission prompt ({key}), shown when the app first asks for this access. "
            "Say exactly what the app does with it, no more and no less.")


def services_menu_comment(_key):
    return ("macOS Services menu item, shown in other apps' Services menu: adds the selected text "
            "to EnviousWispr's words.")


def seeded_entry(before, value, default_comment, source_language):
    """A catalog entry whose English comes from a source seed rather than the compiler: the
    existing comment and non-English localizations are kept, English is the seed's, manual,
    in state `translated` so it is compiled into the English table. Shared by What's New and
    the Info.plist tables."""
    others = {lang: copy.deepcopy(unit) for lang, unit in before.get("localizations", {}).items()
              if lang != source_language}
    return {
        "comment": before.get("comment") or default_comment,
        "extractionState": "manual",
        "localizations": {source_language: {"stringUnit": {"state": "translated", "value": value}}} | others,
    }


def flag_changed_translations(committed_strings, synced_strings, source_language):
    """A translation of English that has since changed must not ship as current.
    xcstringstool flags this itself only for entries whose English it owns (measured: not for
    manual or `translated` English), so the rule lives here."""
    for key, entry in synced_strings.items():
        before = english_units(committed_strings.get(key, {}), source_language)
        if not before or before == english_units(entry, source_language):
            continue
        for lang, unit in entry.get("localizations", {}).items():
            if lang != source_language:
                flag_for_review(unit)


def sync_seeded_table(catalog_path, seed, default_comment):
    """A catalog written entirely from a source seed: exactly the seed's keys, each through
    `seeded_entry`; a key the source no longer has is removed."""
    committed = json.loads(catalog_path.read_text())
    source_language = committed.get("sourceLanguage", "en")
    synced = copy.deepcopy(committed)
    synced["strings"] = {key: seeded_entry(committed["strings"].get(key, {}), value, default_comment(key),
                                           source_language)
                         for key, value in seed.items()}
    flag_changed_translations(committed["strings"], synced["strings"], source_language)
    return committed, synced


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


def string_units(node, path=()):
    """(path, stringUnit) for every stringUnit under `node`, one language's localization;
    `path` is the chain of keys from that root (variations, plural forms, substitutions).
    The one traversal the review flag and the completeness check both use."""
    if isinstance(node, dict):
        unit = node.get("stringUnit")
        if isinstance(unit, dict):
            yield path, unit
        for key, value in node.items():
            if key != "stringUnit":
                yield from string_units(value, path + (key,))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from string_units(value, path + (str(index),))


def flag_for_review(node):
    """Mark every translated stringUnit under `node` (plural/device variations and
    substitutions included) as needs_review."""
    for _, unit in string_units(node):
        if unit.get("state") == "translated":
            unit["state"] = "needs_review"


def english_units(entry, source_language):
    """path -> English value for every English stringUnit of `entry`, so a reworded plural
    form counts as changed English even when the top-level value is the same."""
    return {path: unit.get("value")
            for path, unit in string_units(entry.get("localizations", {}).get(source_language, {}))}


# --- Completeness (#3142 Phase 4) ---
# Every language other than English that the catalogs contain must be complete: each key
# has a value in that language, every one of its string units is `translated`, and each
# unit carries the same placeholders as the English it translates. With no such language
# (English only) there is nothing to check.
FORMAT_SPEC = re.compile(
    r"%(?:(\d+)\$)?(?:[-+0#' ]*(?=[\d*.])|[-+0#']*)(?:\d+|\*(?:\d+\$)?)?(?:\.(?:\d+|\*(?:\d+\$)?))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])")
SUBSTITUTION = re.compile(r"%#@([A-Za-z0-9_]+)@")
# The space flag counts only before a width or precision (`% 5d`): a bare `% d` reads the same
# as German prose ("83 % der"). A spec-like run ending in a letter the parser cannot read
# (`%10$k`) is compared as written. A % that starts neither is a percentage in prose ("83% of",
# "83 % der", "50%-60%"): text, not a placeholder.
UNREADABLE = re.compile(r"%[-+0-9#'$*.]*[A-Za-z@]")
# A single % right after a number, with at most one space between, is a percentage (German
# "83%ige") unless what follows can only be a placeholder: %@, a position (%1$) or a length
# (%lld), as in "1 %@ left". An escaped %% is read first.
INTEGER = re.compile(r"(?:hh|h|ll|l|q|z|t|j)?[dDiuU]")
AFTER_A_NUMBER = re.compile(r"[0-9][ \u00a0\u202f]?$")


def placeholders(text, prose_after_numbers=True):
    """Sorted placeholders of a format string: ("arg", position, type) with implicit positions
    counted in order, ("sub", name) for %#@name@, ("pct",) for %%, and ("lit", text) for a %
    this parser cannot read, which must then match exactly (fails closed); ("prose",) for a
    percentage in prose. `arguments` drops the last two kinds for comparison. Without
    `prose_after_numbers` a % after a number is read like any other (for a line that is
    formatted, whose every literal percent is %%)."""
    tokens, implicit, i = [], 0, 0
    while True:
        j = text.find("%", i)
        if j < 0:
            break
        if text.startswith("%%", j):
            tokens.append(("pct",))
            i = j + 2
            continue
        spec = FORMAT_SPEC.match(text, j)
        unambiguous = spec and (spec.group(1) or spec.group(2) or spec.group(3) == "@")
        if prose_after_numbers and AFTER_A_NUMBER.search(text, 0, j) and not unambiguous:
            tokens.append(("prose",))  # "83%ige", "83 % der": a percentage
            i = j + 1
            continue
        sub = SUBSTITUTION.match(text, j)
        if sub:
            tokens.append(("sub", sub.group(1)))
            i = sub.end()
            continue
        spec = FORMAT_SPEC.match(text, j)
        if spec:
            if "*" in spec.group(0):
                # A dynamic width or precision (`*` or `*2$`) consumes an argument of its own,
                # which this parser does not model; kept as written, at its position, so it must
                # match exactly and cannot move past another argument.
                tokens.append(("unsupported", implicit + 1, spec.group(0)))
                implicit += spec.group(0).count("*") + (0 if spec.group(1) else 1)
                i = spec.end()
                continue
            if spec.group(1):
                position = int(spec.group(1))
            else:
                implicit += 1
                position = implicit
            tokens.append(("arg", position, (spec.group(2) or "") + spec.group(3)))
            i = spec.end()
            continue
        lit = UNREADABLE.match(text, j)
        if lit:
            tokens.append(("lit", lit.group(0)))
            i = lit.end()
        else:
            tokens.append(("prose",))
            i = j + 1
    return sorted(tokens, key=repr)


def shown_on_mac(path):
    """Whether a unit at `path` is text the Mac app can display: not a substitution's form, and
    not another device's (`variations/device/iphone`); plain, plural, and device `mac` or
    `other` all are."""
    if path[:1] == ("substitutions",):
        return False
    if "device" in path:
        index = path.index("device") + 1
        return index < len(path) and path[index] in ("mac", "other")
    return True


def spells_out_a_count(german, english):
    """True when `german` is `english` less its one integer argument: a plural form other than
    `other` may write its number as a word ("ein Wort" for "%lld words"). With two integers
    ("Page %lld of %lld") the counted one is unknown, so nothing may go; nor may anything else."""
    integers = [t for t in english if t[0] == "arg" and INTEGER.fullmatch(t[2])]
    return len(integers) == 1 and sorted(german + integers, key=repr) == english


def arguments(tokens):
    """The tokens that consume or name a format argument (not %% or a prose %)."""
    return [t for t in tokens if t[0] not in ("pct", "prose")]


def incompleteness(strings, source_language, languages):
    """{language: [(key, reason)]} for `strings`, checking every language in `languages`: the
    non-English languages present in ANY of the three catalogs, so German in one catalog
    requires it in all three."""
    languages = sorted(languages)
    report = {}
    for lang in languages:
        problems = []
        for key, entry in strings.items():
            if key == "":  # Text("") extracts an empty key with nothing to translate
                continue
            english = english_units(entry, source_language) or {(): key}  # key-only: the key is the English
            translated = dict(string_units(entry.get("localizations", {}).get(lang, {})))
            if not any(shown_on_mac(path) for path in translated):
                # Substitution forms alone, or another device's text alone, leave the Mac app
                # nothing to display in this language.
                problems.append((key, "missing"))
                continue
            # English here is always one plain value (fresh extraction, seeded entries and manual
            # keys all write it that way), so German forms are checked against it; a German plural
            # must still include `other`, the form every language requires. The same plain English
            # means a German substitution (%#@name@, with its own argument number) never matches it.
            for path in translated:
                if "plural" in path:
                    group = path[:path.index("plural") + 1]
                    if group + ("other",) not in translated:
                        problems.append((key, f"missing {'/'.join(group + ('other',))}"))
            for path, unit in translated.items():
                where = "/".join(path) or "value"
                if unit.get("state") != "translated":
                    problems.append((key, f"{where} is {unit.get('state')}"))
                reference = english.get(path, english.get(()))
                if reference is None:
                    reference = next(iter(english.values()))
                value = unit.get("value")
                if not isinstance(value, str) or not value.strip():
                    problems.append((key, f"{where} has no value"))
                    continue
                # English comes from the compiler, so it is read strictly ("Step 1 %d of 3"); a
                # line with arguments is formatted whole, so its German is read strictly too, and
                # only a line without them reads "83%ige" as a percentage.
                source = placeholders(reference or "", prose_after_numbers=False)
                german = placeholders(value, prose_after_numbers=not arguments(source))
                if arguments(german) != arguments(source) and not (
                        "plural" in path and path[-1] != "other"
                        and spells_out_a_count(arguments(german), arguments(source))):
                    problems.append((key, f"{where} placeholders differ from English"))
                elif arguments(source) and ("prose",) in german:
                    # With arguments the whole line is formatted, so a lone % would be read as
                    # one ("100 % auf" is `% a`); a literal percent there must be written %%.
                    problems.append((key, f"{where} has a % that must be written %%"))
        if problems:
            report[lang] = problems
    return report


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
        # The screen looks these keys up at run time, hence `translated` English.
        synced["strings"][key] = seeded_entry(committed["strings"].get(key, {}), value,
                                              whats_new_comment(key), source_language)
    flag_changed_translations(committed["strings"], synced["strings"], source_language)
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
    parser.add_argument("--info-plist", type=pathlib.Path, default=INFO_PLIST)
    parser.add_argument("--infoplist-catalog", type=pathlib.Path, default=INFOPLIST_CATALOG)
    parser.add_argument("--servicesmenu-catalog", type=pathlib.Path, default=SERVICESMENU_CATALOG)
    args = parser.parse_args(argv)
    try:
        build = xcode_build()
        if build != PINNED_XCODE_BUILD:
            raise Refused(f"Xcode build {build} is not the pinned {PINNED_XCODE_BUILD}")
        files = collect_inputs(args.derived_data, args.configuration)
        seed = whats_new_seed(args.whats_new_source)
        info_seed, services_seed = info_plist_seeds(args.info_plist)
        # Every catalog is computed and validated before any is written, so a seed, parse or
        # validation refusal leaves all three untouched.
        with tempfile.TemporaryDirectory() as tmp:
            committed, synced = sync(args.catalog, files, pathlib.Path(tmp), seed)
        tables = [
            (args.catalog, committed, synced),
            (args.infoplist_catalog, *sync_seeded_table(args.infoplist_catalog, info_seed, info_plist_comment)),
            (args.servicesmenu_catalog,
             *sync_seeded_table(args.servicesmenu_catalog, services_seed, services_menu_comment)),
        ]
        print(f"inputs: {len(files)} .stringsdata from {len(PRODUCTION_TARGETS)} production targets")
        print(f"What's New: {len(seed)} keys from {args.whats_new_source.name}")
        print(f"{args.info_plist.name}: {len(info_seed)} InfoPlist keys, {len(services_seed)} ServicesMenu keys")
        drifted, added, removed, changed = [], [], [], []
        for path, before, after in tables:
            a, r, c = diff(before, after)
            # The main catalog keeps its original report lines; the others name their table.
            name = "" if path == args.catalog else f"{path.stem} "
            prefix = "keys" if path == args.catalog else path.name
            print(f"{prefix}: committed {len(before['strings'])}, synced {len(after['strings'])}")
            for label, keys in (("added", a), ("removed", r), ("changed", c)):
                for k in keys:
                    print(f"  {label}: {name}{k!r}")
            if a or r or c:
                drifted.append((path, after))
            added += a
            removed += r
            changed += c
        # Completeness is judged on the synced catalogs, before either mode returns: --update
        # reports it (it never supplies a translation), --check fails on it.
        incomplete = False
        languages = sorted({lang for _, _, after in tables for entry in after["strings"].values()
                            for lang in entry.get("localizations", {}) if lang != after.get("sourceLanguage", "en")})
        for path, _, after in tables:
            report = incompleteness(after["strings"], after.get("sourceLanguage", "en"), languages)
            for lang, problems in report.items():
                incomplete = True
                print(f"INCOMPLETE: {path.name}: {lang}: {len(problems)} problem(s)")
                for key, reason in problems[:50]:
                    print(f"  {lang} {key!r}: {reason}")
                if len(problems) > 50:
                    print(f"  ... and {len(problems) - 50} more")
        if not languages:
            print("translations: no language beyond English yet")
        elif not incomplete:
            print(f"translations complete: {', '.join(sorted(languages))}")
        if args.update:
            for path, after in drifted:
                write_catalog(path, after)
                print(f"updated {path}")
            if not drifted:
                print("catalog already in sync")
            if incomplete:
                print("the translations above are incomplete; --update never supplies them, and --check fails until they are added")
            return 0
        if incomplete:
            print("INCOMPLETE: add or review the translations listed above and mark them translated "
                  "(interface-localization.md RULE: new-or-changed-ui-text-updates-the-catalog).")
        if drifted:
            print(f"DRIFT: {len(added)} added, {len(removed)} removed, {len(changed)} changed. To fix, on Xcode "
                  f"{PINNED_XCODE_BUILD}: xcodebuild build -project EnviousWispr.xcodeproj -scheme EnviousWispr-Release "
                  "-configuration Release -derivedDataPath .derivedData/L10n -destination 'generic/platform=macOS', "
                  "then scripts/lib/l10n-catalog-sync.sh --update --derived-data .derivedData/L10n "
                  "--configuration Release, and commit the changed catalogs in Sources/EnviousWispr/Resources/.")
            return 1
        if incomplete:
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
