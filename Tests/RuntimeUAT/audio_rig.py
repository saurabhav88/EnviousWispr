"""Set up, prove and undo everything an audio take needs (#3764).

    with AudioRig() as rig:                      # TextEdit: the one test document, never the founder's
        w.test_recording(sentence="...")
    with AudioRig(target=AppTarget("com.google.Chrome", prepare=open_gmail_compose)) as rig:
        w.record_tts("...")

Entering the rig:
1. routes system output, input and alert sounds to BlackHole and pins the app's microphone to it
   (silent_audio.AudioRoute / AlertSink, restore file on disk first); the microphone and the
   app's sounds go through the #3765 dev control door, never a Settings click (#3990);
2. READS BACK all four and refuses (`take_gate.SetupFailed`) unless each is BlackHole;
   the shared output gate also refuses muted or unreadable BlackHole output (#4133);
   with `quiet_app` (default) it also turns the app's start/stop sounds and "other audio"
   ducking off for the takes (`silent_audio.AppSounds`) and puts them back;
3. prepares the paste target, proves it is frontmost and names it to `take_gate`, which
   re-checks it before every take and checks the take's own app.log lines afterwards.
Leaving it restores the devices and the app's microphone and verifies them; a failed restore is
printed and leaves `python3 silent_audio.py restore` to finish.

Every failure here is SETUP, never an app result. `python3 audio_rig.py check` enters and leaves
a rig with no take: run it before a test session (also `uat.py rig-check`).
"""
import os
import signal
import subprocess
import sys
import time

import silent_audio as sa
import take_gate as tg
import wispr_eyes as w

BLACKHOLE_UID = sa.BLACKHOLE_UID
TEXTEDIT = "com.apple.TextEdit"


def _wait_frontmost(bundle_id, seconds=5.0):
    """Whether `bundle_id` became frontmost within `seconds` (polled; activation has no ack)."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if tg.frontmost_bundle() == bundle_id:
            return True
        time.sleep(0.2)  # settle: app activation is asynchronous and signals nothing we can await
    return False


class AppTarget:
    """Any app as the paste target. `prepare` (optional) puts the cursor where the text should
    land, e.g. opens a Gmail compose box; it runs once, after the app is activated."""

    def __init__(self, bundle_id, prepare=None):
        self.bundle_id, self.prepare = bundle_id, prepare

    def activate(self):
        subprocess.run(["open", "-b", self.bundle_id], capture_output=True)

    def close(self):
        """Nothing to close: the caller's app and content stay as the test left them."""

    def ready(self):
        self.activate()
        if self.prepare:
            self.prepare()
        if not _wait_frontmost(self.bundle_id):
            raise tg.SetupFailed("paste-target",
                                 f"{self.bundle_id} did not come to the front "
                                 f"(front is {tg.frontmost_bundle()!r})")


TEXTEDIT_TARGET_FILE = os.path.expanduser("~/.ew-uat-paste-target.txt")


def _osascript(*lines):
    r = subprocess.run(["osascript", *[a for line in lines for a in ("-e", line)]],
                       capture_output=True, text=True, timeout=20)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def _target_doc():
    return f'(first document whose path is "{TEXTEDIT_TARGET_FILE}")'


def close_test_document():
    """Close the test file's TextEdit window, if open. The file is saved, so TextEdit asks nothing."""
    rc, out, _ = _osascript('if application "TextEdit" is running then',
                            'tell application "TextEdit"',
                            f'if exists {_target_doc()} then',
                            f"close {_target_doc()} saving yes", 'return "closed"', "end if",
                            "end tell", "end if", 'return "none"')
    return rc == 0 and out == "closed"


class TextEditTarget(AppTarget):
    """ONE dedicated plain-text file, `~/.ew-uat-paste-target.txt`, emptied and reused by every
    rig. A new untitled document is not used: TextEdit autosaves it into the founder's TextEdit
    folder under a name it invents from the text ("Quarterly Report - Finance"), leaves its
    window open, and asks keep-or-delete when closed by hand (#3774). Never touches a document
    the founder may have open."""

    def __init__(self):
        super().__init__(TEXTEDIT)

    def activate(self):
        _osascript('tell application "TextEdit"', "activate",
                   f"if exists {_target_doc()} then set index of (first window whose document is "
                   f"{_target_doc()}) to 1", "end tell")

    def ready(self):
        if not os.path.exists(TEXTEDIT_TARGET_FILE):
            open(TEXTEDIT_TARGET_FILE, "w").close()
        rc, _, err = _osascript('tell application "TextEdit"', "activate",
                                f'open POSIX file "{TEXTEDIT_TARGET_FILE}"',
                                f'set text of {_target_doc()} to ""', "end tell")
        if rc != 0:
            raise tg.SetupFailed("paste-target", f"TextEdit could not open the test file: {err!r}")
        self.activate()
        if not _wait_frontmost(TEXTEDIT):
            raise tg.SetupFailed("paste-target",
                                 f"TextEdit did not come to the front (front is {tg.frontmost_bundle()!r})")

    def close(self):
        """Keep the test file open for the next rig; `close_test_document()` closes it."""


class AudioRig:
    """`route=False` keeps the real microphone and speaker (only for a take that must hear the
    room, such as the silent probe): the target is still proven, and the BlackHole check is
    skipped through `EW_UAT_SPEAKER_REASON`, which the caller must set. `quiet_app=False` keeps
    the app's sounds as they are, for a take whose subject is those sounds; a `route=False`
    rig never touches them."""

    def __init__(self, target=None, route=True, quiet_app=True):
        self.target = target or TextEditTarget()
        self.use_route = route
        self.quiet_app = quiet_app
        self.route = None
        self.alerts = None
        self.sounds = None
        self.restored = None
        self._old_handlers = {}

    def __enter__(self):
        if tg.declared_target() is not None:
            # Checked before any device moves: a nested rig would overwrite the outer one's restore
            # files and clear its target on exit.
            raise tg.SetupFailed("rig", f"a paste target ({tg.declared_target()}) is already set: "
                                 "no nested rigs; leave the outer one or clear_target() first")
        try:
            if self.use_route:
                # Before any device moves: the dev-app lock and a restorable microphone (#3990).
                self.route = sa.AudioRoute()
                self._install_restore_handlers()
                self.alerts = sa.AlertSink()
                if not self.alerts.apply():
                    raise tg.SetupFailed("audio-route", "alert sounds did not move to BlackHole")
                self.route.apply()
                self._prove_route()
                if self.quiet_app:
                    self.sounds = sa.AppSounds(self.route.client)
                    self.sounds.apply()
            elif not tg.speaker_reason():
                raise tg.SetupFailed("audio-route", "route=False needs EW_UAT_SPEAKER_REASON")
            self.target.ready()
            tg.declare_target(self.target.bundle_id, activate=self.target.activate)
            route = "BlackHole in/out/alerts, app mic pinned" if self.use_route else "REAL mic and speaker"
            print(f"RIG READY: {route}, paste target {self.target.bundle_id}", flush=True)
            return self
        except BaseException as exc:
            self._restore_all()
            if isinstance(exc, (tg.SetupFailed, KeyboardInterrupt)):
                raise
            # SystemExit included: wispr_eyes.connect() exits when the app is gone mid-setup.
            raise tg.SetupFailed("rig", repr(exc)) from exc

    def _install_restore_handlers(self):
        """An interrupt unwinds the take (its own cleanup, then `take_gate.stop_active_take`) and
        then this rig's exit restores BOTH the route and the alert device, in that order. A SIGKILL
        leaves the on-disk restore files for `python3 silent_audio.py restore`."""
        def _unwind(*_):
            raise SystemExit(130)

        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            self._old_handlers[sig] = signal.signal(sig, _unwind)

    def _prove_route(self):
        tg.check_loopback_output()
        for kind in ("input", "system"):
            now = sa._current(kind)
            if now != tg.SILENT_DEVICE:
                raise tg.SetupFailed("audio-route", f"{kind} device is {now!r}, not {tg.SILENT_DEVICE!r}")
        # Read from the RUNNING app through the door, both keys in one snapshot. take_gate's
        # per-take `transport=virtual` stays the proof of what the take captured.
        mic = sa.AppMic.read(self.route.client)
        if mic != sa.AppMic(BLACKHOLE_UID, BLACKHOLE_UID):
            raise tg.SetupFailed("app-microphone",
                                 f"the app's stored microphone is {mic!r}, not {BLACKHOLE_UID}")

    def _restore_all(self):
        """Every step runs even if another fails; True only when all verified. A take still
        running is stopped FIRST, so no recording outlives its route."""
        player_gone, take_idle = tg.stop_active_take()
        tg.clear_target()
        try:
            self.target.close()
        except Exception as close_exc:  # a leftover test document never blocks the restore
            print(f"RIG: could not close the test document: {close_exc!r}", flush=True)
        ok = player_gone and take_idle
        # The app's sounds first: the founder's chime setting comes back even if a device
        # restore then fails.
        parts = (self.sounds, self.route, self.alerts)
        if not player_gone:
            # A test sound may still be playing: every device stays on BlackHole (nothing audible,
            # nothing captured). The on-disk restore files finish the job once it is stopped.
            print("RIG: the test sound is not proven stopped; all audio stays on BlackHole. Stop "
                  "`afplay`, then run `python3 Tests/RuntimeUAT/silent_audio.py restore`", flush=True)
            parts = ()
        elif not take_idle and self.route is not None:
            # The app may still be recording: put the SPEAKERS back but leave the system input and
            # the app's microphone on BlackHole, so it can only hear silence, never the room.
            try:
                self._speakers_back(self.route.original_output)
            except (Exception, SystemExit) as exc:
                print(f"RIG: speakers not put back: {exc!r}", flush=True)
            print("RIG: a take could not be proven stopped; the app's microphone stays on BlackHole. "
                  "Stop the recording, then run `python3 Tests/RuntimeUAT/silent_audio.py restore`", flush=True)
            parts = (self.sounds, self.alerts)  # quiet sounds back is harmless to a live take
        for part in parts:
            if part is None:
                continue
            try:
                ok = bool(part.restore()) and ok
            except (Exception, SystemExit) as restore_exc:  # wispr_eyes.connect() exits if the app went
                print(f"RIG: restore step failed: {restore_exc!r}", flush=True)
                ok = False
        self.route = self.alerts = self.sounds = None
        for sig, old in self._old_handlers.items():
            signal.signal(sig, old)
        self._old_handlers = {}
        self.restored = ok
        return ok

    @staticmethod
    def _speakers_back(device):
        if not sa._restore_device("output", device):
            raise RuntimeError(f"output was not put back to {device!r}")

    def __exit__(self, exc_type, exc, tb):
        if self._restore_all():
            return False
        print("RIG RESTORE INCOMPLETE: run `python3 Tests/RuntimeUAT/silent_audio.py restore`",
              flush=True)
        if exc_type is None:
            # A take that passed while the founder's devices stayed on BlackHole, or while the app
            # may still be recording, is not a pass.
            raise tg.SetupFailed("restore", "a take was not proven stopped, or audio devices or the "
                                 "app microphone were not put back")
        return False


def check():
    """Enter and leave a rig with no take. True when setup and restore both held."""
    rig = AudioRig()
    try:
        with rig:
            pass
    except tg.SetupFailed as exc:
        print(exc, flush=True)
        return False
    if not rig.restored:
        print("RIG CHECK FAIL: setup held but the restore did not verify", flush=True)
        return False
    print("RIG CHECK PASS: setup proven and restored", flush=True)
    return True


def _self_test():
    """Offline: restore failures and nesting, with fake route/alert/target objects."""
    ok = True

    def expect(name, cond):
        nonlocal ok
        ok &= bool(cond)
        print(f"  {'PASS' if cond else 'FAIL'}  {name}")

    class Fake:
        def __init__(self, result=True, boom=False):
            self.result, self.boom, self.calls = result, boom, 0

        def restore(self):
            self.calls += 1
            if self.boom:
                raise RuntimeError("restore exploded")
            return self.result

    class FakeTarget(AppTarget):
        def __init__(self):
            super().__init__("com.example.Fake")
            self.closed = 0

        def close(self):
            self.closed += 1

    print("audio_rig --self-test")
    rig = AudioRig(target=FakeTarget())
    first_alerts = Fake()
    rig.route, rig.alerts = Fake(boom=True), first_alerts
    tg.declare_target("com.example.Fake")
    try:
        rig.__exit__(None, None, None)
        expect("a failed restore after a passing take raises SetupFailed", False)
    except tg.SetupFailed as exc:
        expect("a failed restore after a passing take raises SetupFailed", exc.step == "restore")
    expect("an exploding route restore still restores the alerts",
           rig.restored is False and first_alerts.calls == 1)
    expect("the target was cleared and its document closed", tg.declared_target() is None and rig.target.closed == 1)

    rig = AudioRig(target=FakeTarget())
    alerts = Fake(result=False)
    rig.route, rig.alerts = Fake(), alerts
    expect("a failed restore during an exception does not mask it",
           rig.__exit__(RuntimeError, RuntimeError("x"), None) is False and alerts.calls == 1)

    rig = AudioRig(target=FakeTarget())
    rig.route, rig.alerts = Fake(), Fake()
    expect("a clean restore returns normally", rig.__exit__(None, None, None) is False and rig.restored)

    rig = AudioRig(target=FakeTarget())
    later = Fake()

    class Exits(Fake):
        def restore(self):
            self.calls += 1
            raise SystemExit(1)  # wispr_eyes.connect() when the app disappeared
    rig.route, rig.alerts = Exits(), later
    try:
        rig.__exit__(None, None, None)
    except tg.SetupFailed:
        pass
    expect("an app that vanished during restore still lets the alerts restore", later.calls == 1)

    order = []
    tg.take_started(lambda: order.append("take stopped"), lambda: True)

    class Logs(Fake):
        def restore(self):
            order.append("devices restored")
            return True
    rig = AudioRig(target=FakeTarget())
    rig.route, rig.alerts = Logs(), None
    rig.__exit__(RuntimeError, RuntimeError("take crashed"), None)
    expect("a running take is stopped before the devices are restored",
           order == ["take stopped", "devices restored"])

    tg.take_started(lambda: 1 / 0, lambda: True)
    rig = AudioRig(target=FakeTarget())
    rig.route, rig.alerts = Fake(), Fake()
    expect("a stop that raises but leaves the app idle restores normally",
           rig.__exit__(None, None, None) is False and rig.restored)

    for label, stop, idle in (("a take that stays recording", lambda: None, lambda: False),
                              ("an idle check that raises", lambda: None, lambda: 1 / 0)):
        tg._take = None  # self-test reset: the previous case left an unproven take on purpose
        tg.take_started(stop, idle)
        rig = AudioRig(target=FakeTarget())
        rig._speakers_back = lambda device: None  # never touch the real devices in a self-test
        route = Fake()
        route.original_output = "MacBook Pro Speakers"
        alerts = Fake()
        rig.route, rig.alerts = route, alerts
        try:
            rig.__exit__(None, None, None)
            expect(f"{label}: never a pass", False)
        except tg.SetupFailed as exc:
            expect(f"{label}: SETUP FAILED, app mic left on BlackHole, alerts restored",
                   exc.step == "restore" and route.calls == 0 and alerts.calls == 1)

    class Player:
        def __init__(self):
            self.terminated = False
        def poll(self):
            return None if not self.terminated else -15
        def terminate(self):
            self.terminated = True
        def wait(self, timeout=None):
            return -15
        def kill(self):
            pass
    tg._take = None
    player = Player()
    tg.take_started(lambda: None, lambda: True)
    tg.take_player(player)
    expect("an interrupted take's player is stopped before the restore",
           tg.stop_active_take() == (True, True) and player.terminated)

    tg._take = None
    tg.take_started(lambda: None, lambda: False)
    first = tg.stop_active_take()
    expect("a second cleanup after a failed one is still not proven",
           first == (True, False) and tg.stop_active_take() == (True, False))

    tg._take = None
    sent = []
    tg.take_started(lambda: sent.append("stop"), lambda: False)
    tg.take_stopped()
    expect("a take that stopped itself is still verified, and no second stop is sent",
           tg.stop_active_take() == (True, False) and sent == [])
    try:
        tg.take_started(lambda: None, lambda: True)
        expect("a new take is refused while the previous one is unproven", False)
    except tg.SetupFailed as exc:
        expect("a new take is refused while the previous one is unproven", exc.step == "take-cleanup")

    class Stuck(Player):
        def terminate(self):
            pass
        def wait(self, timeout=None):
            raise subprocess.TimeoutExpired("afplay", timeout)
    tg._take = None
    tg.take_started(lambda: None, lambda: True)
    tg.take_player(Stuck())
    rig = AudioRig(target=FakeTarget())
    alerts = Fake()
    rig.route, rig.alerts = Fake(), alerts
    try:
        rig.__exit__(None, None, None)
        expect("an unkillable player keeps every device on BlackHole", False)
    except tg.SetupFailed:
        expect("an unkillable player keeps every device on BlackHole",
               rig.route is None and alerts.calls == 0)

    tg._take = None
    tg.take_started(lambda: None, lambda: False)
    rig = AudioRig(target=FakeTarget())
    alerts = Fake()
    rig.route, rig.alerts = Fake(), alerts
    rig.route.original_output = "MacBook Pro Speakers"
    rig._speakers_back = lambda device: 1 / 0
    try:
        rig.__exit__(None, None, None)
    except tg.SetupFailed:
        pass
    expect("a failing speakers-only step still restores the alerts", alerts.calls == 1)
    tg._take = None

    class Boom(FakeTarget):
        def ready(self):
            raise SystemExit(1)
    rig = AudioRig(target=Boom(), route=False)
    os_reason = __import__("os").environ
    os_reason["EW_UAT_SPEAKER_REASON"] = "self-test"
    try:
        rig.__enter__()
        expect("an exit during setup becomes SETUP FAILED", False)
    except tg.SetupFailed as exc:
        expect("an exit during setup becomes SETUP FAILED", exc.step == "rig")
    finally:
        os_reason.pop("EW_UAT_SPEAKER_REASON", None)

    # #3990: the app's sounds are restored first, and follow the two safety branches.
    order = []

    class Named(Fake):
        def __init__(self, name):
            super().__init__()
            self.name = name

        def restore(self):
            order.append(self.name)
            return super().restore()
    tg._take = None
    rig = AudioRig(target=FakeTarget())
    rig.sounds, rig.route, rig.alerts = Named("sounds"), Named("route"), Named("alerts")
    rig.__exit__(None, None, None)
    expect("#3990 app sounds are restored before the route and the alerts",
           order == ["sounds", "route", "alerts"] and rig.restored and rig.sounds is None)

    rig = AudioRig(target=FakeTarget())
    sounds, route, alerts = Fake(boom=True), Fake(), Fake()
    rig.sounds, rig.route, rig.alerts = sounds, route, alerts
    try:
        rig.__exit__(None, None, None)
    except tg.SetupFailed:
        pass
    expect("#3990 a sounds restore that raises still restores the route and the alerts",
           route.calls == 1 and alerts.calls == 1 and rig.restored is False)

    tg._take = None
    tg.take_started(lambda: None, lambda: True)
    tg.take_player(Stuck())
    rig = AudioRig(target=FakeTarget())
    sounds = Fake()
    rig.sounds, rig.route, rig.alerts = sounds, Fake(), Fake()
    try:
        rig.__exit__(None, None, None)
    except tg.SetupFailed:
        pass
    expect("#3990 an unkillable player leaves the app sounds untouched too", sounds.calls == 0)

    tg._take = None
    tg.take_started(lambda: None, lambda: False)
    rig = AudioRig(target=FakeTarget())
    rig._speakers_back = lambda device: None
    sounds, route, alerts = Fake(), Fake(), Fake()
    route.original_output = "MacBook Pro Speakers"
    rig.sounds, rig.route, rig.alerts = sounds, route, alerts
    try:
        rig.__exit__(None, None, None)
    except tg.SetupFailed:
        pass
    expect("#3990 an unproven take restores sounds and alerts and leaves the microphone pinned",
           sounds.calls == 1 and alerts.calls == 1 and route.calls == 0)
    tg._take = None

    tg.declare_target("com.example.Outer")
    try:
        AudioRig(target=FakeTarget()).__enter__()
        expect("a nested rig is refused before any device moves", False)
    except tg.SetupFailed as exc:
        expect("a nested rig is refused before any device moves", exc.step == "rig")
    finally:
        tg.clear_target()

    # #4133 harness contract: real setup/cleanup, fake OS and app boundaries.
    from unittest import mock
    import preflight

    class MutedRoute(Fake):
        client = None
        def apply(self):
            pass

    class Alerts(Fake):
        def apply(self):
            return True

    class Target(FakeTarget):
        ready_calls = 0
        def ready(self):
            self.ready_calls += 1

    route, alerts, target = MutedRoute(), Alerts(), Target()
    rig = AudioRig(target=target, quiet_app=False)
    with mock.patch.object(sa, "AudioRoute", return_value=route), \
            mock.patch.object(sa, "AlertSink", return_value=alerts), \
            mock.patch.object(sa, "_current", return_value=tg.SILENT_DEVICE), \
            mock.patch.object(sa.AppMic, "read", return_value=sa.AppMic(BLACKHOLE_UID, BLACKHOLE_UID)), \
            mock.patch.object(tg, "output_device", return_value=tg.SILENT_DEVICE), \
            mock.patch.object(preflight, "output_volume", return_value=("warn", "muted", 75, True)), \
            mock.patch.object(rig, "_install_restore_handlers"):
        refused = False
        try:
            rig.__enter__()
        except tg.SetupFailed as exc:
            refused = exc.step == "audio-output"
        else:
            rig.__exit__(None, None, None)
        expect("muted setup refuses before target readiness and restores both routes",
               refused and target.ready_calls == 0 and target.closed == 1
               and route.calls == 1 and alerts.calls == 1 and rig.restored
               and tg.declared_target() is None)
    print("PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__" and sys.argv[1:] == ["check"]:
    sys.exit(0 if check() else 1)
if __name__ == "__main__" and sys.argv[1:] == ["close-target"]:
    print("closed test document window", close_test_document())
    sys.exit(0)
if __name__ == "__main__" and sys.argv[1:] == ["--self-test"]:
    sys.exit(0 if _self_test() else 1)
