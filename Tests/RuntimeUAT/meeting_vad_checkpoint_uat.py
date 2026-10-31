#!/usr/bin/env python3
"""#4254 responsiveness checkpoint: actions DURING a meeting Whisper pass's speech detection.

    python3 Tests/RuntimeUAT/meeting_vad_checkpoint_uat.py --run-dir <dir> [--minutes 25]

Run with Bash `run_in_background: true`, holding the shared dev-app lock, with ONE debug
instance of THIS worktree's build running and Debug Mode on. Reuses `meeting_uat.py`'s rig,
identity, door, players and cleanup helpers.

Steps (one owned test meeting; no other meeting is touched):
1. Baseline: dictation start responsiveness per engine, no meeting: the dev door's `dictation
   start` round trip (request until the take exists), then `stop`, silent BlackHole input.
2. Record one `--minutes` test meeting (the scripted conversation plus 20 s of silence, looped)
   with the meeting transcript engine set to Whisper; Stop; wait for ready.
3. Passes on demand: `meeting retry --engine whisper` (the retry endpoint defaults to
   Parakeet). Each pass's detection is bracketed by the app's own counts-only lines
   `whisper_meeting_vad_start token=T` and `whisper_meeting_vad outcome=... token=T`. An
   action fires as soon as the start line is seen (no artificial pause) and counts as DURING
   detection only when the outcome line for that token is still absent once the action's door
   reply has returned. Actions: dictation starts on Parakeet (meeting-owned model route) and on
   Whisper (shared model route), a switch into Whisper and away from it, user-style Quit
   (terminate the verified PID; its exit, new crash reports, relaunch, the meeting ready
   again), and Delete last (the meeting's row and folder gone).
4. Sampled residency: the app's footprint every 1 s across one pass.

Prints JSON rows; receipt <run dir>/meeting-vad-checkpoint.json. Exit 0 PASS, 1 FAIL, 2 COULD
NOT TELL, 3 SETUP FAILED. Settings restored at the end.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import meeting_uat as m  # noqa: E402

LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")


def log_size():
    return os.path.getsize(LOG)


def log_since(offset):
    with open(LOG, "rb") as f:
        f.seek(offset)
        return f.read().decode("utf-8", "replace")


def wait_start_line(offset, seconds=120):
    """(token, offset just after it) of the first detection start line after `offset`."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        text = log_since(offset)
        for line in text.splitlines():
            if "whisper_meeting_vad_start token=" in line:
                token = line.split("token=")[1].split()[0]
                return token, offset + len(text.encode("utf-8"))
        time.sleep(0.02)  # deadline-fallback: the app's log is the only signal
    return None, offset


def outcome_logged(offset, token):
    """Whether the outcome line for `token` is in the log after `offset`."""
    return any("whisper_meeting_vad outcome=" in line and f"token={token} " in line
               for line in log_since(offset).splitlines())


def dictation_start_ms():
    """Milliseconds from the start request until the take exists, then stop it."""
    t0 = time.monotonic()
    status, reply = m.door("dictation", "start")
    ms = (time.monotonic() - t0) * 1000
    if status != 0 or not reply.get("ok"):
        return None, reply
    receipt = json.dumps(reply["result"]["receipt"])
    m.door("dictation", "stop", "--receipt", receipt)
    m.door("dictation", "wait", "--receipt", receipt, timeout=120)
    return ms, None


def set_setting(key, value):
    return m.door_ok("settings", "set", key, json.dumps(value))


def switch(name):
    import wispr_eyes as w
    t0 = time.monotonic()
    w.switch_backend(name, wait=120)
    return (time.monotonic() - t0) * 1000


def looped_audio(directory, minutes):
    conversation, _, _ = m.make_conversation(directory)
    with wave.open(conversation, "rb") as src:
        data = src.readframes(src.getnframes())
        rate = src.getframerate()
    block = data + b"\0\0" * (20 * rate)
    out = os.path.join(directory, "long.wav")
    with wave.open(out, "wb") as dst:
        dst.setnchannels(1)
        dst.setsampwidth(2)
        dst.setframerate(rate)
        written = 0
        while written < minutes * 60 * rate:
            dst.writeframes(block)
            written += len(block) // 2
    return out, written / rate


def run(run_dir, minutes):
    import audio_rig
    rows = []
    made = []
    saved = {k: m.door_ok("settings", "get", k)["value"]
             for k in ("meetingTranscriptEngine", "selectedBackend")}
    status = 0
    try:
        m.this_build_pid()
        set_setting("meetingTranscriptEngine", "whisper")
        work = tempfile.mkdtemp(prefix="vad-checkpoint-", dir=run_dir)
        audio, seconds = looped_audio(work, minutes)
        with audio_rig.AudioRig(), m.Players() as players:
            # 1. Baselines, no meeting.
            baseline = {}
            for engine in ("parakeet", "whisper"):
                switch(engine)
                values = [v for v, _ in (dictation_start_ms() for _ in range(5)) if v is not None]
                baseline[engine] = values
            rows.append({"baselineStartMs": baseline})
            print(json.dumps(rows[-1]))
            # 2. One owned meeting.
            switch("parakeet")
            meeting_id = m.start_meeting(call_sound=True)
            made.append(meeting_id)
            player = players.play(audio)
            time.sleep(seconds + 2)  # deadline-fallback: the recording's planned length
            players.stop(player)
            t0 = time.monotonic()
            m.stop_and_wait_ready(meeting_id, seconds=1800)
            rows.append({"firstPassSeconds": round(time.monotonic() - t0, 1), "recordedSeconds": seconds})
            print(json.dumps(rows[-1]))

            def one_pass(label, action):
                offset = log_size()
                m.door_ok("meeting", "retry", meeting_id, "--engine", "whisper")
                token, after = wait_start_line(offset)
                if token is None:
                    rows.append({"pass": label, "couldNotTell": "no detection start line"})
                    return None
                result = action()
                during = not outcome_logged(after, token)
                row = {"pass": label, "token": token, "duringDetection": during, "result": result}
                rows.append(row)
                print(json.dumps(row))
                return row

            def wait_ready():
                return m.wait_for("ready", lambda: m.meeting_get(meeting_id)["meeting"]["state"] == "ready", 1800, 2.0)

            # 3a. Dictation starts, meeting-owned model (Parakeet dictation) and shared (Whisper).
            for engine in ("parakeet", "whisper"):
                switch(engine)
                for i in range(3):
                    one_pass(f"dictation-{engine}-{i}", lambda: {"startMs": dictation_start_ms()[0]})
                    wait_ready()
            # 3b. Engine switches during detection, into Whisper and away from it.
            switch("parakeet")
            one_pass("switch-into-whisper", lambda: {"switchMs": switch("whisper")})
            wait_ready()
            one_pass("switch-away-from-whisper", lambda: {"switchMs": switch("parakeet")})
            wait_ready()
            # 4. Sampled residency across one pass.
            pid = m.this_build_pid()
            samples = []

            def sample_pass():
                end = time.monotonic() + 600
                while time.monotonic() < end:
                    value = m.footprint_bytes(pid)
                    if value:
                        samples.append(value)
                    if m.meeting_get(meeting_id)["meeting"]["state"] == "ready":
                        break
                    time.sleep(1)  # deadline-fallback: 1 s sampling period
                return {"sampledResidencyPeakMB": round(max(samples) / 1048576) if samples else None,
                        "samples": len(samples)}
            one_pass("residency", sample_pass)
            wait_ready()
            # 3c. Quit during detection.
            before = m.crash_reports()

            def quit_app():
                import AppKit
                pid_now = m.this_build_pid()
                app = AppKit.NSRunningApplication.runningApplicationWithProcessIdentifier_(pid_now)
                if app is None or not app.terminate():
                    return {"quitSent": False}
                t0 = time.monotonic()
                gone = m.wait_for("exit", lambda: not any(p == pid_now for p, _ in m.dev_pids()), 60, 0.2)
                return {"quitSent": True, "exited": bool(gone), "exitSeconds": round(time.monotonic() - t0, 2)}
            quit_row = one_pass("quit", quit_app)
            time.sleep(5)  # deadline-fallback: ReportCrash writes within seconds of an exit
            new_reports = sorted(m.crash_reports() - before)
            subprocess.run(["open", m.DEV_APP], check=True)
            if not m.wait_for("relaunch", m.dev_pids, 60, 1.0) or not m.wait_for(
                    "door", lambda: m.door("meeting", "status")[0] == 0, 60, 1.0):
                raise m.Setup("the dev app did not relaunch")
            recovered = wait_ready()
            rows.append({"quitCrashReports": new_reports, "recoveredReady": bool(recovered)})
            print(json.dumps(rows[-1]))
            # 3d. Delete last.

            def delete():
                t0 = time.monotonic()
                st, reply = m.door("meeting", "delete", meeting_id)
                return {"deleteOk": st == 0 and bool(reply.get("ok")),
                        "deleteSeconds": round(time.monotonic() - t0, 2)}
            one_pass("delete", delete)
            gone_row = m.door("meeting", "get", meeting_id)[0] != 0
            folder_gone = m.meeting_folder(meeting_id) is None
            rows.append({"deletedRowGone": gone_row, "deletedFolderGone": folder_gone})
            print(json.dumps(rows[-1]))
            if gone_row:
                made.remove(meeting_id)
            fails = [r for r in rows if r.get("duringDetection") is False]
            if quit_row and not quit_row.get("result", {}).get("exited"):
                status = 1
            if new_reports or not recovered or not gone_row:
                status = 1
            if fails and status == 0:
                status = 2
    except m.Setup as error:
        rows.append({"setup": str(error)})
        status = 3
    finally:
        for key, value in saved.items():
            try:
                if key == "selectedBackend":
                    switch(value)
                else:
                    set_setting(key, value)
            except Exception as error:  # restoration must be reported, never hidden
                rows.append({"restoreFailed": key, "error": str(error)})
        if made:
            m.cleanup(made)
        with open(os.path.join(run_dir, "meeting-vad-checkpoint.json"), "w") as f:
            json.dump({"exit": status, "rows": rows}, f, indent=1)
    return status


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--minutes", type=float, default=25.0)
    args = parser.parse_args()
    os.makedirs(args.run_dir, exist_ok=True)
    sys.exit(run(args.run_dir, args.minutes))


if __name__ == "__main__":
    main()
