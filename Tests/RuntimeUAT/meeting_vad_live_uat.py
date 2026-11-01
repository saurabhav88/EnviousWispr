#!/usr/bin/env python3
"""#4254 dev-app UAT: Whisper meeting speech detection on both tracks, live and saved.

    python3 Tests/RuntimeUAT/meeting_vad_live_uat.py --run-dir <dir>

Run with Bash `run_in_background: true`, holding the shared dev-app lock, with ONE debug
instance of THIS worktree's build running and Debug Mode on. Reuses `meeting_uat.py`'s door,
players, checks, dictation and cleanup helpers.

One meeting records with the call sound on, live words forced to the Universal engine, the
meeting transcript engine set to Whisper and "Turn off dictation during meetings" off (both
restored after). `audio_rig.AudioRig` routes output
and the app's microphone to BlackHole, so the microphone track and the real call-sound tap
(which hears every process) both carry one playback of the #4254 representative-voice
fixtures (`Tests/Fixtures/meeting-voices/`) with long noise-floor silences between them.

Evidence:
- `meeting.live` (DEBUG door) every 2 s: per track, the live session's speech detection (run,
  epoch, degraded, fed, classified, silent/covered/pending cycles, completed decodes). Each
  captured track needs non-null reports that never degrade, one run and epoch, classified
  growing past zero, silent cycles over the silences and completed decodes over speech. A null
  report is unknown, never evidence.
- app.log since Start: no `whisper_meeting_vad outcome=vad_unavailable` line (live or final),
  and at least one final `whisper_meeting_vad outcome=vad_ok` or `vad_skipped_all` line.
- Words: the call track's live text at the end of playback and its saved transcript, each
  compared in order with the script (reported); the saved call track must keep every script
  word. One dictation, driven through the door, completes while the meeting records.

Exit 0 PASS, 1 FAIL, 2 COULD NOT TELL, 3 SETUP FAILED. Receipt <run dir>/meeting-vad-live.json.
The meeting this run made is deleted at the end; no other meeting is touched.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import meeting_uat as m  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))
FIXTURES = os.path.join(ROOT, "Tests", "Fixtures", "meeting-voices")
LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
# The sequence played, with the noise-floor silence (seconds) before each case.
SEQUENCE = [(20, "quiet-beside-loud"), (20, "two-voices-overlapping"), (15, "yes-no-between-silences"),
            (10, "speech-over-music-and-noise"), (10, "music-and-noise-only")]
TAIL_SECONDS = 15
RATE = 16_000


def words(text):
    return re.findall(r"[^\W_]+", (text or "").lower())


def edits(hyp, ref):
    """(missing reference words in order, extra words) by longest common subsequence."""
    n, k = len(hyp), len(ref)
    table = [[0] * (k + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(k - 1, -1, -1):
            table[i][j] = table[i + 1][j + 1] + 1 if hyp[i] == ref[j] else max(table[i + 1][j], table[i][j + 1])
    missing, extra, i, j = [], [], 0, 0
    while i < n or j < k:
        if i < n and j < k and hyp[i] == ref[j]:
            i, j = i + 1, j + 1
        elif j < k and (i == n or table[i][j + 1] >= table[i + 1][j]):
            missing.append(ref[j])
            j += 1
        else:
            extra.append(hyp[i])
            i += 1
    return missing, extra


def build_audio(work):
    """(path, ordered reference words, seconds) of the played sequence; the noise floor matches
    the fixtures' (-66 dBFS white noise, fixed seed)."""
    import numpy as np
    manifest = {c["id"]: c for c in json.load(open(os.path.join(FIXTURES, "manifest.json")))}
    rng = np.random.default_rng(4254)
    parts, reference = [], []
    for silence, case in SEQUENCE:
        parts.append(rng.normal(0, 10 ** (-66 / 20), silence * RATE))
        with wave.open(os.path.join(FIXTURES, manifest[case]["file"])) as w:
            parts.append(np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768)
        # Overlapping voices have no single word order; their first voice then the second is the
        # order a transcript gives, and each is scored as part of the whole.
        texts = [manifest[case]["reference"]] if manifest[case]["reference"] is not None else [
            v["text"] for v in manifest[case]["voices"]]
        for text in texts:
            reference += words(text)
    parts.append(rng.normal(0, 10 ** (-66 / 20), TAIL_SECONDS * RATE))
    samples = np.concatenate(parts)
    path = os.path.join(work, "meeting-vad-live.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(np.clip(np.round(samples * 32767), -32768, 32767).astype("<i2").tobytes())
    return path, reference, len(samples) / RATE


def log_size():
    return os.path.getsize(LOG) if os.path.exists(LOG) else 0


def log_since(offset):
    with open(LOG, "rb") as f:
        f.seek(offset)
        return f.read().decode("utf-8", "replace")


def door_dictation(c, players, work, sentence):
    """One dictation while the meeting records, driven through the door (no key is held, so a
    key pressed on this Mac cannot cancel it), heard alone: playback has ended. Checks the
    take's ending and that its History row holds the spoken words."""
    aiff = os.path.join(work, "dictation.aiff")
    subprocess.run(["say", "-v", "Samantha", "-o", aiff, sentence], check=True)
    started = m.door_ok("dictation", "start")["receipt"]
    receipt = json.dumps(started)
    players.finish(players.play(aiff))
    time.sleep(1)  # deadline-fallback: the trailing word's audio reaches the capture
    # Auto-stop may already have ended the take on the trailing silence: nothing to stop then.
    status, reply = m.door("dictation", "stop", "--receipt", receipt)
    if status != 0 and (reply.get("error") or {}).get("code") != "notRecording":
        raise m.Setup(f"dictation stop refused: {reply}")
    _, reply = m.door("dictation", "wait", "--receipt", receipt, "--timeout", "90", timeout=120)
    ending, text = dictation_outcome(reply, started.get("take"))
    heard = [w for w in words(sentence) if w in words(text)]
    c.check("a dictation completes while the meeting records", ending == "completed",
            json.dumps({"ending": ending, "take": started.get("take")}))
    c.check("the dictation's saved text holds the spoken words", len(heard) >= 0.8 * len(words(sentence)),
            f"{len(heard)}/{len(words(sentence))} words")


def dictation_outcome(reply, take):
    """(ending, saved row as text) of a `dictation wait` reply for exactly `take`; (None, "")
    when the reply is for another take or holds no terminal."""
    result = reply.get("result") or {}
    terminal = result.get("terminal") or {}
    if (terminal.get("receipt") or {}).get("take") != take:
        return None, ""
    return terminal.get("ending"), json.dumps(result.get("row") or {})


# `TurnAssembler.bothSpeakersID`: a sentence the speaker step heard on both voices.
BOTH = "both"


def track_text(meeting, prefix):
    """A track's visible words from a `meeting get --include-text` reply: its own turns
    (`mic:` or `sys:`) and the `both` turns, each once, in transcript order."""
    transcript = meeting.get("transcript") or {}
    listed = (transcript.get("projection") or {}).get("visibleTurnIDs")
    visible = None if listed is None else set(listed)
    lines = []
    for turn in transcript.get("turns") or []:
        speaker = turn.get("speakerId") or ""
        if not (speaker.startswith(prefix) or speaker == BOTH):
            continue
        if visible is not None and turn.get("id") not in visible:
            continue
        lines.append(turn.get("text") or "")
    return " ".join(lines)


def self_test():
    """Offline controls shaped like the producers' replies."""
    failures = []

    def expect(name, cond):
        print(f"  {'ok' if cond else 'FAILED'}  {name}")
        if not cond:
            failures.append(name)

    done = {"ok": True, "result": {"terminal": {"ending": "completed", "receipt": {"take": "T1"}},
                                    "row": {"text": "Please add the date."}}}
    expect("terminal ending read for the take", dictation_outcome(done, "T1")[0] == "completed")
    expect("the row text is read", "please" in words(dictation_outcome(done, "T1")[1]))
    expect("another take's terminal is refused", dictation_outcome(done, "T2") == (None, ""))
    expect("no terminal reads as none", dictation_outcome({"ok": True, "result": {}}, "T1") == (None, ""))
    meeting = {"transcript": {"turns": [
        {"id": "a", "speakerId": "sys:S1", "text": "One."},
        {"id": "b", "speakerId": "mic:you", "text": "Echo."},
        {"id": "c", "speakerId": "both", "text": "Yes."},
        {"id": "d", "speakerId": "sys:S2", "text": "Hidden."},
    ], "projection": {"visibleTurnIDs": ["a", "b", "c"]}}}
    expect("call track: own and both turns, hidden ones left out", track_text(meeting, "sys:") == "One. Yes.")
    expect("mic track: own and both turns", track_text(meeting, "mic:") == "Echo. Yes.")
    expect("edits find a missing word in order", edits(["a", "c"], ["a", "b", "c"]) == (["b"], []))
    print(f"self-test: {7 - len(failures)} passed, {len(failures)} failed")
    return 1 if failures else 0


def detection_verdict(samples, track):
    """(ok, detail) for one track's detection reports over the run."""
    reports = [s["tracks"].get(track) for s in samples]
    known = [r for r in reports if r]
    if not known:
        return False, f"no report for {track} in {len(samples)} reads"
    identity = {(r["run"], r["epoch"]) for r in known}
    first, last = known[0], known[-1]
    problems = []
    if any(r["degraded"] for r in known):
        problems.append("degraded")
    if len(identity) != 1:
        problems.append(f"run/epoch changed {sorted(identity)}")
    if not (last["classified"] > first["classified"] and last["classified"] > 0):
        problems.append(f"classified did not grow ({first['classified']} -> {last['classified']})")
    if last["silentCycles"] <= 0:
        problems.append("no silent cycle")
    if last["completedDecodes"] <= 0:
        problems.append("no completed decode")
    detail = {"reads": len(samples), "known": len(known), "first": first, "last": last}
    return not problems, json.dumps({"problems": problems, **detail})


def run(run_dir, made, c):
    import audio_rig
    work = tempfile.mkdtemp(prefix="meeting-vad-live-", dir=run_dir)
    audio, reference, seconds = build_audio(work)
    engine = m.door_ok("settings", "get", "meetingTranscriptEngine").get("value")
    # "Turn off dictation during meetings" would refuse the dictation check by design.
    turns_off = m.door_ok("settings", "get", "meetingTurnsOffDictation").get("value")
    m.door_ok("settings", "set", "meetingTranscriptEngine", json.dumps("whisper"))
    m.door_ok("settings", "set", "meetingTurnsOffDictation", "false")
    try:
        offset = log_size()
        with audio_rig.AudioRig(), m.Players() as players:
            meeting_id = m.start_meeting(call_sound=True, live_engine="universal")
            started = time.monotonic()
            made.append(meeting_id)
            status = m.door_ok("meeting", "status")
            c.check("the meeting records with the call sound", status["callSoundStatus"] == "captured",
                    status["callSoundStatus"])
            player = players.play(audio)
            chosen = m.wait_for("engine", lambda: m.live_state().get("engine"), 60, 1.0)
            c.check("live words use the Universal engine", chosen == "universal", str(chosen))
            reads = []
            while player.poll() is None and time.monotonic() - started < seconds + 30:
                live = m.door_ok("meeting", "live").get("live") or {}
                reads.append({
                    "t": round(time.monotonic() - started, 1),
                    "tracks": {k: v.get("detection") for k, v in (live.get("tracks") or {}).items()},
                })
                time.sleep(2)  # deadline-fallback: fixed sampling period of a real-time read
            c.check("the recording played once to the end", player.poll() == 0,
                    f"afplay exit {player.poll()} after {time.monotonic() - started:.0f} s of {seconds:.0f} s")
            live_call = " ".join(l.get("text") or "" for l in m.live_lines() if l.get("track") == "callSound")
            for track in ("microphone", "callSound"):
                ok, detail = detection_verdict(reads, track)
                c.check(f"{track}: live speech detection ran on the pinned model the whole time", ok, detail)
            door_dictation(c, players, work, m.DICTATIONS[0])
            players.stop_all()
            ready = m.stop_and_wait_ready(meeting_id)
        c.check("the transcript is ready after Stop", bool(ready) and ready["meeting"]["state"] == "ready",
                (ready or {}).get("meeting", {}).get("state", "timed out"))
        log = log_since(offset)
        unavailable = len(re.findall(r"whisper_meeting_vad outcome=vad_unavailable", log))
        detected = len(re.findall(r"whisper_meeting_vad outcome=(?:vad_ok|vad_skipped_all) ", log))
        c.check("no detection fell back to the undetected route", unavailable == 0, f"{unavailable} lines")
        c.check("the saved transcript ran with detection", detected > 0, f"{detected} vad_ok/vad_skipped_all lines")
        if ready:
            saved = m.meeting_get(meeting_id, include_text=True)
            # Synthetic audio and its transcript only: kept beside the receipt for diagnosis.
            keep = os.path.join(run_dir, f"meeting-{meeting_id}")
            os.makedirs(keep, exist_ok=True)
            with open(os.path.join(keep, "meeting.json"), "w") as f:
                json.dump(saved, f, indent=1)
            for path in m.audio_files(meeting_id):
                subprocess.run(["cp", path, keep], check=True)
            saved_call = track_text(saved, "sys:")
            missing, extra = edits(words(saved_call), reference)
            c.check("the saved call track keeps every script word", not missing,
                    json.dumps({"missing": missing, "extra": extra}))
            live_missing, live_extra = edits(words(live_call), reference)
            c.rows.append({"liveCallVsScript": {"missing": live_missing, "extra": live_extra},
                           "savedCallVsScript": {"missing": missing, "extra": extra}})
            print(f"  live call vs script: missing {live_missing} extra {live_extra}")
            print(f"  saved call vs script: missing {missing} extra {extra}")
            print(f"  live call text: {live_call}")
            print(f"  saved call text: {saved_call}")
    finally:
        m.door_ok("settings", "set", "meetingTranscriptEngine", json.dumps(engine))
        m.door_ok("settings", "set", "meetingTurnsOffDictation", json.dumps(turns_off))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--run-dir")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.run_dir:
        parser.error("--run-dir is required")
    if not os.path.isdir(args.run_dir):
        parser.error("--run-dir must exist")
    receipt = os.path.join(args.run_dir, "meeting-vad-live.json")
    m.RECEIPT["path"], m.RECEIPT["scenario"] = receipt, "vad-live"
    import take_gate as tg
    made, c, status = [], m.Checks(), None
    try:
        m.this_build_pid()
        run(args.run_dir, made, c)
    except (m.Setup, tg.SetupFailed, subprocess.SubprocessError, OSError) as error:
        print(f"SETUP FAILED: {type(error).__name__}: {error}")
        c.rows.append({"setup": f"{type(error).__name__}: {error}"})
        status = m.EXIT_SETUP
    except (m.Unsure, tg.CouldNotTell) as error:
        c.cannot_tell("the run", f"{type(error).__name__}: {error}")
    except Exception as error:  # a harness defect is never an app result
        c.cannot_tell("the run", f"harness error {type(error).__name__}: {error}")
    finally:
        left = [r for r in m.cleanup(made) if not r["deleted"]] if made else []
    if left:
        c.rows.append({"cleanup": left})
        status = m.EXIT_SETUP if status is None and c.status() != m.EXIT_FAIL else status
    status = c.status() if status is None else status
    with open(receipt, "w") as f:
        json.dump({"scenario": "vad-live", "exit": status, "rows": c.rows}, f, indent=1)
    print(f"verdict: {m.VERDICTS[status]} ({receipt})")
    return status


if __name__ == "__main__":
    sys.exit(main())
