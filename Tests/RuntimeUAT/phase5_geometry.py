"""Per-design pill geometry, on screen (#2377 chunk 6, row 1 — owed since Phase 4).

Phase 4 never verified this: it could not get the shared dev-app slot. The rows
are Classic, Level Rail and Reading Well, each with lifecycle-confirmed CGWindow
bounds and a screenshot, plus the 288-point Level Rail width and badge placement
the founder asked about.

**Settings are snapshotted and restored.** The dev build redirects most settings
to `com.enviouswispr.app`, the SHARED suite, so a value left behind changes what
every other worktree's dev build reads on next launch.

The design is read once per FRESH recording and then held — an `NSPanel` cannot
grow mid-recording without a rebuild, and a rebuild is the #930 flicker. So each
row sets the defaults, then starts a NEW recording.

Every wait here reads a real signal: a settings value read back, the window server
reporting the panel on screen, or the app's own terminal marker. None guesses.
"""

import json
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import defaults_store as ds  # noqa: E402  (type-preserving park-and-restore)
import wispr_eyes as rk  # noqa: E402  (record-key helpers; merged in #2425)
import wispr_eyes as w  # noqa: E402

UAT = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.validation/runs/2377-phase5-live-uat"
)
SHOTS = UAT / "geometry"
SHOTS.mkdir(parents=True, exist_ok=True)
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"
DOMAIN = "com.enviouswispr.app"
OVERLAY_ID = 64874

KEYS = ["livePreviewEnabled", "recordingPillDesignWithoutWords"]

# **A BOOL MUST BE WRITTEN AS A BOOL, AND THIS HARNESS WAS NOT.**
# `SettingsManager` reads `livePreviewEnabled` with `object(forKey:) as? Bool`
# (SettingsManager.swift:966). `defaults write <dom> <key> 1` stores a STRING, so
# that cast yields nil and the app silently falls back to the SHIPPED DEFAULT --
# `defaults read` still prints back the `1` you wrote, so nothing here looks
# wrong. With the shipped default now ON (2026-09-01) the two `False` rows would
# have recorded reading-well geometry while labelled levelRail and classic, which
# is the exact evidence this harness exists to produce.
# Owner of the trap, not restated: .claude/knowledge/settings-defaults.md
# RULE: preset-a-dev-setting-in-the-shared-suite-never-the-dev-domain.
BOOL_KEYS = {"livePreviewEnabled"}

ROWS = [
    ("readingWell", {"livePreviewEnabled": True}),
    ("levelRail", {"livePreviewEnabled": False, "recordingPillDesignWithoutWords": "levelRail"}),
    ("classic", {"livePreviewEnabled": False, "recordingPillDesignWithoutWords": "classic"}),
]


def read_default(key):
    r = subprocess.run(["defaults", "read", DOMAIN, key], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def write_default(key, value):
    """Write one row value, in the spelling the app's own reader accepts.

    `SettingsManager` reads `livePreviewEnabled` with `object(forKey:) as? Bool`
    (SettingsManager.swift:966). `defaults write <dom> <key> 1` stores a STRING,
    so that cast yields nil and the app falls back to the SHIPPED DEFAULT --
    while `defaults read` still prints the `1` back, so nothing looks wrong. With
    the shipped default ON since 2026-09-01, the two `False` rows below would
    have captured reading-well geometry under the labels levelRail and classic,
    which is the evidence this harness exists to produce.
    """
    if key in BOOL_KEYS:
        ds.write_typed(DOMAIN, key, value, "-bool")
        return
    ds.write_typed(DOMAIN, key, value, "-string")


def expected_readback(key, value):
    """What `defaults read` prints for a value this harness just wrote.

    A bool comes back as `1`/`0`, never as `true`/`false`, so comparing the
    read-back against the value as written would fail forever on exactly the keys
    the writer above was fixed for.
    """
    if key in BOOL_KEYS:
        return "1" if value else "0"
    return str(value)


def apply_settings(settings, timeout=5.0):
    """Write, then READ BACK until the value is what we wrote.

    A signal, not a wait: `defaults` is a separate process writing a shared
    suite, and the honest question is whether the value landed — which the value
    itself answers.
    """
    for k, v in settings.items():
        write_default(k, v)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if all(read_default(k) == expected_readback(k, v) for k, v in settings.items()):
            return True
        time.sleep(0.05)  # test-fixture-timer: read-back polling cadence
    return False


def bounds(pid):
    import Quartz

    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    for x in info or []:
        if x.get("kCGWindowOwnerPID") == pid and x.get("kCGWindowNumber") == OVERLAY_ID:
            b = x.get("kCGWindowBounds") or {}
            return {
                "x": round(b.get("X", 0)), "y": round(b.get("Y", 0)),
                "w": round(b.get("Width", 0)), "h": round(b.get("Height", 0)),
                "onscreen": bool(x.get("kCGWindowIsOnscreen")),
            }
    return None


def await_idle(timeout=25.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        t = LOG.read_text(errors="replace")
        if max(t.rfind("dictation_terminal"), t.rfind("Clipboard cleanup")) > t.rfind("Recording started"):
            return True
        time.sleep(0.25)  # test-fixture-timer: log-polling cadence; the app emits no readiness event
    return False


def await_visible(pid, timeout=8.0):
    """Wait for the lifecycle-confirmed overlay to be on screen — a signal from
    the window server, not a duration."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        b = bounds(pid)
        if b and b["onscreen"] and b["w"] > 0:
            return b
        time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence
    return None


def main():
    pid = int(sys.argv[1])
    # TYPE-PRESERVING, not text-only. `defaults read` prints a boolean `false`
    # and a string "0" identically, so a text-only park-and-restore silently
    # rewrites the developer's own preference into a different plist type -- and
    # a text-only restore check cannot see it. Owner: defaults_store.
    snapshot = ds.snapshot(DOMAIN, KEYS)
    report = {"pid": pid, "settings_snapshot": snapshot, "rows": {}}
    print("snapshot:", snapshot)

    try:
        for name, settings in ROWS:
            await_idle()
            report.setdefault("applied", {})[name] = apply_settings(settings)

            rk.single_press_record_key()
            seen = await_visible(pid)
            shot = SHOTS / f"{name}.png"
            if seen:
                subprocess.run(["/usr/sbin/screencapture", "-x", "-o", str(shot)], capture_output=True)
            rk.single_press_record_key()  # stop
            report["rows"][name] = {
                "settings": settings,
                "bounds": seen,
                "screenshot": str(shot) if seen else None,
            }
            print(f"  {name}: {seen}")
    finally:
        landed = ds.restore(DOMAIN, snapshot)
        report["settings_restored"] = {k: ds.read_typed(DOMAIN, k) for k in KEYS}
        report["restore_clean"] = all(landed.values())
        report["restore_failed_keys"] = [k for k, good in landed.items() if not good]
        (UAT / "geometry.json").write_text(json.dumps(report, indent=2, default=str))
        print(json.dumps(report, indent=2, default=str)[:2000])


if __name__ == "__main__":
    main()
