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
from wispr_eyes import connect, find_all_elements, get_attr, nav, perform_action  # noqa: E402,F401

SWITCH = "/opt/homebrew/bin/SwitchAudioSource"
SILENT_DEVICE = "BlackHole 2ch"
RESTORE_FILE = os.path.expanduser("~/.ew-uat-audio-restore.json")
LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")


def input_picker():
    """The Microphone & Media tab's "Input device" control, or None. #3385: found by its
    label in the content (`settings_nav.input_control`), never "the first popup"."""
    try:
        return w._sn.input_control(w._ax(), w._app)
    except w.NavigationError:
        return None


def select_input_device(name):
    """Choose `name` in Dictation Settings > Microphone & Media and PROVE the control took it.

    Delegates to `wispr_eyes.select_input_choice` (`settings_nav.select_input`): it walks the
    control's OWN menu (a whole-app menu-item scan returns every menu on the system), accepts
    a transport-decorated item ("Studio Mic · USB") by its device name, refuses two matches,
    and cancels a stale menu through AX.

    **No Escape key.** The #1946 original pressed Escape through System Events to clear a stale
    menu, and a key goes to whatever app is FRONT: TextEdit answered it with the alert beep the
    founder heard through every run (measured 2026-09-23 with `BeepMeter`: -20.8 dB for that one
    key press, -91 dB without it). A stale menu is cancelled on the picker itself instead, and only
    when one is open.
    """
    w.select_input_choice(auto=False, name=name)


def select_input_choice(choice):
    """Put back a captured `settings_nav.InputChoice`: Auto as Auto, a device by its name, and
    prove the stored UID is the captured one."""
    w.restore_input_choice(choice)


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
        # #3385: the STORED choice (its UID, "" for Auto) with the name the control shows for
        # it, never the display text alone. Unreadable or ambiguous refuses here, before any
        # device is switched.
        self.original_app_device = w.read_input_choice()
        self.applied = False

    def install_restore_handlers(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, lambda *_: (self.restore(), sys.exit(130)))

    def apply(self):
        with open(RESTORE_FILE, "w") as fh:
            json.dump({"output": self.original_output, "input": self.original_input,
                       "app_device": self.original_app_device.to_json()}, fh)
        print(f"ORIGINALS output={self.original_output!r} input={self.original_input!r} "
              f"app_device={self.original_app_device!r}", flush=True)
        self.applied = True
        for kind in ("output", "input"):
            subprocess.run([SWITCH, "-s", SILENT_DEVICE, "-t", kind], capture_output=True)
        select_input_device(SILENT_DEVICE)
        print(f"SILENT    output={_current('output')!r} input={_current('input')!r} "
              f"app_device={w.read_input_choice()!r}", flush=True)

    def restore(self):
        """True when all three devices are verified back. Safe after a PARTIAL `apply`."""
        if not self.applied:
            return True
        self.applied = False
        return _restore(self.original_output, self.original_input, self.original_app_device)


def _restore(output, input_, app_device):
    """`app_device` is the captured `settings_nav.InputChoice`, or None when a restore file
    holds no usable one (an older run kept only the display text, which cannot say which
    device a named choice was): then the app device is reported unrestored for a human."""
    subprocess.run([SWITCH, "-s", output, "-t", "output"], capture_output=True)
    subprocess.run([SWITCH, "-s", input_, "-t", "input"], capture_output=True)
    if app_device is None:
        print("RESTORE WARNING: no captured app device choice; choose it again by hand in "
              "Dictation Settings > Microphone & Media", flush=True)
    else:
        try:
            select_input_choice(app_device)
        except Exception as exc:  # the system devices are put back even if the picker is not
            print(f"RESTORE WARNING: app device not restored: {exc!r}", flush=True)
    try:
        app_now = w.read_input_choice()
    except Exception as exc:
        app_now = None
        print(f"RESTORE WARNING: app device unreadable: {exc!r}", flush=True)
    # All THREE are verified: a failed picker restore would otherwise leave the founder's app
    # listening to BlackHole behind a "verified" line. The app device is verified by its stored
    # UID ("" for Auto; the device Auto resolves to follows the system input just restored).
    app_ok = app_now is not None and app_device is not None and app_now.same_choice(app_device)
    ok = _current("output") == output and _current("input") == input_ and app_ok
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
        try:
            app = w._sn.InputChoice.from_json(saved["app_device"])
        except w._sn.PreferenceError as exc:
            print(f"RESTORE WARNING: {exc}", flush=True)
            app = None
        ok = _restore(saved["output"], saved["input"], app) and ok
    if os.path.exists(AlertSink.FILE):
        with open(AlertSink.FILE) as fh:
            ok = _restore_alert(json.load(fh)) and ok
    sys.exit(0 if ok else 1)
