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
import copy
import hashlib
import select
import threading
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import wispr_eyes as w  # noqa: E402
from wispr_eyes import connect, find_all_elements, get_attr, nav, perform_action  # noqa: E402,F401

SWITCH = "/opt/homebrew/bin/SwitchAudioSource"
SILENT_DEVICE = "BlackHole 2ch"
RESTORE_FILE = os.path.expanduser("~/.ew-uat-audio-restore.json")
LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
_PLAYER = "/usr/bin/afplay"
_CHILD = r"""
import json, os, sys
sys.path.insert(0, sys.argv[1])
from instance_guard import process_start
lock, gate, ready = map(int, sys.argv[2:5])
os.set_inheritable(lock, True)
data = (json.dumps({"pid": os.getpid(), "start": list(process_start(os.getpid()))}) + "\n").encode()
while data:
    count = os.write(ready, data)
    if count <= 0:
        raise RuntimeError("ready pipe failed")
    data = data[count:]
os.close(ready)
command = b""
while len(command) < 3:
    chunk = os.read(gate, 3 - len(command))
    if not chunk:
        sys.exit(125)
    command += chunk
os.close(gate)
if command != b"GO\n":
    sys.exit(125)
os.execv("/usr/bin/afplay", ["/usr/bin/afplay", sys.argv[5]])
"""


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
    fd = os.open(RESTORE_FILE + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
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
        os.close(fd)  # An inherited child retains exclusion; never explicitly unlock it.


def _init_playback_journal(route):
    from instance_guard import process_start
    route._playback_guard = threading.RLock()
    route._player = None
    route._payload.update(version=3, run=uuid.uuid4().hex,
                          harness={"pid": os.getpid(), "start": list(process_start(os.getpid()))},
                          playback=None, lineage=[])


def _replace_record(path, owned, payload):
    """Update an already-owned journal under its common resource lock."""
    if _record_bytes(path) != owned:
        raise RuntimeError("audio journal ownership changed")
    data = (json.dumps(payload, sort_keys=True) + "\n").encode()
    directory = os.path.dirname(path)
    fd, temporary = tempfile.mkstemp(prefix=".ew-journal-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as fh:
            os.fchmod(fh.fileno(), 0o600)
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        if _record_bytes(path) != owned:
            raise RuntimeError("audio journal changed before commit")
        os.replace(temporary, path)
        actual = _record_bytes(path)
        if actual[1] != data:
            raise RuntimeError("audio journal commit changed")
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        return actual
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def _set_playback(route, playback):
    from instance_guard import process_start
    if not route.applied or route._lock is None:
        raise RuntimeError("playback requires the applied resource owner")
    owner = {"pid": os.getpid(), "start": list(process_start(os.getpid()))}
    if route._payload.get("harness") != owner:
        raise RuntimeError("playback journal belongs to another harness")
    payload = copy.deepcopy(route._payload)
    payload["playback"] = playback
    route._owned = _replace_record(route.FILE, route._owned, payload)
    route._payload = payload


def _ready_identity(fd, deadline):
    data = bytearray()
    while not data.endswith(b"\n"):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise RuntimeError("playback child readiness expired")
        chunk = os.read(fd, 256)
        if not chunk:
            raise RuntimeError("playback child exited before readiness")
        data.extend(chunk)
        if len(data) > 256 or data.count(b"\n") > 1:
            raise RuntimeError("playback readiness is malformed")
    value = json.loads(data)
    if (not isinstance(value, dict) or set(value) != {"pid", "start"}
            or type(value["pid"]) is not int or not 0 < value["pid"] <= 2_147_483_647
            or not isinstance(value["start"], list) or len(value["start"]) != 2
            or any(type(n) is not int for n in value["start"])
            or value["start"][0] <= 0 or not 0 <= value["start"][1] < 1_000_000):
        raise RuntimeError("playback child identity is malformed")
    return value


def _python_executable():
    """Framework Python may re-exec: compare with the current runtime's native path."""
    from instance_guard import process_start
    pid = os.getpid()
    before = process_start(pid)
    result = subprocess.run(["ps", "-ww", "-o", "comm=", "-p", str(pid)],
                            capture_output=True, text=True, timeout=5)
    value = result.stdout.strip()
    if (result.returncode != 0 or result.stderr.strip() or len(value.splitlines()) != 1
            or not os.path.isabs(value) or process_start(pid) != before):
        raise RuntimeError("current Python executable is unreadable")
    return os.path.realpath(value)


def _verify_blocked_child(pid, start):
    from instance_guard import process_start
    before = process_start(pid)
    result = subprocess.run(["ps", "-ww", "-o", "comm=", "-p", str(pid)],
                            capture_output=True, text=True, timeout=5)
    if (result.returncode != 0 or result.stderr.strip()
            or len(result.stdout.strip().splitlines()) != 1
            or os.path.realpath(result.stdout.strip()) != _python_executable()
            or before != tuple(start) or process_start(pid) != before):
        raise RuntimeError("blocked playback child identity changed")


def _spawn_playback(route, clip, timeout=5.0):
    clip = os.path.realpath(clip)
    with open(clip, "rb") as fh:
        content = fh.read()
    if not content:
        raise RuntimeError("playback clip is empty")
    with route._playback_guard:
        if route._payload.get("playback") is not None:
            raise RuntimeError("previous playback remains unresolved")
        lease = {"stage": "intent", "nonce": uuid.uuid4().hex,
                 "clip": clip, "sha256": hashlib.sha256(content).hexdigest()}
        _set_playback(route, lease)  # Committed before any child can exist.
        gate_r = gate_w = ready_r = ready_w = None
        proc = None
        try:
            gate_r, gate_w = os.pipe()
            ready_r, ready_w = os.pipe()
            proc = subprocess.Popen([sys.executable, "-c", _CHILD, HERE,
                                     str(route._lock), str(gate_r), str(ready_w), clip],
                                    pass_fds=(route._lock, gate_r, ready_w),
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE)
            route._player = proc
            os.close(gate_r); gate_r = None
            os.close(ready_w); ready_w = None
            identity = _ready_identity(ready_r, time.monotonic() + timeout)
            if identity["pid"] != proc.pid:
                raise RuntimeError("playback child PID mismatch")
            _verify_blocked_child(proc.pid, identity["start"])
            lease.update(stage="committed", **identity)
            _set_playback(route, lease)  # Fsynced before GO can permit audio.
            proc._ew_audio_route = route
            if os.write(gate_w, b"GO\n") != 3:
                raise RuntimeError("playback GO failed")
            return proc
        except BaseException as error:
            if gate_w is not None:
                os.close(gate_w); gate_w = None
            try:
                w._reap_playback(proc, timeout)
                remaining = route._payload.get("playback")
                if proc is not None and isinstance(remaining, dict) and remaining["stage"] == "intent":
                    _set_playback(route, None)  # Owned child reaped after its GO pipe closed.
                    route._player = None
            except BaseException as cleanup:
                error.add_note(f"playback cleanup failed: {cleanup!r}")
            raise
        finally:
            for fd in (gate_r, gate_w, ready_r, ready_w):
                if fd is not None:
                    os.close(fd)


def _complete_playback(route, proc, timeout=5.0):
    from instance_guard import TargetIdentity, prove_target_exited
    with route._playback_guard:
        lease = route._payload.get("playback")
        if (not isinstance(lease, dict) or lease.get("stage") != "committed"
                or lease.get("pid") != proc.pid):
            raise RuntimeError("playback completion has no matching lease")
        proc.wait(timeout=timeout)
        prove_target_exited(TargetIdentity(proc.pid, _PLAYER, tuple(lease["start"])))
        _set_playback(route, None)
        proc._ew_audio_route = None
        route._player = None


def _current_harness():
    from instance_guard import process_start
    return {"pid": os.getpid(), "start": list(process_start(os.getpid()))}


def _process_identity(data):
    from instance_guard import TargetIdentity
    if (not isinstance(data, dict) or set(data) != {"pid", "start"}
            or type(data["pid"]) is not int or not 0 < data["pid"] <= 2_147_483_647
            or not isinstance(data["start"], list) or len(data["start"]) != 2
            or any(type(value) is not int for value in data["start"])
            or data["start"][0] <= 0 or not 0 <= data["start"][1] < 1_000_000):
        raise RuntimeError("audio journal process identity is malformed")
    return TargetIdentity(data["pid"], _PLAYER, tuple(data["start"]))


def _validate_playback_journal(payload):
    import re
    if (not isinstance(payload, dict) or payload.get("version") != 3
            or not isinstance(payload.get("run"), str)
            or re.fullmatch(r"[0-9a-f]{32}", payload["run"]) is None
            or not isinstance(payload.get("lineage"), list)
            or payload.get("kind") not in {"audio", "alert", "audio-alert"}):
        raise RuntimeError("unsupported or malformed playback recovery journal")
    required = {"version", "run", "harness", "playback", "lineage", "kind", "target", "devices"}
    if payload["kind"] in {"audio", "audio-alert"}:
        required.add("app_device")
    if set(payload) != required:
        raise RuntimeError("audio journal fields are incomplete or unexpected")
    _validate_lineage(payload)
    harness = _process_identity(payload.get("harness"))
    lease = payload.get("playback")
    if lease is not None:
        if (not isinstance(lease, dict) or lease.get("stage") not in {"intent", "committed"}
                or not isinstance(lease.get("nonce"), str)
                or re.fullmatch(r"[0-9a-f]{32}", lease["nonce"]) is None
                or not isinstance(lease.get("clip"), str) or not os.path.isabs(lease["clip"])
                or not isinstance(lease.get("sha256"), str)
                or re.fullmatch(r"[0-9a-f]{64}", lease["sha256"]) is None):
            raise RuntimeError("playback lease is malformed")
        keys = {"stage", "nonce", "clip", "sha256"}
        if lease["stage"] == "committed":
            keys |= {"pid", "start"}
            _process_identity({key: lease.get(key) for key in ("pid", "start")})
        if set(lease) != keys:
            raise RuntimeError("playback lease fields are incomplete or unexpected")
    return harness, lease


def _decode_target(data):
    from instance_guard import TargetIdentity
    if (not isinstance(data, dict) or set(data) != {"pid", "executable", "start"}
            or not isinstance(data["executable"], str) or not os.path.isabs(data["executable"])
            or not data["executable"].endswith(".app/Contents/MacOS/EnviousWispr")):
        raise RuntimeError("audio recovery target identity is malformed")
    identity = _process_identity({key: data[key] for key in ("pid", "start")})
    return TargetIdentity(identity.pid, data["executable"], identity.start)


def _validate_lineage(payload):
    target = _decode_target(payload.get("target"))
    previous = None
    for entry in payload["lineage"]:
        if not isinstance(entry, dict) or set(entry) != {"old", "new", "replacement_start"}:
            raise RuntimeError("audio handoff lineage is malformed")
        old, new = _decode_target(entry["old"]), _decode_target(entry["new"])
        if (old == new or old.executable != new.executable
                or (previous is not None and old != previous)):
            raise RuntimeError("audio handoff lineage is discontinuous")
        replacement = entry["replacement_start"]
        if replacement is not None:
            observed = _process_identity({"pid": old.pid, "start": replacement})
            if observed.start == old.start:
                raise RuntimeError("audio handoff claims exit of the same native process")
        previous = new
    if previous is not None and previous != target:
        raise RuntimeError("audio journal target differs from its last verified handoff")


def _player_running(lease):
    from instance_guard import process_start, prove_target_exited, InstanceGuardError
    identity = _process_identity({key: lease.get(key) for key in ("pid", "start")})
    try:
        before = process_start(identity.pid)
    except InstanceGuardError:
        prove_target_exited(identity)  # Unreadability alone never means disappearance.
        return False
    if before != identity.start:
        return False  # Positive native PID reuse proves this particular child ended.
    result = subprocess.run(["ps", "-ww", "-o", "comm=", "-p", str(identity.pid)],
                            capture_output=True, text=True, timeout=5)
    try:
        after = process_start(identity.pid)
    except InstanceGuardError:
        prove_target_exited(identity)
        return False
    if after != before:
        return False
    if (result.returncode != 0 or result.stderr.strip()
            or len(result.stdout.strip().splitlines()) != 1
            or os.path.realpath(result.stdout.strip()) not in
            {_python_executable(), _PLAYER}):
        raise RuntimeError("owned playback executable is unknown")
    return True


def _stop_orphan_playback(payload):
    from instance_guard import prove_target_exited
    harness, lease = _validate_playback_journal(payload)
    prove_target_exited(harness)  # A live or unreadable owner forbids cross-process recovery.
    if lease is None:
        return
    if lease["stage"] != "committed":
        raise RuntimeError("an unidentified pre-GO child still holds the audio lock")
    for stop_signal in (signal.SIGTERM, signal.SIGKILL):
        if not _player_running(lease):
            return
        try:
            os.kill(lease["pid"], stop_signal)  # Identity was freshly verified above.
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 30.0  # Existing recording/recovery completion allowance.
        while True:
            try:
                if not _player_running(lease):
                    return
            except RuntimeError:
                # Native teardown can temporarily lose its identity fields while
                # kill(0) still sees the PID. This is unknown, never an exit proof.
                pass
            if time.monotonic() >= deadline:
                break
            time.sleep(0.05)  # deadline-fallback: observe the owned child's native exit.
    raise RuntimeError("owned orphan playback did not end")


def _target_json(target):
    return {"pid": target.pid, "executable": target.executable, "start": list(target.start)}


def _saved_target(data):
    from instance_guard import verify_target
    target = _decode_target(data)
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
    harness, lease = _validate_playback_journal(payload)
    if lease is not None:
        raise RuntimeError("unresolved playback lease blocks physical restoration")
    if payload["harness"] != _current_harness():
        from instance_guard import prove_target_exited
        prove_target_exited(harness)
    target = _saved_target(payload.get("target"))
    choices = payload.get("devices")
    expected = {"audio": {"output", "input"}, "alert": {"output", "system"},
                "audio-alert": {"output", "input", "system"}}[payload["kind"]]
    if not isinstance(choices, dict) or set(choices) != expected:
        raise RuntimeError("audio recovery devices are incomplete")
    for kind, choice in choices.items():
        if not isinstance(choice, dict) or not isinstance(choice.get("uid"), str) or not choice["uid"]:
            raise RuntimeError("audio recovery device identity is missing")
        _resolve_device(kind, choice["uid"])
    app_choice = None
    if payload["kind"] in {"audio", "audio-alert"}:
        app_choice = w._sn.InputChoice.from_json(payload.get("app_device"))
    if getattr(w, "_standalone_player", None) is not None:
        raise RuntimeError("standalone playback blocks audio recovery")
    w._stop_recording(target, 30.0)  # existing recording completion allowance
    if w._recording_state(target) != "idle":
        raise RuntimeError("capture release was not confirmed before restoration")
    w._recording_cleanup_safe = True  # Durable empty playback plus confirmed capture release.
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
    with w._defer_recording_signals():
        if os.path.lexists(RESTORE_FILE) and os.path.lexists(AlertSink.FILE):
            raise RuntimeError("conflicting audio recovery records require their original owner")
        owned = _record_bytes(path)
        payload = json.loads(owned[1])
        _validate_playback_journal(payload)
        try:
            fd = _record_lock(path)
        except BlockingIOError:
            if payload["harness"] == _current_harness():
                raise
            if _record_bytes(path) != owned:
                raise RuntimeError("audio journal changed before orphan recovery")
            _stop_orphan_playback(payload)
            fd = _record_lock(path)
        try:
            if _record_bytes(path) != owned:
                raise RuntimeError("audio journal changed during orphan recovery")
            if payload["harness"] != _current_harness():
                from instance_guard import prove_target_exited
                harness, _ = _validate_playback_journal(payload)
                prove_target_exited(harness)
            lease = payload["playback"]
            if lease is not None:
                if lease["stage"] == "committed":
                    _stop_orphan_playback(payload)
                # Holding the common lock closes the pre-GO case: any possible
                # child still alive before exec would retain that same lock.
                payload = copy.deepcopy(payload)
                payload["playback"] = None
                owned = _replace_record(path, owned, payload)
            return _restore_record(path, owned, payload)
        finally:
            _release_record_lock(fd)


class AudioRoute:
    """Own one silent run and its durable, retryable recovery record."""
    FILE = RESTORE_FILE
    KINDS = ("output", "input")
    KIND = "audio"

    def __init__(self, include_alerts=False):
        if include_alerts:
            if self.KIND != "audio":
                raise RuntimeError("only the full audio owner can include alerts")
            self.KINDS = ("output", "input", "system")
            self.KIND = "audio-alert"
        if not os.path.exists(SWITCH):
            raise RuntimeError("silent audio routing tool is missing")
        w.connect()
        self.target = w._target
        _idle(self.target)
        self.devices = {kind: _device(kind) for kind in self.KINDS}
        self.original_output = self.devices["output"]["name"]
        self.original_input = self.devices.get("input", {}).get("name")
        self.original_app_device = w.read_input_choice() if "input" in self.KINDS else None
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
            for record in (RESTORE_FILE, AlertSink.FILE):
                if record != self.FILE and os.path.lexists(record):
                    raise RuntimeError("another audio recovery record must be resolved first")
            _idle(self.target)
            if any(_device(kind)["uid"] != choice["uid"] for kind, choice in self.devices.items()):
                raise RuntimeError("audio snapshot changed before application")
            if "input" in self.KINDS and not w.read_input_choice().same_choice(self.original_app_device):
                raise RuntimeError("app microphone snapshot changed")
            silent = {kind: _resolve_device(kind, SILENT_DEVICE, "name") for kind in self.KINDS}
            self._payload = {"version": 2, "kind": self.KIND, "target": _target_json(self.target),
                             "devices": self.devices}
            if self.original_app_device is not None:
                self._payload["app_device"] = self.original_app_device.to_json()
            _init_playback_journal(self)
            with w._defer_recording_signals():
                self._owned = _publish_recovery(self.FILE, self._payload)
                self.applied = True
                w._active_audio_route = self
            for kind, choice in silent.items():
                _idle(self.target)
                _switch_and_verify(kind, choice, target=self.target)
            if "input" in self.KINDS:
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

    def finish_playback(self, timeout=30.0):
        with self._playback_guard:
            if self._player is not None:
                w._reap_playback(self._player, timeout)

    def restore(self):
        try:
            if not self.applied:
                return True
            if self._lock is None:
                self._lock = _record_lock(self.FILE)
            with self._playback_guard, w._defer_recording_signals():
                self.finish_playback()
                lease = self._payload.get("playback")
                if isinstance(lease, dict) and lease["stage"] == "intent":
                    # No GO was committed. Reacquiring after close positively
                    # proves no pre-exec child still holds the inherited lock.
                    _release_record_lock(self._lock)
                    self._lock = None
                    self._lock = _record_lock(self.FILE)
                    _set_playback(self, None)
                ok = _restore_record(self.FILE, self._owned, self._payload)
                if ok:
                    self.applied = False
                    if getattr(w, "_active_audio_route", None) is self:
                        w._active_audio_route = None
                return ok
        finally:
            _release_record_lock(self._lock)
            self._lock = None
            self._restore_handlers()

    def transfer_after_verified_exit(self, new, proof):
        from instance_guard import verify_exit_proof, verify_target
        with self._playback_guard, w._defer_recording_signals():
            self.finish_playback()
            if not self.applied or self._lock is None:
                raise RuntimeError("audio handoff requires its current resource lock")
            _validate_playback_journal(self._payload)
            if self._payload["playback"] is not None or self._payload["harness"] != _current_harness():
                raise RuntimeError("unresolved playback or foreign ownership blocks audio handoff")
            old = self.target
            if new.executable != old.executable or w._target != old:
                raise RuntimeError("audio handoff conflicts with the retained app")
            verify_exit_proof(old, proof)
            verify_target(new)
            if w._recording_state(new) != "idle":
                raise RuntimeError("replacement capture has not been released")
            payload = copy.deepcopy(self._payload)
            payload["target"] = _target_json(new)
            payload["lineage"].append({"old": _target_json(old), "new": _target_json(new),
                                       "replacement_start": list(proof.replacement_start)
                                       if proof.replacement_start is not None else None})
            _validate_playback_journal(payload)
            verify_exit_proof(old, proof)
            verify_target(new)
            self._owned = _replace_record(self.FILE, self._owned, payload)
            self._payload, self.target = payload, new
            w.bind_after_verified_exit(old, new, proof)
            # Derived from durable no-playback, verified old exit and released new capture.
            w._recording_cleanup_safe = True


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
