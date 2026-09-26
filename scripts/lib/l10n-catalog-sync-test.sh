#!/bin/bash
# #3142: self-test for scripts/lib/l10n-catalog-sync.sh. Builds a fixture
# derived-data tree of hand-written `.stringsdata` for every production target and
# runs the REAL script and the REAL `xcrun xcstringstool` against it. Each negative
# case must fail with its own reason; the clean cases must pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/l10n-catalog-sync.sh"

exec python3 - "$SYNC" <<'PY'
import atexit, copy, json, os, pathlib, plistlib, re, shutil, subprocess, sys, tempfile

SYNC = sys.argv[1]
TARGETS = [
    "EnviousWisprCore", "EnviousWisprObservabilityCore", "EnviousWisprStorage",
    "EnviousWisprModelDelivery", "EnviousWisprPostProcessing", "EnviousWisprAudio",
    "EnviousWisprServices", "EnviousWisprFluidAudioBridge", "EnviousWisprASR",
    "EnviousWisprLLM", "EnviousWisprPipeline", "EnviousWisprContacts",
    "EnviousWisprLivePreview", "EnviousWisprWhisperPreviewAdapter", "EnviousWisprAppKit",
    "EnviousWisprDesktopEffects", "EnviousWisprAppLive", "EnviousWispr",
]
MANUAL = {
    "settings.aiPolish.enable.title": "Enable AI Polish",
    "menu.setupRequired.continue": "Setup Required: Continue Setup…",
    "notification.update.ready.body": "Version %@ is ready. Click to install.",
}

# The script's own list must equal this fixture's: a drifted list would make the
# fixture pass while the real run refuses (or the reverse).
listed = re.search(r"PRODUCTION_TARGETS = \[(.*?)\]", pathlib.Path(SYNC).read_text(), re.S).group(1)
assert re.findall(r'"([A-Za-z]+)"', listed) == TARGETS, "self-test target list differs from the script's"

# What's New fixture source (#3142 PR 2E): read by the REAL renderer through the sync.
def whats_new(alpha_bullets=("One", "Two"), alpha_title="Alpha", alpha_desc="Alpha paragraph.", duplicate=False):
    bullets = ", ".join(f'"{b}"' for b in alpha_bullets)
    second_id = "alpha" if duplicate else "beta"
    return f'''
  static let entries: [Entry] = [
    Entry(
      id: "alpha",
      icon: "sparkles",
      title: "{alpha_title}",
      description: "{alpha_desc}",
      bullets: [{bullets}],
      version: "9.9.9"
    ),
    Entry(
      id: "{second_id}",
      icon: "sparkles",
      title: "Beta",
      description: "Beta paragraph.",
      version: "9.9.8"
    ),
  ]
'''


def stringsdata(entries):
    return json.dumps({"source": "/fixture.swift", "tables": {"Localizable": entries}, "version": 1})


def entry(key, value=None):
    e = {"comment": "", "key": key, "location": {"startingColumn": 1, "startingLine": 1}}
    if value is not None:
        e["value"] = value
    return e


def fixture(root, extra_keys=(), drop_manual=None, manual_override=None, drop_target=None, extra_target=None, metadata_only_target=None):
    base = root / "dd/Build/Intermediates.noindex/EnviousWispr.build/Release"
    for t in TARGETS:
        if t == drop_target:
            continue
        d = base / f"{t}.build/Objects-normal/arm64"
        d.mkdir(parents=True)
        # Xcode writes this into every target even with extraction off.
        (d / "ExtractedAppShortcutsMetadata.stringsdata").write_text(stringsdata([]))
        if t == metadata_only_target:
            continue
        entries = [entry(f"{t} plain copy")]
        if t == "EnviousWisprAppKit":
            # A key-only format literal (sync writes a positional English value) and a
            # semantic key with an English default: both are English the code owns.
            entries += [entry("%@ · %@"), entry("fixture.value.key", "Value text")]
            for k, v in MANUAL.items():
                if k == drop_manual:
                    continue
                entries.append(entry(k, manual_override if (manual_override is not None and k == manual_override_key[0]) else v))
            entries += [entry(k) for k in extra_keys]
        (d / "File.stringsdata").write_text(stringsdata(entries))
    if extra_target:
        d = base / f"{extra_target}.build/Objects-normal/arm64"
        d.mkdir(parents=True)
        (d / "File.stringsdata").write_text(stringsdata([entry("x")]))
    # Tuist resource-bundle targets exist in every real build and must be accepted, not read.
    for bundle in ("EnviousWispr_EnviousWisprAppKit", "EnviousWispr_EnviousWisprPostProcessing"):
        (base / f"{bundle}.build").mkdir(parents=True)
    # Test target data must be IGNORED, never merged.
    d = base / "EnviousWisprTests.build/Objects-normal/arm64"
    d.mkdir(parents=True, exist_ok=True)
    (d / "Test.stringsdata").write_text(stringsdata([entry("a string only a test uses")]))
    return root / "dd"


manual_override_key = [None]


def committed_catalog(path):
    strings = {k: {"comment": "fixture manual", "extractionState": "manual",
                   "localizations": {"en": {"stringUnit": {"state": "translated", "value": v}}}}
               for k, v in MANUAL.items()}
    path.write_text(json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"}, indent=2) + "\n")


# Info.plist fixture (#3142 Phase 3) and its two catalogs, written already in sync so a case
# that is not about them sees no drift from them. Each entry carries the fields the sync
# writes; the comment is the fixture's own, which the sync keeps.
PLIST = {
    "CFBundleName": "EnviousWispr",
    "NSMicrophoneUsageDescription": "Microphone for dictation.",
    "NSContactsUsageDescription": "Contacts for names.",
    "NSHumanReadableCopyright": "Copyright fixture.",
    "AppUsageDescription": "Ignored: no NS prefix.",
    "NSServices": [{"NSMenuItem": {"default": "Add to Words"}, "NSMessage": "quickAddWord"}],
}


def seeded(value):
    return {"comment": "fixture", "extractionState": "manual",
            "localizations": {"en": {"stringUnit": {"state": "translated", "value": value}}}}


def plist_catalogs(plist):
    info = {k: seeded(v) for k, v in plist.items()
            if (k.startswith("NS") and k.endswith("UsageDescription")) or k == "NSHumanReadableCopyright"}
    services = {i["NSMenuItem"]["default"]: seeded(i["NSMenuItem"]["default"]) for i in plist.get("NSServices", [])}
    return ({"sourceLanguage": "en", "strings": info, "version": "1.0"},
            {"sourceLanguage": "en", "strings": services, "version": "1.0"})


def write_plist_fixture(root, plist=PLIST, catalogs_from=None):
    root.mkdir(parents=True, exist_ok=True)
    with open(root / "Info.plist", "wb") as fh:
        plistlib.dump(plist, fh)
    info, services = plist_catalogs(catalogs_from if catalogs_from is not None else plist)
    (root / "InfoPlist.xcstrings").write_text(json.dumps(info, indent=2) + "\n")
    (root / "ServicesMenu.xcstrings").write_text(json.dumps(services, indent=2) + "\n")
    return root


SHARED_PLIST = write_plist_fixture(pathlib.Path(tempfile.mkdtemp()))
atexit.register(shutil.rmtree, SHARED_PLIST, True)


def plist_args(root):
    return ["--info-plist", str(root / "Info.plist"), "--infoplist-catalog", str(root / "InfoPlist.xcstrings"),
            "--servicesmenu-catalog", str(root / "ServicesMenu.xcstrings")]


def run(*args, env=None, whats_new_source=None, plist_root=None):
    with tempfile.TemporaryDirectory() as tmp:
        if whats_new_source is None:
            whats_new_source = pathlib.Path(tmp) / "WhatsNewContent.swift"
            whats_new_source.write_text(whats_new())
        p = subprocess.run([SYNC, *args, "--whats-new-source", str(whats_new_source),
                            *plist_args(plist_root or SHARED_PLIST)], capture_output=True, text=True, env=env)
        return p.returncode, p.stdout + p.stderr


failures, cases = [], 0


def expect(name, code, out, want_code, want_text):
    global cases
    cases += 1
    ok = code == want_code and want_text in out
    print(f"{'PASS' if ok else 'FAIL'}  {name}: exit {code}")
    if not ok:
        failures.append(name)
        print(out)


def case(name, want_code, want_text, *, mode="--check", configuration="Release", prepare_update=True, fake_xcode_build=None, remove_catalog=False, edit_committed=None, verify=None, whats_new_source=None, **fx):
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        catalog = root / "Localizable.xcstrings"
        committed_catalog(catalog)
        if prepare_update:
            clean = fixture(root / "clean")
            code, out = run("--update", "--derived-data", str(clean), "--configuration", "Release", "--catalog", str(catalog))
            assert code == 0, out
        wn = None
        if whats_new_source is not None:
            wn = root / "WhatsNewContent.swift"
            wn.write_text(whats_new_source)
        dd = fixture(root / "case", **fx)
        env = None
        if fake_xcode_build:
            # A fake `xcodebuild` first on PATH reports a different active build; the real
            # `xcrun xcstringstool` is never reached because the pin refuses first.
            bindir = root / "fakebin"
            bindir.mkdir()
            fake = bindir / "xcodebuild"
            fake.write_text(f"#!/bin/sh\necho 'Xcode 26.6'\necho 'Build version {fake_xcode_build}'\n")
            fake.chmod(0o755)
            env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}")
        if remove_catalog:
            catalog.unlink()
        if edit_committed:
            data = json.loads(catalog.read_text())
            edit_committed(data["strings"])
            catalog.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        code, out = run(mode, "--derived-data", str(dd), "--configuration", configuration, "--catalog", str(catalog), env=env,
                        whats_new_source=wn)
        expect(name, code, out, want_code, want_text)
        if verify:
            problem = verify(json.loads(catalog.read_text())["strings"])
            if problem:
                failures.append(name)
                print(f"FAIL  {name}: {problem}")
        if name == "clean sync passes":
            data = json.loads(catalog.read_text())
            assert "a string only a test uses" not in data["strings"], "test-target key leaked into the catalog"
            for k in MANUAL:
                assert data["strings"][k]["comment"] == "fixture manual", f"manual object not restored for {k}"
            print("PASS  clean sync: test-target key excluded, manual objects restored")


case("clean sync passes", 0, "catalog in sync")
case("added key is drift", 1, "added: 'a brand new label'", extra_keys=["a brand new label"])
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    catalog = root / "Localizable.xcstrings"
    committed_catalog(catalog)
    dd = fixture(root / "clean", extra_keys=["a label that will be deleted"])
    assert run("--update", "--derived-data", str(dd), "--configuration", "Release", "--catalog", str(catalog))[0] == 0
    code, out = run("--check", "--derived-data", str(fixture(root / "case")), "--configuration", "Release", "--catalog", str(catalog))
    expect("stale key is drift", code, out, 1, "removed: 'a label that will be deleted'")
case("missing manual key refuses", 2, "is not extracted", drop_manual="menu.setupRequired.continue")
manual_override_key[0] = "settings.aiPolish.enable.title"
# A copy change to a semantic key is ordinary drift, and --update writes the code's
# English while keeping the curated object (its comment).
case("changed manual default is drift", 1, "changed: 'settings.aiPolish.enable.title'", manual_override="Enable AI Polishing")
case("update writes a changed manual default, keeps its comment", 0, "updated", mode="--update", manual_override="Enable AI Polishing",
     verify=lambda s: None if (s["settings.aiPolish.enable.title"]["localizations"]["en"]["stringUnit"]["value"] == "Enable AI Polishing"
                               and s["settings.aiPolish.enable.title"]["comment"] == "fixture manual"
                               and s["settings.aiPolish.enable.title"]["extractionState"] == "manual")
     else f"manual entry is {s['settings.aiPolish.enable.title']!r}")


def add_german_to_manual(strings):
    strings["settings.aiPolish.enable.title"]["localizations"]["de"] = {
        "stringUnit": {"state": "translated", "value": "KI-Politur aktivieren"}}


case("changed manual default flags its translation for review", 0, "updated", mode="--update",
     manual_override="Enable AI Polishing", edit_committed=add_german_to_manual,
     verify=lambda s: None if s["settings.aiPolish.enable.title"]["localizations"].get("de", {}).get("stringUnit", {}).get("state") == "needs_review"
     else f"German entry is {s['settings.aiPolish.enable.title']['localizations'].get('de')!r}")


def add_german_plural_to_manual(strings):
    strings["settings.aiPolish.enable.title"]["localizations"]["de"] = {"variations": {"plural": {
        "one": {"stringUnit": {"state": "translated", "value": "KI-Politur aktivieren"}},
        "other": {"stringUnit": {"state": "translated", "value": "KI-Politur aktivieren"}}}}}


case("changed manual default flags nested translations for review", 0, "updated", mode="--update",
     manual_override="Enable AI Polishing", edit_committed=add_german_plural_to_manual,
     verify=lambda s: None if {v["stringUnit"]["state"] for v in s["settings.aiPolish.enable.title"]["localizations"]["de"]["variations"]["plural"].values()} == {"needs_review"}
     else f"German entry is {s['settings.aiPolish.enable.title']['localizations']['de']!r}")
manual_override_key[0] = None


def add_english_plural_to_manual(strings):
    strings["menu.setupRequired.continue"]["localizations"]["en"]["variations"] = {"plural": {}}


case("manual key with English variations refuses", 2, "plain stringUnit", edit_committed=add_english_plural_to_manual)
case("missing production input refuses", 2, "no .stringsdata", drop_target="EnviousWisprPipeline")
case("unknown first-party target refuses", 2, "do not know", extra_target="EnviousWisprNewModule")
case("unknown target without the prefix refuses", 2, "do not know", extra_target="WisprNewModule")
case("wrong Xcode build refuses", 2, "is not the pinned", fake_xcode_build="00X000")
case("metadata-only target refuses", 2, "no .stringsdata", metadata_only_target="EnviousWisprStorage")
case("missing catalog refuses", 2, "REFUSED", remove_catalog=True)


def edit_positional(strings):
    strings["%@ · %@"]["localizations"]["en"]["stringUnit"]["value"] = "%1$@ / %2$@"


def edit_translated_default(strings):
    unit = strings["fixture.value.key"]["localizations"]["en"]["stringUnit"]
    unit["value"], unit["state"] = "Hand-edited text", "translated"


# An incremental sync keeps English already in the catalog in both shapes; the code must win.
case("hand-edited positional English is drift", 1, "changed: '%@ · %@'", edit_committed=edit_positional)
case("hand-edited translated English is drift", 1, "changed: 'fixture.value.key'", edit_committed=edit_translated_default)
case("update restores the code's English", 0, "updated", mode="--update", edit_committed=edit_translated_default,
     verify=lambda s: None if s["fixture.value.key"]["localizations"]["en"]["stringUnit"]["value"] == "Value text"
     else f"English left as {s['fixture.value.key']['localizations']['en']['stringUnit']['value']!r}")
# Debug extracts #if DEBUG copy that never ships; only Release is an authority.
case("Debug configuration refuses", 2, "invalid choice", configuration="Debug")

# --- What's New seed (#3142 PR 2E) ---
WN = "whatsNew."


def seeded_ok(s):
    want = {"whatsNew.alpha.title": "Alpha", "whatsNew.alpha.description": "Alpha paragraph.",
            "whatsNew.alpha.bullet.0": "One", "whatsNew.alpha.bullet.1": "Two",
            "whatsNew.beta.title": "Beta", "whatsNew.beta.description": "Beta paragraph."}
    got = {k: v["localizations"]["en"]["stringUnit"]["value"] for k, v in s.items() if k.startswith(WN)}
    if got != want:
        return f"seeded {got!r}"
    for k in want:
        e = s[k]
        if e["extractionState"] != "manual" or e["localizations"]["en"]["stringUnit"]["state"] != "translated" or "What's New" not in e["comment"]:
            return f"{k} is {e!r}"
    if s["whatsNew.alpha.bullet.1"]["comment"] != "Settings > What's New: point 2 of the list under one feature announcement (entry alpha).":
        return f"bullet comment {s['whatsNew.alpha.bullet.1']['comment']!r}"
    return None


# The clean case above already checks after an update that seeded the fixture; this one
# writes from a catalog with NO What's New keys and inspects every seeded object.
case("update seeds every What's New field as a manual translated entry", 0, "updated", mode="--update",
     edit_committed=lambda s: [s.pop(k) for k in [k for k in s if k.startswith(WN)]], verify=seeded_ok)
case("changed What's New title is drift", 1, "changed: 'whatsNew.alpha.title'", whats_new_source=whats_new(alpha_title="Alpha, renamed"))
case("changed What's New description is drift", 1, "changed: 'whatsNew.alpha.description'", whats_new_source=whats_new(alpha_desc="New paragraph."))
case("changed bullet is drift", 1, "changed: 'whatsNew.alpha.bullet.1'", whats_new_source=whats_new(alpha_bullets=("One", "Two, reworded")))
case("inserted bullet shifts the later ones and adds a key", 1, "added: 'whatsNew.alpha.bullet.2'", whats_new_source=whats_new(alpha_bullets=("One", "New", "Two")))
case("inserted bullet reports the moved English as changed", 1, "changed: 'whatsNew.alpha.bullet.1'", whats_new_source=whats_new(alpha_bullets=("One", "New", "Two")))
case("removed bullet is drift", 1, "removed: 'whatsNew.alpha.bullet.1'", whats_new_source=whats_new(alpha_bullets=("One",)))
case("reordered bullets are drift", 1, "changed: 'whatsNew.alpha.bullet.0'", whats_new_source=whats_new(alpha_bullets=("Two", "One")))
case("a What's New key missing from the catalog is drift", 1, "added: 'whatsNew.beta.title'",
     edit_committed=lambda s: s.pop("whatsNew.beta.title"))
case("a What's New key the source no longer has is drift", 1, "removed: 'whatsNew.gone.title'",
     edit_committed=lambda s: s.__setitem__("whatsNew.gone.title", copy.deepcopy(s["whatsNew.beta.title"])))


def add_german_to_whats_new(strings):
    for key, value in (("whatsNew.alpha.bullet.0", "Eins"), ("whatsNew.alpha.bullet.1", "Zwei"), ("whatsNew.beta.title", "Beta")):
        strings[key]["localizations"]["de"] = {"stringUnit": {"state": "translated", "value": value}}
    strings["whatsNew.alpha.bullet.0"]["comment"] = "curated note"


def review_after_reorder(s):
    de = {k: s[k]["localizations"]["de"]["stringUnit"] for k in ("whatsNew.alpha.bullet.0", "whatsNew.alpha.bullet.1", "whatsNew.beta.title")}
    if [de["whatsNew.alpha.bullet.0"]["state"], de["whatsNew.alpha.bullet.1"]["state"], de["whatsNew.beta.title"]["state"]] != ["needs_review", "needs_review", "translated"]:
        return f"German states {de!r}"
    if s["whatsNew.alpha.bullet.0"]["comment"] != "curated note":
        return f"comment {s['whatsNew.alpha.bullet.0']['comment']!r}"
    if s["whatsNew.alpha.bullet.0"]["localizations"]["en"]["stringUnit"]["value"] != "Two":
        return "English not taken from the source"
    return None


case("reorder keeps translations and comments but flags the moved ones for review", 0, "updated", mode="--update",
     whats_new_source=whats_new(alpha_bullets=("Two", "One")), edit_committed=add_german_to_whats_new, verify=review_after_reorder)


def translated_then_check():
    # Translations the sync did not write must survive a clean check: a German value beside
    # unchanged English is not drift.
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        catalog = root / "Localizable.xcstrings"
        committed_catalog(catalog)
        dd = fixture(root / "clean")
        assert run("--update", "--derived-data", str(dd), "--configuration", "Release", "--catalog", str(catalog))[0] == 0
        data = json.loads(catalog.read_text())
        add_german_to_whats_new(data["strings"])
        catalog.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        code, out = run("--check", "--derived-data", str(dd), "--configuration", "Release", "--catalog", str(catalog))
        # Phase 4: German on three keys only is INCOMPLETE German, but still not drift.
        expect("an unchanged What's New translation is not drift", code, out, 1, "INCOMPLETE")
        if "DRIFT" in out:
            failures.append("an unchanged What's New translation is not drift")
            print("FAIL  a partial German translation was reported as drift")


translated_then_check()
case("a What's New source the renderer refuses stops the run", 2, "What's New seed refused by the renderer",
     whats_new_source=whats_new(duplicate=True))
case("an extracted key in the What's New namespace stops the run", 2, "use the What's New prefix", extra_keys=["whatsNew.alpha.title"])

# --- Completeness (#3142 Phase 4) ---
def german_everywhere(strings, skip=(), value_for=None):
    """German for every key, in state translated, equal to its English (so placeholders match),
    except `skip`; `value_for(key, english)` may override one value."""
    for key, entry in strings.items():
        if key in skip:
            continue
        english = entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", key)
        value = value_for(key, english) if value_for else english
        entry.setdefault("localizations", {})["de"] = {"stringUnit": {"state": "translated", "value": value}}


def completeness_case(name, want_code, want_texts, *, mode="--check", edit=None, extra_keys=(), forbid=(),
                      prepare_keys=None, verify=None):
    """A clean update (with `prepare_keys` extracted, default `extra_keys`), then `edit` on the main
    catalog, then `mode` with `extra_keys` extracted."""
    global cases
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        catalog = root / "Localizable.xcstrings"
        committed_catalog(catalog)
        keys = extra_keys if prepare_keys is None else prepare_keys
        assert run("--update", "--derived-data", str(fixture(root / "clean", extra_keys=keys)), "--configuration",
                   "Release", "--catalog", str(catalog))[0] == 0
        if edit:
            data = json.loads(catalog.read_text())
            edit(data["strings"])
            catalog.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        # German in the main catalog must be in the two Info.plist catalogs too, so a case with
        # German gets plist catalogs that carry it (value = English, placeholders equal).
        tables = write_plist_fixture(root / "plist")
        if any("de" in e.get("localizations", {}) for e in json.loads(catalog.read_text())["strings"].values()):
            for table in ("InfoPlist.xcstrings", "ServicesMenu.xcstrings"):
                data = json.loads((tables / table).read_text())
                german_everywhere(data["strings"])
                (tables / table).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        code, out = run(mode, "--derived-data", str(fixture(root / "case", extra_keys=extra_keys)), "--configuration",
                        "Release", "--catalog", str(catalog), plist_root=tables)
        cases += 1
        ok = code == want_code and all(t in out for t in want_texts) and not any(t in out for t in forbid)
        problem = verify(json.loads(catalog.read_text())["strings"]) if ok and verify else None
        print(f"{'PASS' if ok and not problem else 'FAIL'}  {name}: exit {code}")
        if not ok or problem:
            failures.append(name)
            print(problem or out)


completeness_case("an English-only catalog has nothing to complete", 0, ["no language beyond English yet", "catalog in sync"])
completeness_case("complete German passes", 0, ["translations complete: de", "catalog in sync"], edit=german_everywhere)
completeness_case("a key without German fails", 1, ["INCOMPLETE: Localizable.xcstrings: de", "'fixture.value.key': missing"],
                  edit=lambda s: german_everywhere(s, skip={"fixture.value.key"}), forbid=["DRIFT"])


def german_state(state):
    def edit(strings):
        german_everywhere(strings)
        strings["fixture.value.key"]["localizations"]["de"]["stringUnit"]["state"] = state
    return edit


completeness_case("German in state new fails", 1, ["'fixture.value.key': value is new"], edit=german_state("new"))
completeness_case("German in state needs_review fails", 1, ["'fixture.value.key': value is needs_review"],
                  edit=german_state("needs_review"))
completeness_case("a German value missing a placeholder fails", 1, ["'%@ · %@': value placeholders differ from English"],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: "%@" if k == "%@ · %@" else e))
completeness_case("a translated German unit with no value fails", 1, ["'fixture.value.key': value has no value"],
                  edit=lambda s: (german_everywhere(s), s["fixture.value.key"]["localizations"]["de"]["stringUnit"].pop("value")))
completeness_case("a dynamic width is not the same placeholder as a plain one", 1, ["'%@ · %@': value placeholders differ from English"],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: "%*@ · %@" if k == "%@ · %@" else e))
completeness_case("a whitespace-only German value fails", 1, ["'fixture.value.key': value has no value"],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: "   " if k == "fixture.value.key" else e))
WIDTH = "%1$*2$lld words"
completeness_case("a positional width that reads another argument fails", 1,
                  [f"{WIDTH!r}: value placeholders differ from English"], extra_keys=[WIDTH],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: "%1$*3$lld Wörter" if k == WIDTH else e))


completeness_case("reordered positional placeholders of the same types pass", 0, ["translations complete: de"],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: "%2$@ · %1$@" if k == "%@ · %@" else e))
TYPED = "%1$@ has %2$lld words"
completeness_case("a positional type swap fails", 1, [f"{TYPED!r}: value placeholders differ from English"],
                  extra_keys=[TYPED],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: "%2$@ hat %1$lld Wörter" if k == TYPED else e))
def german_substitution(strings):
    german_everywhere(strings, value_for=lambda k, e: "%#@count@" if k == TYPED else e)
    strings[TYPED]["localizations"]["de"]["substitutions"] = {"count": {
        "argNum": 1, "formatSpecifier": "lld",
        "variations": {"plural": {"other": {"stringUnit": {"state": "translated", "value": "%arg Wörter"}}}}}}


completeness_case("a German plural substitution, whose argument English cannot pin, fails", 1,
                  [f"{TYPED!r}: value placeholders differ from English"], extra_keys=[TYPED], edit=german_substitution)
ODD = "%10$k items"
completeness_case("a placeholder the parser cannot read must match in full", 1,
                  [f"{ODD!r}: value placeholders differ from English"], extra_keys=[ODD],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: "%11$k Einträge" if k == ODD else e))
PROSE = "Right 83% of the time, 5%. Up 2%, (9%), 50%-60% or 100%"
completeness_case("percentages in prose are not placeholders", 0, ["translations complete: de"], extra_keys=[PROSE],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: (
                      "83 % der Fälle richtig, eine 83%ige Quote, 5 %. Plus 2 %, (9 %), 50–60 % oder 100 %" if k == PROSE else e)))
completeness_case("a placeholder added beside a prose percentage fails", 1,
                  [f"{PROSE!r}: value placeholders differ from English"], extra_keys=[PROSE],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: (
                      "%@ der Fälle, 5 %. Plus 2 %, (9 %), 50–60 % oder 100 %" if k == PROSE else e)))
WORDS = "%lld words"
completeness_case("a space-flagged placeholder with a width counts", 1,
                  [f"{WORDS!r}: value placeholders differ from English"], extra_keys=[WORDS],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: "%lld Wörter % 5d" if k == WORDS else e))
ESCAPED = "%lld of 100%% done"
completeness_case("a literal percent in a format string must be written %%", 1,
                  [f"{ESCAPED!r}: value has a % that must be written %%"], extra_keys=[ESCAPED],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: "%lld von 100 % fertig" if k == ESCAPED else e))
AUDIO = "Your audio never leaves this Mac. Only the text goes to %@."
completeness_case("a prose percent the format would read as an argument fails", 1,
                  [f"{AUDIO!r}: value has a % that must be written %%"], extra_keys=[AUDIO],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: (
                      "Deine Audiodaten bleiben zu 100 % auf diesem Mac. Nur der Text geht an %@." if k == AUDIO else e)))
completeness_case("an escaped percent in a format string passes, and %% may become a word", 0, ["translations complete: de"],
                  extra_keys=[AUDIO, ESCAPED],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: {
                      AUDIO: "Deine Audiodaten bleiben zu 100 %% auf diesem Mac. Nur der Text geht an %@.",
                      ESCAPED: "%lld von 100 Prozent fertig"}.get(k, e)))
LEFT = "1 %@ left, 2 %lld, 3 %1$@"
completeness_case("a placeholder after a number still counts", 1,
                  [f"{LEFT!r}: value placeholders differ from English"], extra_keys=[LEFT],
                  edit=lambda s: german_everywhere(s, value_for=lambda k, e: "1 übrig, 2 %lld, 3 %1$@" if k == LEFT else e))


def german_word_plural(one, key=WORDS, other="%lld Wörter"):
    def edit(strings):
        german_everywhere(strings)
        strings[key]["localizations"]["de"] = {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": one}},
            "other": {"stringUnit": {"state": "translated", "value": other}}}}}
    return edit


completeness_case("a German plural form may spell out its number", 0, ["translations complete: de"],
                  extra_keys=[WORDS], edit=german_word_plural("ein Wort"))
completeness_case("the other form may not drop the number", 1, [f"{WORDS!r}: variations/plural/other placeholders differ"],
                  extra_keys=[WORDS], edit=german_word_plural("ein Wort", other="Wörter"))
NAMED = "%@ has %lld words"
completeness_case("a plural form may not drop a name", 1, [f"{NAMED!r}: variations/plural/one placeholders differ"],
                  extra_keys=[NAMED], edit=german_word_plural("hat ein Wort", key=NAMED, other="%@ hat %lld Wörter"))
PAGE = "Page %lld of %lld"
completeness_case("with two numbers a plural form may drop neither", 1, [f"{PAGE!r}: variations/plural/one placeholders differ"],
                  extra_keys=[PAGE], edit=german_word_plural("Seite %1$lld", key=PAGE, other="Seite %1$lld von %2$lld"))
STEP = "Step 1 %d of 3"
completeness_case("a placeholder after a number in English still counts", 1, [f"{STEP!r}: value placeholders differ"],
                  extra_keys=[STEP], edit=lambda s: german_everywhere(s, value_for=lambda k, e: "Schritt 1 von 3" if k == STEP else e))
completeness_case("and German may keep it", 0, ["translations complete: de"],
                  extra_keys=[STEP], edit=lambda s: german_everywhere(s, value_for=lambda k, e: "Schritt 1 %d von 3" if k == STEP else e))


def german_substitutions_only(strings):
    german_everywhere(strings)
    strings["fixture.value.key"]["localizations"]["de"] = {"substitutions": {"count": {
        "argNum": 1, "formatSpecifier": "lld",
        "variations": {"plural": {"other": {"stringUnit": {"state": "translated", "value": "Wert"}}}}}}}


completeness_case("German with only substitution forms is missing", 1, ["'fixture.value.key': missing"],
                  edit=german_substitutions_only)


def german_device(device):
    def edit(strings):
        german_everywhere(strings)
        strings["fixture.value.key"]["localizations"]["de"] = {"variations": {"device": {
            device: {"stringUnit": {"state": "translated", "value": "Wert"}}}}}
    return edit


completeness_case("German only for iPhone is missing on the Mac", 1, ["'fixture.value.key': missing"],
                  edit=german_device("iphone"))
completeness_case("German for the Mac counts", 0, ["translations complete: de"], edit=german_device("mac"))
GONE = "Old wording"


def stale_with_german(strings):
    entry = strings.get(GONE)
    if not entry:
        return f"{GONE!r} was dropped"
    if entry.get("extractionState") != "stale":
        return f"{GONE!r} is {entry.get('extractionState')}, not stale"
    if "de" not in entry.get("localizations", {}):
        return f"{GONE!r} lost its German"
    return None


completeness_case("a removed key with German is kept stale, and the rest stays complete", 0,
                  ["STALE: Localizable.xcstrings: 1 key(s)", repr(GONE), "translations complete: de"], mode="--update",
                  prepare_keys=[GONE], extra_keys=[], edit=german_everywhere, verify=stale_with_german)
completeness_case("a removed key without German is still removed", 0, ["removed: 'Old wording'"], mode="--update",
                  prepare_keys=[GONE], extra_keys=[],
                  verify=lambda s: f"{GONE!r} was kept" if GONE in s else None)


def stale_then_deleted(strings):
    german_everywhere(strings)
    strings[GONE]["extractionState"] = "stale"
    del strings[GONE]


completeness_case("deleting a stale key by hand is in sync", 0, ["catalog in sync"], prepare_keys=[GONE], extra_keys=[],
                  edit=stale_then_deleted, forbid=["STALE", "DRIFT"])


def already_stale(strings):
    german_everywhere(strings)
    strings[GONE]["extractionState"] = "stale"


completeness_case("a stale key already recorded is in sync and needs no completeness", 0,
                  ["catalog in sync", "STALE"], prepare_keys=[GONE], extra_keys=[], edit=already_stale, forbid=["DRIFT"])
completeness_case("the empty key needs no German", 0, ["translations complete: de"], extra_keys=[""],
                  edit=lambda s: german_everywhere(s, skip={""}))


def german_plural(strings, forms=("one", "other")):
    german_everywhere(strings)
    strings["fixture.value.key"]["localizations"]["de"] = {"variations": {"plural": {
        form: {"stringUnit": {"state": "translated", "value": "Wert"}} for form in forms}}}


completeness_case("German plural forms, all translated, pass", 0, ["translations complete: de"], edit=german_plural)


def german_plural_one_new(strings):
    german_plural(strings)
    strings["fixture.value.key"]["localizations"]["de"]["variations"]["plural"]["other"]["stringUnit"]["state"] = "new"


completeness_case("a German plural without its other form fails", 1, ["'fixture.value.key': missing variations/plural/other"],
                  edit=lambda s: german_plural(s, forms=("one",)))
completeness_case("one German plural form not translated fails", 1, ["'fixture.value.key': variations/plural/other is new"],
                  edit=german_plural_one_new)
completeness_case("changed English flags nested German forms for review, and the next check fails", 0,
                  ["updated", "variations/plural/one is needs_review", "never supplies them"], mode="--update",
                  edit=lambda s: (german_plural(s), s["fixture.value.key"]["localizations"]["en"]["stringUnit"].__setitem__("value", "Old text")),
                  verify=lambda s: None if {u["stringUnit"]["state"] for u in s["fixture.value.key"]["localizations"]["de"]["variations"]["plural"].values()} == {"needs_review"}
                  else f"German plural is {s['fixture.value.key']['localizations']['de']!r}")
completeness_case("drift and missing German are both reported", 1, ["DRIFT", "INCOMPLETE", "'a label with no German yet': missing"],
                  prepare_keys=(), extra_keys=["a label with no German yet"], edit=german_everywhere)
completeness_case("update writes drift and reports missing German without supplying it", 0,
                  ["updated", "INCOMPLETE", "never supplies them"], mode="--update", prepare_keys=(),
                  extra_keys=["a label with no German yet"], edit=german_everywhere,
                  verify=lambda s: None if "de" not in s["a label with no German yet"].get("localizations", {})
                  else "the update supplied a translation")


# --- Info.plist tables (#3142 Phase 3) ---
def plist_case(name, want_code, want_texts, *, mode="--check", plist=PLIST, catalogs_from=None, edit_tables=None,
               raw_plist=None, extra_keys=(), verify=None):
    """Runs one mode against a case-owned Info.plist and its catalogs, after a clean update of the
    main catalog. `want_texts` must all appear in the output."""
    global cases
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        catalog = root / "Localizable.xcstrings"
        committed_catalog(catalog)
        assert run("--update", "--derived-data", str(fixture(root / "clean")), "--configuration", "Release",
                   "--catalog", str(catalog))[0] == 0
        tables = write_plist_fixture(root / "plist", plist, catalogs_from)
        if raw_plist is not None:
            (tables / "Info.plist").write_bytes(raw_plist)
        if edit_tables:
            for file_name, edit in edit_tables.items():
                data = json.loads((tables / file_name).read_text())
                edit(data["strings"])
                (tables / file_name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        before = {f: (tables / f).read_bytes() for f in ("InfoPlist.xcstrings", "ServicesMenu.xcstrings")}
        before["Localizable.xcstrings"] = catalog.read_bytes()
        dd = fixture(root / "case", extra_keys=extra_keys)
        code, out = run(mode, "--derived-data", str(dd), "--configuration", "Release", "--catalog", str(catalog),
                        plist_root=tables)
        cases += 1
        ok = code == want_code and all(t in out for t in want_texts)
        problem = None
        if ok and verify:
            after = {f: json.loads((tables / f).read_text())["strings"]
                     for f in ("InfoPlist.xcstrings", "ServicesMenu.xcstrings")}
            after["Localizable.xcstrings"] = catalog.read_bytes()
            after["before"] = before
            after["bytes"] = {f: (tables / f).read_bytes() for f in ("InfoPlist.xcstrings", "ServicesMenu.xcstrings")} | {
                "Localizable.xcstrings": catalog.read_bytes()}
            problem = verify(after)
        print(f"{'PASS' if ok and not problem else 'FAIL'}  {name}: exit {code}")
        if not ok or problem:
            failures.append(name)
            print(problem or out)


def seeded_as_written(t):
    info, services = t["InfoPlist.xcstrings"], t["ServicesMenu.xcstrings"]
    if sorted(info) != ["NSContactsUsageDescription", "NSHumanReadableCopyright", "NSMicrophoneUsageDescription"]:
        return f"InfoPlist keys {sorted(info)!r}"
    if info["NSMicrophoneUsageDescription"]["localizations"]["en"]["stringUnit"] != {"state": "translated", "value": "Microphone for dictation."}:
        return f"microphone entry {info['NSMicrophoneUsageDescription']!r}"
    if info["NSMicrophoneUsageDescription"]["extractionState"] != "manual" or "permission prompt" not in info["NSMicrophoneUsageDescription"]["comment"]:
        return f"microphone entry {info['NSMicrophoneUsageDescription']!r}"
    if "About box" not in info["NSHumanReadableCopyright"]["comment"]:
        return f"copyright comment {info['NSHumanReadableCopyright']['comment']!r}"
    if list(services) != ["Add to Words"] or "Services menu" not in services["Add to Words"]["comment"]:
        return f"ServicesMenu {services!r}"
    return None


EMPTY = {"CFBundleName": "x"}
plist_case("update writes both Info.plist catalogs from the plist, ignoring non-prompt keys", 0,
           ["updated", "InfoPlist.xcstrings", "ServicesMenu.xcstrings"], mode="--update", catalogs_from=EMPTY,
           verify=seeded_as_written)
plist_case("a changed permission prompt is drift", 1, ["changed: InfoPlist 'NSMicrophoneUsageDescription'"],
           plist=dict(PLIST, NSMicrophoneUsageDescription="Microphone, reworded."), catalogs_from=PLIST)
plist_case("a new permission prompt is drift", 1, ["added: InfoPlist 'NSCameraUsageDescription'"],
           plist=dict(PLIST, NSCameraUsageDescription="Camera."), catalogs_from=PLIST)
plist_case("a removed permission prompt is drift", 1, ["removed: InfoPlist 'NSContactsUsageDescription'"],
           plist={k: v for k, v in PLIST.items() if k != "NSContactsUsageDescription"}, catalogs_from=PLIST)


def german_on_microphone(strings):
    strings["NSMicrophoneUsageDescription"]["localizations"]["de"] = {"stringUnit": {"state": "translated", "value": "Mikrofon."}}
    strings["NSContactsUsageDescription"]["localizations"]["de"] = {"stringUnit": {"state": "translated", "value": "Kontakte."}}


def microphone_under_review(t):
    info = t["InfoPlist.xcstrings"]
    mic, contacts = info["NSMicrophoneUsageDescription"], info["NSContactsUsageDescription"]
    if mic["localizations"]["de"]["stringUnit"]["state"] != "needs_review" or mic["comment"] != "fixture":
        return f"microphone {mic!r}"
    if contacts["localizations"]["de"]["stringUnit"]["state"] != "translated":
        return f"contacts {contacts!r}"
    if mic["localizations"]["en"]["stringUnit"]["value"] != "Microphone, reworded.":
        return "English not taken from the plist"
    return None


plist_case("a changed prompt keeps its translation and comment and flags it for review", 0, ["updated"], mode="--update",
           plist=dict(PLIST, NSMicrophoneUsageDescription="Microphone, reworded."), catalogs_from=PLIST,
           edit_tables={"InfoPlist.xcstrings": german_on_microphone}, verify=microphone_under_review)
plist_case("a changed Services title removes the old entry and adds an untranslated one", 1,
           ["removed: ServicesMenu 'Add to Words'", "added: ServicesMenu 'Add to My Words'"],
           plist=dict(PLIST, NSServices=[{"NSMenuItem": {"default": "Add to My Words"}}]), catalogs_from=PLIST)


def german_on_services(strings):
    strings["Add to Words"]["localizations"]["de"] = {"stringUnit": {"state": "translated", "value": "Zu Wörtern"}}


def old_title_stale(t):
    old = t["ServicesMenu.xcstrings"].get("Add to Words")
    if not old or old.get("extractionState") != "stale" or "de" not in old.get("localizations", {}):
        return f"old title {old!r}"
    return None if "Add to My Words" in t["ServicesMenu.xcstrings"] else "new title missing"


plist_case("a changed Services title with German keeps the old entry stale", 0,
           ["STALE: ServicesMenu.xcstrings: 1 key(s)", "added: ServicesMenu 'Add to My Words'"], mode="--update",
           plist=dict(PLIST, NSServices=[{"NSMenuItem": {"default": "Add to My Words"}}]), catalogs_from=PLIST,
           edit_tables={"ServicesMenu.xcstrings": german_on_services}, verify=old_title_stale)
plist_case("two Services items with one title stop the run", 2, ["two Services items titled 'Add to Words'"],
           plist=dict(PLIST, NSServices=PLIST["NSServices"] * 2), catalogs_from=PLIST)
plist_case("a plist with no permission prompts stops the run", 2, ["has no permission prompts"],
           plist=EMPTY, catalogs_from=PLIST)


def nothing_written(t):
    for name, original in t["before"].items():
        if t["bytes"][name] != original:
            return f"{name} was written"
    return None


plist_case("a malformed plist stops an update before any catalog is written", 2, ["REFUSED"], mode="--update",
           raw_plist=b"not a property list", extra_keys=["a label the update would add"], verify=nothing_written)

def german_on_one_prompt(strings):
    strings["NSMicrophoneUsageDescription"]["localizations"]["de"] = {"stringUnit": {"state": "translated", "value": "Mikrofon."}}


def german_moved_width(strings):
    strings["NSMicrophoneUsageDescription"]["localizations"]["de"] = {
        "stringUnit": {"state": "translated", "value": "%@ %*d"}}


plist_case("a dynamic-width placeholder moved past another argument fails", 1,
           ["'NSMicrophoneUsageDescription': value placeholders differ from English"],
           plist=dict(PLIST, NSMicrophoneUsageDescription="%*d %@"), catalogs_from=dict(PLIST, NSMicrophoneUsageDescription="%*d %@"),
           edit_tables={"InfoPlist.xcstrings": german_moved_width})
plist_case("German in the permission catalog requires it in all three catalogs", 1,
           ["INCOMPLETE: InfoPlist.xcstrings: de", "'NSContactsUsageDescription': missing",
            "INCOMPLETE: Localizable.xcstrings: de", "INCOMPLETE: ServicesMenu.xcstrings: de"], catalogs_from=PLIST,
           edit_tables={"InfoPlist.xcstrings": german_on_one_prompt})

print(f"{cases} cases, {len(failures)} failed" + (f": {failures}" if failures else ""))
sys.exit(1 if failures else 0)
PY
