"""Per-design geometry via PRESET-AND-RELAUNCH (#2377 chunk 6).

Each row presets one design, relaunches the existing bundle, holds a recording
open, and measures the overlay. Three facts decide the design and each is a
property of the app rather than of this script:

**A single press is PUSH-TO-TALK and ends in the same second it starts.** The
app answers one with `Recording started` / `Debounce timer fired — stopping PTT`
/ `discarded` at one timestamp, so a window search races a sub-second overlay and
returns a real measurement only sometimes. Rows hold the pill open with the
hands-free double press, which refuses on the app's own
`Hands-free mode activated`.

**A preset governs the NEXT LAUNCH, and the app must be STOPPED when it is
written.** A running instance owns these keys and flushes its in-memory copy on
quit, so a value written while it is alive is overwritten by the instance being
replaced. Owner: settings-defaults.md
RULE: preset-a-dev-setting-in-the-shared-suite-never-the-dev-domain.

**A Bool must be written as a Bool.** `livePreviewEnabled` is read
`object(forKey:) as? Bool ?? default` (`SettingsManager.swift:941`); `defaults
write <dom> <key> 1` stores a STRING, which does not bridge, so the app silently
uses its shipped default.

**THE WIDTH SPREAD IS NOT THE VERDICT.** Two of three rows can collide and still
leave a spread, so a row that fell back to another design would pass a check
written to catch exactly that. `isEnabledForGeometry` is
`selectedRoute().isSupportedOnThisSystem() && isPreviewOn()`
(`LivePreviewCoordinator.swift:286`), and when the capability is absent `resolve`
falls back to the no-words group (`PillDefinition.swift:223`) and renders a
DIFFERENT pill at a plausible size. Each row therefore asserts the group it
actually rendered, from the app's own `LIVE_PREVIEW session started`, and the
verdict is `width_spread_ok AND all_rows_correct_group AND restore_clean`.

The overlay is re-identified per launch by LIFECYCLE — the window that appeared
with the recording and was gone after it — because both pid and window id change.
More than one candidate REFUSES, per tools-and-apps.md
RULE: a-harness-that-ACTS-on-a-shared-resource-must-refuse-not-choose.
"""

import json
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import phase5_overlay_lifecycle as lc  # noqa: E402
import wispr_eyes as rk  # noqa: E402  (record-key helpers; merged in #2425)

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
# never turns on. A `0` row is right by accident, because both a false Bool and a
# failed bridge answer false — only a TRUE value exposes the defect.
BOOL_KEYS = {"livePreviewEnabled"}

# THE PRODUCTION CONTRACTS, pinned. `all_rows_correct_group` proves the words vs
# no-words GROUP and nothing finer — classic and levelRail are both no-words, so
# swapping their two presets satisfies it and still passes. These are the sizes
# the designs declare (`PillDefinition.swift:56`, `:111`): classic 185 wide with
# the fixed 92-point interaction frame, levelRail 288, and the reading well 400
# content-sized from the first frame.
EXPECTED_GEOMETRY = {
    "classic": (185, 92),
    "levelRail": (288, 92),
    "readingWell": (400, 34),
}

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


def screen_is_locked():
    """True when the login window owns the screen.

    A LOCKED SCREEN INVALIDATES A RUN SILENTLY. The app still records, the window
    server still reports pill geometry, and `screencapture` still writes a file of
    the usual size — so a row asserting only that its frames EXIST passes while
    every frame shows the login window. Delivery also degrades to clipboard-only
    for want of any focused text field.

    Owner: tools-and-apps.md FACT: synthetic-escape-does-not-reach-a-carbon-hotkey,
    which prescribes this check before anything else in a Live UAT.
    """
    import Quartz

    d = Quartz.CGSessionCopyCurrentDictionary() or {}
    return bool(d.get("CGSSessionScreenIsLocked"))


def capture_window(window_id, path):
    """Capture ONE window by id, which beats a full-screen shot twice over.

    It frames exactly the subject, so no cropping is needed and nothing else on
    screen can be mistaken for the pill. And it reads the window's own backing
    store rather than the display, so **it works while the screen is LOCKED** —
    verified against a pill created during a locked session: 18 KB of exactly the
    pill, where the full-screen capture of that same moment is the login window.

    Returns True when a file was written.
    """
    r = subprocess.run(["/usr/sbin/screencapture", "-x", "-o", f"-l{window_id}", str(path)],
                       capture_output=True)
    return r.returncode == 0 and pathlib.Path(path).exists()


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

    # CAPTURE WHILE THE PILL IS UP. The window's backing store is torn down when
    # the presentation ends, so a capture taken after the stop returns a blank
    # frame at a constant size — three designs all producing 4450 identical bytes
    # is what that looks like, and it passes a file-exists check.
    shot = SHOTS / f"{name}.png"
    fresh_now = set(during) - before
    captured = capture_window(next(iter(fresh_now)), shot) if len(fresh_now) == 1 else False

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
    # the lines being looked for.
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
    elif not captured:
        err = "no screenshot was written while the pill was up"
    else:
        seen = dict(during[life["window_id"]], id=life["window_id"])

    return {"overlay": seen, "locked": True,
            "preview_session_started": preview_started,
            "screenshot": str(shot) if shot.exists() else None,
            "lifecycle": life,
            "settled": settled}, err


def main():
    snapshot = {k: read_default(k) for k in KEYS}
    # Recorded, not refused: every frame this row takes is captured BY WINDOW ID,
    # which the lock cannot substitute. A row taking a full-SCREEN artifact still
    # has to refuse.
    report = {"snapshot": snapshot, "screen_locked": screen_is_locked(), "rows": {}}
    try:
        for name, settings in ROWS:
            # STOP FIRST, THEN WRITE. A running app owns these keys and flushes its
            # own in-memory copy on quit, so a value written while it is alive is
            # overwritten by the instance being replaced, so the preset never
            # reaches the new instance and every row resolves the default group.
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
        report["all_rows_expected_geometry"] = all(
            tuple((report["rows"].get(name, {}).get("overlay") or {}).get(k)
                  for k in ("w", "h")) == expected
            for name, expected in EXPECTED_GEOMETRY.items())
        report["verdict"] = ("PASS" if report["width_spread_ok"]
                             and report["all_rows_correct_group"]
                             and report["all_rows_expected_geometry"]
                             and report["restore_clean"] else "REFUSED")
        (UAT / "geometry-relaunch.json").write_text(json.dumps(report, indent=2, default=str))
        print(json.dumps({k: report[k] for k in
                          ("widths", "heights", "rows_measured", "width_spread_ok",
                           "all_rows_correct_group", "all_rows_expected_geometry",
                           "verdict", "restore_clean")},
                         indent=2))


if __name__ == "__main__":
    main()
