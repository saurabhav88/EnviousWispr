"""EnviousMeet on the real Debug app (#3972 plan section 11.1, R7, R51, R58).

    python3 Tests/RuntimeUAT/meeting_uat.py feature --run-dir <dir>
    python3 Tests/RuntimeUAT/meeting_uat.py crash --run-dir <dir>
    python3 Tests/RuntimeUAT/meeting_uat.py latency --run-dir <dir> [--takes 20]
    python3 Tests/RuntimeUAT/meeting_uat.py memory --run-dir <dir> [--minutes 10]
    python3 Tests/RuntimeUAT/meeting_uat.py live --run-dir <dir> [--live-engine apple|universal] [--audio <wav>]
    python3 Tests/RuntimeUAT/meeting_uat.py speechkill --run-dir <dir>
    python3 Tests/RuntimeUAT/meeting_uat.py quit --run-dir <dir>
    python3 Tests/RuntimeUAT/meeting_uat.py --self-test

Run every scenario with Bash `run_in_background: true` (the dictations hold the push-to-talk
key through CGEvent), holding the shared dev-app lock, with ONE debug instance of THIS
worktree's build running and Debug Mode on (verdicts come from app.log and the dev-control
door, never the clipboard).

The call is a scripted two-person conversation made with two built-in macOS voices, so its reference
words are known exactly. No real meeting recording (AMI) is on this Mac and none is
downloaded, and no bake-off number exists: the WER here is against that script and is NOT
the plan's "within 3 points of the AMI bake-off" check, which stays open.

Audio stays silent: `audio_rig.AudioRig` routes output and the app's microphone to BlackHole.
The call-sound tap hears every process, so the call track carries the conversation and each
dictation's TTS; the microphone (BlackHole) hears the same audio, which is the no-headphones
case: the mic copies of call lines are probable echo and hidden by default (R7 rig C). Every
player this script starts is its own process group, killed and reaped before the rig restores
the speakers, also on an error.

- feature: Start (call sound on), notes saved, the conversation plays alone (its call-track
  turns are scored against the script), then five dictations land while the meeting still
  records, live words appear, Stop, the transcript is ready, at least two call-track speakers
  in the conversation, echo hidden, audio on disk, a summary when an AI Polish provider can
  write one, Delete audio removes the files.
- crash: Start, play 40 s, SIGKILL the verified dev PID, relaunch, the meeting is recovered
  as interrupted and transcribed.
- latency: `--takes` dictations with no meeting; `--takes` while a meeting records with live
  words proven active; `--takes` during a meeting's after-recording pass where the pass lasts.
  Median within +10 %, p90 within +20 % (R51); p95 reported. Missing takes: COULD NOT TELL.
- live (#3973, #4105): live words through the chosen engine (`--live-engine apple`, the default, or
  `universal`; the door forces it for that meeting) on `--audio` (a recording to replay, kept out of
  the run's artifacts) or the synthetic conversation; they progress on both
  tracks; a dictation with live preview lands meanwhile; Stop gives the transcript and the live
  words go; saved tracks cover the recording; speech-service RSS and app footprint every 5 s.
- speechkill (#3973): SIGKILL Apple's `localspeechrecognition` mid-meeting (by executable path;
  refused unless exactly one exists, re-verified just before the kill; it is the user session's
  one service, so another app recognizing speech at that moment is interrupted too):
  a track says live words stopped, the meeting keeps recording, Stop gives the transcript and
  the saved tracks cover the recording.
- quit (#3973): Quit (`NSRunningApplication.terminate`, the quit Cmd-Q sends, to the verified
  PID) while live words run: the app exits, no crash report, and the
  meeting is transcribed after relaunch.
- memory: `footprint` peak of the app process sampled every 1 s over `--minutes` of
  dictation-only work, then the same with a meeting recording and live words proven active;
  at most 1.2 GB added (R51, R58). Under 90 % sample coverage in an arm: COULD NOT TELL.

Exit: 0 PASS, 1 FAIL (an app result), 2 COULD NOT TELL, 3 SETUP FAILED. Receipt:
<run dir>/meeting-<scenario>.json, written after cleanup on every path. Every meeting this
run made is deleted at the end; no other meeting is touched.
"""
import argparse
import glob
import json
import os
import re
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

ROOT = os.path.dirname(os.path.dirname(HERE))
DEV_APP = os.path.join(ROOT, "build", "EnviousWispr Local.app")
EXECUTABLE_RE = re.compile(r"^\s*(\d+) (/.*Local\.app/Contents/MacOS/EnviousWispr)$")

EXIT_PASS, EXIT_FAIL, EXIT_UNSURE, EXIT_SETUP = 0, 1, 2, 3
VERDICTS = ["PASS", "FAIL", "COULD NOT TELL", "SETUP FAILED"]

# The call: two people, alternating, with known words. Short turns with pauses between them.
CONVERSATION = [
    ("onyx", "Good morning everyone. Let's start with the launch plan for the new release."),
    ("nova", "Thanks. The build is ready and the testers signed off yesterday afternoon."),
    ("onyx", "Great. What is still open before we can ship it to customers?"),
    ("nova", "Two things. The help pages need new screenshots, and the website needs the "
             "download link."),
    ("onyx", "Who owns the screenshots? I think Maria offered to take them."),
    ("nova", "Yes, Maria has them. She expects to finish by Thursday morning."),
    ("onyx", "Then let's plan the release for Friday at ten in the morning."),
    ("nova", "Friday works. I will tell the support team so they can prepare answers."),
    ("onyx", "Good. One more question. Did the crash on older Macs get fixed?"),
    ("nova", "It did. We tested it on three machines and it no longer happens."),
    ("onyx", "Excellent work. Let's meet again on Thursday to confirm everything."),
    ("nova", "Sounds good. I will send a short summary after this call."),
]
DICTATIONS = [
    "Please add the release date to the shared calendar.",
    "Remind me to call the printer about the new labels.",
    "The quarterly report is due on the fifteenth.",
    "Book a table for four people on Saturday evening.",
    "Send the updated contract to the legal team today.",
]
GAP_SECONDS = 1.2
SAMPLE_RATE = 24000
# A clean two-voice TTS call transcribed by Parakeet; a stated acceptance policy, not a
# measured product claim.
MAX_CALL_WER = 0.15
PLAYER_SECONDS = 600
# Turns starting this long after the conversation's last word are not part of it.
WINDOW_SLACK_MS = 2000
MIN_SAMPLE_COVERAGE = 0.9


# ---------- pure helpers (self-tested) ----------

def normalize(text):
    """Lowercase words, punctuation stripped; digits kept (the same normalizer for both sides)."""
    return re.findall(r"[a-z0-9']+", text.lower().replace("’", "'"))


def wer(reference, hypothesis):
    """Word error rate: word-level edit distance over the reference word count."""
    ref, hyp = normalize(reference), normalize(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1] / len(ref)


def percentile(values, fraction):
    """Nearest-rank percentile of a non-empty list."""
    ordered = sorted(values)
    rank = max(1, int(-(-fraction * len(ordered) // 1)))
    return ordered[min(rank, len(ordered)) - 1]


def latency_verdict(baseline, during):
    """R51: median within +10 % and p90 within +20 % of the no-meeting baseline."""
    b_med, d_med = statistics.median(baseline), statistics.median(during)
    b_p90, d_p90 = percentile(baseline, 0.9), percentile(during, 0.9)
    ok = d_med <= b_med * 1.10 and d_p90 <= b_p90 * 1.20
    return ok, {"baselineMedian": b_med, "duringMedian": d_med, "baselineP90": b_p90,
                "duringP90": d_p90, "baselineP95": percentile(baseline, 0.95),
                "duringP95": percentile(during, 0.95), "takes": [len(baseline), len(during)]}


def parse_footprint(text):
    """Bytes of the `phys_footprint` line of `footprint -p <pid>` output, or None."""
    match = re.search(r"phys_footprint:\s*([\d.]+)\s*([KMG]?B)", text)
    if not match:
        return None
    scale = {"B": 1, "KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3}[match.group(2)]
    return int(float(match.group(1)) * scale)


def memory_verdict(baseline, during, expected_samples):
    """(exit status, detail). Each arm is (peak bytes, samples taken)."""
    (b_peak, b_count), (d_peak, d_count) = baseline, during
    need = int(expected_samples * MIN_SAMPLE_COVERAGE)
    if b_count < need or d_count < need or b_peak <= 0 or d_peak <= 0:
        return EXIT_UNSURE, f"samples {b_count}/{d_count}, need {need} in each arm"
    added = d_peak - b_peak
    detail = (f"baseline {b_peak / 1e9:.2f} GB, during {d_peak / 1e9:.2f} GB, "
              f"added {added / 1e9:.2f} GB")
    return (EXIT_PASS if added <= 1.2 * 1024 ** 3 else EXIT_FAIL), detail


CAPTURE_TRACKS = ("microphone", "callSound")


def saved_audio_problems(record, recorded_seconds, tracks=CAPTURE_TRACKS):
    """Every reason the saved audio does not cover the recording (#3973). Each expected track
    must be present, captured, have frames, cover the recorded length and have no gaps; missing
    or malformed data is a problem, never skipped."""
    problems = []
    duration = (record.get("durationMs") or 0) / 1000 if isinstance(record, dict) else 0
    if duration <= 0:
        problems.append(f"no recorded length ({record.get('durationMs') if isinstance(record, dict) else record})")
    elif abs(duration - recorded_seconds) > 5:
        problems.append(f"recorded {duration:.1f} s against {recorded_seconds:.1f} s wall clock")
    saved = (record.get("tracks") if isinstance(record, dict) else None) or {}
    for name in tracks:
        track = saved.get(name)
        if not isinstance(track, dict):
            problems.append(f"{name}: missing")
            continue
        if track.get("status") != "captured":
            problems.append(f"{name}: status {track.get('status')}")
        frames = track.get("frames")
        if not isinstance(frames, int) or frames <= 0:
            problems.append(f"{name}: frames {frames}")
        elif duration > 0 and abs(frames / 16000 - duration) > 3:
            problems.append(f"{name}: {frames / 16000:.1f} s of {duration:.1f} s")
        if track.get("gaps") != 0:
            problems.append(f"{name}: gaps {track.get('gaps')}")
    if isinstance(record, dict) and record.get("failureCode") in ("audio_damaged", "audio_unreadable"):
        problems.append(f"failureCode {record.get('failureCode')}")
    return problems


def call_text_between(meeting, start_ms, end_ms):
    """The call track's visible words in turns starting in [start_ms, end_ms]."""
    transcript = meeting.get("transcript") or {}
    # An explicitly empty list hides every turn; only an absent projection shows them all.
    listed = (transcript.get("projection") or {}).get("visibleTurnIDs")
    visible = None if listed is None else set(listed)
    out = []
    for turn in transcript.get("turns") or []:
        start = turn.get("startMs")
        if not (turn.get("speakerId") or "").startswith("sys:") or start is None:
            continue
        if visible is not None and turn.get("id") not in visible:
            continue
        if start_ms <= start <= end_ms:
            out.append(turn.get("text") or "")
    return " ".join(out)


def phrase_heard(phrase, text, need=0.6):
    """(heard, hits, content words): at least `need` of the phrase's distinct content words
    (longer than three letters) appear in `text`."""
    words = sorted({w for w in normalize(phrase) if len(w) > 3})
    got = set(normalize(text))
    hits = sum(1 for w in words if w in got)
    return bool(words) and hits >= need * len(words), hits, len(words)


PREVIEW_ENDED_RE = re.compile(r"LIVE_PREVIEW session ended, feeds=(\d+) shownChars=(\d+)")


def preview_witness(log_text):
    """(feeds, shown characters) of dictation's live preview sessions that ended in `log_text`
    (LivePreviewCoordinator's own line), or None when none ended."""
    found = [(int(a), int(b)) for a, b in PREVIEW_ENDED_RE.findall(log_text)]
    if not found:
        return None
    return max(f for f, _ in found), max(c for _, c in found)


def wait_preview_witness(start, read, seconds=20.0, every=1.0, clock=time.monotonic,
                         sleep=time.sleep):
    """Dictation's live preview witness for the take that began at `start`: `read(start)` returns
    the app.log lines stamped since then across rotated files (`wispr_eyes.log_lines_since`).
    The session's end line may follow the take's return, so this waits up to `seconds` for a
    witness that showed words; it returns the last witness seen (possibly None)."""
    deadline = clock() + seconds
    witness = None
    while True:
        witness = preview_witness("\n".join(read(start)))
        if (witness and witness[1] > 0) or clock() >= deadline:
            return witness
        sleep(every)  # deadline-fallback: the preview's teardown logs its line; nothing signals it


def held_recording(killed_at, observed_at, still_recording, need=30.0):
    """(passed, elapsed): the meeting was observed recording at least `need` seconds after the
    kill. Both times on one monotonic clock."""
    elapsed = observed_at - killed_at
    return bool(still_recording) and elapsed >= need, round(elapsed, 1)


# A sentence played only after the speech service is killed: never in the conversation.
POST_KILL_SENTENCE = ("Seventeen purple lanterns arrived at the harbor museum before sunrise "
                      "on Wednesday.")


def call_track_text(meeting, window_end_ms=None):
    """The call track's visible words from a `meeting get --include-text` reply, only turns
    that start before `window_end_ms` when it is given."""
    transcript = meeting.get("transcript") or {}
    # An explicitly empty list hides every turn; only an absent projection shows them all.
    listed = (transcript.get("projection") or {}).get("visibleTurnIDs")
    visible = None if listed is None else set(listed)
    lines, speakers = [], set()
    for turn in transcript.get("turns") or []:
        speaker = turn.get("speakerId") or ""
        # Track speaker prefixes: `mic:` and `sys:` (MeetingTrackKind.speakerPrefix).
        if not speaker.startswith("sys:") or (visible is not None and turn.get("id") not in visible):
            continue
        start = turn.get("startMs")
        if window_end_ms is not None and (start is None or start > window_end_ms):
            continue
        lines.append(turn.get("text") or "")
        speakers.add(speaker)
    return " ".join(lines), speakers


# ---------- the app ----------

class Setup(Exception):
    """The run could not be set up: not an app result."""


class Unsure(Exception):
    """The run cannot tell: not an app result."""


def door(*argv, timeout=60):
    """(exit status, reply document) of one dev_control.py call."""
    proc = subprocess.run([sys.executable, os.path.join(HERE, "dev_control.py"), *argv],
                          capture_output=True, text=True, timeout=timeout)
    try:
        return proc.returncode, json.loads(proc.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        raise Setup(f"dev_control {' '.join(argv[:2])} printed no JSON: {proc.stderr[-400:]}")


def door_ok(*argv, timeout=60):
    status, reply = door(*argv, timeout=timeout)
    if status != 0 or not reply.get("ok"):
        raise Setup(f"dev_control {' '.join(argv[:2])} refused: {reply}")
    return reply["result"]


def dev_pids():
    out = subprocess.run(["ps", "-eww", "-o", "pid=,comm="], capture_output=True,
                         text=True).stdout
    return [(int(m.group(1)), m.group(2)) for m in map(EXECUTABLE_RE.match, out.splitlines())
            if m]


def this_build_pid():
    """The one dev instance, and only if it is THIS worktree's build."""
    pids = dev_pids()
    mine = [pid for pid, exe in pids if exe.startswith(DEV_APP + "/")]
    if len(pids) != 1 or len(mine) != 1:
        raise Setup(f"need exactly one dev instance of {DEV_APP}; found {pids}")
    return mine[0]


def wait_for(label, predicate, seconds, every=1.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(every)  # deadline-fallback: polls the app's own state; nothing signals it
    return None


def meeting_get(meeting_id, include_text=False):
    argv = ["meeting", "get", meeting_id] + (["--include-text"] if include_text else [])
    return door_ok(*argv)


def live_lines():
    return (door_ok("meeting", "live")["live"] or {}).get("lines") or []


def live_state():
    return door_ok("meeting", "live")["live"] or {}


def track_text_lengths(live=None):
    """{track: characters of its live words} (#3973: per track, so each track's progress shows)."""
    live = live_state() if live is None else live
    lengths = {"microphone": 0, "callSound": 0}
    for line in live.get("lines") or []:
        lengths[line.get("track")] = lengths.get(line.get("track"), 0) + len(line.get("text") or "")
    return lengths


def track_statuses(live=None):
    live = live_state() if live is None else live
    return {name: (state or {}).get("status") for name, state in (live.get("tracks") or {}).items()}


SPEECH_SERVICE_RE = re.compile(r"^\s*(\d+) (/.*/localspeechrecognition)$")


def speech_service_pids():
    """Apple's speech service processes, by EXECUTABLE PATH (never a bare name)."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,comm="], capture_output=True, text=True).stdout
    return [int(m.group(1)) for m in map(SPEECH_SERVICE_RE.match, out.splitlines()) if m]


def the_speech_service(pids):
    """The one speech-service PID to stop, or Setup naming every candidate. Never chooses
    between several (tools-and-apps.md RULE: a-harness-that-ACTS-on-a-shared-resource-must-refuse-
    not-choose)."""
    if len(pids) != 1:
        raise Setup(f"need exactly one localspeechrecognition process; found {pids}")
    return pids[0]


def still_the_speech_service(pid):
    """Re-verified just before the kill: `pid` is still a localspeechrecognition executable."""
    return pid in speech_service_pids()


def rss_mb(pids):
    if not pids:
        return 0.0
    out = subprocess.run(["ps", "-o", "rss=", "-p", ",".join(map(str, pids))],
                         capture_output=True, text=True).stdout
    return sum(int(v) for v in out.split() if v.isdigit()) / 1024


class Sampler:
    """Every 5 s while the meeting records (plan section 3a): Apple's speech service RSS and the
    app's footprint. Coverage is reported, never assumed."""

    def __init__(self, pid):
        self.pid, self.rows, self.stop = pid, [], threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stop.is_set():
            try:
                app = footprint_bytes(self.pid)
            except subprocess.TimeoutExpired:
                app = None
            self.rows.append({"t": time.monotonic(), "speech_mb": round(rss_mb(speech_service_pids()), 1),
                              "app_mb": round(app / 1048576, 1) if app else None})
            self.stop.wait(5.0)  # deadline-fallback: the 5 s sampling period, ended by stop

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.stop.set()
        self.thread.join()
        return False

    def summary(self):
        speech = [r["speech_mb"] for r in self.rows if r["speech_mb"]]
        app = [r["app_mb"] for r in self.rows if r["app_mb"]]
        return {"samples": len(self.rows),
                "speech_mb_first": speech[0] if speech else None,
                "speech_mb_peak": max(speech) if speech else None,
                "app_mb_first": app[0] if app else None, "app_mb_peak": max(app) if app else None}


def live_text_length():
    """Characters of live words so far (#3973: a streaming line grows, so lines need not)."""
    return sum(len(line.get("text") or "") for line in live_lines())


def meeting_folder(meeting_id):
    found = glob.glob(os.path.expanduser(
        f"~/Library/Application Support/*/Meetings/{meeting_id}"))
    return found[0] if len(found) == 1 else None


def audio_files(meeting_id):
    folder = meeting_folder(meeting_id)
    if not folder:
        return []
    return [p for p in glob.glob(os.path.join(folder, "**", "*"), recursive=True)
            if os.path.isfile(p) and p.endswith((".caf", ".wav", ".m4a"))]


# The two people: built-in macOS voices, so the call has two clearly different speakers on
# every Mac (the OpenAI voice key is optional; without it `wispr_eyes.tts` falls back to one
# voice for every line, which cannot test speaker labels).
CALL_VOICES = {"onyx": "Samantha", "nova": "Daniel"}


def make_conversation(directory):
    """(WAV path, reference text, seconds) of the conversation: `say` turns joined by pauses."""
    parts = []
    for index, (voice, line) in enumerate(CONVERSATION):
        aiff = os.path.join(directory, f"turn-{index:02d}.aiff")
        wav = os.path.join(directory, f"turn-{index:02d}.wav")
        subprocess.run(["say", "-v", CALL_VOICES[voice], "-o", aiff, line], check=True,
                       timeout=60)
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1", aiff, wav],
            check=True, capture_output=True)
        parts.append(wav)
    out = os.path.join(directory, "conversation.wav")
    frames = 0
    with wave.open(out, "wb") as dst:
        dst.setnchannels(1)
        dst.setsampwidth(2)
        dst.setframerate(SAMPLE_RATE)
        silence = b"\0\0" * int(SAMPLE_RATE * GAP_SECONDS)
        for part in parts:
            with wave.open(part, "rb") as src:
                data = src.readframes(src.getnframes())
            dst.writeframes(data + silence)
            frames += len(data) // 2 + len(silence) // 2
    return out, " ".join(line for _, line in CONVERSATION), frames / SAMPLE_RATE


class PlaybackNotStopped(Exception):
    """An owned player group may still be playing: the speakers must not come back."""


# Where `main` writes the receipt; `Players` writes it too when it must exit at once.
RECEIPT = {"path": None, "scenario": None}


def group_alive(pgid):
    """Whether any process (leader or child) of that process group still exists."""
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class Players:
    """Every audio player this run starts, each the leader of its own process group, so a
    looping shell's afplay child is in that group too. `stop`/`stop_all` SIGKILL each owned
    GROUP whether or not its leader already exited, reap the leader, and prove the group is
    empty. If that cannot be proved, `__exit__` writes the receipt and exits the process at
    once (`os._exit`), so the enclosing AudioRig never restores the speakers while playback is
    possible; the route stays on BlackHole and the message names the manual restore."""

    def __init__(self):
        self.procs = []
        self.killpg, self.alive = os.killpg, group_alive

    def start(self, argv):
        proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
        self.procs.append(proc)
        return proc

    def play(self, path):
        return self.start(["afplay", path])

    def loop(self, path):
        return self.start(["bash", "-c", 'while true; do afplay "$0"; done', path])

    def finish(self, proc):
        """Waits for the player's own exit, with a deadline in case afplay hangs."""
        proc.wait(timeout=PLAYER_SECONDS)  # deadline-fallback: around the process-exit signal

    def stop(self, proc):
        try:
            self.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=10)  # deadline-fallback: reaping a SIGKILLed leader
        except subprocess.TimeoutExpired:
            pass
        empty = wait_for("player group gone", lambda: not self.alive(proc.pid), 5, 0.1)
        if not empty:
            raise PlaybackNotStopped(f"player group {proc.pid} still has processes")

    def stop_all(self):
        """Tries every owned group; any error on any of them leaves shutdown unproved."""
        failures = []
        for proc in self.procs:
            try:
                self.stop(proc)
            except Exception as error:
                failures.append(f"{proc.pid}: {type(error).__name__}: {error}")
        if failures:
            raise PlaybackNotStopped("; ".join(failures))

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        try:
            self.stop_all()
        except BaseException as error:
            unsafe_exit(error)
        return False


def unsafe_exit(error, exit=os._exit):
    """Playback may continue: record it and leave WITHOUT unwinding into the rig's restore."""
    try:
        message = (f"SETUP FAILED: {error}. The audio route stays on BlackHole: kill the "
                   f"player, then run `python3 Tests/RuntimeUAT/silent_audio.py restore`.")
        print(message, flush=True)
        if RECEIPT["path"]:
            with open(RECEIPT["path"], "w") as f:
                json.dump({"scenario": RECEIPT["scenario"], "exit": EXIT_SETUP,
                           "rows": [{"setup": message}]}, f, indent=1)
    except BaseException:
        pass  # diagnostics are best effort; the exit below is not
    finally:
        exit(EXIT_SETUP)


def start_meeting(call_sound=True, live_engine=None):
    extra = ["--live-engine", live_engine] if live_engine else []
    reply = door_ok("meeting", "start", "--entry-point", "menu",
                    "--call-sound" if call_sound else "--no-call-sound", *extra)
    if reply.get("outcome") != "recording":
        raise Setup(f"meeting start did not record: {reply}")
    return reply["meetingID"]


def stop_and_wait_ready(meeting_id, seconds=900):
    door_ok("meeting", "stop", meeting_id)

    def settled():
        reply = meeting_get(meeting_id)
        return reply if reply["meeting"]["state"] in ("ready", "failed", "notesOnly") else None

    return wait_for("ready", settled, seconds, 2.0)


class Checks:
    def __init__(self):
        self.rows, self.unsure = [], False

    def check(self, name, ok, detail=""):
        self.rows.append({"check": name, "ok": bool(ok), "detail": detail})
        print(f"  {'PASS' if ok else 'FAIL'}  {name}  {detail}")

    def cannot_tell(self, name, reason):
        self.unsure = True
        self.rows.append({"check": name, "ok": None, "couldNotTell": reason})
        print(f"  COULD NOT TELL  {name}  {reason}")

    def skip(self, name, reason):
        self.rows.append({"check": name, "ok": None, "skipped": reason})
        print(f"  SKIP  {name}  {reason}")

    def status(self):
        if any(r.get("ok") is False for r in self.rows):
            return EXIT_FAIL
        return EXIT_UNSURE if self.unsure else EXIT_PASS


# ---------- scenarios ----------

def scenario_feature(run_dir, made, checks):
    import audio_rig
    import wispr_eyes as w
    c = checks
    work = tempfile.mkdtemp(prefix="meeting-uat-", dir=run_dir)
    audio, reference, seconds = make_conversation(work)
    with audio_rig.AudioRig(), Players() as players:
        meeting_id = start_meeting(call_sound=True)
        started = time.monotonic()
        made.append(meeting_id)
        status = door_ok("meeting", "status")
        c.check("the meeting records with the call sound", status["phase"]["name"] == "recording"
                and status["callSoundStatus"] == "captured", f"{status['callSoundStatus']}")
        notes = door_ok("meeting", "notes-set", meeting_id, "--text",
                        "Ask Maria about screenshots")
        c.check("notes typed during the recording are saved", notes.get("saved") is True)
        # The conversation alone: its call-track turns are scored against the script.
        offset_ms = int((time.monotonic() - started) * 1000)
        players.finish(players.play(audio))
        window_end_ms = offset_ms + int(seconds * 1000) + WINDOW_SLACK_MS
        time.sleep(WINDOW_SLACK_MS / 1000 + 1)  # deadline-fallback: dictations start after it
        landed = 0
        for sentence in DICTATIONS:
            result = w.record_tts(sentence, voice="echo", focus_app="TextEdit")
            landed += bool(result.get("success"))
        c.check("every dictation during the meeting is transcribed", landed == len(DICTATIONS),
                f"{landed}/{len(DICTATIONS)}")
        live = wait_for("live words", live_lines, 150, 5.0)
        c.check("live words appear while the meeting records", bool(live),
                f"{len(live or [])} lines")
        ready = stop_and_wait_ready(meeting_id)
    if not ready:
        c.check("the transcript is ready after Stop", False, "timed out")
        return
    record = ready["meeting"]
    c.check("the transcript is ready after Stop", record["state"] == "ready", record["state"])
    text, speakers = call_track_text(meeting_get(meeting_id, include_text=True), window_end_ms)
    score = wer(reference, text) if text else 1.0
    c.check("the conversation's call-track words match the script", score <= MAX_CALL_WER,
            f"WER {score:.3f} (limit {MAX_CALL_WER}; turns before {window_end_ms} ms)")
    c.check("at least two speakers in the conversation", len(speakers) >= 2,
            f"{sorted(speakers)}")
    c.check("probable echo is hidden from the mic track", record["echoTurnCount"] > 0,
            f"{record['echoTurnCount']} echo turns")
    files = audio_files(meeting_id)
    c.check("the meeting's audio is on disk", bool(files) and record["audioKept"],
            f"{len(files)} files")
    summary = door_ok("meeting", "summary-get", meeting_id)
    if summary["configurationProblem"]:
        c.skip("a summary is written",
               f"no provider can write one: {summary['configurationProblem']}")
    else:
        def written():
            state = door_ok("meeting", "summary-get", meeting_id)
            return state if state["summary"] and not state["writing"] else None

        done = wait_for("summary", written, 300, 3.0)
        c.check("a summary is written", bool(done), (done or summary).get("activity") or "written")
    door_ok("meeting", "delete-audio", meeting_id)
    c.check("Delete audio removes the files", not audio_files(meeting_id)
            and meeting_get(meeting_id)["meeting"]["audioKept"] is False)


def scenario_crash(run_dir, made, checks):
    import audio_rig
    c = checks
    work = tempfile.mkdtemp(prefix="meeting-crash-", dir=run_dir)
    audio, _, _ = make_conversation(work)
    with audio_rig.AudioRig(), Players() as players:
        meeting_id = start_meeting(call_sound=True)
        made.append(meeting_id)
        players.play(audio)
        time.sleep(40)  # deadline-fallback: 40 s of recording before the crash
        pid = this_build_pid()
        os.kill(pid, signal.SIGKILL)
        players.stop_all()
        gone = wait_for("exit", lambda: not any(p == pid for p, _ in dev_pids()), 10, 0.2)
        c.check("the app is gone after SIGKILL", bool(gone))
        subprocess.run(["open", DEV_APP], check=True)
        if not wait_for("relaunch", dev_pids, 60, 1.0):
            raise Setup("the dev app did not relaunch")
        if not wait_for("door", lambda: door("meeting", "status")[0] == 0, 60, 1.0):
            raise Setup("the relaunched app's door did not open")

        def recovered():
            reply = meeting_get(meeting_id)["meeting"]
            return reply if reply["state"] == "ready" else None

        record = wait_for("recovered", recovered, 600, 3.0)
    c.check("the interrupted meeting is recovered and transcribed", bool(record),
            (record or {}).get("state", "not ready"))
    c.check("it is marked as interrupted", bool(record) and record.get("wasInterrupted") is True)


def wait_both_tracks_progress(label, seconds=120):
    """Both tracks' live text grows between two reads at least 10 s apart."""
    first = wait_for(f"{label}: live words on both tracks",
                     lambda: (lambda n: n if n["microphone"] and n["callSound"] else None)(
                         track_text_lengths()), seconds, 2.0)
    if not first:
        return None, track_text_lengths()
    time.sleep(10)  # deadline-fallback: the progress window; the text is read again after it
    later = wait_for(f"{label}: progress", lambda: (lambda n: n if n["microphone"] > first["microphone"]
                     and n["callSound"] > first["callSound"] else None)(track_text_lengths()),
                     seconds, 2.0)
    return first, later or track_text_lengths()


def check_saved_audio(c, meeting_id, recorded_seconds):
    """Both captured tracks cover the recording, with frames and no gaps."""
    record = meeting_get(meeting_id)["meeting"]
    problems = saved_audio_problems(record, recorded_seconds)
    c.check("the saved audio covers the recording on both tracks", not problems,
            "; ".join(problems) or f"{(record.get('durationMs') or 0) / 1000:.1f} s, both tracks")
    return record


def isolated_dictation(c, players, audio, sentence):
    """A push-to-talk dictation with dictation's live preview on, heard alone: the meeting's
    playback stops first and resumes after. Checks the transcript against the spoken sentence,
    the take gate's input and paste checks (`success`), and that the preview showed words."""
    import wispr_eyes as w
    preview = door_ok("settings", "get", "livePreviewEnabled")
    for proc in list(players.procs):
        players.stop(proc)
    players.procs.clear()
    import datetime
    take_start = datetime.datetime.now().astimezone()
    door_ok("settings", "set", "livePreviewEnabled", "true")
    try:
        result = w.record_tts(sentence, voice="echo", focus_app="TextEdit")
    finally:
        door_ok("settings", "set", "livePreviewEnabled", json.dumps(preview.get("value")))
    players.loop(audio)
    raw = result.get("raw_asr") or ""
    score = wer(sentence, raw) if raw else 1.0
    c.check("the dictation lands in the paste target during the meeting",
            bool(result.get("success")), json.dumps({k: result.get(k) for k in ("success", "provider")}))
    c.check("the dictation heard the spoken sentence", score <= 0.2, f"WER {score:.2f}: {raw[:120]}")
    witness = wait_preview_witness(take_start, w.log_lines_since)
    c.check("dictation's live preview showed words", bool(witness) and witness[1] > 0,
            f"feeds, shownChars = {witness} (app.log since {take_start.isoformat()})")


def scenario_live(run_dir, made, checks, engine, audio=None):
    """#3973, #4105: live words through the chosen engine on both tracks while the meeting
    records, never shrinking over the pauses, a dictation with its own live preview during it,
    then the normal transcript."""
    import audio_rig
    import wispr_eyes as w
    c = checks
    work = tempfile.mkdtemp(prefix="meeting-live-", dir=run_dir)
    if audio is None:
        audio, _, _ = make_conversation(work)
    with audio_rig.AudioRig(), Players() as players, Sampler(this_build_pid()) as sampler:
        meeting_id = start_meeting(call_sound=True, live_engine=engine)
        started = time.monotonic()
        made.append(meeting_id)
        players.loop(audio)
        want = engine
        chosen = wait_for("engine", lambda: live_state().get("engine"), 60, 1.0)
        c.check("the live words use the expected engine", chosen == want, f"{chosen} (want {want})")
        first, later = wait_both_tracks_progress("live")
        # #4105: a pause never wipes what was already shown (samples 2 s apart over 30 s).
        shrank = []
        previous = track_text_lengths()
        for _ in range(15):
            time.sleep(2)  # deadline-fallback: the sampling period of a real-time check
            now = track_text_lengths()
            for track in ("microphone", "callSound"):
                if now[track] < previous[track] - 20:
                    shrank.append((track, previous[track], now[track]))
            previous = now
        c.check("live words never shrink over the pauses", not shrank, json.dumps(shrank))
        c.check("live words appear on both tracks", bool(first), json.dumps(first or later))
        c.check("both tracks' live text keeps growing", bool(first) and later["microphone"] >
                first["microphone"] and later["callSound"] > first["callSound"],
                f"{first} -> {later}")
        c.check("every track is running", set(track_statuses().values()) == {"running"},
                json.dumps(track_statuses()))
        # A dictation with dictation's own live preview while the meeting records.
        isolated_dictation(c, players, audio, DICTATIONS[0])
        after = track_text_lengths()
        time.sleep(15)  # deadline-fallback: live words after the dictation, read again after it
        resumed = track_text_lengths()
        c.check("call live words grow in the 15 s after the dictation",
                resumed["callSound"] > after["callSound"],
                f"{after} -> {resumed}")
        players.stop_all()
        recorded = time.monotonic() - started
        ready = stop_and_wait_ready(meeting_id)
    c.check("the transcript is ready after Stop", bool(ready) and ready["meeting"]["state"] == "ready",
            (ready or {}).get("meeting", {}).get("state", "timed out"))
    c.check("the live words are gone once the transcript is ready", not live_state(),
            json.dumps(live_state())[:200])
    if ready:
        check_saved_audio(c, meeting_id, recorded)
    checks.rows.append({"memory": sampler.summary()})
    print(f"  memory: {json.dumps(sampler.summary())}")


def scenario_speechkill(run_dir, made, checks):
    """#3973: Apple's speech service dies mid-meeting. Live words stop; the recording, its saved
    audio and the final transcript do not."""
    import audio_rig
    c = checks
    work = tempfile.mkdtemp(prefix="meeting-kill-", dir=run_dir)
    audio, _, _ = make_conversation(work)
    with audio_rig.AudioRig(), Players() as players:
        meeting_id = start_meeting(call_sound=True, live_engine="apple")
        started = time.monotonic()
        made.append(meeting_id)
        players.loop(audio)
        if wait_for("engine", lambda: live_state().get("engine"), 60, 1.0) != "apple":
            raise Unsure(f"the meeting is not on Apple speech: {live_state().get('engine')}")
        first, later = wait_both_tracks_progress("before the kill")
        if not first:
            raise Unsure(f"no live words on both tracks before the kill: {later}")
        # One user-session service serves every app's Apple speech: stopping it also interrupts
        # any other app recognizing speech right now (macOS restarts it on the next request).
        pid = the_speech_service(speech_service_pids())
        if not still_the_speech_service(pid):
            raise Setup(f"localspeechrecognition {pid} changed before the kill")
        os.kill(pid, signal.SIGKILL)
        pids = [pid]
        killed_at = time.monotonic()
        print(f"  killed localspeechrecognition {pid}")
        stopped = wait_for("a track stops", lambda: (lambda t: t if any(
            (v or "").startswith("stopped") for v in t.values()) else None)(track_statuses()), 60, 1.0)
        c.check("a live-words track says it stopped", bool(stopped), json.dumps(track_statuses()))
        status = door_ok("meeting", "status")
        c.check("the meeting keeps recording after the kill", status["phase"]["name"] == "recording",
                status["phase"]["name"])
        # A sentence never played before, alone, inside the continued recording.
        for proc in list(players.procs):
            players.stop(proc)
        players.procs.clear()
        clip = os.path.join(work, "post-kill.wav")
        aiff = os.path.join(work, "post-kill.aiff")
        subprocess.run(["say", "-v", CALL_VOICES["nova"], "-o", aiff, POST_KILL_SENTENCE],
                       check=True, timeout=60)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1", aiff,
                        clip], check=True, capture_output=True)
        said_from_ms = int((time.monotonic() - started) * 1000)
        player = players.play(clip)
        players.finish(player)
        c.check("the post-kill sentence played to the end", player.returncode == 0,
                f"afplay exit {player.returncode}")
        said_to_ms = int((time.monotonic() - started) * 1000)
        # Observed, not assumed: wait until 30 s have passed since the kill, then read the phase.
        remaining = 30 - (time.monotonic() - killed_at)
        if remaining > 0:
            time.sleep(remaining)  # deadline-fallback: the 30 s window after the kill is fixed
        status = door_ok("meeting", "status")
        held, elapsed = held_recording(killed_at, time.monotonic(),
                                       status["phase"]["name"] == "recording")
        c.check("the meeting is still recording at least 30 s after the kill", held,
                f"{status['phase']['name']} {elapsed} s after the kill")
        players.stop_all()
        recorded = time.monotonic() - started
        ready = stop_and_wait_ready(meeting_id)
    c.check("the transcript is ready after Stop", bool(ready) and ready["meeting"]["state"] == "ready",
            (ready or {}).get("meeting", {}).get("state", "timed out"))
    if ready:
        check_saved_audio(c, meeting_id, recorded)
        # Turn times are on the meeting clock, which starts a little after `started`.
        text = call_text_between(meeting_get(meeting_id, include_text=True),
                                 said_from_ms - 5000, said_to_ms + 2000)
        heard, hits, total = phrase_heard(POST_KILL_SENTENCE, text)
        c.check("the sentence played after the kill is in the final transcript", heard,
                f"{hits}/{total} content words in call turns {said_from_ms}-{said_to_ms} ms: {text[:160]}")
    checks.rows.append({"killedAfterSeconds": round(killed_at - started, 1), "pids": pids})


def crash_reports():
    return set(glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*EnviousWispr*")))


def scenario_quit(run_dir, made, checks):
    """#3973: the user quits while the meeting's live words run: the app exits without a crash
    report, and the meeting is kept and transcribed after relaunch."""
    import audio_rig
    c = checks
    work = tempfile.mkdtemp(prefix="meeting-quit-", dir=run_dir)
    audio, _, _ = make_conversation(work)
    before = crash_reports()
    with audio_rig.AudioRig(), Players() as players:
        meeting_id = start_meeting(call_sound=True)
        made.append(meeting_id)
        players.loop(audio)
        first, _ = wait_both_tracks_progress("before quit")
        c.check("live words run before the quit", bool(first))
        pid = this_build_pid()
        # The quit a user's Cmd-Q sends, to this exact process: never by bundle id, which every
        # worktree's dev build shares (tools-and-apps.md RULE: dev-bundle-id-collision-across-worktrees).
        import AppKit
        app = AppKit.NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
        if app is None or not (app.executableURL().path() or "").startswith(DEV_APP + "/"):
            raise Setup(f"pid {pid} is no longer this worktree's dev app")
        if not app.terminate():
            raise Setup(f"the quit request to pid {pid} was not sent")
        gone = wait_for("exit", lambda: not any(p == pid for p, _ in dev_pids()), 30, 0.5)
        c.check("the app exits after Quit", bool(gone))
        players.stop_all()
        time.sleep(5)  # deadline-fallback: ReportCrash writes within seconds of an exit
        new = sorted(crash_reports() - before)
        c.check("no crash report within 5 s of the exit", not new, json.dumps(new))
        # Relaunched inside the rig: its restore puts the app's own microphone back through the
        # door, which needs the app running.
        subprocess.run(["open", DEV_APP], check=True)
        if not wait_for("relaunch", dev_pids, 60, 1.0):
            raise Setup("the dev app did not relaunch")
        if not wait_for("door", lambda: door("meeting", "status")[0] == 0, 60, 1.0):
            raise Setup("the relaunched app's door did not open")

    def kept():
        reply = meeting_get(meeting_id)["meeting"]
        return reply if reply["state"] == "ready" else None

    record = wait_for("transcribed", kept, 600, 3.0)
    c.check("the meeting is kept and transcribed after relaunch", bool(record),
            (record or {}).get("state", "not ready"))


def asr_seconds(sentence):
    import wispr_eyes as w
    result = w.record_tts(sentence, voice="echo", focus_app="TextEdit")
    match = re.match(r"\s*([\d.]+)", result.get("asr_time") or "")
    return float(match.group(1)) if match else None


BETWEEN_TAKES_SECONDS = 8


def timed_takes(count, sentence, players=None, audio=None, still=lambda: True):
    """ASR seconds of up to `count` takes, stopping when `still()` turns false. With `audio`,
    the call plays for BETWEEN_TAKES_SECONDS before each take and is stopped before the take
    starts, so every take hears only its own TTS whatever the arm (R51 compares like with
    like); the gaps keep a recording meeting's live words busy."""
    values = []
    for _ in range(count):
        if not still():
            break
        if audio:
            player = players.play(audio)
            time.sleep(BETWEEN_TAKES_SECONDS)  # deadline-fallback: a fixed call interval
            players.stop(player)
        # The condition must hold at both take boundaries, or the take is not counted.
        if not still():
            break
        value = asr_seconds(sentence)
        if value is not None and still():
            values.append(value)
    return values


def scenario_latency(run_dir, made, checks, takes):
    import audio_rig
    c = checks
    sentence = "Please schedule the design review for next Tuesday afternoon."
    work = tempfile.mkdtemp(prefix="meeting-latency-", dir=run_dir)
    audio, _, _ = make_conversation(work)
    with audio_rig.AudioRig(), Players() as players:
        baseline = timed_takes(takes, sentence, players, audio)
        meeting_id = start_meeting(call_sound=True)
        made.append(meeting_id)
        players.finish(players.play(audio))
        preview = wait_for("live words", live_text_length, 150, 5.0)
        recording = timed_takes(takes, sentence, players, audio)
        preview_after = live_text_length()
        door_ok("meeting", "stop", meeting_id)
        in_pass = wait_for("pass", lambda: door_ok("meeting", "status")["processing"], 60, 0.5)
        during_pass = timed_takes(
            takes, sentence, players, audio,
            still=lambda: bool(door_ok("meeting", "status")["processing"])
        ) if in_pass else []
    if len(baseline) < takes:
        c.cannot_tell("the no-meeting baseline", f"{len(baseline)}/{takes} timed takes")
        return
    if not preview or preview_after <= preview:
        c.cannot_tell("ASR time while a meeting records with live words",
                      "live words were not shown to be active through the takes")
    elif len(recording) < takes:
        c.cannot_tell("ASR time while a meeting records with live words",
                      f"{len(recording)}/{takes} timed takes")
    else:
        ok, numbers = latency_verdict(baseline, recording)
        c.check("ASR time while a meeting records with live words stays in the bound", ok,
                json.dumps(numbers))
    if len(during_pass) < takes:
        c.cannot_tell("ASR time during the after-recording pass",
                      f"{len(during_pass)}/{takes} timed takes while the pass ran")
    else:
        ok, numbers = latency_verdict(baseline, during_pass)
        c.check("ASR time during the after-recording pass stays in the bound", ok,
                json.dumps(numbers))


def footprint_bytes(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True,
                         timeout=10).stdout
    return parse_footprint(out)


def sampled_peak(pid, seconds, work):
    """(peak bytes, samples taken) every 1 s while `work()` runs, over a fixed window."""
    peak, count, stop = [0], [0], threading.Event()

    def sample():
        while not stop.is_set():
            try:
                value = footprint_bytes(pid)
            except subprocess.TimeoutExpired:
                value = None
            if value:
                peak[0] = max(peak[0], value)
                count[0] += 1
            stop.wait(1.0)  # deadline-fallback: the 1 s sampling period (R58), ended by stop

    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    started = time.monotonic()
    try:
        work()
        remaining = seconds - (time.monotonic() - started)
        if remaining > 0:
            time.sleep(remaining)  # deadline-fallback: the measured window has a fixed length
    finally:
        stop.set()
        thread.join()
    return peak[0], count[0]


def scenario_memory(run_dir, made, checks, minutes):
    import audio_rig
    import wispr_eyes as w
    c = checks
    seconds = minutes * 60
    pid = this_build_pid()
    work_dir = tempfile.mkdtemp(prefix="meeting-memory-", dir=run_dir)
    audio, _, _ = make_conversation(work_dir)

    def dictations():
        for sentence in DICTATIONS:
            w.record_tts(sentence, voice="echo", focus_app="TextEdit")

    previews = []
    with audio_rig.AudioRig(), Players() as players:
        baseline = sampled_peak(pid, seconds, dictations)
        meeting_id = start_meeting(call_sound=True)
        made.append(meeting_id)

        def meeting_work():
            players.loop(audio)
            dictations()
            previews.append(live_text_length())

        during = sampled_peak(pid, seconds, meeting_work)
        previews.append(live_text_length())
        players.stop_all()
        door_ok("meeting", "stop", meeting_id)
    name = "a recording meeting with live words adds at most 1.2 GB"
    if not previews or previews[-1] == 0 or previews[-1] <= previews[0]:
        c.cannot_tell(name, f"live words were not shown to be active: {previews}")
        return
    status, detail = memory_verdict(baseline, during, int(seconds))
    if status == EXIT_UNSURE:
        c.cannot_tell(name, detail)
    else:
        c.check(name, status == EXIT_PASS, detail)


def cleanup(made, delete=None):
    """[(meeting id, deleted, detail)] for every meeting this run made."""
    delete = delete or (lambda meeting_id: door("meeting", "delete", meeting_id))
    results = []
    for meeting_id in made:
        try:
            status, reply = delete(meeting_id)
            deleted = status == 0 and bool(reply.get("ok"))
            detail = "deleted" if deleted else json.dumps(reply)[:300]
        except (Setup, subprocess.SubprocessError, OSError) as error:
            deleted, detail = False, f"{type(error).__name__}: {error}"
        print(f"  cleanup: {meeting_id}: {detail}")
        results.append({"meetingID": meeting_id, "deleted": deleted, "detail": detail})
    return results


def run_scenario(args, delete=None):
    """(exit status, rows). Every harness error maps to its declared exit code; a meeting left
    behind is SETUP FAILED, never PASS."""
    import take_gate as tg
    made, checks = [], Checks()
    status = None
    try:
        this_build_pid()
        print(f"== meeting {args.scenario}")
        if args.scenario == "feature":
            scenario_feature(args.run_dir, made, checks)
        elif args.scenario == "crash":
            scenario_crash(args.run_dir, made, checks)
        elif args.scenario == "latency":
            scenario_latency(args.run_dir, made, checks, args.takes)
        elif args.scenario == "live":
            scenario_live(args.run_dir, made, checks, args.live_engine, audio=args.audio)
        elif args.scenario == "speechkill":
            scenario_speechkill(args.run_dir, made, checks)
        elif args.scenario == "quit":
            scenario_quit(args.run_dir, made, checks)
        else:
            scenario_memory(args.run_dir, made, checks, args.minutes)
    except (Setup, tg.SetupFailed, subprocess.SubprocessError, OSError) as error:
        print(f"SETUP FAILED: {type(error).__name__}: {error}")
        checks.rows.append({"setup": f"{type(error).__name__}: {error}"})
        status = EXIT_SETUP
    except (Unsure, tg.CouldNotTell) as error:
        checks.cannot_tell("the run", f"{type(error).__name__}: {error}")
    except Exception as error:  # a harness defect is never an app result
        checks.cannot_tell("the run", f"harness error {type(error).__name__}: {error}")
    finally:
        left = [r for r in cleanup(made, delete) if not r["deleted"]] if made else []
    if left:
        checks.rows.append({"cleanup": left})
        status = EXIT_SETUP if status is None and checks.status() != EXIT_FAIL else status
    return (checks.status() if status is None else status), checks.rows


def self_test():
    failures = []

    def expect(name, cond):
        print(f"  {'ok' if cond else 'FAIL'}  {name}")
        if not cond:
            failures.append(name)

    expect("identical text has no errors", wer("Hello, World!", "hello world") == 0.0)
    # #3973: saved audio, post-kill speech and the dictation witness.
    good = {"durationMs": 60000, "failureCode": None, "tracks": {
        "microphone": {"status": "captured", "frames": 960000, "gaps": 0},
        "callSound": {"status": "captured", "frames": 958000, "gaps": 0}}}
    expect("both full tracks pass", saved_audio_problems(good, 61) == [])
    missing = {**good, "tracks": {"microphone": good["tracks"]["microphone"]}}
    expect("a missing call track fails", saved_audio_problems(missing, 61) == ["callSound: missing"])
    zero = {**good, "tracks": {**good["tracks"], "callSound": {"status": "captured", "frames": 0,
                                                               "gaps": 0}}}
    expect("a zero-frame track fails", any("frames 0" in p for p in saved_audio_problems(zero, 61)))
    off = {**good, "tracks": {**good["tracks"], "callSound": {"status": "failed", "frames": 958000,
                                                              "gaps": 0}}}
    expect("an uncaptured track fails", any("status failed" in p for p in saved_audio_problems(off, 61)))
    gappy = {**good, "tracks": {**good["tracks"], "microphone": {"status": "captured",
                                                                  "frames": 960000, "gaps": 1}}}
    expect("a gap fails", any("gaps 1" in p for p in saved_audio_problems(gappy, 61)))
    expect("a short track fails", any("callSound:" in p for p in saved_audio_problems(
        {**good, "tracks": {**good["tracks"], "callSound": {"status": "captured", "frames": 16000 * 50,
                                                            "gaps": 0}}}, 61)))
    expect("no length fails", saved_audio_problems({"tracks": good["tracks"]}, 61)[0].startswith("no recorded"))
    expect("a malformed reply fails", saved_audio_problems({}, 61) != [])
    turns = {"transcript": {"projection": {"visibleTurnIDs": ["a", "b", "c"]}, "turns": [
        {"id": "a", "speakerId": "sys:1", "startMs": 10000, "text": "Good morning everyone."},
        {"id": "b", "speakerId": "sys:2", "startMs": 90000, "text": POST_KILL_SENTENCE},
        {"id": "c", "speakerId": "mic:1", "startMs": 90500, "text": "Seventeen purple lanterns"}]}}
    heard, _, _ = phrase_heard(POST_KILL_SENTENCE, call_text_between(turns, 85000, 100000))
    expect("the post-kill sentence in its window is heard", heard)
    heard, _, _ = phrase_heard(POST_KILL_SENTENCE, call_text_between(turns, 0, 60000))
    expect("pre-kill text alone does not count", not heard)
    early = {"transcript": {"turns": [
        {"id": "b", "speakerId": "sys:2", "startMs": 20000, "text": POST_KILL_SENTENCE}]}}
    heard, _, _ = phrase_heard(POST_KILL_SENTENCE, call_text_between(early, 85000, 100000))
    expect("the sentence before the kill window does not count", not heard)
    hidden = {"transcript": {"projection": {"visibleTurnIDs": ["x"]}, "turns": [
        {"id": "b", "speakerId": "sys:2", "startMs": 90000, "text": POST_KILL_SENTENCE}]}}
    heard, _, _ = phrase_heard(POST_KILL_SENTENCE, call_text_between(hidden, 85000, 100000))
    expect("a hidden turn does not count", not heard)
    none_visible = {"transcript": {"projection": {"visibleTurnIDs": []}, "turns": [
        {"id": "b", "speakerId": "sys:2", "startMs": 90000, "text": POST_KILL_SENTENCE}]}}
    heard, _, _ = phrase_heard(POST_KILL_SENTENCE, call_text_between(none_visible, 85000, 100000))
    expect("an empty visible list hides every turn", not heard)
    no_projection = {"transcript": {"turns": [
        {"id": "b", "speakerId": "sys:2", "startMs": 90000, "text": POST_KILL_SENTENCE}]}}
    heard, _, _ = phrase_heard(POST_KILL_SENTENCE, call_text_between(no_projection, 85000, 100000))
    expect("no projection shows every turn", heard)
    expect("call_track_text: an empty visible list hides every turn",
           call_track_text(none_visible)[0] == "")
    expect("call_track_text: no projection shows every turn",
           call_track_text(no_projection)[0] == POST_KILL_SENTENCE)
    heard, _, _ = phrase_heard(POST_KILL_SENTENCE, "the call ended")
    expect("unrelated text does not count", not heard)
    expect("one speech service is the one to stop", the_speech_service([4242]) == 4242)
    for candidates in ([], [1, 2]):
        try:
            the_speech_service(candidates)
            refused = False
        except Setup:
            refused = True
        expect(f"{len(candidates)} speech services refuse the kill", refused)
    expect("a matching dictation passes", wer(DICTATIONS[0], DICTATIONS[0].lower()) <= 0.2)
    expect("a mismatched dictation fails", wer(DICTATIONS[0], "Good morning everyone") > 0.2)
    log = ("x LIVE_PREVIEW session ended, feeds=40 shownChars=52\n"
           "y LIVE_PREVIEW session ended, feeds=3 shownChars=0\n")
    expect("the preview witness reads its own line", preview_witness(log) == (40, 52))
    # The witness reader: lines from rotated files arrive through `read`; a late line is waited for.
    rotated = ["[2026-10-25T10:00:01Z] [INFO] [LivePreview] LIVE_PREVIEW session ended, feeds=12 shownChars=30"]
    expect("a witness in a rotated file is read",
           wait_preview_witness("t", lambda _: rotated, seconds=0) == (12, 30))
    reads, now = [], [0.0]

    def late(_start):
        reads.append(1)
        return rotated if len(reads) >= 3 else []

    witness = wait_preview_witness("t", late, seconds=10, every=1.0, clock=lambda: now[0],
                                   sleep=lambda d: now.__setitem__(0, now[0] + d))
    expect("a late witness is waited for", witness == (12, 30) and len(reads) == 3)
    witness = wait_preview_witness("t", lambda _: [], seconds=3, every=1.0, clock=lambda: now[0],
                                   sleep=lambda d: now.__setitem__(0, now[0] + d))
    expect("no witness by the deadline is None", witness is None)
    expect("recording 31 s after the kill passes", held_recording(100.0, 131.0, True) == (True, 31.0))
    expect("29 s after the kill fails", held_recording(100.0, 129.0, True)[0] is False)
    expect("not recording fails", held_recording(100.0, 140.0, False)[0] is False)
    expect("no preview line is no witness", preview_witness("LIVE_PREVIEW resolving") is None)
    expect("a preview that showed nothing is not a witness",
           preview_witness("LIVE_PREVIEW session ended, feeds=9 shownChars=0") == (9, 0))
    expect("one substitution in four words", wer("a b c d", "a x c d") == 0.25)
    expect("a deletion and an insertion", wer("a b c", "a c d") == 2 / 3)
    expect("an empty hypothesis is all errors", wer("a b", "") == 1.0)
    expect("curly apostrophes normalize", normalize("Let’s go") == ["let's", "go"])
    expect("nearest-rank p90 of ten", percentile(list(range(1, 11)), 0.9) == 9)
    expect("p90 of one value", percentile([4.0], 0.9) == 4.0)
    ok, _ = latency_verdict([1.0] * 10, [1.09] * 10)
    expect("+9 % median passes", ok)
    ok, _ = latency_verdict([1.0] * 10, [1.11] * 10)
    expect("+11 % median fails", not ok)
    ok, _ = latency_verdict([1.0] * 10, [1.0] * 8 + [1.3, 1.3])
    expect("+30 % p90 with a steady median fails", not ok)
    ok, _ = latency_verdict([1.0] * 10, [1.0] * 8 + [1.15, 1.15])
    expect("+15 % p90 passes", ok)
    expect("footprint MB", parse_footprint("phys_footprint: 512 MB") == 512 * 1024 ** 2)
    expect("footprint GB", parse_footprint("  phys_footprint: 1.5 GB\n") == int(1.5 * 1024 ** 3))
    expect("no footprint line", parse_footprint("nothing") is None)
    gb = 1024 ** 3
    expect("memory within budget passes",
           memory_verdict((gb, 600), (2 * gb, 600), 600)[0] == EXIT_PASS)
    expect("memory over budget fails",
           memory_verdict((gb, 600), (int(2.3 * gb), 600), 600)[0] == EXIT_FAIL)
    expect("no during samples cannot tell",
           memory_verdict((gb, 600), (0, 0), 600)[0] == EXIT_UNSURE)
    expect("interrupted sampling cannot tell",
           memory_verdict((gb, 600), (gb, 300), 600)[0] == EXIT_UNSURE)
    reply = {"transcript": {
        "projection": {"visibleTurnIDs": ["t1", "t3", "t5"]},
        "turns": [{"id": "t1", "speakerId": "sys:S1", "startMs": 0, "text": "hello"},
                  {"id": "t2", "speakerId": "sys:S2", "startMs": 10, "text": "hidden"},
                  {"id": "t3", "speakerId": "sys:S2", "startMs": 20, "text": "there"},
                  {"id": "t4", "speakerId": "mic:you", "startMs": 30, "text": "mine"},
                  {"id": "t5", "speakerId": "sys:S1", "startMs": 9000, "text": "dictated"}]}}
    text, speakers = call_track_text(reply)
    expect("only visible call turns, in order", text == "hello there dictated")
    text, speakers = call_track_text(reply, window_end_ms=100)
    expect("the conversation window drops later turns", text == "hello there")
    expect("call speakers counted in the window", speakers == {"sys:S1", "sys:S2"})
    expect("a correct transcript of the played call passes its reference",
           wer("Good morning everyone.", "good morning everyone") == 0.0)

    class FakeProc:
        def __init__(self, pid):
            self.pid = pid

        def wait(self, timeout=None):
            return 0

    # A leader that already exited with a child still playing: its group is killed anyway.
    groups = {-7: True}
    players = Players()
    players.procs.append(FakeProc(-7))
    players.killpg = lambda pgid, sig: groups.__setitem__(pgid, False)
    players.alive = lambda pgid: groups[pgid]
    players.stop_all()
    expect("an exited leader's surviving child is still killed", groups[-7] is False)

    # A group that cannot be emptied never lets the rig restore the speakers.
    exits, restored = [], []
    players = Players()
    players.procs.append(FakeProc(-8))
    players.killpg = lambda pgid, sig: None
    players.alive = lambda pgid: True

    class Rig:
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            restored.append(True)

    class Exit(BaseException):
        pass

    def fake_exit(code):
        exits.append(code)
        raise Exit()

    original = globals()["unsafe_exit"]
    globals()["unsafe_exit"] = lambda error: original(error, exit=fake_exit)
    try:
        with Rig(), players:
            pass
    except Exit:
        pass
    finally:
        globals()["unsafe_exit"] = original
    # `os._exit` never unwinds; the fake raises a BaseException the rig does not see as a
    # normal exit only for this test, so it checks that the exit was asked for first.
    expect("a player that cannot be stopped exits SETUP FAILED", exits == [EXIT_SETUP])

    # The latency arms hear the same thing: the call stops before every take.
    events = []

    class Recorder(Players):
        def play(self, path):
            events.append("play")
            return FakeProc(-9)

        def stop(self, proc):
            events.append("stop")

    saved = globals()["asr_seconds"], time.sleep
    globals()["asr_seconds"] = lambda sentence: events.append("take") or 1.0
    time.sleep = lambda seconds: None
    try:
        timed_takes(3, "x", Recorder(), "/call.wav")
    finally:
        globals()["asr_seconds"], time.sleep = saved
    expect("the call is stopped before every take", events == ["play", "stop", "take"] * 3)

    # The pass ends in the gap before the last take: that take is never counted.
    checks_left = iter([True, True, True, True, True, True, True, False])
    globals()["asr_seconds"] = lambda sentence: 1.0
    time.sleep = lambda seconds: None
    events.clear()
    try:
        counted = timed_takes(3, "x", Recorder(), "/call.wav", still=lambda: next(checks_left))
    finally:
        globals()["asr_seconds"], time.sleep = saved
    expect("a pass that ends before the take boundary does not count", len(counted) == 2)
    ending = iter([True, True, False])
    globals()["asr_seconds"] = lambda sentence: 1.0
    try:
        counted = timed_takes(1, "x", still=lambda: next(ending))
    finally:
        globals()["asr_seconds"] = saved[0]
    expect("a pass that ends during the take does not count", counted == [])

    # Any shutdown error, and a failed receipt write, still request the exit first.
    for label, kill, path in (("PermissionError", PermissionError("denied"), None),
                              ("receipt OSError", None, "/nonexistent-dir/receipt.json")):
        exits.clear()
        players = Players()
        players.procs.append(FakeProc(-10))

        def raising_kill(pgid, sig, _kill=kill):
            if _kill:
                raise _kill

        players.killpg = raising_kill
        players.alive = lambda pgid, _kill=kill: _kill is None
        RECEIPT["path"] = path
        globals()["unsafe_exit"] = lambda error: original(error, exit=fake_exit)
        try:
            with players:
                pass
        except Exit:
            pass
        finally:
            globals()["unsafe_exit"] = original
            RECEIPT["path"] = None
        expect(f"{label} during shutdown still requests the exit", exits == [EXIT_SETUP])

    import types
    for error, want in ((Setup("x"), EXIT_SETUP), (subprocess.TimeoutExpired("x", 1), EXIT_SETUP),
                        (Unsure("x"), EXIT_UNSURE), (KeyError("x"), EXIT_UNSURE)):
        def boom(*_a, _error=error):
            raise _error
        saved = globals()["scenario_feature"], globals()["this_build_pid"]
        globals()["scenario_feature"], globals()["this_build_pid"] = boom, lambda: 1
        try:
            status, rows = run_scenario(types.SimpleNamespace(scenario="feature", run_dir="/tmp"))
        finally:
            globals()["scenario_feature"], globals()["this_build_pid"] = saved
        expect(f"{type(error).__name__} maps to {VERDICTS[want]}", status == want and rows)

    def passing(_run_dir, made, checks):
        made.append("m1")
        checks.check("fine", True)

    for label, delete in (("refused", lambda _id: (1, {"ok": False})),
                          ("timed out", lambda _id: (_ for _ in ()).throw(
                              subprocess.TimeoutExpired("delete", 60)))):
        saved = globals()["scenario_feature"], globals()["this_build_pid"]
        globals()["scenario_feature"], globals()["this_build_pid"] = passing, lambda: 1
        try:
            status, rows = run_scenario(
                types.SimpleNamespace(scenario="feature", run_dir="/tmp"), delete=delete)
        finally:
            globals()["scenario_feature"], globals()["this_build_pid"] = saved
        expect(f"a {label} deletion after a passing run is not PASS",
               status == EXIT_SETUP and any("cleanup" in r for r in rows))
    print(f"meeting_uat self-test: {len(failures)} failed")
    return EXIT_PASS if not failures else EXIT_FAIL


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("scenario", nargs="?", choices=[
        "feature", "crash", "latency", "memory", "live", "speechkill", "quit"])
    parser.add_argument("--live-engine", choices=["apple", "universal"], default="apple")
    parser.add_argument("--audio", help="live: a WAV to replay instead of the synthetic conversation")
    parser.add_argument("--run-dir")
    parser.add_argument("--takes", type=int, default=20)
    parser.add_argument("--minutes", type=float, default=10.0)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.scenario or not args.run_dir or not os.path.isdir(args.run_dir):
        parser.error("a scenario and an existing --run-dir are required")
    receipt = os.path.join(args.run_dir, f"meeting-{args.scenario}.json")
    RECEIPT["path"], RECEIPT["scenario"] = receipt, args.scenario
    status, rows = run_scenario(args)
    with open(receipt, "w") as f:
        json.dump({"scenario": args.scenario, "exit": status, "rows": rows}, f, indent=1)
    print(f"verdict: {VERDICTS[status]} ({receipt})")
    return status


if __name__ == "__main__":
    sys.exit(main())
