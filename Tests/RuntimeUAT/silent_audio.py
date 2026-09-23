"""Route a UAT's speech through BlackHole so nothing is audible (uat-testing.md
RULE: silent-uat-via-blackhole-and-select-the-mic-in-the-UI).

Ported, not re-derived, from the #1946 artifact
`docs/feature-requests/issue-1946-artifacts/2026-09-08-live-uat-background-band.py`
(`select_input_device`, `AudioRoute`), so a tracked driver can use it.

    route = AudioRoute()
    route.install_restore_handlers()
    route.apply()
    try: ... finally: route.restore()

Three things the rule requires and this does:
- The app's microphone is chosen through the Settings UI: a `defaults write` never reaches a running
  app and the take silently captures silence. A virtual mic only counts when PINNED, never on Auto.
- The originals are written to an on-disk restore file before anything changes, because a restore
  living only in this process cannot survive SIGKILL: `python3 silent_audio.py restore` replays it.
- Every restore reads the devices back instead of assuming the write landed.
Callers assert `transport=virtual` on each take (`take_was_virtual`).
"""
import json
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import wispr_eyes as w  # noqa: E402
from wispr_eyes import connect, find_all_elements, get_attr, nav, perform_action  # noqa: E402

SWITCH = "/opt/homebrew/bin/SwitchAudioSource"
SILENT_DEVICE = "BlackHole 2ch"
RESTORE_FILE = os.path.expanduser("~/.ew-uat-audio-restore.json")
LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")


def input_picker():
    """The Microphone pane's device picker, or None."""
    for el in find_all_elements(w._app, role="AXPopUpButton"):
        return el
    return None


def select_input_device(name):
    """Choose `name` in Settings -> Microphone and PROVE the picker took it.

    Walks the popup's OWN `AXMenu` (a whole-app menu-item scan returns every menu on the system)
    and cancels a stale menu through AX; the landed check polls the picker's value.

    **No Escape key.** The #1946 original pressed Escape through System Events to clear a stale
    menu, and a key goes to whatever app is FRONT: TextEdit answered it with the alert beep the
    founder heard through every run (measured 2026-09-23 with `BeepMeter`: -20.8 dB for that one
    key press, -91 dB without it). A stale menu is cancelled on the picker itself instead, and only
    when one is open.
    """
    connect()
    if not nav("Microphone"):
        raise RuntimeError("could not navigate to Settings -> Microphone")
    picker = input_picker()
    if picker is None:
        raise RuntimeError("could not find the input-device picker")
    stale = next((k for k in (get_attr(picker, "AXChildren") or [])
                  if get_attr(k, "AXRole") == "AXMenu"), None)
    if stale is not None:
        perform_action(stale, "AXCancel")
    if get_attr(picker, "AXValue") == name:
        return
    perform_action(picker, "AXPress")
    time.sleep(1.2)  # settle: the popup renders its menu with no AX acknowledgement
    menu = next((k for k in (get_attr(picker, "AXChildren") or [])
                 if get_attr(k, "AXRole") == "AXMenu"), None)
    if menu is None:
        raise RuntimeError("the picker opened no menu")
    items = get_attr(menu, "AXChildren") or []
    hits = [i for i in items if (get_attr(i, "AXTitle") or "") == name]
    if len(hits) != 1:
        raise RuntimeError(f"refusing: {len(hits)} items match {name!r} in "
                           f"{[get_attr(i, 'AXTitle') for i in items]}")
    perform_action(hits[0], "AXPress")
    deadline = time.time() + 5.0
    while time.time() < deadline:
        if get_attr(input_picker(), "AXValue") == name:
            return
        time.sleep(0.25)  # settle: poll interval on the picker's own value
    raise RuntimeError(f"pressed {name!r} but the picker still reads "
                       f"{get_attr(input_picker(), 'AXValue')!r}")


def _current(kind):
    return subprocess.run([SWITCH, "-c", "-t", kind], capture_output=True, text=True).stdout.strip()


def take_was_virtual(log_offset):
    """Whether every capture since `log_offset` reported a virtual transport, and at least one did."""
    with open(LOG, "rb") as fh:
        fh.seek(log_offset)
        text = fh.read().decode("utf-8", "replace")
    transports = [line.split("transport=")[1].split()[0]
                  for line in text.splitlines() if "ZERO_PREFIX_MEASURE transport=" in line]
    return bool(transports) and all(t == "virtual" for t in transports), transports


class AudioRoute:
    """Make the drill inaudible, and put everything back even when interrupted."""

    def __init__(self):
        if not os.path.exists(SWITCH):
            raise RuntimeError(f"{SWITCH} is missing; cannot route audio silently")
        self.original_output = _current("output")
        self.original_input = _current("input")
        connect()
        nav("Microphone")
        picker = input_picker()
        self.original_app_device = (get_attr(picker, "AXValue") if picker else None) or "Auto"
        self.applied = False

    def install_restore_handlers(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, lambda *_: (self.restore(), sys.exit(130)))

    def apply(self):
        with open(RESTORE_FILE, "w") as fh:
            json.dump({"output": self.original_output, "input": self.original_input,
                       "app_device": self.original_app_device}, fh)
        print(f"ORIGINALS output={self.original_output!r} input={self.original_input!r} "
              f"app_device={self.original_app_device!r}", flush=True)
        self.applied = True
        for kind in ("output", "input"):
            subprocess.run([SWITCH, "-s", SILENT_DEVICE, "-t", kind], capture_output=True)
        select_input_device(SILENT_DEVICE)
        print(f"SILENT    output={_current('output')!r} input={_current('input')!r} "
              f"app_device={get_attr(input_picker(), 'AXValue')!r}", flush=True)

    def restore(self):
        """True when all three devices are verified back. Safe after a PARTIAL `apply`."""
        if not self.applied:
            return True
        self.applied = False
        return _restore(self.original_output, self.original_input, self.original_app_device)


def _restore(output, input_, app_device):
    subprocess.run([SWITCH, "-s", output, "-t", "output"], capture_output=True)
    subprocess.run([SWITCH, "-s", input_, "-t", "input"], capture_output=True)
    try:
        select_input_device(app_device)
    except Exception as exc:  # the system devices are put back even if the picker is not
        print(f"RESTORE WARNING: app device not restored: {exc!r}", flush=True)
    picker = input_picker()
    app_now = get_attr(picker, "AXValue") if picker else None
    # All THREE are verified: a failed picker restore would otherwise leave the founder's app
    # listening to BlackHole behind a "verified" line.
    ok = _current("output") == output and _current("input") == input_ and app_now == app_device
    print(f"RESTORED  output={_current('output')!r} input={_current('input')!r} "
          f"app_device={app_now!r} verified={ok}", flush=True)
    if ok and os.path.exists(RESTORE_FILE):
        os.remove(RESTORE_FILE)
    return ok




class AlertSink:
    """Send ALL sound, system alert beeps included, to BlackHole for a whole run, and restore it.

    The alert device (`-t system`) is separate from the output device: without this, the
    "nothing can take that key" beep still plays on the speakers during a silent run.
    """

    def __init__(self):
        self.original = {kind: _current(kind) for kind in ("output", "system")}

    FILE = os.path.expanduser("~/.ew-uat-alert-restore.json")

    def apply(self):
        # On disk first, so a SIGKILLed run can be undone: `python3 silent_audio.py restore`.
        with open(self.FILE, "w") as fh:
            json.dump(self.original, fh)
        for kind in self.original:
            subprocess.run([SWITCH, "-s", SILENT_DEVICE, "-t", kind], capture_output=True)
        # Verified, not assumed: the meter is only evidence when both devices really moved.
        return all(_current(kind) == SILENT_DEVICE for kind in self.original)

    def restore(self):
        return _restore_alert(self.original)


def _restore_alert(original):
    for kind, device in original.items():
        subprocess.run([SWITCH, "-s", device, "-t", kind], capture_output=True)
    ok = all(_current(kind) == device for kind, device in original.items())
    print(f"ALERTS    {({k: _current(k) for k in original})} verified={ok}", flush=True)
    if ok and os.path.exists(AlertSink.FILE):
        os.remove(AlertSink.FILE)
    return ok


class BeepMeter:
    """Record BlackHole while a step runs and report its loudest moment in dB.

    A step that plays nothing reads about -91 dB; one macOS alert beep reads about -21 dB
    (measured 2026-09-23 with `osascript -e beep` and `afplay Tink.aiff`). A beep means a key or
    click reached something that refused it, so a driver step that beeps is misfiring.
    Only meaningful while `AlertSink` is applied, and never around a step that plays speech.
    """

    QUIET_CEILING_DB = -60.0

    def __init__(self, path):
        self.path = path
        self.proc = None

    def __enter__(self):
        self.proc = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "avfoundation", "-i", ":0",
             "-y", self.path], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)
        time.sleep(0.6)  # settle: ffmpeg opens the device before it records; no ack to wait on
        return self

    def __exit__(self, *exc):
        time.sleep(0.4)  # settle: a beep that trails the last action is still inside the window
        self.proc.communicate(input=b"q", timeout=10)
        return False

    def max_db(self):
        out = subprocess.run(["ffmpeg", "-hide_banner", "-i", self.path, "-af", "volumedetect",
                              "-f", "null", "-"], capture_output=True, text=True).stderr
        for line in out.splitlines():
            if "max_volume:" in line:
                return float(line.split("max_volume:")[1].split()[0])
        return None


if __name__ == "__main__" and sys.argv[1:] == ["restore"]:
    ok = True
    if os.path.exists(RESTORE_FILE):
        with open(RESTORE_FILE) as fh:
            saved = json.load(fh)
        ok = _restore(saved["output"], saved["input"], saved["app_device"]) and ok
    if os.path.exists(AlertSink.FILE):
        with open(AlertSink.FILE) as fh:
            ok = _restore_alert(json.load(fh)) and ok
    sys.exit(0 if ok else 1)
