#!/usr/bin/env python3
"""Environment probes every Live UAT recipe depends on, in one place (#2775).

Each probe answers ONE question about the machine and returns
`(level, detail)` with level in {"ok", "warn", "fail", "info"}. `uat.py preflight` runs them all and prints the result; `uat.py run` re-asks
the volume one before an AUDIO recipe. Nothing here drives the app or blocks it.

Why these probes and not others: every one is a trap this repo already paid
for, written up in `uat-testing.md` FACT: uat-gotchas or `code-tooling.md`
RULE: uat-verdicts-from-app-log, and each was rediscovered by a session that
had not read the row. A probe that prints the answer at the moment it matters
is cheaper than a rule a session has to remember to look up.

Imports nothing heavy at module level, so `--self-test` runs on the hosted
runner (#2426 split). The two macOS-permission probes import PyObjC lazily and
report `fail: PyObjC missing` rather than raising.

    python3 Tests/RuntimeUAT/preflight.py --self-test
"""

import json
import os
import subprocess
import sys

# The speaker is part of the instrument: TTS plays through the system output and
# the app hears it through the microphone. Below this level a take is silent,
# the app correctly reports empty text, and a UAT reads that as a product
# defect. The value was 25 in `faultInjection.py`'s inline probe, which now
# calls here (one owner).
MIN_OUTPUT_VOLUME = 25

TTS_KEY_PATH = os.path.expanduser("~/.enviouswispr-keys/openai-api-key")
BLACKHOLE_DRIVER = "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"


# ------------------------------------------------------------------ parsers --
# Pure functions over the tool output, so the self-test can drive them with
# fixture strings and the live probes stay two lines each.

def parse_volume(stdout):
    """`osascript` prints `<level>,<muted>` e.g. `19,false`. Returns
    (level:int|None, muted:bool|None)."""
    parts = [p.strip() for p in (stdout or "").strip().split(",")]
    if len(parts) != 2 or not parts[0].isdigit() or parts[1] not in ("true", "false"):
        return None, None
    return int(parts[0]), parts[1] == "true"


def classify_volume(level, muted):
    if level is None:
        return "warn", "could not read the system output volume"
    if muted:
        return "warn", f"system output is MUTED (volume {level}); audio recipes will refuse"
    if level < MIN_OUTPUT_VOLUME:
        return "warn", (f"system output volume {level} is below {MIN_OUTPUT_VOLUME}; "
                        "the take would be silent and read as a product defect. Raise it.")
    return "ok", f"output volume {level}, not muted"


def parse_default_output(profiler_json):
    """From `system_profiler SPAudioDataType -json`, the default output device
    as (name, transport) or (None, None)."""
    try:
        items = json.loads(profiler_json)["SPAudioDataType"][0]["_items"]
    except (ValueError, KeyError, IndexError, TypeError):
        return None, None
    for dev in items:
        if dev.get("coreaudio_default_audio_output_device") == "spaudio_yes":
            return dev.get("_name"), dev.get("coreaudio_device_transport")
    return None, None


def classify_output_device(name, transport):
    if name is None:
        return "warn", "could not determine the default output device"
    if transport and "bluetooth" in transport.lower():
        return "warn", (f"default output is Bluetooth ({name}). TTS to a Bluetooth output while the "
                        "input is the built-in mic produced `asr_empty_despite_audio` on 2026-08-2x "
                        "(#2123 family). Route output to the built-in speakers or use the silent "
                        "BlackHole recipe.")
    return "ok", f"default output: {name} ({transport})"


# ------------------------------------------------------------------- probes --

def output_volume():
    """(level, detail) for the system output. Also returns the raw reading so
    callers that REFUSE (an audio recipe about to start) can quote it."""
    try:
        r = subprocess.run(
            ["osascript", "-e", "set s to (get volume settings)",
             "-e", '(output volume of s as text) & "," & (output muted of s as text)'],
            capture_output=True, text=True, timeout=10)
        level, muted = parse_volume(r.stdout if r.returncode == 0 else "")
    except (OSError, subprocess.SubprocessError):
        level, muted = None, None
    lvl, detail = classify_volume(level, muted)
    return lvl, detail, level, muted


def audio_output_ok():
    """True when an audio recipe may start: unmuted and at or above the floor.
    `faultInjection.py` scenarios call this instead of carrying their own probe."""
    lvl, _detail, _level, _muted = output_volume()
    return lvl == "ok"


def default_output_transport():
    try:
        r = subprocess.run(["system_profiler", "SPAudioDataType", "-json"],
                           capture_output=True, text=True, timeout=20)
        name, transport = parse_default_output(r.stdout if r.returncode == 0 else "")
    except (OSError, subprocess.SubprocessError):
        name, transport = None, None
    return classify_output_device(name, transport)


def blackhole_present():
    if os.path.isdir(BLACKHOLE_DRIVER):
        return "info", "BlackHole 2ch installed (silent UAT recipe available: uat-testing.md RULE: silent-uat-via-blackhole-and-select-the-mic-in-the-UI)"
    return "info", "BlackHole not installed; silent-audio UAT unavailable on this machine"


def tts_key_present():
    # Existence only. Never read, print, or fingerprint the content here.
    if os.path.isfile(TTS_KEY_PATH) and os.path.getsize(TTS_KEY_PATH) > 0:
        return "info", "OpenAI TTS key present (echo voice); non-English samples still go through Azure (code-uat.md RULE: tts-azure-for-international)"
    return "warn", "no OpenAI TTS key file; `tts()` falls back to macOS `say` (Evan)"


def accessibility_trusted():
    try:
        from ApplicationServices import AXIsProcessTrusted  # lazy: PyObjC
    except ImportError:
        return "fail", "PyObjC (ApplicationServices) not importable; the harness cannot drive the app"
    try:
        ok = bool(AXIsProcessTrusted())
    except Exception as e:  # noqa: BLE001 - report, never raise, inside a probe
        return "fail", f"AXIsProcessTrusted raised: {e}"
    if ok:
        return "ok", "Accessibility permission granted to this process"
    return "fail", ("Accessibility NOT granted to this shell; every AX read returns nothing. "
                    "System Settings > Privacy & Security > Accessibility")


def screen_recording_granted():
    try:
        from Quartz import CGPreflightScreenCaptureAccess  # lazy: PyObjC
    except ImportError:
        return "warn", "PyObjC (Quartz) not importable; cannot check Screen Recording"
    try:
        ok = bool(CGPreflightScreenCaptureAccess())
    except Exception as e:  # noqa: BLE001
        return "warn", f"CGPreflightScreenCaptureAccess raised: {e}"
    if ok:
        return "ok", "Screen Recording granted (screenshots and `record()` will work)"
    return "warn", ("Screen Recording NOT granted: `screenshot()`/`record()` produce no file. One-time "
                    "founder grant; never retry, never reset permissions (code-uat.md "
                    "RULE: visual-design-verification-needs-a-real-screenshot)")


def proc_start_epoch(pid):
    """Epoch seconds when PID started, or None on any failure. `ps -o lstart=` in
    the C locale gives a stable `Sat Jul 11 15:36:48 2026`.

    Used two ways, both about proving the RUNNING image is the one under test:
    `faultInjection.py` compares it against a build's manifest (a stale process
    left running when a new build is copied over the same path would otherwise
    pass identity), and `uat.py preflight` asks for a Debug-Mode launch banner at
    or after it (a banner from an earlier launch proves nothing about this one)."""
    from datetime import datetime  # local: keep the module import list light
    try:
        raw = subprocess.check_output(
            ["ps", "-o", "lstart=", "-p", str(int(pid))], text=True,
            env={**os.environ, "LC_ALL": "C"}).strip()
        return datetime.strptime(raw, "%a %b %d %H:%M:%S %Y").timestamp()
    except (subprocess.CalledProcessError, ValueError, OSError):
        return None


ALL_PROBES = (
    ("output-volume", lambda: output_volume()[:2]),
    ("output-device", default_output_transport),
    ("accessibility", accessibility_trusted),
    ("screen-recording", screen_recording_granted),
    ("blackhole", blackhole_present),
    ("tts-key", tts_key_present),
)


def run_all():
    """[(name, level, detail)] for every probe, in a fixed order."""
    out = []
    for name, fn in ALL_PROBES:
        try:
            level, detail = fn()
        except Exception as e:  # noqa: BLE001 - a probe that raises is a probe that failed
            level, detail = "fail", f"probe raised: {e}"
        out.append((name, level, detail))
    return out


# ---------------------------------------------------------------- self-test --

def _self_test():
    failures, ran = [], []

    def check(name, cond):
        print(("  PASS  " if cond else "  FAIL  ") + name)
        ran.append(name)
        if not cond:
            failures.append(name)

    check("parse_volume '19,false'", parse_volume("19,false") == (19, False))
    check("parse_volume '65,true'", parse_volume("65,true\n") == (65, True))
    check("parse_volume malformed", parse_volume("execution error: x") == (None, None))
    check("parse_volume empty", parse_volume("") == (None, None))
    check("classify: muted is warn", classify_volume(65, True)[0] == "warn")
    check("classify: 19 is warn (below floor)", classify_volume(19, False)[0] == "warn")
    check("classify: 25 is ok (floor is inclusive)", classify_volume(MIN_OUTPUT_VOLUME, False)[0] == "ok")
    check("classify: unknown is warn", classify_volume(None, None)[0] == "warn")

    fixture = json.dumps({"SPAudioDataType": [{"_items": [
        {"_name": "BlackHole 2ch", "coreaudio_device_transport": "coreaudio_device_type_virtual"},
        {"_name": "AirPods Pro", "coreaudio_device_transport": "coreaudio_device_type_bluetooth",
         "coreaudio_default_audio_output_device": "spaudio_yes"},
        {"_name": "MacBook Pro Speakers", "coreaudio_device_transport": "coreaudio_device_type_builtin"},
    ]}]})
    name, transport = parse_default_output(fixture)
    check("parse_default_output finds the default", name == "AirPods Pro")
    check("bluetooth default output is warn", classify_output_device(name, transport)[0] == "warn")
    check("builtin default output is ok",
          classify_output_device("MacBook Pro Speakers", "coreaudio_device_type_builtin")[0] == "ok")
    check("no default output is warn", classify_output_device(None, None)[0] == "warn")
    check("parse_default_output on garbage", parse_default_output("not json") == (None, None))
    check("parse_default_output on empty items",
          parse_default_output(json.dumps({"SPAudioDataType": [{"_items": []}]})) == (None, None))

    # The probe table is closed and every probe returns a two-tuple with a known level.
    levels = {"ok", "warn", "fail", "info"}
    check("ALL_PROBES has six named probes", [n for n, _ in ALL_PROBES] ==
          ["output-volume", "output-device", "accessibility", "screen-recording", "blackhole", "tts-key"])
    for n, lvl, _d in [(n, l, d) for (n, l, d) in [(n, *fn()) for n, fn in ALL_PROBES if n in ("blackhole", "tts-key")]]:
        check(f"probe {n} returns a known level", lvl in levels)

    total = len(ran)
    if failures:
        print(f"\npreflight self-test: {len(failures)} of {total} FAILED")
        return 1
    print(f"\npreflight self-test: {total}/{total} passed")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    for name, level, detail in run_all():
        print(f"{level.upper():5} {name:17} {detail}")
