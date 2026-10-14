"""Set up, prove and undo everything an audio take needs (#3764).

    with AudioRig() as rig:                      # TextEdit: a NEW document, never an existing one
        w.test_recording(sentence="...")
    with AudioRig(target=AppTarget("com.google.Chrome", prepare=open_gmail_compose)) as rig:
        w.record_tts("...")

Entering the rig:
1. routes system output, input and alert sounds to BlackHole and pins the app's microphone to it
   (silent_audio.AudioRoute / AlertSink, restore file on disk first);
2. READS BACK all four and refuses (`take_gate.SetupFailed`) unless each is BlackHole;
3. prepares the paste target, proves it is frontmost and names it to `take_gate`, which
   re-checks it before every take and checks the take's own app.log lines afterwards.
Leaving it restores the devices and the app's microphone and verifies them; a failed restore is
printed and leaves `python3 silent_audio.py restore` to finish.

Every failure here is SETUP, never an app result. `python3 audio_rig.py check` enters and leaves
a rig with no take: run it before a test session (also `uat.py rig-check`).
"""
import signal
import subprocess
import sys
import time

import silent_audio as sa
import take_gate as tg
import wispr_eyes as w

BLACKHOLE_UID = "BlackHole2ch_UID"
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


class TextEditTarget(AppTarget):
    """A NEW TextEdit document. Never clears or reuses one the founder may have open."""

    def __init__(self):
        super().__init__(TEXTEDIT)
        self.document = None

    def activate(self):
        subprocess.run(["osascript", "-e", 'tell application "TextEdit" to activate'],
                       capture_output=True, timeout=20)

    def ready(self):
        r = subprocess.run(["osascript", "-e", 'tell application "TextEdit"', "-e", "activate",
                            "-e", "set d to make new document", "-e", "return name of d",
                            "-e", "end tell"],
                           capture_output=True, text=True, timeout=20)
        if r.returncode != 0 or not r.stdout.strip():
            raise tg.SetupFailed("paste-target", f"TextEdit refused a new document: {r.stderr.strip()!r}")
        self.document = r.stdout.strip()
        if not _wait_frontmost(TEXTEDIT):
            raise tg.SetupFailed("paste-target",
                                 f"TextEdit did not come to the front (front is {tg.frontmost_bundle()!r})")

    def close(self):
        """Close only the document this target made, unsaved (it holds test dictation)."""
        if not self.document:
            return
        name = self.document.replace('"', '\\"')
        subprocess.run(["osascript", "-e", 'tell application "TextEdit"', "-e",
                        f'if exists document "{name}" then close document "{name}" saving no',
                        "-e", "end tell"], capture_output=True, timeout=20)
        self.document = None


class AudioRig:
    """`route=False` keeps the real microphone and speaker (only for a take that must hear the
    room, such as the silent probe): the target is still proven, and the BlackHole check is
    skipped through `EW_UAT_SPEAKER_REASON`, which the caller must set."""

    def __init__(self, target=None, route=True):
        self.target = target or TextEditTarget()
        self.use_route = route
        self.route = None
        self.alerts = None
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
                self.route = sa.AudioRoute()
                self._install_restore_handlers()
                self.alerts = sa.AlertSink()
                if not self.alerts.apply():
                    raise tg.SetupFailed("audio-route", "alert sounds did not move to BlackHole")
                self.route.apply()
                self._prove_route()
            elif not tg.speaker_reason():
                raise tg.SetupFailed("audio-route", "route=False needs EW_UAT_SPEAKER_REASON")
            self.target.ready()
            tg.declare_target(self.target.bundle_id, activate=self.target.activate)
            route = "BlackHole in/out/alerts, app mic pinned" if self.use_route else "REAL mic and speaker"
            print(f"RIG READY: {route}, paste target {self.target.bundle_id}", flush=True)
            return self
        except Exception as exc:
            self._restore_all()
            if isinstance(exc, tg.SetupFailed):
                raise
            raise tg.SetupFailed("rig", repr(exc)) from exc

    def _install_restore_handlers(self):
        """An interrupt restores BOTH the route and the alert device, then exits (a SIGKILL leaves
        the on-disk restore files for `python3 silent_audio.py restore`)."""
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            self._old_handlers[sig] = signal.signal(
                sig, lambda *_: (self._restore_all(), sys.exit(130)))

    def _prove_route(self):
        for kind in ("output", "input", "system"):
            now = sa._current(kind)
            if now != tg.SILENT_DEVICE:
                raise tg.SetupFailed("audio-route", f"{kind} device is {now!r}, not {tg.SILENT_DEVICE!r}")
        choice = w.read_input_choice()
        if choice.uid != BLACKHOLE_UID:
            raise tg.SetupFailed("app-microphone",
                                 f"the app's stored microphone is {choice!r}, not {BLACKHOLE_UID}")

    def _restore_all(self):
        """Every step runs even if another fails; True only when all verified."""
        tg.clear_target()
        try:
            self.target.close()
        except Exception as close_exc:  # a leftover test document never blocks the restore
            print(f"RIG: could not close the test document: {close_exc!r}", flush=True)
        ok = True
        for part in (self.route, self.alerts):
            if part is None:
                continue
            try:
                ok = bool(part.restore()) and ok
            except Exception as restore_exc:
                print(f"RIG: restore step failed: {restore_exc!r}", flush=True)
                ok = False
        self.route = self.alerts = None
        for sig, old in self._old_handlers.items():
            signal.signal(sig, old)
        self._old_handlers = {}
        self.restored = ok
        return ok

    def __exit__(self, exc_type, exc, tb):
        if self._restore_all():
            return False
        print("RIG RESTORE INCOMPLETE: run `python3 Tests/RuntimeUAT/silent_audio.py restore`",
              flush=True)
        if exc_type is None:
            # A take that passed while the founder's devices stayed on BlackHole is not a pass.
            raise tg.SetupFailed("restore", "audio devices or the app microphone were not put back")
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

    tg.declare_target("com.example.Outer")
    try:
        AudioRig(target=FakeTarget()).__enter__()
        expect("a nested rig is refused before any device moves", False)
    except tg.SetupFailed as exc:
        expect("a nested rig is refused before any device moves", exc.step == "rig")
    finally:
        tg.clear_target()
    print("PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__" and sys.argv[1:] == ["check"]:
    sys.exit(0 if check() else 1)
if __name__ == "__main__" and sys.argv[1:] == ["--self-test"]:
    sys.exit(0 if _self_test() else 1)
