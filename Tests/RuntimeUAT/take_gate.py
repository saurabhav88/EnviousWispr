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

import preflight

SWITCH = "/opt/homebrew/bin/SwitchAudioSource"
SILENT_DEVICE = "BlackHole 2ch"
LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
REPAIR = "Not an app result. Repair the setup or the harness, rerun the failed step, then continue."

_target = None
_activate = None
_paste = None
_takes = 1


class SetupFailed(RuntimeError):
    def __init__(self, step, detail):
        super().__init__(f"SETUP FAILED [{step}]: {detail}. {REPAIR}")
        self.step = step


class CouldNotTell(RuntimeError):
    def __init__(self, detail):
        super().__init__(f"COULD NOT TELL: {detail}. Not an app result.")


_take = None  # {"stop", "idle", "player", "stopped"}: kept until the take is PROVEN over


def take_started(stop, idle):
    """Register the running take: `stop()` ends it (menu Stop, key up) and `idle()` answers
    whether the app is no longer recording. The registration stays until `stop_active_take`
    PROVES both the player gone and the app idle; the audio rig runs that before it puts any
    device back (#3764). A previous take that is not proven over refuses the new one."""
    global _take
    if _take is not None and stop_active_take() != (True, True):
        raise SetupFailed("take-cleanup", "the previous take is not proven stopped")
    _take = {"stop": stop, "idle": idle, "player": None, "stopped": False}


def take_player(proc):
    """The running take's audio player, so an interrupted take stops it before output returns
    to the speakers."""
    if _take is not None:
        _take["player"] = proc


def take_stopped():
    """The take sent its own stop (menu Stop, key up). The registration stays: the next
    `stop_active_take` verifies it without sending another stop."""
    if _take is not None:
        _take["stopped"] = True


def _player_gone(proc):
    """Stop the player and prove it exited (True), or report it may still play (False)."""
    if proc is None:
        return True
    for attempt in (getattr(proc, "terminate", None), getattr(proc, "kill", None)):
        try:
            if proc.poll() is not None:
                return True
            if attempt is not None:
                attempt()
            proc.wait(timeout=5)
        except BaseException:
            pass
    try:
        return proc.poll() is not None
    except BaseException:
        return False


def stop_active_take():
    """Prove the registered take over: (player_gone, app_idle). Sends the stop only if the take
    did not send its own. Clears the registration ONLY when both are proven; otherwise a later
    call re-checks. Never raises: it runs on the way out of a failure, including an interrupt."""
    global _take
    take = _take
    if take is None:
        return True, True
    player_ok = _player_gone(take["player"])
    if not take["stopped"]:
        try:
            take["stop"]()
        except BaseException as exc:
            print(f"TAKE CLEANUP: stop raised {exc!r}", flush=True)
        take["stopped"] = True
    try:
        idle = bool(take["idle"]())
    except BaseException as exc:
        print(f"TAKE CLEANUP: idle check raised {exc!r}", flush=True)
        idle = False
    if player_ok and idle:
        _take = None
    else:
        print(f"TAKE CLEANUP NOT PROVEN: player_gone={player_ok} app_idle={idle}", flush=True)
    return player_ok, idle


def declare_target(bundle_id, activate=None, paste=None, takes=1):
    """Name the app that must be frontmost for the take (its bundle id, e.g. com.apple.TextEdit).
    `activate` (optional) brings it back to the front; the gate calls it once before refusing.
    `paste`: where the text must land when that is another app (a launcher panel), or
    CALLER_VERIFIES when the caller checks the landing itself; default: the same app.
    `takes`: recordings the take deliberately makes (default 1).
    Scripts that set up their own route call it per take; `clear_target()` when they are done."""
    global _target, _activate, _paste, _takes
    _target, _activate, _paste, _takes = bundle_id, activate, paste, takes


def clear_target():
    global _target, _activate, _paste, _takes
    _target = _activate = _paste = None
    _takes = 1


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


def check_loopback_output():
    """Prove the current loopback route and mute state at this admission point (#4133).

    The bookends refuse an observed route change; they are not an atomic OS snapshot.
    Read only: mute/volume changes would need device-specific recovery journals.
    """
    device = output_device()
    if device != SILENT_DEVICE:
        raise SetupFailed(
            "audio-route",
            f"output is {device!r}, not {SILENT_DEVICE!r}. Use audio_rig.AudioRig, or set "
            "EW_UAT_SPEAKER_REASON for a deliberate speaker take")
    _classification, _detail, _level, muted = preflight.output_volume()
    after = output_device()
    if after != device:
        raise SetupFailed("audio-route", f"output changed from {device!r} to {after!r} while reading mute")
    if muted is True:
        raise SetupFailed(
            "audio-output",
            f"{SILENT_DEVICE} is muted. Cleanup may restore your physical output; verify "
            "BlackHole's identity before clearing its mute and retrying. Do not blindly "
            "unmute the current default output")
    if muted is not False:
        raise SetupFailed("audio-output", f"could not read {SILENT_DEVICE}'s output mute state; "
                          "repair the osascript output-volume probe before retrying")
    # The reader also classifies an acoustic volume floor. Loopback mute admission does
    # not inherit that physical-speaker policy; an unmuted flag is not signal proof.


def check_before_play():
    """Refuse to play take audio unless the setup holds. Call right before the sound starts."""
    reason = speaker_reason()
    if reason:
        print(f"SPEAKER TAKE (EW_UAT_SPEAKER_REASON={reason!r}): BlackHole check skipped", flush=True)
    else:
        check_loopback_output()
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


CALLER_VERIFIES = "*"  # paste=CALLER_VERIFIES: the caller checks where the text landed itself


def classify(chunk, target, speaker_ok=False, paste=None, takes=1):
    """Pure verdict over the app.log entries one take wrote. Returns (outcome, detail) where
    outcome is "APP", "SETUP" or "COULD_NOT_TELL".

    `paste`: the bundle the text must land in (default `target`), or CALLER_VERIFIES when the
    caller checks the landing itself (a launcher panel, an app swap). `takes`: recordings this
    take deliberately makes. The evidence ends at the `takes`-th terminal line: a recording that
    STARTS after that is the app's own behaviour (#3107), reported, never mixed into the evidence."""
    # Safety holds across the WHOLE window, not just this take's own slice: a real-mic capture or
    # a paste into another app anywhere in it is SETUP, never hidden behind the cut.
    expected_paste = target if paste is None else paste
    if not speaker_ok and any(t != "virtual" for t in TRANSPORT.findall(chunk)):
        return "SETUP", f"a capture in this window was not through the virtual device: {TRANSPORT.findall(chunk)}"
    if expected_paste not in (None, CALLER_VERIFIES) and any(p != expected_paste for p in PASTE.findall(chunk)):
        return "SETUP", f"a paste in this window left the named target {expected_paste!r}: {PASTE.findall(chunk)}"
    lines = chunk.splitlines()
    cut, seen = len(lines), 0
    for i, line in enumerate(lines):
        if TERMINAL.search(line):
            seen += 1
            if seen == takes:
                cut = i + 1
                break
    own = "\n".join(lines[:cut])
    after = "\n".join(lines[cut:])
    # A paste logged just after the terminal still belongs to this take (paste precedes the
    # terminal in practice; keep any paste before the next recording starts).
    tail_pastes = PASTE.findall(after.split("Recording started.")[0])
    extra = ""
    if "Recording started." in after:
        extra = ("; NOTE: another recording started after this take (#3107: a menu Stop on a loopback "
                 "mic starts an unrequested take); it is the app's behaviour, outside this take's evidence")
    transports = TRANSPORT.findall(own)
    pastes = PASTE.findall(own) + tail_pastes
    terminals = TERMINAL.findall(own)
    if transports and terminals and (len(transports) != takes or len(terminals) != takes):
        return "COULD_NOT_TELL", (f"capture/terminal count does not match this take (expected {takes}, "
                                  f"captures={transports}, terminals={terminals}){extra}")
    if not transports:
        return "COULD_NOT_TELL", ("no capture line (ZERO_PREFIX_MEASURE) in app.log for this take; "
                                  "if the report above shows no recording either, read it as the app's")
    if not speaker_ok and any(t != "virtual" for t in transports):
        return "SETUP", f"capture was not through the virtual device: transports={transports}"
    if expected_paste not in (None, CALLER_VERIFIES) and any(p != expected_paste for p in pastes):
        return "SETUP", f"paste left the named target {expected_paste!r}: pasted into {pastes}"
    if len(terminals) < takes:
        return "COULD_NOT_TELL", f"expected {takes} dictation_terminal line(s), found {len(terminals)}"
    if (expected_paste != CALLER_VERIFIES and "completed" in terminals and not pastes):
        return "COULD_NOT_TELL", "a completed take with no paste line: delivery cannot be placed"
    note = f"transports={transports} terminals={terminals} pasted_into={pastes or 'nothing'}{extra}"
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
    outcome, detail = classify(text, _target, speaker_ok=bool(speaker_reason()),
                               paste=_paste, takes=_takes)
    if outcome == "SETUP":
        raise SetupFailed("take-evidence", detail)
    if outcome == "COULD_NOT_TELL":
        raise CouldNotTell(detail)
    print(f"TAKE SETUP PROVEN: {detail}", flush=True)
    return detail


def _output_mute_self_test():
    """Harness contract: exercise real admission with fake OS reads, never audio or an app."""
    from unittest import mock
    import preflight

    passed = True
    target = "com.example.MuteControl"
    rows = (
        ("muted output refuses", 75, True, [SILENT_DEVICE] * 2, "audio-output"),
        ("unmuted output admits", 75, False, [SILENT_DEVICE] * 2, None),
        ("loopback does not inherit the acoustic volume floor", 19, False, [SILENT_DEVICE] * 2, None),
        ("unknown mute refuses", None, None, [SILENT_DEVICE] * 2, "audio-output"),
        ("wrong output refuses", 75, False, ["Speakers"], "audio-route"),
        ("output changes during the mute read", 75, False, [SILENT_DEVICE, "Speakers"], "audio-route"),
    )
    with mock.patch.dict(os.environ, {"EW_UAT_SPEAKER_REASON": ""}), \
            mock.patch(__name__ + "._target", target), \
            mock.patch(__name__ + ".frontmost_bundle", return_value=target):
        for name, level, muted, devices, expected in rows:
            reading = (*preflight.classify_volume(level, muted), level, muted)
            with mock.patch(__name__ + ".output_device", side_effect=devices), \
                    mock.patch.object(preflight, "output_volume", return_value=reading):
                got = None
                try:
                    check_before_play()
                except SetupFailed as exc:
                    got = exc.step
                good = got == expected
                passed &= good
                print(f"  {'PASS' if good else 'FAIL'}  {name}: step={got!r}, expected={expected!r}")

        with mock.patch(__name__ + ".output_device", return_value=SILENT_DEVICE), \
                mock.patch.object(preflight, "output_volume", side_effect=[
                    ("ok", "unmuted", 75, False), ("warn", "muted", 75, True)]) as reader:
            check_before_play()
            refused = False
            try:
                check_before_play()
            except SetupFailed as exc:
                refused = exc.step == "audio-output"
            good = refused and reader.call_count == 2
            passed &= good
            print(f"  {'PASS' if good else 'FAIL'}  a later take re-reads mute instead of caching readiness")

        with mock.patch.dict(os.environ, {"EW_UAT_SPEAKER_REASON": "self-test"}), \
                mock.patch(__name__ + ".output_device", side_effect=AssertionError("speaker route queried")), \
                mock.patch.object(preflight, "output_volume", side_effect=AssertionError("speaker mute queried")):
            check_before_play()
            print("  PASS  deliberate speaker take keeps its existing loopback bypass")
    return bool(passed)


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
    second = ("[x] [INFO] [Pipeline] Recording started. Backend: parakeet, streaming=false\n"
              + nospeech)
    expect("an unrequested second take after this one (#3107) stays outside the evidence",
           classify(p_te + v + second, te), "APP")
    expect("two recordings before this take's terminal", classify(v.splitlines(True)[0] * 2 + v + p_te, te),
           "COULD_NOT_TELL")
    expect("a deliberate two-take hold with takes=2", classify(p_te + v + p_te + v, te, takes=2), "APP")
    p_lp = "[x] [INFO] [PipelineTiming] Paste cascade: tier=ax_direct, app=com.enviouswispr.uat.launcherpanel, duration=5ms\n"
    expect("a launcher panel paste with paste= that panel", classify(p_lp + v, te, paste="com.enviouswispr.uat.launcherpanel"), "APP")
    expect("a launcher panel paste without declaring it", classify(p_lp + v, te), "SETUP")
    expect("caller-verified landing accepts any paste", classify(p_gh + v, te, paste=CALLER_VERIFIES), "APP")
    expect("caller-verified landing still requires the virtual capture", classify(p_gh + b, te, paste=CALLER_VERIFIES), "SETUP")
    expect("a real-mic capture after the cut is still SETUP", classify(p_te + v + "[x] Recording started.\n" + b, te), "SETUP")
    expect("a wrong-app paste after the cut is still SETUP", classify(p_te + v + "[x] Recording started.\n" + p_gh, te), "SETUP")
    expect("two terminals with one capture is COULD NOT TELL", classify(p_te + v + v.splitlines(True)[1], te, takes=2), "COULD_NOT_TELL")
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
    ok = _output_mute_self_test() and ok
    print("PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    import sys
    sys.exit(0 if _self_test() else 1)
