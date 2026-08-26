"""Per-design geometry via PRESET-AND-RELAUNCH (#2377 chunk 6, Codex option 1).

Two earlier methods failed and both failed QUIETLY, which is why this one is
built to prove the design changed rather than to assume it:

  - defaults write alone   — the value changed, the app never re-read it
  - driving the picker     — `tap`/`see` navigation is #1296-unreliable; two of
                             three taps silently did not take

`settings-defaults.md` RULE: preset-a-dev-setting-in-the-shared-suite-never-the-dev-domain
says a preset governs the NEXT LAUNCH. So: preset, relaunch the EXISTING bundle
(no rebuild), then record.

**The window id and pid both change per launch**, so neither is assumed: the
overlay is re-identified each round by lifecycle — the window that appears with a
recording and is gone after it.

The verdict is the WIDTH SPREAD. Three designs that all report one width mean the
preset did not take, whatever any other signal says.
"""

import json
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

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

ROWS = [
    ("classic", {"livePreviewEnabled": "0", "recordingPillDesignWithoutWords": "classic"}),
    ("levelRail", {"livePreviewEnabled": "0", "recordingPillDesignWithoutWords": "levelRail"}),
    ("readingWell", {"livePreviewEnabled": "1"}),
]


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


def relaunch(timeout=30.0):
    for p in dev_pids():
        subprocess.run(["kill", "-TERM", str(p)], capture_output=True)
    deadline = time.time() + timeout
    while dev_pids() and time.time() < deadline:
        time.sleep(0.2)  # test-fixture-timer: process-table polling; TERM emits no signal here
    subprocess.run(["open", "-n", BUNDLE], capture_output=True)
    while time.time() < deadline:
        pids = dev_pids()
        if len(pids) == 1:
            return pids[0]
        time.sleep(0.2)  # test-fixture-timer: process-table polling for the new instance
    return None


def await_idle(timeout=30.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        t = LOG.read_text(errors="replace")
        if max(t.rfind("dictation_terminal"), t.rfind("Clipboard cleanup")) > t.rfind("Recording started"):
            return True
        time.sleep(0.25)  # test-fixture-timer: log-polling cadence
    return False


def main():
    snapshot = {k: read_default(k) for k in KEYS}
    report = {"snapshot": snapshot, "rows": {}}
    try:
        for name, settings in ROWS:
            for k, v in settings.items():
                subprocess.run(["defaults", "write", DOMAIN, k, v], check=True)
            pid = relaunch()
            if not pid:
                report["rows"][name] = {"error": "relaunch produced no single instance"}
                continue

            before = set(windows(pid))
            rk.single_press_record_key()
            # the overlay is whatever became visible with the recording
            seen, deadline = None, time.time() + 10
            while time.time() < deadline:
                now = windows(pid)
                fresh = [(i, m) for i, m in now.items() if m["onscreen"] and m["layer"] > 0]
                if fresh:
                    seen = dict(fresh[0][1], id=fresh[0][0])
                    break
                time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence
            shot = SHOTS / f"{name}.png"
            if seen:
                subprocess.run(["/usr/sbin/screencapture", "-x", "-o", str(shot)], capture_output=True)
            rk.single_press_record_key()
            await_idle()
            report["rows"][name] = {
                "pid": pid, "settings": settings, "overlay": seen,
                "screenshot": str(shot) if seen else None,
                "new_window_ids": sorted(set(windows(pid)) - before),
            }
            print(f"  {name}: pid={pid} overlay={seen}")
    finally:
        for k, v in snapshot.items():
            if v is None:
                subprocess.run(["defaults", "delete", DOMAIN, k], capture_output=True)
            else:
                subprocess.run(["defaults", "write", DOMAIN, k, v], check=True)
        report["restored"] = {k: read_default(k) for k in KEYS}
        report["restore_clean"] = report["restored"] == snapshot
        widths = {n: (r.get("overlay") or {}).get("w") for n, r in report["rows"].items()}
        report["widths"] = widths
        report["width_spread_ok"] = len({w for w in widths.values() if w}) > 1
        (UAT / "geometry-relaunch.json").write_text(json.dumps(report, indent=2, default=str))
        print(json.dumps({k: report[k] for k in ("widths", "width_spread_ok", "restore_clean")}, indent=2))


if __name__ == "__main__":
    main()
