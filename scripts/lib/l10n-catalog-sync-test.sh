#!/bin/bash
# #3142: self-test for scripts/lib/l10n-catalog-sync.sh. Builds a fixture
# derived-data tree of hand-written `.stringsdata` for every production target and
# runs the REAL script and the REAL `xcrun xcstringstool` against it. Each negative
# case must fail with its own reason; the clean cases must pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/l10n-catalog-sync.sh"

exec python3 - "$SYNC" <<'PY'
import copy, json, os, pathlib, re, shutil, subprocess, sys, tempfile

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


def run(*args, env=None, whats_new_source=None):
    with tempfile.TemporaryDirectory() as tmp:
        if whats_new_source is None:
            whats_new_source = pathlib.Path(tmp) / "WhatsNewContent.swift"
            whats_new_source.write_text(whats_new())
        p = subprocess.run([SYNC, *args, "--whats-new-source", str(whats_new_source)], capture_output=True, text=True, env=env)
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
        expect("an unchanged What's New translation is not drift", code, out, 0, "catalog in sync")


translated_then_check()
case("a What's New source the renderer refuses stops the run", 2, "What's New seed refused by the renderer",
     whats_new_source=whats_new(duplicate=True))
case("an extracted key in the What's New namespace stops the run", 2, "use the What's New prefix", extra_keys=["whatsNew.alpha.title"])

print(f"{cases} cases, {len(failures)} failed" + (f": {failures}" if failures else ""))
sys.exit(1 if failures else 0)
PY
