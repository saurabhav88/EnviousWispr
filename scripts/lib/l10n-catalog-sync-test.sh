#!/bin/bash
# #3142: self-test for scripts/lib/l10n-catalog-sync.sh. Builds a fixture
# derived-data tree of hand-written `.stringsdata` for every production target and
# runs the REAL script and the REAL `xcrun xcstringstool` against it. Each negative
# case must fail with its own reason; the clean cases must pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/l10n-catalog-sync.sh"

exec python3 - "$SYNC" <<'PY'
import json, os, pathlib, re, shutil, subprocess, sys, tempfile

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


def run(*args, env=None):
    p = subprocess.run([SYNC, *args], capture_output=True, text=True, env=env)
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


def case(name, want_code, want_text, *, mode="--check", configuration="Release", prepare_update=True, fake_xcode_build=None, remove_catalog=False, **fx):
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        catalog = root / "Localizable.xcstrings"
        committed_catalog(catalog)
        if prepare_update:
            clean = fixture(root / "clean")
            code, out = run("--update", "--derived-data", str(clean), "--configuration", "Release", "--catalog", str(catalog))
            assert code == 0, out
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
        code, out = run(mode, "--derived-data", str(dd), "--configuration", configuration, "--catalog", str(catalog), env=env)
        expect(name, code, out, want_code, want_text)
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
case("changed manual default refuses", 2, "extracted default", manual_override="Enable AI Polishing")
manual_override_key[0] = None
case("missing production input refuses", 2, "no .stringsdata", drop_target="EnviousWisprPipeline")
case("unknown first-party target refuses", 2, "does not know", extra_target="EnviousWisprNewModule")
case("wrong Xcode build refuses", 2, "is not the pinned", fake_xcode_build="00X000")
case("metadata-only target refuses", 2, "no .stringsdata", metadata_only_target="EnviousWisprStorage")
case("missing catalog refuses", 2, "REFUSED", remove_catalog=True)
# Debug extracts #if DEBUG copy that never ships; only Release is an authority.
case("Debug configuration refuses", 2, "invalid choice", configuration="Debug")

print(f"{cases} cases, {len(failures)} failed" + (f": {failures}" if failures else ""))
sys.exit(1 if failures else 0)
PY
