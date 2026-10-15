"""The one gate every audio take passes through (#3764).

A take that plays sound into EnviousWispr is only an APP result when its setup is proven:
sound goes to BlackHole (nothing audible, nothing else captured), a paste target was named,
and that target is frontmost when the sound plays. Afterwards the app's own log must show the
capture came through the virtual device and the paste landed in the named target.

Three outcomes, never two:
- APP: setup proven; whatever the take shows is about the app.
- SETUP FAILED (`SetupFailed`): a setup step did not hold. Not an app result. Fix the setup or
  the harness, then rerun the step.
- COULD NOT TELL (`CouldNotTell`): the evidence was missing. Not an app result either.

`AudioRig` (audio_rig.py) sets all of this up. Scripts that route BlackHole themselves call
`declare_target(bundle_id)` once their target is ready. A deliberate speaker or real-mic take
sets `EW_UAT_SPEAKER_REASON=<why>`: the BlackHole check is skipped, loudly, and the target
check still applies.

No wispr_eyes import here: wispr_eyes and silent_audio both import this module.
"""
import os
import re
import subprocess

SWITCH = "/opt/homebrew/bin/SwitchAudioSource"
SILENT_DEVICE = "BlackHole 2ch"
LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
REPAIR = "Not an app result. Repair the setup or the harness, rerun the failed step, then continue."

_target = None
_activate = None


class SetupFailed(RuntimeError):
    def __init__(self, step, detail):
        super().__init__(f"SETUP FAILED [{step}]: {detail}. {REPAIR}")
        self.step = step


class CouldNotTell(RuntimeError):
    def __init__(self, detail):
        super().__init__(f"COULD NOT TELL: {detail}. Not an app result.")


_take = None  # {"stop": callable, "idle": callable, "player": Popen or None}


def take_started(stop, idle):
    """Register the running take: `stop()` ends it (menu Stop, key up) and `idle()` answers
    whether the app is no longer recording. Whatever ends the run, `stop_active_take` stops the
    player and the take and PROVES the app idle before the audio rig puts the devices back."""
    global _take
    _take = {"stop": stop, "idle": idle, "player": None}


def take_player(proc):
    """The running take's audio player, so an interrupted take stops it before output returns
    to the speakers."""
    if _take is not None:
        _take["player"] = proc


def take_stopped():
    """The take ended normally: nothing left to stop."""
    global _take
    _take = None


def stop_active_take():
    """Stop a registered take's player and capture, then verify the app is idle. Returns True
    when nothing was running or the stop is proven; never raises (it runs on the way out of a
    failure, including an interrupt)."""
    global _take
    take, _take = _take, None
    if take is None:
        return True
    proc = take["player"]
    if proc is not None:
        try:
            if proc.poll() is None:
                proc.terminate()
            proc.wait(timeout=5)
        except BaseException:
            try:
                proc.kill()
            except BaseException:
                pass
    try:
        take["stop"]()
    except BaseException as exc:
        print(f"TAKE CLEANUP: stop raised {exc!r}", flush=True)
    try:
        idle = bool(take["idle"]())
    except BaseException as exc:
        print(f"TAKE CLEANUP: idle check raised {exc!r}", flush=True)
        idle = False
    print("TAKE STOPPED and verified idle before the restore" if idle else
          "TAKE CLEANUP FAILED: the app may still be recording", flush=True)
    return idle


def declare_target(bundle_id, activate=None):
    """Name the app the take must paste into (its bundle id, e.g. com.apple.TextEdit).
    `activate` (optional) brings it back to the front; the gate calls it once before refusing.
    Scripts that set up their own route call it per take; `clear_target()` when they are done."""
    global _target, _activate
    _target, _activate = bundle_id, activate


def clear_target():
    global _target, _activate
    _target = _activate = None


def declared_target():
    return _target


def speaker_reason():
    return os.environ.get("EW_UAT_SPEAKER_REASON", "").strip()


def output_device():
    """The current system output device, or raise SetupFailed when it cannot be read."""
    if not os.path.exists(SWITCH):
        raise SetupFailed("audio-route", f"{SWITCH} is missing (brew install switchaudio-osx)")
    r = subprocess.run([SWITCH, "-c", "-t", "output"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        raise SetupFailed("audio-route", f"cannot read the output device: {r.stderr.strip()!r}")
    return r.stdout.strip()


def frontmost_bundle():
    """The frontmost app's bundle id, read fresh from LaunchServices (`lsappinfo`), or raise
    SetupFailed. Not `NSWorkspace.frontmostApplication`: it is updated by run-loop notifications,
    which a long-running script that never pumps its run loop does not receive."""
    try:
        asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=5).stdout.strip()
        out = subprocess.run(["lsappinfo", "info", "-only", "bundleid", asn],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception as exc:
        raise SetupFailed("paste-target", f"cannot read the frontmost app: {exc!r}")
    m = re.search(r'bundleID="([^"]+)"', out)
    if not asn or not m:
        raise SetupFailed("paste-target", f"cannot read the frontmost app (lsappinfo said {out.strip()!r})")
    return m.group(1)


def check_before_play():
    """Refuse to play take audio unless the setup holds. Call right before the sound starts."""
    reason = speaker_reason()
    if reason:
        print(f"SPEAKER TAKE (EW_UAT_SPEAKER_REASON={reason!r}): BlackHole check skipped", flush=True)
    else:
        device = output_device()
        if device != SILENT_DEVICE:
            raise SetupFailed(
                "audio-route",
                f"output is {device!r}, not {SILENT_DEVICE!r}. Use audio_rig.AudioRig, or set "
                "EW_UAT_SPEAKER_REASON for a deliberate speaker take")
    if _target is None:
        raise SetupFailed(
            "paste-target",
            "no paste target named. Use audio_rig.AudioRig(target=...) or take_gate.declare_target()")
    front = frontmost_bundle()
    if front != _target and _activate is not None:
        _activate()
        front = _wait_front(_target)
    if front != _target:
        raise SetupFailed("paste-target", f"frontmost is {front!r}, not the named target {_target!r}")


def _wait_front(bundle_id, seconds=3.0):
    import time
    deadline = time.monotonic() + seconds
    front = frontmost_bundle()
    while front != bundle_id and time.monotonic() < deadline:
        time.sleep(0.2)  # settle: app activation is asynchronous and signals nothing we can await
        front = frontmost_bundle()
    return front


def log_offset():
    try:
        return os.path.getsize(LOG)
    except OSError as exc:
        raise SetupFailed("app-log", f"cannot read {LOG}: {exc!r}")


def log_since(offset):
    try:
        with open(LOG, "rb") as fh:
            fh.seek(offset)
            return fh.read().decode("utf-8", "replace")
    except OSError as exc:
        raise CouldNotTell(f"cannot read {LOG}: {exc!r}")


TRANSPORT = re.compile(r"ZERO_PREFIX_MEASURE transport=(\S+)")
PASTE = re.compile(r"Paste cascade: tier=\S+?, app=([^,\s]+),")
TERMINAL = re.compile(r"dictation_terminal result=(\S+)")


def classify(chunk, target, speaker_ok=False):
    """Pure verdict over the app.log lines one take wrote. Returns (outcome, detail) where outcome
    is "APP", "SETUP" or "COULD_NOT_TELL"."""
    transports = TRANSPORT.findall(chunk)
    pastes = PASTE.findall(chunk)
    terminals = TERMINAL.findall(chunk)
    if len(transports) > 1 or len(terminals) > 1:
        hint = ""
        if chunk.count("Recording started.") > 1:
            hint = ("; a second recording STARTED inside this take, the shape of #3107 (a menu Stop on "
                    "a loopback mic starts an unrequested take): use push-to-talk (record_tts) for it")
        return "COULD_NOT_TELL", (f"more than one recording in this take (captures={transports}, "
                                  f"terminals={terminals}); the evidence cannot be tied to one take{hint}")
    if not transports:
        return "COULD_NOT_TELL", ("no capture line (ZERO_PREFIX_MEASURE) in app.log for this take; "
                                  "if the report above shows no recording either, read it as the app's")
    if not speaker_ok and any(t != "virtual" for t in transports):
        return "SETUP", f"capture was not through the virtual device: transports={transports}"
    if target is not None and any(p != target for p in pastes):
        return "SETUP", f"paste left the named target {target!r}: pasted into {pastes}"
    if not terminals:
        return "COULD_NOT_TELL", "no dictation_terminal line for this take"
    if terminals[0] == "completed" and not pastes:
        return "COULD_NOT_TELL", "a completed take with no paste line: delivery cannot be placed"
    note = f"transports={transports} terminal={terminals[0]} pasted_into={pastes or 'nothing'}"
    return "APP", note


def check_player(returncode, killed_by_harness=False):
    """A take whose sound never played records silence and reads like an app failure. Call with
    the player's exit status after the recording stopped."""
    if returncode is None:
        raise SetupFailed("playback", "the audio player never finished")
    if returncode != 0 and not killed_by_harness:
        raise SetupFailed("playback", f"afplay exited {returncode}: the take heard no speech")


def check_after_take(evidence):
    """Raise SetupFailed / CouldNotTell unless the take's own log lines prove its setup.
    `evidence` is the take's log text (wispr_eyes passes its rotation-proof
    `log_entries_since`), or a byte offset into app.log for scripts that track one."""
    text = log_since(evidence) if isinstance(evidence, int) else evidence
    if not isinstance(text, str):
        raise CouldNotTell(f"no readable log evidence for this take ({type(evidence).__name__})")
    outcome, detail = classify(text, _target, speaker_ok=bool(speaker_reason()))
    if outcome == "SETUP":
        raise SetupFailed("take-evidence", detail)
    if outcome == "COULD_NOT_TELL":
        raise CouldNotTell(detail)
    print(f"TAKE SETUP PROVEN: {detail}", flush=True)
    return detail


def _self_test():
    ok = True

    def expect(name, got, want):
        nonlocal ok
        good = got[0] == want
        ok &= good
        print(f"  {'PASS' if good else 'FAIL'}  {name}: {got}")

    te = "com.apple.TextEdit"
    v = ("[x] [INFO] [Audio] ZERO_PREFIX_MEASURE transport=virtual wake_ms=0\n"
         "[x] [INFO] [Telemetry] dictation_terminal result=completed reason=nil take=A\n")
    nospeech = ("[x] [INFO] [Audio] ZERO_PREFIX_MEASURE transport=virtual wake_ms=0\n"
                "[x] [INFO] [Telemetry] dictation_terminal result=discarded reason=no_speech take=A\n")
    b = ("[x] [INFO] [Audio] ZERO_PREFIX_MEASURE transport=built_in wake_ms=0\n"
         "[x] [INFO] [Telemetry] dictation_terminal result=completed reason=nil take=B\n")
    p_te = "[x] [INFO] [PipelineTiming] Paste cascade: tier=ax_direct, app=com.apple.TextEdit, duration=5ms\n"
    p_gh = "[x] [INFO] [PipelineTiming] Paste cascade: tier=cgevent, app=com.mitchellh.ghostty, duration=58ms\n"
    print("take_gate --self-test")
    expect("virtual capture, pasted into the target", classify(v + p_te, te), "APP")
    expect("completed take with no paste line", classify(v, te), "COULD_NOT_TELL")
    expect("discarded take with no paste line", classify(nospeech, te), "APP")
    expect("two recordings in one take", classify(v + p_te + v + p_te, te), "COULD_NOT_TELL")
    expect("capture but no terminal line", classify(v.splitlines(True)[0] + p_te, te), "COULD_NOT_TELL")
    expect("speaker capture", classify(b + p_te, te), "SETUP")
    expect("speaker capture on a declared speaker take", classify(b + p_te, te, speaker_ok=True), "APP")
    expect("pasted into another app", classify(v + p_gh, te), "SETUP")
    expect("one of two pastes left the target", classify(v + p_te + p_gh, te), "SETUP")
    for code, killed, want in ((0, False, "OK"), (1, False, "SETUP"), (-15, True, "OK"), (None, False, "SETUP")):
        try:
            check_player(code, killed)
            got = ("OK",)
        except SetupFailed as exc:
            got = ("SETUP", exc.step)
        expect(f"player exit {code} killed={killed}", got, want)
    expect("no capture line", classify(p_te, te), "COULD_NOT_TELL")
    expect("empty log", classify("", te), "COULD_NOT_TELL")
    # The gate refuses before playing when nothing is set up.
    clear_target()
    try:
        os.environ["EW_UAT_SPEAKER_REASON"] = "self-test"
        check_before_play()
        expect("no target named refuses", ("PLAYED",), "SETUP")
    except SetupFailed as exc:
        expect("no target named refuses", ("SETUP", exc.step), "SETUP")
    finally:
        os.environ.pop("EW_UAT_SPEAKER_REASON", None)
    declare_target("com.example.NotFrontmost")
    try:
        os.environ["EW_UAT_SPEAKER_REASON"] = "self-test"
        check_before_play()
        expect("a target that is not frontmost refuses", ("PLAYED",), "SETUP")
    except SetupFailed as exc:
        expect("a target that is not frontmost refuses", ("SETUP", exc.step), "SETUP")
    finally:
        os.environ.pop("EW_UAT_SPEAKER_REASON", None)
        clear_target()
    print("PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    import sys
    sys.exit(0 if _self_test() else 1)
