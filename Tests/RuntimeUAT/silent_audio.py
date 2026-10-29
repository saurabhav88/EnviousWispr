"""Route a UAT's speech through BlackHole so nothing is audible (uat-testing.md
RULE: silent-uat-via-blackhole-and-select-the-mic-in-the-UI).

Ported, not re-derived, from the #1946 artifact
`docs/feature-requests/issue-1946-artifacts/2026-09-08-live-uat-background-band.py`
(`AudioRoute`), so a tracked driver can use it.

    route = AudioRoute()
    route.install_restore_handlers()
    route.apply()
    try: ... finally: route.restore()

Three things the rule requires and this does:
- The app's microphone is pinned through the #3765 dev control door (`AppMic`, #3990), which runs
  the app's own `chooseInputDevice` inside the running app: a `defaults write` never reaches a
  running app and the take silently captures silence, and the Settings route opened the
  Microphone list about 8 times per rig. A virtual mic only counts when PINNED, never on Auto.
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


BLACKHOLE_UID = "BlackHole2ch_UID"
OVERRIDE, SELECTED = "preferredInputDeviceIDOverride", "selectedInputDeviceUID"


def connected_input_uids():
    """The UIDs of every input device the system lists now (`SwitchAudioSource`, one JSON
    object per line). Raises rather than returning an empty list: BlackHole is always there."""
    out = subprocess.run([SWITCH, "-a", "-t", "input", "-f", "json"], capture_output=True,
                         text=True)
    uids = [json.loads(line)["uid"] for line in out.stdout.splitlines() if line.strip()]
    if out.returncode != 0 or not uids:
        raise RuntimeError(f"could not list input devices: {out.stderr.strip() or 'none listed'}")
    return uids


class AppMic:
    """The app's stored microphone choice: both keys `SettingsManager.chooseInputDevice`
    writes (#3990). Read and written through the dev control door, inside the running app,
    so no Settings click is needed (the Microphone list used to open about 8 times per rig).

    The reconciler (`InputDevicePreferencePolicy`) keeps three shapes stable: (X, X) with X
    connected, ("", "") for Auto, and ("", Y) with Y away (a pinned device that left; Y is
    pinned again when it returns). Those are the shapes this captures; anything else refuses
    before a device moves."""

    def __init__(self, override, selected):
        self.override, self.selected = override, selected

    def __eq__(self, other):
        return (isinstance(other, AppMic)
                and (self.override, self.selected) == (other.override, other.selected))

    def __repr__(self):
        return f"AppMic(override={self.override!r}, selected={self.selected!r})"

    @classmethod
    def read(cls, client):
        """Both keys from ONE `settings list` reply, so they are one snapshot."""
        values = client.values(OVERRIDE, SELECTED)
        if not all(isinstance(values[k], str) for k in (OVERRIDE, SELECTED)):
            raise RuntimeError(f"the app's microphone keys are not strings: {values}")
        return cls(values[OVERRIDE], values[SELECTED])

    def to_json(self):
        return {"override": self.override, "selected": self.selected}

    @classmethod
    def from_json(cls, data):
        """A journal entry, or the pre-#3990 `InputChoice` shape (`{"uid", "shown"}`, restored
        by the picker, which wrote both keys to that UID)."""
        if isinstance(data, dict) and {"override", "selected"} <= set(data):
            return cls(data["override"], data["selected"])
        if isinstance(data, dict) and isinstance(data.get("uid"), str):
            return cls(data["uid"], data["uid"])
        return None

    def check_restorable(self, connected):
        """Refuse a capture that could not be put back exactly. Read-only: the same rule as
        `MicrophoneChoiceValidation.isSelectable` (Auto, or a connected device)."""
        if self.override and self.selected != self.override:
            raise RuntimeError(f"{self!r} is not a shape the app keeps; refusing before any "
                               "device moves")
        if self.override and self.override not in connected:
            raise RuntimeError(f"the app's microphone {self.override!r} is not connected, so it "
                               "could not be chosen again; refusing before any device moves")

    def restore(self, client):
        """The owner write (both keys), then, for ("", Y) only, the remembered device: the
        reconciler's own stable state, which the owner cannot express. The override is never
        forced: a missing device pinned that way would silently record from another (#3479)."""
        client.set(OVERRIDE, self.override)
        if not self.override and self.selected:
            client.set(SELECTED, self.selected, force=True)

    def restored_by(self, now, connected):
        """Whether `now` is this choice put back. For ("", Y) the reconciler may already have
        pinned Y if it came back meanwhile; (Y, Y) then counts, and says so."""
        if now == self:
            return True, "exact"
        if not self.override and self.selected in connected and now == AppMic(self.selected,
                                                                                self.selected):
            return True, f"{self.selected!r} came back and the app pinned it again"
        return False, "differs"


def refuse_stale_journal(path):
    """Refuse a setup while a previous run's restore file exists: overwriting it would replace
    the founder's real devices or settings with this run's BlackHole values (#3990)."""
    if os.path.exists(path):
        raise RuntimeError(f"{path} is left from an earlier run that was not put back; run "
                           "`python3 Tests/RuntimeUAT/silent_audio.py restore` first")


def _current(kind):
    return subprocess.run([SWITCH, "-c", "-t", kind], capture_output=True, text=True).stdout.strip()


def _device_snapshot(kind):
    """Capture identity before routing changes; a failed read must never become an original.
    The numeric Core Audio id is temporary. Only name and UID belong in the journal (#4181)."""
    out = subprocess.run([SWITCH, "-c", "-t", kind, "-f", "json"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"could not read {kind} device: {out.stderr.strip()}")
    device = json.loads(out.stdout)
    if (not isinstance(device, dict) or device.get("type") != kind
            or not all(isinstance(device.get(key), str) and device[key].strip()
                       for key in ("name", "uid"))):
        raise RuntimeError(f"could not read {kind} device identity: {device!r}")
    return {key: device[key] for key in ("name", "uid")}


def _restore_device(kind, saved):
    """Restore one system device, with readback, without preventing another restore attempt.
    Older journals contain only a name. A new identity record never falls back to that name:
    Bluetooth name selection can report success while leaving the route on BlackHole (#4181)."""
    try:
        if isinstance(saved, str) and saved.strip():
            flag, value = "-s", saved
        elif (isinstance(saved, dict)
              and all(isinstance(saved.get(key), str) and saved[key].strip()
                      for key in ("name", "uid"))):
            flag, value = "-u", saved["uid"]
        else:
            raise ValueError(f"unusable saved device: {saved!r}")
        out = subprocess.run([SWITCH, flag, value, "-t", kind],
                             capture_output=True, text=True)
        now = _device_snapshot(kind)
        # -u also accepts UID substrings. Exact readback, not the switcher's success line,
        # determines whether the original device is back. Keep the name check as well.
        matches = now["name"] == saved if flag == "-s" else now == {
            "name": saved["name"], "uid": saved["uid"]}
        ok = out.returncode == 0 and matches
        print(f"DEVICE    {kind} saved={saved!r} now={now!r} verified={ok}", flush=True)
        if out.returncode != 0:
            print(f"RESTORE WARNING: {kind} selection failed: {out.stderr.strip()}", flush=True)
        return ok
    except Exception as exc:
        print(f"RESTORE WARNING: {kind} not restored: {exc!r}", flush=True)
        return False


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

    def __init__(self, client=None):
        """`client`: a `dev_control.DoorClient` for the app under test; default the one
        `wispr_eyes.connect()` drives. Refuses, before anything moves, when this caller may
        not change the shared dev app or the app's microphone could not be put back."""
        if not os.path.exists(SWITCH):
            raise RuntimeError(f"{SWITCH} is missing; cannot route audio silently")
        refuse_stale_journal(RESTORE_FILE)
        self.client = client if client is not None else w.door()
        self.client.check_owner()
        self.original_output = _device_snapshot("output")
        self.original_input = _device_snapshot("input")
        self.original_app_device = AppMic.read(self.client)
        self.original_app_device.check_restorable(connected_input_uids())
        self.applied = False

    def install_restore_handlers(self):
        """An interrupt UNWINDS (SystemExit 130); it never restores here. Every caller restores
        in its own `finally`, and only after it proved the take stopped (`end_take_then_restore`,
        `TAKE_STUCK`), so the founder's microphone is never handed to a take that may still be
        recording (#3991). This handler used to restore first, ahead of that proof."""
        def _unwind(*_):
            raise SystemExit(130)

        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, _unwind)

    def apply(self):
        with open(RESTORE_FILE, "w") as fh:
            json.dump({"output": self.original_output, "input": self.original_input,
                       "app_device": self.original_app_device.to_json()}, fh)
        print(f"ORIGINALS output={self.original_output!r} input={self.original_input!r} "
              f"app_device={self.original_app_device!r}", flush=True)
        self.applied = True
        for kind in ("output", "input"):
            subprocess.run([SWITCH, "-s", SILENT_DEVICE, "-t", kind], capture_output=True)
        # The app's own owner (`chooseInputDevice`) through the door, inside the running app:
        # a virtual mic counts only when PINNED, never on Auto. take_gate still proves each
        # take captured from it (`transport=virtual`).
        self.client.set(OVERRIDE, BLACKHOLE_UID)
        print(f"SILENT    output={_current('output')!r} input={_current('input')!r} "
              f"app_device={AppMic.read(self.client)!r}", flush=True)

    def restore(self):
        """True when all three devices are verified back. Safe after a PARTIAL `apply`."""
        if not self.applied:
            return True
        self.applied = False
        return _restore(self.original_output, self.original_input, self.original_app_device,
                        self.client)


def _restore(output, input_, app_device, client):
    """Put back the system output and input, then the app's microphone. Each is attempted
    whatever happened to the others, and all are verified. `app_device` is None when a restore
    file holds no usable choice; `client` is None when the app could not be reached: either
    way the app's microphone is reported unrestored and the file is kept."""
    output_ok = _restore_device("output", output)
    input_ok = _restore_device("input", input_)
    app_ok, how, app_now = False, "not attempted", None
    if app_device is None:
        print("RESTORE WARNING: no captured app microphone; choose it again by hand in "
              "Dictation Settings > Microphone", flush=True)
    elif client is None:
        print("RESTORE WARNING: the app could not be reached; its microphone was not put "
              f"back to {app_device!r}", flush=True)
    else:
        try:
            client.follow_relaunch()  # a driver may have restarted the same build on purpose
            app_device.restore(client)
        except Exception as exc:  # the system devices are put back even if the app is not
            print(f"RESTORE WARNING: app microphone not restored: {exc!r}", flush=True)
        try:
            app_now = AppMic.read(client)
            app_ok, how = app_device.restored_by(app_now, connected_input_uids())
        except Exception as exc:
            print(f"RESTORE WARNING: app microphone unreadable: {exc!r}", flush=True)
    # All THREE are verified: a failed app restore would otherwise leave the founder's app
    # listening to BlackHole behind a "verified" line.
    ok = output_ok and input_ok and app_ok
    print(f"RESTORED  output={output!r} input={input_!r} "
          f"app_device={app_now!r} ({how}) verified={ok}", flush=True)
    if ok and os.path.exists(RESTORE_FILE):
        os.remove(RESTORE_FILE)
    return ok


class AppSounds:
    """Quiet the app for a rig's takes, through the door, and put it back (#3990).

    On BlackHole the start and stop sounds land on the loopback the take records, and
    "Turn down other audio" lowers the clip the rig plays through it; the harness's own
    input-warning chime lands there too (uat-testing.md, #3834 gotchas row). The originals
    are journaled before the first change, so `python3 silent_audio.py restore` can undo a
    killed run."""

    QUIET = {"playRecordingSounds": False, "otherAudioWhileDictating": "nothing"}
    FILE = os.path.expanduser("~/.ew-uat-app-sounds-restore.json")

    def __init__(self, client):
        self.client = client
        self.original = None
        self.input_warn = None

    def apply(self):
        refuse_stale_journal(self.FILE)
        original = self.client.values(*self.QUIET)
        with open(self.FILE, "w") as fh:
            json.dump(original, fh)
        self.original, self.input_warn = original, w._INPUT_WARN
        w._INPUT_WARN = False
        for key, value in self.QUIET.items():
            self.client.set(key, value)
        now = self.client.values(*self.QUIET)
        if now != self.QUIET:
            raise RuntimeError(f"the app's sounds read {now}, not {self.QUIET}")
        print(f"QUIET     app sounds {original} -> {now}", flush=True)

    def restore(self):
        """True when the originals are verified back, or nothing was changed."""
        if self.original is None:
            return True
        if self.input_warn is not None:
            w._INPUT_WARN = self.input_warn
        original, self.original = self.original, None
        return _restore_sounds(original, self.client)


def _restore_sounds(original, client):
    ok = True
    try:
        client.follow_relaunch()  # a driver may have restarted the same build on purpose
    except Exception as exc:
        print(f"RESTORE WARNING: app sounds not restored: {exc!r}", flush=True)
        return False
    for key, value in original.items():
        try:
            client.set(key, value)
        except Exception as exc:  # each setting is attempted whatever happened to the other
            print(f"RESTORE WARNING: {key} not restored: {exc!r}", flush=True)
            ok = False
    try:
        now = client.values(*original)
    except Exception as exc:
        now = None
        print(f"RESTORE WARNING: app sounds unreadable: {exc!r}", flush=True)
    ok = ok and now == original
    print(f"SOUNDS    {now} verified={ok}", flush=True)
    if ok and os.path.exists(AppSounds.FILE):
        os.remove(AppSounds.FILE)
    return ok


class AlertSink:
    """Send ALL sound, system alert beeps included, to BlackHole for a whole run, and restore it.

    The alert device (`-t system`) is separate from the output device: without this, the
    "nothing can take that key" beep still plays on the speakers during a silent run.
    """

    def __init__(self):
        self.original = {kind: _device_snapshot(kind) for kind in ("output", "system")}
        self.applied = False

    FILE = os.path.expanduser("~/.ew-uat-alert-restore.json")

    def apply(self):
        refuse_stale_journal(self.FILE)
        # On disk first, so a SIGKILLed run can be undone: `python3 silent_audio.py restore`.
        self.applied = True
        with open(self.FILE, "w") as fh:
            json.dump(self.original, fh)
        for kind in self.original:
            subprocess.run([SWITCH, "-s", SILENT_DEVICE, "-t", kind], capture_output=True)
        # Verified, not assumed: the meter is only evidence when both devices really moved.
        return all(_current(kind) == SILENT_DEVICE for kind in self.original)

    def restore(self):
        """True when restored and verified, or never applied (an unapplied sink must not
        replay its readings over a journal it refused to overwrite)."""
        if not self.applied:
            return True
        self.applied = False
        return _restore_alert(self.original)


def _restore_alert(original):
    restored = [_restore_device(kind, device) for kind, device in original.items()]
    ok = all(restored)
    print(f"ALERTS    saved={original!r} verified={ok}", flush=True)
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


def _app_client():
    """The door of the running dev app for recovery, or None (reported) when it cannot be
    reached: the system devices are put back either way."""
    try:
        return w.door()
    except BaseException as exc:  # wispr_eyes.connect() exits when the app is not running
        print(f"RESTORE WARNING: the dev app's control door is unreachable: {exc!r}", flush=True)
        return None


def player_running():
    """Whether a test sound may still be playing: any `afplay`. A rig plays its clips with it,
    and a killed run can leave one playing into BlackHole."""
    return subprocess.run(["pgrep", "-x", "afplay"], capture_output=True).returncode == 0


# The app's driver states that cannot be capturing (`DevControlDispatcher.project`). Anything
# else (recording, a model loading for a start, transcribing right after one) counts as maybe
# listening, so a recovery waits rather than hand it the founder's microphone.
_AT_REST = {"idle", "complete", "error", "advisory"}


def app_may_be_listening(client):
    """True unless the app is proven not to be capturing: no dev app running at all, or the
    door says its driver is at rest. An app that runs but cannot be asked counts as listening."""
    if client is None:
        import dev_control
        # Dev builds only: the shipped app never had its microphone pinned by a rig.
        return any(exe.endswith(dev_control.DEV_EXECUTABLE_SUFFIX)
                   for exe in w.running_enviouswispr_instances().values())
    try:
        state = (client.status().get("activeDriver") or {}).get("state")
    except Exception as exc:
        print(f"RESTORE WARNING: could not ask the app whether it is recording: {exc!r}",
              flush=True)
        return True
    return state not in _AT_REST


def recover(player=None, listening=None):
    """Replay every journal a killed run left. Ownership first, before any device or journal
    changes; each journal is replayed whatever happened to the others and is removed only once
    its own part verified.

    A killed run's take registration died with it, so idleness is proven here, independently
    (#3991), with the same policy as `AudioRig._restore_all`: a test sound still playing keeps
    every device on BlackHole; an app that may still be recording gets its speakers and alert
    sounds back while the system input and its own microphone stay on BlackHole, so it can only
    hear silence. Both leave their journals for the next run of this command. `player` and
    `listening` are self-test seams."""
    import dev_control
    dev_control.check_owner()
    ok = True
    client = None
    if os.path.exists(RESTORE_FILE) or os.path.exists(AppSounds.FILE):
        client = _app_client()
    player = player_running() if player is None else player
    if player:
        print("RESTORE HELD: a test sound (`afplay`) is still playing; every device stays on "
              "BlackHole. Stop it, then run this again.", flush=True)
        ok = False
    listening = (not player and app_may_be_listening(client)) if listening is None else listening
    if os.path.exists(RESTORE_FILE) and not player:
        with open(RESTORE_FILE) as fh:
            saved = json.load(fh)
        if listening:
            output_ok = _restore_device("output", saved["output"])
            print(f"RESTORE HELD: the app may still be recording; speakers restore "
                  f"verified={output_ok}, the input and the app's microphone stay on BlackHole. "
                  "Stop the recording, then run this again.", flush=True)
            ok = False
        else:
            app = AppMic.from_json(saved.get("app_device"))
            ok = _restore(saved["output"], saved["input"], app, client) and ok
    if os.path.exists(AppSounds.FILE):
        with open(AppSounds.FILE) as fh:
            sounds = json.load(fh)
        if client is None:
            print(f"RESTORE WARNING: app sounds not put back to {sounds}", flush=True)
            ok = False
        else:
            ok = _restore_sounds(sounds, client) and ok
    if os.path.exists(AlertSink.FILE) and not player:
        with open(AlertSink.FILE) as fh:
            ok = _restore_alert(json.load(fh)) and ok
    return ok


def _self_test():
    """Offline (#3990): the app's microphone and sounds against a fake door that applies the
    owner's rule (`chooseInputDevice` writes both keys; a non-forced device must be connected).
    No real device, journal or app is touched."""
    import tempfile
    ok = True

    def expect(name, cond):
        nonlocal ok
        ok &= bool(cond)
        print(f"  {'PASS' if cond else 'FAIL'}  {name}")

    class FakeClient:
        def __init__(self, store, connected, refuse=()):
            self.store, self.connected, self.refuse, self.writes = dict(store), connected, refuse, []

        def values(self, *keys):
            return {k: self.store[k] for k in keys}

        def follow_relaunch(self):
            return False

        def set(self, key, value, force=False):
            self.writes.append((key, value, force))
            if key in self.refuse:
                raise RuntimeError(f"refused {key}")
            if key in (OVERRIDE, SELECTED) and not force:
                if value and value not in self.connected:
                    raise RuntimeError("that input device is not connected")
                self.store[OVERRIDE] = self.store[SELECTED] = value
            else:
                self.store[key] = value

    def mic_store(override, selected):
        return {OVERRIDE: override, SELECTED: selected}

    print("silent_audio --self-test")
    connected = ["BuiltInMicrophoneDevice", BLACKHOLE_UID]
    for label, override, selected, refused in (
            ("a pinned connected device", "BuiltInMicrophoneDevice", "BuiltInMicrophoneDevice", False),
            ("Auto", "", "", False),
            ("Auto with a remembered device that is away", "", "AirPodsUID", False),
            ("a pinned device that is not connected", "AirPodsUID", "AirPodsUID", True),
            ("a pair the app never keeps", "BuiltInMicrophoneDevice", "AirPodsUID", True)):
        try:
            AppMic(override, selected).check_restorable(connected)
            got = False
        except RuntimeError:
            got = True
        expect(f"capture of {label} is {'refused' if refused else 'accepted'} before anything moves",
               got == refused)

    for label, captured in (("a pinned device", AppMic("BuiltInMicrophoneDevice", "BuiltInMicrophoneDevice")),
                            ("Auto", AppMic("", "")),
                            ("Auto with a remembered device that is away", AppMic("", "AirPodsUID"))):
        client = FakeClient(mic_store(BLACKHOLE_UID, BLACKHOLE_UID), connected)
        captured.restore(client)
        now = AppMic.read(client)
        verified, _ = captured.restored_by(now, connected)
        expect(f"{label} is put back exactly and verified", now == captured and verified)
        expect(f"{label}: the override is never forced",
               all(not force for key, _, force in client.writes if key == OVERRIDE))

    away = AppMic("", "AirPodsUID")
    expect("a remembered device that came back and was pinned again counts as restored",
           away.restored_by(AppMic("AirPodsUID", "AirPodsUID"), connected + ["AirPodsUID"])[0])
    expect("a microphone left on BlackHole never counts as restored",
           not away.restored_by(AppMic(BLACKHOLE_UID, BLACKHOLE_UID), connected)[0])
    expect("a pre-#3990 journal entry restores the picker's both-keys choice",
           AppMic.from_json({"uid": "BuiltInMicrophoneDevice", "shown": "MacBook Pro Microphone"})
           == AppMic("BuiltInMicrophoneDevice", "BuiltInMicrophoneDevice")
           and AppMic.from_json({"uid": "", "shown": None}) == AppMic("", "")
           and AppMic.from_json({"shown": "x"}) is None)

    folder = tempfile.mkdtemp(prefix="ew-silent-audio-selftest-")
    saved_file, saved_warn = AppSounds.FILE, w._INPUT_WARN
    try:
        AppSounds.FILE = os.path.join(folder, "sounds.json")
        original = {"playRecordingSounds": True, "otherAudioWhileDictating": "turnDown"}
        client = FakeClient(original, connected)
        sounds = AppSounds(client)
        w._INPUT_WARN = True
        sounds.apply()
        expect("app sounds are journaled, then quieted, with the harness chime off",
               json.load(open(AppSounds.FILE)) == original and client.values(*AppSounds.QUIET)
               == AppSounds.QUIET and w._INPUT_WARN is False)
        try:
            AppSounds(client).apply()
            expect("a second setup over an unrestored journal is refused", False)
        except RuntimeError:
            expect("a second setup over an unrestored journal is refused",
                   json.load(open(AppSounds.FILE)) == original)
        expect("app sounds and the chime come back and the journal is removed",
               sounds.restore() and client.values(*original) == original and w._INPUT_WARN is True
               and not os.path.exists(AppSounds.FILE))

        client = FakeClient(original, connected, refuse=("otherAudioWhileDictating",))
        sounds = AppSounds(client)
        try:
            sounds.apply()
        except RuntimeError:
            pass
        partial = client.values(*original)
        restored = sounds.restore()
        expect("a half-applied quiet is put back as far as it went, and the journal is kept",
               partial["playRecordingSounds"] is False and not restored
               and client.store["playRecordingSounds"] is True and os.path.exists(AppSounds.FILE))
        os.remove(AppSounds.FILE)
        expect("an unapplied AppSounds restores nothing", AppSounds(client).restore())
    finally:
        AppSounds.FILE, w._INPUT_WARN = saved_file, saved_warn
        for name in os.listdir(folder):
            os.remove(os.path.join(folder, name))
        os.rmdir(folder)
    _device_restore_cases(expect, FakeClient)
    _recover_cases(expect)

    route = object.__new__(AudioRoute)  # no device or app is read: only the handler is tested
    restored = []
    route.restore = lambda: restored.append(True)
    old = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        route.install_restore_handlers()
        try:
            os.kill(os.getpid(), signal.SIGTERM)
            time.sleep(0.1)  # settle: the handler runs at the next bytecode boundary
            code = None
        except SystemExit as exc:
            code = exc.code
    finally:
        for sig, handler in old.items():
            signal.signal(sig, handler)
    expect("#3991 an interrupt unwinds to the caller's proven restore and restores nothing itself",
           code == 130 and restored == [])
    print("PASS" if ok else "FAIL")
    return ok


def _device_restore_cases(expect, fake_client):
    """Harness Contract (#4181): a successful name write can leave Bluetooth alerts silent.
    Fake only the system boundary; exercise the real snapshot, journal and restore owners."""
    import tempfile
    from unittest.mock import patch

    original = {"name": "Storm", "uid": "Bluetooth:output"}
    microphone = {"name": "MacBook Pro Microphone", "uid": "BuiltInMicrophoneDevice"}
    silent = {"name": SILENT_DEVICE, "uid": BLACKHOLE_UID}
    originals = {"output": original, "system": original, "input": microphone}
    devices = {kind: dict(device) for kind, device in originals.items()}
    commands = []
    fail_writes, broken_reads = set(), set()
    wrong_uid = set()

    def run(argv, **kwargs):
        if argv[0] != SWITCH:
            raise AssertionError(f"unexpected external command: {argv}")
        commands.append(argv)
        kind = argv[argv.index("-t") + 1]
        if "-c" in argv:
            now = devices[kind]
            text = ("unreadable" if kind in broken_reads else
                    json.dumps(dict(now, type=kind)) if "-f" in argv else now["name"])
            return subprocess.CompletedProcess(argv, 0, text, "")
        if kind in fail_writes:
            return subprocess.CompletedProcess(argv, 1, "", "device unavailable")
        if "-u" in argv:
            uid = argv[argv.index("-u") + 1]
            for device in (originals[kind], silent):
                if uid == device["uid"]:
                    devices[kind] = dict(device)
            if kind in wrong_uid:
                devices[kind]["uid"] = "another-device-with-the-same-name"
        elif argv[argv.index("-s") + 1] == SILENT_DEVICE:
            devices[kind] = dict(silent)
        elif kind != "system":
            devices[kind] = dict(originals[kind])
        # Reproduce the issue: name selection of Storm's system route reports success
        # without changing it. UID selection above actually restores the device.
        return subprocess.CompletedProcess(argv, 0, "device set", "")

    with tempfile.TemporaryDirectory(prefix="ew-device-selftest-") as folder:
        with patch.object(subprocess, "run", run), patch.object(
                AlertSink, "FILE", os.path.join(folder, "alerts.json")), patch.dict(
                globals(), RESTORE_FILE=os.path.join(folder, "route.json")):
            sink = AlertSink()
            expect("#4181 Bluetooth fixture routes output and alerts to BlackHole", sink.apply())
            with open(AlertSink.FILE) as fh:
                journal = json.load(fh)
            expect("#4181 alert originals retain name and full UID on disk",
                   journal == {"output": original, "system": original})
            restored = sink.restore()
            expect("#4181 Bluetooth alerts restore even when name selection silently does nothing",
                   restored and devices["system"] == original
                   and not os.path.exists(AlertSink.FILE))

            sink = AlertSink()
            sink.apply()
            wrong_uid.add("system")
            start = len(commands)
            restored = sink.restore()
            expect("#4181 a different UID with the same name cannot clear the alert journal",
                   not restored and os.path.exists(AlertSink.FILE)
                   and all("-s" not in cmd for cmd in commands[start:]))
            wrong_uid.clear()

            devices["system"] = dict(silent)
            fail_writes.add("output")
            expect("#4181 a failed output write still restores alerts and keeps the journal",
                   not _restore_alert(journal) and devices["system"] == original
                   and os.path.exists(AlertSink.FILE))
            fail_writes.clear()
            broken_reads.add("output")
            devices["system"] = dict(silent)
            expect("#4181 unreadable output verification still attempts the alert restore",
                   not _restore_alert(journal) and devices["system"] == original
                   and os.path.exists(AlertSink.FILE))
            broken_reads.clear()
            expect("#4181 a later verified recovery clears the kept alert journal",
                   _restore_alert(journal) and not os.path.exists(AlertSink.FILE))

            legacy = {"output": "Storm", "system": SILENT_DEVICE}
            with open(AlertSink.FILE, "w") as fh:
                json.dump(legacy, fh)
            expect("#4181 legacy name-only alert journals remain readable",
                   _restore_alert(legacy) and not os.path.exists(AlertSink.FILE))

            broken_reads.add("system")
            start = len(commands)
            try:
                AlertSink()
                refused = False
            except (ValueError, RuntimeError):
                refused = True
            expect("#4181 unreadable originals refuse capture without moving devices",
                   refused and all("-c" in cmd for cmd in commands[start:]))
            broken_reads.clear()

            client = fake_client({OVERRIDE: microphone["uid"], SELECTED: microphone["uid"]},
                                 [microphone["uid"], BLACKHOLE_UID])
            client.check_owner = lambda: None
            with patch("dev_control.check_owner", return_value="owned"), patch.object(
                    sys.modules[__name__], "connected_input_uids", return_value=client.connected):
                devices.update({kind: dict(device) for kind, device in originals.items()})
                route = AudioRoute(client)
                route.apply()
                with open(RESTORE_FILE) as fh:
                    saved = json.load(fh)
                expect("#4181 route originals are journaled and all three choices restore",
                       saved["output"] == original and saved["input"] == microphone
                       and route.restore() and devices == originals
                       and not os.path.exists(RESTORE_FILE))

                # An outer alert sink legitimately makes BlackHole the inner route's original.
                outer = AlertSink()
                outer.apply()
                inner = AudioRoute(client)
                inner.apply()
                inner_ok = inner.restore()
                expect("#4181 nested cleanup leaves the outer silent output until its own restore",
                       inner_ok and devices["output"] == silent and outer.restore()
                       and devices == originals)

                with open(RESTORE_FILE, "w") as fh:
                    json.dump(saved, fh)
                devices["output"] = devices["input"] = dict(silent)
                start = len(commands)
                with patch.object(sys.modules[__name__], "_app_client", return_value=None):
                    result = recover(player=False, listening=True)
                expect("#4181 recovery restores only speakers while a take may listen",
                       not result and devices["output"] == original and devices["input"] == silent
                       and os.path.exists(RESTORE_FILE)
                       and all(cmd[cmd.index("-t") + 1] == "output" for cmd in commands[start:]))

                import audio_rig
                devices["output"] = dict(silent)
                start = len(commands)
                with patch.object(audio_rig, "sa", sys.modules[__name__]):
                    audio_rig.AudioRig._speakers_back(original)
                expect("#4181 live-rig speakers-only cleanup uses the same identity restore",
                       devices["output"] == original and devices["input"] == silent
                       and all(cmd[cmd.index("-t") + 1] == "output" for cmd in commands[start:]))


def _recover_cases(expect):
    """#3991: recovery in a new process proves idleness itself. Every outside effect is
    replaced: the lock owner, the app, the device switcher and the three journals."""
    import tempfile
    import dev_control
    g = globals()
    names = ("_app_client", "_restore", "_restore_sounds", "_restore_alert", "_current",
             "RESTORE_FILE")
    saved = {n: g[n] for n in names}
    saved_files = (AppSounds.FILE, AlertSink.FILE)
    saved_owner, saved_run = dev_control.check_owner, subprocess.run
    folder = tempfile.mkdtemp(prefix="ew-recover-selftest-")
    try:
        dev_control.check_owner = lambda boundaries=None: "owned"
        g["_app_client"] = lambda: None
        g["_current"] = lambda kind: "BlackHole 2ch"
        g["RESTORE_FILE"] = os.path.join(folder, "route.json")
        AppSounds.FILE = os.path.join(folder, "sounds.json")
        AlertSink.FILE = os.path.join(folder, "alerts.json")
        for label, player, listening, want in (
                ("nothing playing and the app at rest: every journal is replayed",
                 False, False, {"route", "alerts"}),
                ("a test sound still playing: nothing is touched",
                 True, False, set()),
                ("the app may still be recording: only the speakers and the alert sounds",
                 False, True, {"speakers", "alerts"})):
            calls = set()
            with open(RESTORE_FILE, "w") as fh:
                json.dump({"output": "MacBook Pro Speakers", "input": "MacBook Pro Microphone",
                           "app_device": {"override": "", "selected": ""}}, fh)
            with open(AlertSink.FILE, "w") as fh:
                json.dump({"output": "MacBook Pro Speakers", "system": "MacBook Pro Speakers"}, fh)
            # As the real one does: a verified restore removes its journal.
            g["_restore"] = lambda *a: (calls.add("route"), os.remove(RESTORE_FILE), True)[2]
            g["_restore_alert"] = lambda *a: (calls.add("alerts"), True)[1]

            def run(argv, **kw):
                if argv[:1] == [SWITCH] and argv[-1] == "output":
                    calls.add("speakers")
                return subprocess.CompletedProcess(argv, 0, "", "")
            subprocess.run = run
            result = recover(player=player, listening=listening)
            kept = os.path.exists(RESTORE_FILE)
            expect(f"#3991 recovery: {label}",
                   calls == want and result == (want == {"route", "alerts"})
                   and kept == (want != {"route", "alerts"}))
            for path in (RESTORE_FILE, AlertSink.FILE):
                if os.path.exists(path):
                    os.remove(path)
        subprocess.run = saved_run
        saved_instances = w.running_enviouswispr_instances
        try:
            w.running_enviouswispr_instances = lambda: {"9": "/Applications/EnviousWispr.app/Contents/MacOS/EnviousWispr"}
            shipped = app_may_be_listening(None)
            w.running_enviouswispr_instances = lambda: {"9": "/x/build/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"}
            dev = app_may_be_listening(None)
        finally:
            w.running_enviouswispr_instances = saved_instances

        class Door:
            def __init__(self, state=None, boom=False):
                self.state, self.boom = state, boom

            def status(self):
                if self.boom:
                    raise RuntimeError("door gone")
                return {"activeDriver": {"state": self.state}}
        expect("#3991 an unreachable dev app counts as listening; the shipped app does not",
               dev is True and shipped is False)
        expect("#3991 a door that says idle, complete, error or advisory is at rest",
               not any(app_may_be_listening(Door(s)) for s in ("idle", "complete", "error",
                                                               "advisory")))
        expect("#3991 recording, loading or transcribing, or a door that fails, counts as listening",
               all(app_may_be_listening(Door(s)) for s in ("recording", "loadingModel",
                                                           "transcribing"))
               and app_may_be_listening(Door(boom=True)))
    finally:
        g.update(saved)
        AppSounds.FILE, AlertSink.FILE = saved_files
        dev_control.check_owner, subprocess.run = saved_owner, saved_run
        for name in os.listdir(folder):
            os.remove(os.path.join(folder, name))
        os.rmdir(folder)


if __name__ == "__main__" and sys.argv[1:] == ["restore"]:
    sys.exit(0 if recover() else 1)
if __name__ == "__main__" and sys.argv[1:] == ["--self-test"]:
    sys.exit(0 if _self_test() else 1)
