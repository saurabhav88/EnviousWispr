"""Per-design geometry via PRESET-AND-RELAUNCH (#2377 chunk 6, Codex option 1).

Three earlier methods failed and all three failed QUIETLY, which is why this one
is built to prove each precondition rather than to assume it:

  - defaults write alone   — the value changed, the app never re-read it
  - driving the picker     — `tap`/`see` navigation is #1296-unreliable; two of
                             three taps silently did not take
  - a SINGLE press         — see below; this is the one that produced a plausible
                             number for one design and `null` for two

**A SINGLE PRESS IS PUSH-TO-TALK AND ENDS IN THE SAME SECOND IT STARTS.** Measured
2026-08-25 from the app's own log across this script's first run:

    [20:39:45] Recording started. Backend: parakeet, streaming=false
    [20:39:45] Debounce timer fired — stopping PTT (no double-press detected)
    [20:39:45] dictation_terminal result=discarded

So the overlay existed for well under a second and the window search was RACING
it. `classic` returned 243x51 because one poll happened to land inside that
window; `levelRail` and `readingWell` returned `overlay: null` from the identical
code against an app behaving identically. **A racing instrument does not fail —
it reports a real measurement, sometimes**, and the two nulls read as a product
defect in two designs rather than as one flaw in the harness.

The fix is not a longer search. It is to hold the pill open: the double press
engages hands-free lock, so the recording stays up until it is stopped, and
`double_press_record_key` refuses on `Hands-free mode activated` rather than on
the press landing. Every row is therefore measured under the SAME lock state,
which is recorded in the report so the numbers are attributable.

`settings-defaults.md` RULE: preset-a-dev-setting-in-the-shared-suite-never-the-dev-domain
says a preset governs the NEXT LAUNCH. So: preset, relaunch the EXISTING bundle
(no rebuild), then measure.

**The window id and pid both change per launch**, so neither is assumed: the
overlay is re-identified each round by LIFECYCLE — the window that APPEARED with
the recording — and the round REFUSES if that is not exactly one window, per
tools-and-apps.md RULE: a-harness-that-ACTS-on-a-shared-resource-must-refuse-not-choose.
The previous revision took `fresh[0]` out of an unordered dict, which is a choice
wearing an identification's clothes.

**PRESET WITH THE APP STOPPED, NEVER WHILE IT RUNS.** A running instance owns
these keys and flushes its in-memory copy on quit, so a value written before the
TERM is overwritten by the app being replaced. Measured 2026-08-25: with the write
first, three relaunches produced three hands-free locks and ZERO
`LIVE_PREVIEW session started` lines.

**THE WIDTH SPREAD IS NOT THE VERDICT, AND BELIEVING IT WAS COST THIS SCRIPT A
ROUND.** Two of three rows can collide and still leave a spread, so a readingWell
row that silently fell back to levelRail passed a check written to catch exactly
that. `isEnabledForGeometry` is `selectedRoute().isSupportedOnThisSystem() &&
isPreviewOn()` (`LivePreviewCoordinator.swift:286`), so the toggle is one of two
conditions; when the capability is absent `resolve` falls back to the no-words
group (`PillDefinition.swift:223`). Each row therefore asserts the group it
actually rendered, from the app's own `LIVE_PREVIEW` line, and the verdict is
`width_spread_ok AND all_rows_correct_group`.
"""

import json
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import phase5_overlay_lifecycle as lc  # noqa: E402
import phase5_record_key as rk  # noqa: E402

UAT = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.validation/runs/2377-phase5-live-uat"
)
SHOTS = UAT / "geometry-relaunch"
SHOTS.mkdir(parents=True, exist_ok=True)
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"
DOMAIN = "com.enviouswispr.app"
BUNDLE = "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-2377-phase5/build/EnviousWispr Local.app"
KEYS = ["livePreviewEnabled", "recordingPillDesignWithoutWords"]

# **WRITE A BOOL AS A BOOL.** `livePreviewEnabled` is read as
# `defaults.object(forKey:) as? Bool` (`SettingsManager.swift:941`), and
# `defaults write <domain> <key> 1` writes an INTEGER, which does not bridge —
# so the app falls back to the shipped default (`false`) and the words capability
# never turns on. Measured 2026-08-25: with `1` the readingWell row produced ZERO
# `LIVE_PREVIEW session started` lines across three runs; the identical row with
# `-bool YES` started a preview session on the first attempt. The `0` rows were
# right by accident, because both a false Bool and a failed bridge answer false.
BOOL_KEYS = {"livePreviewEnabled"}

ROWS = [
    ("classic", {"livePreviewEnabled": False, "recordingPillDesignWithoutWords": "classic"}),
    ("levelRail", {"livePreviewEnabled": False, "recordingPillDesignWithoutWords": "levelRail"}),
    ("readingWell", {"livePreviewEnabled": True}),
]


def write_default(key, value):
    if key in BOOL_KEYS:
        subprocess.run(["defaults", "write", DOMAIN, key, "-bool",
                        "YES" if value else "NO"], check=True)
    else:
        subprocess.run(["defaults", "write", DOMAIN, key, str(value)], check=True)


def expected_read(key, value):
    """What `defaults read` prints back for a value we just wrote."""
    return ("1" if value else "0") if key in BOOL_KEYS else str(value)


def read_default(k):
    r = subprocess.run(["defaults", "read", DOMAIN, k], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def dev_pids():
    out = subprocess.run(["ps", "-eo", "pid=,command="], capture_output=True, text=True).stdout
    needle = "EnviousWispr Local.app/Contents/MacOS/" + "EnviousWispr"
    return sorted(int(l.split(None, 1)[0]) for l in out.splitlines()
                  if needle in l and "/bin/zsh" not in l and "python3" not in l)


def windows(pid):
    import Quartz

    got = {}
    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    for x in info or []:
        if x.get("kCGWindowOwnerPID") != pid:
            continue
        b = x.get("kCGWindowBounds") or {}
        got[x.get("kCGWindowNumber")] = {
            "w": round(b.get("Width", 0)), "h": round(b.get("Height", 0)),
            "x": round(b.get("X", 0)), "y": round(b.get("Y", 0)),
            "layer": x.get("kCGWindowLayer"),
            "onscreen": bool(x.get("kCGWindowIsOnscreen")),
        }
    return got


def visible_overlays(pid):
    """Windows a user could actually see: onscreen, above the normal layer."""
    return {i: m for i, m in windows(pid).items() if m["onscreen"] and (m["layer"] or 0) > 0}


def stop_app(timeout=30.0):
    """TERM every dev instance and wait for the process table to agree it is gone."""
    for p in dev_pids():
        subprocess.run(["kill", "-TERM", str(p)], capture_output=True)
    deadline = time.time() + timeout
    while dev_pids() and time.time() < deadline:
        time.sleep(0.2)  # test-fixture-timer: process-table polling; TERM emits no signal here
    return not dev_pids()


def start_app(timeout=30.0):
    subprocess.run(["open", "-n", BUNDLE], capture_output=True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        pids = dev_pids()
        if len(pids) == 1:
            return pids[0]
        time.sleep(0.2)  # test-fixture-timer: process-table polling for the new instance
    return None


def await_idle(timeout=60.0):
    """Idle by the app's OWN terminal marker, never by elapsed time.

    A relaunch replays any spool the TERM orphaned, so a fresh instance can be
    mid-pipeline for seconds after it appears. `HotkeyService` answers a press in
    that state with `Key press ignored — pipeline is still processing`, which the
    caller then reads as the gesture failing.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        t = LOG.read_text(errors="replace")
        if max(t.rfind("dictation_terminal"), t.rfind("Clipboard cleanup")) > t.rfind("Recording started"):
            return True
        time.sleep(0.25)  # test-fixture-timer: log-polling cadence
    return False


def measure_row(name, pid, since_bytes):
    """Hold the pill open, identify it by lifecycle, measure, then stop.

    Returns (record, error). The recording is stopped on EVERY path that locked
    it — a refusal must not leave the app recording, which is what
    `stop_after_short_hold` exists for.
    """
    before = set(visible_overlays(pid))

    if not rk.double_press_record_key():
        return None, "hands-free did not engage; nothing was locked"

    # Locked, so the pill is up until we stop it. No race to win.
    during, deadline = {}, time.time() + 10
    while time.time() < deadline:
        during = visible_overlays(pid)
        if set(during) - before:
            break
        time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence

    shot = SHOTS / f"{name}.png"
    if set(during) - before:
        subprocess.run(["/usr/sbin/screencapture", "-x", "-o", str(shot)], capture_output=True)

    # THE CAPABILITY, ASSERTED FROM THE APP RATHER THAN INFERRED FROM THE TOGGLE.
    # `isEnabledForGeometry` is `selectedRoute().isSupportedOnThisSystem() &&
    # isPreviewOn()` (LivePreviewCoordinator.swift:286), so writing
    # `livePreviewEnabled=1` is only ONE of two conditions. When the capability is
    # absent, `DesignResolution.resolve` falls back to the no-words group
    # (PillDefinition.swift:223) and renders levelRail — which is why an unasserted
    # readingWell row returned byte-identical geometry to the row before it and
    # looked like two designs that merely share a width.
    # SEEK IN BINARY. `st_size` is BYTES and `read_text()[n:]` slices CHARACTERS,
    # and this log is full of em-dashes at 3 bytes each — so a byte offset applied
    # to a decoded string lands far PAST the intended point and silently discards
    # the lines being looked for. The first version of this check reported
    # `LIVE_PREVIEW: NONE` for a run whose own log carried
    # `LIVE_PREVIEW session started, engine=apple` at the matching second.
    with LOG.open("rb") as fh:
        fh.seek(since_bytes)
        tail = fh.read().decode("utf-8", errors="replace")
    preview_started = "LIVE_PREVIEW session started" in tail

    rk.stop_after_short_hold(0.0)  # waits out the lock cooldown, then stops
    settled = await_idle()

    # AFTER the recording, so the window that VANISHED can be identified. Appearing
    # is not enough: any window opening during the take appears too, and only the
    # disappearance ties a candidate to the recording.
    after = set(visible_overlays(pid))
    life = lc.describe(before, set(during), after)

    err = None
    seen = None
    if not settled:
        # A false idle is BLOCKED, never ignored. Reading a measurement taken while
        # the pipeline is still running attributes one take's geometry to another.
        err = "the app never returned to idle; refusing to report this row"
    elif life["verdict"] != lc.OK:
        err = (f"overlay not uniquely identified: {life['verdict']} "
               f"(appeared {life['appeared']}, gone {life['appeared_and_gone']}, "
               f"still present {life['still_present_after']})")
    elif not shot.exists():
        err = "no screenshot was written; the row has no visual evidence"
    else:
        seen = dict(during[life["window_id"]], id=life["window_id"])

    return {"overlay": seen, "locked": True,
            "preview_session_started": preview_started,
            "screenshot": str(shot) if shot.exists() else None,
            "lifecycle": life,
            "settled": settled}, err


def main():
    snapshot = {k: read_default(k) for k in KEYS}
    report = {"snapshot": snapshot, "rows": {}}
    try:
        for name, settings in ROWS:
            # STOP FIRST, THEN WRITE. A running app owns these keys and flushes its
            # own in-memory copy on quit, so a value written while it is alive is
            # overwritten by the instance being replaced. Measured 2026-08-25: with
            # the write first, three relaunches produced three hands-free locks and
            # ZERO `LIVE_PREVIEW session started` lines, so `livePreviewEnabled=1`
            # never reached the new instance and all three rows resolved the
            # no-words group — levelRail and readingWell returned byte-identical
            # 288x92 and the spread check passed on two distinct values out of three.
            if not stop_app():
                report["rows"][name] = {"error": "an instance survived TERM; refusing to preset"}
                continue
            for k, v in settings.items():
                write_default(k, v)
            observed = {k: read_default(k) for k in settings}
            wanted = {k: expected_read(k, v) for k, v in settings.items()}
            pid = start_app()
            if not pid:
                report["rows"][name] = {"error": "relaunch produced no single instance"}
                continue
            if not await_idle():
                report["rows"][name] = {
                    "pid": pid, "settings": {k: str(v) for k, v in settings.items()},
                    "error": "the app never reached idle before this row; refusing to measure"}
                continue
            since = LOG.stat().st_size

            record, err = measure_row(name, pid, since)
            row = {"pid": pid, "settings": {k: str(v) for k, v in settings.items()},
                   "defaults_after_write": observed,
                   "preset_took": observed == wanted}
            row.update(record or {})
            if not row["preset_took"]:
                err = f"preset did not take: wanted {wanted}, read {observed}"
            wants_words = bool(settings.get("livePreviewEnabled"))
            got_words = bool(row.get("preview_session_started"))
            row["capability_as_expected"] = (wants_words == got_words)
            if not row["capability_as_expected"]:
                err = (f"words capability was {got_words}, expected {wants_words} — "
                       "the design group resolved is not the one this row names")
            if err:
                row["error"] = err
            report["rows"][name] = row
            print(f"  {name}: pid={pid} overlay={(record or {}).get('overlay')} err={err}")
    finally:
        for k, v in snapshot.items():
            if v is None:
                subprocess.run(["defaults", "delete", DOMAIN, k], capture_output=True)
            elif k in BOOL_KEYS:
                subprocess.run(["defaults", "write", DOMAIN, k, "-bool",
                                "YES" if v == "1" else "NO"], check=True)
            else:
                subprocess.run(["defaults", "write", DOMAIN, k, v], check=True)
        report["restored"] = {k: read_default(k) for k in KEYS}
        report["restore_clean"] = report["restored"] == snapshot
        widths = {n: (r.get("overlay") or {}).get("w") for n, r in report["rows"].items()}
        heights = {n: (r.get("overlay") or {}).get("h") for n, r in report["rows"].items()}
        report["widths"] = widths
        report["heights"] = heights
        measured = [w for w in widths.values() if w]
        report["rows_measured"] = len(measured)
        # Every row must have produced a number AND the numbers must differ. A
        # spread computed over two rows when three were asked for is a partial
        # result wearing a verdict's clothes.
        report["width_spread_ok"] = len(measured) == len(ROWS) and len(set(measured)) > 1
        # The spread alone is NOT the verdict. Two of three rows colliding still
        # passes it, which is what let a fallback-to-levelRail readingWell row
        # through. Every row must also have rendered the group it names.
        report["all_rows_correct_group"] = all(
            r.get("capability_as_expected") is True for r in report["rows"].values())
        # `restore_clean` is part of the VERDICT, not a footnote beside it. A run
        # that measured correctly and left the shared settings suite altered has
        # changed what every other worktree's dev build reads on next launch.
        report["verdict"] = ("PASS" if report["width_spread_ok"]
                             and report["all_rows_correct_group"]
                             and report["restore_clean"] else "REFUSED")
        (UAT / "geometry-relaunch.json").write_text(json.dumps(report, indent=2, default=str))
        print(json.dumps({k: report[k] for k in
                          ("widths", "heights", "rows_measured", "width_spread_ok",
                           "all_rows_correct_group", "verdict", "restore_clean")},
                         indent=2))


if __name__ == "__main__":
    main()
