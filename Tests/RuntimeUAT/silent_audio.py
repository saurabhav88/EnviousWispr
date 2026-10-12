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
import fcntl
import tempfile
import stat
import contextlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import wispr_eyes as w  # noqa: E402
from wispr_eyes import connect, find_all_elements, get_attr, nav, perform_action  # noqa: E402,F401

SWITCH = "/opt/homebrew/bin/SwitchAudioSource"
SILENT_DEVICE = "BlackHole 2ch"
RESTORE_FILE = os.path.expanduser("~/.ew-uat-audio-restore.json")
LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")


def input_picker():
    """The Microphone tab's "Input device" control, or None. #3385: found by its
    label in the content (`settings_nav.input_control`), never "the first popup"."""
    try:
        return w._sn.input_control(w._ax(), w._app)
    except w.NavigationError:
        return None


def select_input_device(name):
    """Choose `name` in Dictation Settings > Microphone and PROVE the control took it.

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


def _route_read(args):
    result = subprocess.run([SWITCH, *args, "-f", "json"], capture_output=True, text=True, timeout=5)
    if result.returncode != 0 or not isinstance(result.stderr, str) or result.stderr.strip():
        raise RuntimeError("audio route read did not complete cleanly")
    if not isinstance(result.stdout, str) or not result.stdout.strip():
        raise RuntimeError("audio route read is empty")
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    for row in rows:
        if (not isinstance(row, dict) or not all(isinstance(row.get(k), str) and row[k]
                for k in ("name", "uid", "id", "type")) or not row["id"].isascii()
                or not row["id"].isdecimal() or len(row["id"]) > 10
                or not 0 < int(row["id"]) <= 4_294_967_295):
            raise RuntimeError("audio device identity is malformed")
    return rows


def _device(kind):
    rows = _route_read(["-c", "-t", kind])
    if len(rows) != 1:
        raise RuntimeError("current audio device is ambiguous")
    return rows[0]


def _current(kind):
    return _device(kind)["name"]


def _resolve_device(kind, value, key="uid"):
    rows = _route_read(["-a", "-t", "output" if kind == "system" else kind])
    matches = [row for row in rows if row[key] == value]
    if len(matches) != 1:
        raise RuntimeError("audio device is missing or ambiguous")
    return matches[0]


def _switch_and_verify(kind, choice, *, target):
    # Numeric live ID selected from one exact UID match; -u accepts substrings.
    device = _resolve_device(kind, choice["uid"])
    _idle(target)
    result = subprocess.run([SWITCH, "-i", device["id"], "-t", kind],
                            capture_output=True, text=True, timeout=5)
    if result.returncode != 0 or result.stderr.strip():
        raise RuntimeError("audio device switch failed")
    now = _device(kind)
    if (now["uid"], now["id"]) != (device["uid"], device["id"]):
        raise RuntimeError("audio device switch did not land")


def take_was_virtual(log_offset):
    """Whether every capture since `log_offset` reported a virtual transport, and at least one did."""
    with open(LOG, "rb") as fh:
        fh.seek(log_offset)
        text = fh.read().decode("utf-8", "replace")
    transports = [line.split("transport=")[1].split()[0]
                  for line in text.splitlines() if "ZERO_PREFIX_MEASURE transport=" in line]
    return bool(transports) and all(t == "virtual" for t in transports), transports


def _record_bytes(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as fh:
        info = os.fstat(fh.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise RuntimeError("audio recovery is not a regular file")
        return (info.st_dev, info.st_ino), fh.read()


def _publish_recovery(path, payload):
    data = (json.dumps(payload, sort_keys=True) + "\n").encode()
    directory = os.path.dirname(path)
    fd, temporary = tempfile.mkstemp(prefix=".ew-audio-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as fh:
            os.fchmod(fh.fileno(), 0o600)
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.link(temporary, path)  # exclusive atomic publication, never overwrite
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        identity, actual = _record_bytes(path)
        if actual != data:
            raise RuntimeError("audio recovery publication changed")
        return identity, data
    finally:
        os.unlink(temporary)


def _record_lock(path):
    fd = os.open(path + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise RuntimeError("audio recovery lock is not a regular file")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BaseException:
        os.close(fd)
        raise
    return fd


def _release_record_lock(fd):
    if fd is not None:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def _target_json(target):
    return {"pid": target.pid, "executable": target.executable, "start": list(target.start)}


def _saved_target(data):
    from instance_guard import TargetIdentity, verify_target
    if (not isinstance(data, dict) or type(data.get("pid")) is not int
            or not isinstance(data.get("executable"), str)
            or not isinstance(data.get("start"), list) or len(data["start"]) != 2
            or any(type(n) is not int or n < 0 for n in data["start"])):
        raise RuntimeError("audio recovery target identity is malformed")
    target = TargetIdentity(data["pid"], data["executable"], tuple(data["start"]))
    verify_target(target)
    w.connect(expected_pid=target.pid, expected_executable=target.executable)
    return target


def _idle(target):
    if not w._recording_cleanup_safe:
        raise RuntimeError("playback or recording cleanup remains unresolved")
    if w._recording_state(target) != "idle":
        raise RuntimeError("physical audio restore requires positive non-recording state")


def _restore_record(path, owned, payload):
    if _record_bytes(path) != owned:
        raise RuntimeError("audio recovery ownership changed")
    if not isinstance(payload, dict) or payload.get("version") != 2 or payload.get("kind") not in {"audio", "alert"}:
        raise RuntimeError("unsupported audio recovery record")
    target = _saved_target(payload.get("target"))
    choices = payload.get("devices")
    expected = {"output", "input"} if payload["kind"] == "audio" else {"output", "system"}
    if not isinstance(choices, dict) or set(choices) != expected:
        raise RuntimeError("audio recovery devices are incomplete")
    for kind, choice in choices.items():
        if not isinstance(choice, dict) or not isinstance(choice.get("uid"), str) or not choice["uid"]:
            raise RuntimeError("audio recovery device identity is missing")
        _resolve_device(kind, choice["uid"])
    app_choice = None
    if payload["kind"] == "audio":
        app_choice = w._sn.InputChoice.from_json(payload.get("app_device"))
    if not w._recording_cleanup_safe:
        raise RuntimeError("unreaped playback blocks audio recovery")
    w._stop_recording(target, 30.0)  # existing recording completion allowance
    for kind, choice in choices.items():
        _idle(target)
        _switch_and_verify(kind, choice, target=target)
    if app_choice is not None:
        _idle(target)
        select_input_choice(app_choice)
        if not w.read_input_choice().same_choice(app_choice):
            raise RuntimeError("app microphone restoration did not land")
    _idle(target)
    if any(_device(kind)["uid"] != choice["uid"] for kind, choice in choices.items()):
        raise RuntimeError("audio restoration changed during verification")
    if _record_bytes(path) != owned:
        raise RuntimeError("audio recovery record changed before removal")
    os.unlink(path)
    return True


def _replay_recovery(path):
    fd = _record_lock(path)
    try:
        owned = _record_bytes(path)
        payload = json.loads(owned[1])
        with w._defer_recording_signals():
            return _restore_record(path, owned, payload)
    finally:
        _release_record_lock(fd)


class AudioRoute:
    """Own one silent run and its durable, retryable recovery record."""
    FILE = RESTORE_FILE
    KINDS = ("output", "input")
    KIND = "audio"

    def __init__(self):
        if not os.path.exists(SWITCH):
            raise RuntimeError("silent audio routing tool is missing")
        w.connect()
        self.target = w._target
        _idle(self.target)
        self.devices = {kind: _device(kind) for kind in self.KINDS}
        self.original_output = self.devices["output"]["name"]
        self.original_input = self.devices.get("input", {}).get("name")
        self.original_app_device = w.read_input_choice() if self.KIND == "audio" else None
        self.original = {kind: choice["name"] for kind, choice in self.devices.items()}
        self.applied, self._owned, self._lock = False, None, None
        self._handlers = {}

    def install_restore_handlers(self):
        if self._handlers:
            return
        def interrupted(sig, frame):
            raise SystemExit(128 + sig)  # unwind recording first; never restore here
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            self._handlers[sig] = signal.getsignal(sig)
            signal.signal(sig, interrupted)

    def _restore_handlers(self):
        for sig, handler in self._handlers.items():
            signal.signal(sig, handler)
        self._handlers = {}

    def apply(self):
        if self.applied:
            raise RuntimeError("silent route already owns a recovery record")
        self._lock = _record_lock(self.FILE)
        try:
            _idle(self.target)
            if any(_device(kind)["uid"] != choice["uid"] for kind, choice in self.devices.items()):
                raise RuntimeError("audio snapshot changed before application")
            if self.KIND == "audio" and not w.read_input_choice().same_choice(self.original_app_device):
                raise RuntimeError("app microphone snapshot changed")
            silent = {kind: _resolve_device(kind, SILENT_DEVICE, "name") for kind in self.KINDS}
            self._payload = {"version": 2, "kind": self.KIND, "target": _target_json(self.target),
                             "devices": self.devices}
            if self.original_app_device is not None:
                self._payload["app_device"] = self.original_app_device.to_json()
            with w._defer_recording_signals():
                self._owned = _publish_recovery(self.FILE, self._payload)
                self.applied = True
            for kind, choice in silent.items():
                _idle(self.target)
                _switch_and_verify(kind, choice, target=self.target)
            if self.KIND == "audio":
                _idle(self.target)
                select_input_device(SILENT_DEVICE)
                if w.read_input_choice().uid != silent["input"]["uid"]:
                    raise RuntimeError("silent app microphone did not land")
            return True
        except BaseException as error:
            try:
                self.restore()
            except BaseException as cleanup:
                error.add_note(f"audio restore failed: {cleanup!r}")
            raise
        finally:
            if not self.applied:
                _release_record_lock(self._lock)
                self._lock = None

    def restore(self):
        try:
            if not self.applied:
                return True
            if self._lock is None:
                self._lock = _record_lock(self.FILE)
            with w._defer_recording_signals():
                ok = _restore_record(self.FILE, self._owned, self._payload)
                if ok:
                    self.applied = False
                return ok
        finally:
            _release_record_lock(self._lock)
            self._lock = None
            self._restore_handlers()


class AlertSink(AudioRoute):
    FILE = os.path.expanduser("~/.ew-uat-alert-restore.json")
    KINDS = ("output", "system")
    KIND = "alert"


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
    try:
        for path in (RESTORE_FILE, AlertSink.FILE):
            if os.path.lexists(path):
                _replay_recovery(path)
    except BaseException as error:
        print(f"RESTORE REFUSED: {error!r}", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
