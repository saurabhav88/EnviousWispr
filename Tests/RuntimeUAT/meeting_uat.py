"""EnviousMeet on the real Debug app (#3972 plan section 11.1, R7, R51, R58).

    python3 Tests/RuntimeUAT/meeting_uat.py feature --run-dir <dir>
    python3 Tests/RuntimeUAT/meeting_uat.py crash --run-dir <dir>
    python3 Tests/RuntimeUAT/meeting_uat.py latency --run-dir <dir> [--takes 20]
    python3 Tests/RuntimeUAT/meeting_uat.py memory --run-dir <dir> [--minutes 10]
    python3 Tests/RuntimeUAT/meeting_uat.py --self-test

Run every scenario with Bash `run_in_background: true` (the dictations hold the push-to-talk
key through CGEvent), holding the shared dev-app lock, with ONE debug instance of THIS
worktree's build running and Debug Mode on (verdicts come from app.log and the dev-control
door, never the clipboard).

The call is a scripted two-person conversation made with two TTS voices, so its reference
words are known exactly. No real meeting recording (AMI) is on this Mac and none is
downloaded; the WER here is against that script, not the AMI number of the plan.

Audio stays silent: `audio_rig.AudioRig` routes output and the app's microphone to BlackHole.
The call-sound tap hears every process, so the call track carries the conversation and each
dictation's TTS; the microphone (BlackHole) hears the same audio, which is the no-headphones
case: the mic copies of call lines are probable echo and hidden by default (R7 rig C).

- feature: Start (call sound on), live words appear, notes saved, five dictations land in
  TextEdit while the meeting records, Stop, the transcript is ready with call-track WER
  against the script, at least two call-track speakers, echo hidden, audio on disk, a summary
  when an AI Polish provider can write one, Delete audio removes the files, Delete meeting.
- crash: Start, play 40 s, SIGKILL the verified dev PID, relaunch, the meeting is recovered
  as interrupted and transcribed.
- latency: `--takes` dictations with no meeting, then the same during a meeting's
  after-recording pass; median within +10 %, p90 within +20 % (R51).
- memory: `footprint` peak of the app process sampled every 1 s over `--minutes` of
  dictation-only work, then the same with a meeting recording and live words; at most
  1.2 GB added (R51, R58).

Exit: 0 PASS, 1 FAIL (an app result), 2 COULD NOT TELL, 3 SETUP FAILED. Receipts:
<run dir>/meeting-<scenario>.json and the console. Every meeting this run made is deleted at
the end; no other meeting is touched.
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

# The call: two people, alternating, with known words. Short turns with pauses between them,
# about three minutes when spoken.
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
# No bake-off number exists for this script; the plan's "within 3 points of the bake-off"
# cannot be applied. A clean TTS conversation transcribed by Parakeet should stay far below this.
MAX_CALL_WER = 0.15
PLAYER_SECONDS = 600


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
                "duringP95": percentile(during, 0.95)}


def parse_footprint(text):
    """Bytes of the `phys_footprint` line of `footprint -p <pid>` output, or None."""
    match = re.search(r"phys_footprint:\s*([\d.]+)\s*([KMG]?B)", text)
    if not match:
        return None
    scale = {"B": 1, "KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3}[match.group(2)]
    return int(float(match.group(1)) * scale)


def call_track_text(meeting):
    """The call track's visible words from a `meeting get --include-text` reply."""
    transcript = meeting.get("transcript") or {}
    visible = set((transcript.get("projection") or {}).get("visibleTurnIDs") or [])
    names = transcript.get("speakerNames") or {}
    lines, speakers = [], set()
    for turn in transcript.get("turns") or []:
        speaker = turn.get("speakerId") or ""
        # Track speaker prefixes: `mic:` and `sys:` (MeetingTrackKind.speakerPrefix).
        if not speaker.startswith("sys:") or (visible and turn.get("id") not in visible):
            continue
        lines.append(turn.get("text") or "")
        speakers.add(speaker)
    return " ".join(lines), speakers, names


# ---------- the app ----------

class Setup(Exception):
    """The run could not be set up: not an app result."""


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


def make_conversation(directory):
    """A WAV of the conversation (TTS turns joined by pauses) and its reference text."""
    import wispr_eyes as w
    parts = []
    for index, (voice, line) in enumerate(CONVERSATION):
        mp3 = w.tts(line, voice=voice)
        wav = os.path.join(directory, f"turn-{index:02d}.wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@24000", "-c", "1", mp3, wav],
                       check=True, capture_output=True)
        parts.append(wav)
    out = os.path.join(directory, "conversation.wav")
    with wave.open(out, "wb") as dst:
        dst.setnchannels(1)
        dst.setsampwidth(2)
        dst.setframerate(24000)
        silence = b"\0\0" * int(24000 * GAP_SECONDS)
        for part in parts:
            with wave.open(part, "rb") as src:
                dst.writeframes(src.readframes(src.getnframes()))
            dst.writeframes(silence)
    return out, " ".join(line for _, line in CONVERSATION)


def play(path):
    return subprocess.Popen(["afplay", path], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)


def finish(player):
    """Waits for the player's exit (its signal), with a deadline in case afplay hangs."""
    player.wait(timeout=PLAYER_SECONDS)  # deadline-fallback: around the process-exit signal


def start_meeting(call_sound=True):
    reply = door_ok("meeting", "start", "--entry-point", "menu",
                    "--call-sound" if call_sound else "--no-call-sound")
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

    def skip(self, name, reason):
        self.rows.append({"check": name, "ok": None, "skipped": reason})
        print(f"  SKIP  {name}  {reason}")

    def status(self):
        if any(r["ok"] is False for r in self.rows):
            return EXIT_FAIL
        return EXIT_UNSURE if self.unsure else EXIT_PASS


# ---------- scenarios ----------

def scenario_feature(run_dir, made):
    import audio_rig
    import wispr_eyes as w
    c = Checks()
    work = tempfile.mkdtemp(prefix="meeting-uat-", dir=run_dir)
    audio, reference = make_conversation(work)
    with audio_rig.AudioRig():
        meeting_id = start_meeting(call_sound=True)
        made.append(meeting_id)
        status = door_ok("meeting", "status")
        c.check("the meeting records with the call sound", status["phase"]["name"] == "recording"
                and status["callSoundStatus"] == "captured", f"{status['callSoundStatus']}")
        notes = door_ok("meeting", "notes-set", meeting_id, "--text", "Ask Maria about screenshots")
        c.check("notes typed during the recording are saved", notes.get("saved") is True)
        player = play(audio)
        landed = 0
        for sentence in DICTATIONS:
            time.sleep(12)  # deadline-fallback: spaces the dictations through the call
            result = w.record_tts(sentence, voice="echo", focus_app="TextEdit")
            landed += bool(result.get("success"))
        c.check("every dictation during the meeting is transcribed", landed == len(DICTATIONS),
                f"{landed}/{len(DICTATIONS)}")
        live = wait_for("live words", lambda: (door_ok("meeting", "live")["live"] or {})
                        .get("lines"), 150, 5.0)
        c.check("live words appear while the meeting records", bool(live),
                f"{len(live or [])} lines")
        finish(player)
        ready = stop_and_wait_ready(meeting_id)
    if not ready:
        c.check("the transcript is ready after Stop", False, "timed out")
        return c
    record = ready["meeting"]
    c.check("the transcript is ready after Stop", record["state"] == "ready", record["state"])
    full = meeting_get(meeting_id, include_text=True)
    text, speakers, _ = call_track_text(full)
    score = wer(reference, text) if text else 1.0
    c.check("call-track words match the conversation", score <= MAX_CALL_WER,
            f"WER {score:.3f} (limit {MAX_CALL_WER}; the call track also carries the dictations)")
    c.check("at least two speakers on the call track", len(speakers) >= 2, f"{sorted(speakers)}")
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
    return c


def scenario_crash(run_dir, made):
    import audio_rig
    c = Checks()
    work = tempfile.mkdtemp(prefix="meeting-crash-", dir=run_dir)
    audio, _ = make_conversation(work)
    with audio_rig.AudioRig():
        meeting_id = start_meeting(call_sound=True)
        made.append(meeting_id)
        player = play(audio)
        time.sleep(40)  # deadline-fallback: 40 s of recording before the crash
        pid = this_build_pid()
        os.kill(pid, signal.SIGKILL)
        player.terminate()
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
    return c


def asr_seconds(sentence):
    import wispr_eyes as w
    result = w.record_tts(sentence, voice="echo", focus_app="TextEdit")
    match = re.match(r"\s*([\d.]+)", result.get("asr_time") or "")
    return float(match.group(1)) if match else None


def scenario_latency(run_dir, made, takes):
    import audio_rig
    c = Checks()
    sentence = "Please schedule the design review for next Tuesday afternoon."
    with audio_rig.AudioRig():
        baseline = [s for s in (asr_seconds(sentence) for _ in range(takes)) if s is not None]
        work = tempfile.mkdtemp(prefix="meeting-latency-", dir=run_dir)
        audio, _ = make_conversation(work)
        meeting_id = start_meeting(call_sound=True)
        made.append(meeting_id)
        finish(play(audio))
        door_ok("meeting", "stop", meeting_id)
        if not wait_for("pass", lambda: door_ok("meeting", "status")["processing"], 60, 0.5):
            c.unsure = True
            c.skip("dictation during the after-recording pass", "the pass ended before a take")
            return c
        during = []
        for _ in range(takes):
            if not door_ok("meeting", "status")["processing"]:
                break
            seconds = asr_seconds(sentence)
            if seconds is not None:
                during.append(seconds)
    if len(baseline) < takes or len(during) < max(5, takes // 2):
        c.unsure = True
        c.skip("ASR time during a meeting pass",
               f"baseline {len(baseline)}, during {len(during)}")
        return c
    ok, numbers = latency_verdict(baseline, during)
    c.check("ASR time during a meeting pass stays in the bound", ok, json.dumps(numbers))
    return c


def footprint_bytes(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    return parse_footprint(out)


def sampled_peak(pid, seconds, work):
    """Peak footprint sampled every 1 s while `work()` runs, over a fixed window."""
    peak, stop = [0], threading.Event()

    def sample():
        while not stop.is_set():
            value = footprint_bytes(pid)
            if value:
                peak[0] = max(peak[0], value)
            stop.wait(1.0)  # deadline-fallback: the 1 s sampling period (R58), ended by stop

    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    started = time.monotonic()
    work()
    remaining = seconds - (time.monotonic() - started)
    if remaining > 0:
        time.sleep(remaining)  # deadline-fallback: the measured window has a fixed length
    stop.set()
    thread.join()
    return peak[0]


def scenario_memory(run_dir, made, minutes):
    import audio_rig
    import wispr_eyes as w
    c = Checks()
    seconds = minutes * 60
    pid = this_build_pid()
    work_dir = tempfile.mkdtemp(prefix="meeting-memory-", dir=run_dir)
    audio, _ = make_conversation(work_dir)

    def dictations():
        for sentence in DICTATIONS:
            w.record_tts(sentence, voice="echo", focus_app="TextEdit")

    with audio_rig.AudioRig():
        baseline = sampled_peak(pid, seconds, dictations)
        meeting_id = start_meeting(call_sound=True)
        made.append(meeting_id)

        def meeting_work():
            player = subprocess.Popen(
                ["bash", "-c", f"while true; do afplay '{audio}'; done"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                dictations()
                left = seconds - 120
                if left > 0:
                    time.sleep(left)  # deadline-fallback: keep the call playing for the window
            finally:
                player.terminate()

        during = sampled_peak(pid, seconds, meeting_work)
        door_ok("meeting", "stop", meeting_id)
    added = during - baseline
    c.check("a recording meeting with live words adds at most 1.2 GB",
            baseline > 0 and added <= 1.2 * 1024 ** 3,
            f"baseline {baseline / 1e9:.2f} GB, during {during / 1e9:.2f} GB, "
            f"added {added / 1e9:.2f} GB")
    return c


def cleanup(made):
    for meeting_id in made:
        status, reply = door("meeting", "delete", meeting_id)
        print(f"  cleanup: delete {meeting_id}: {'ok' if status == 0 else reply}")


def self_test():
    failures = []

    def expect(name, cond):
        print(f"  {'ok' if cond else 'FAIL'}  {name}")
        if not cond:
            failures.append(name)

    expect("identical text has no errors", wer("Hello, World!", "hello world") == 0.0)
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
    reply = {"transcript": {
        "projection": {"visibleTurnIDs": ["t1", "t3"]},
        "turns": [{"id": "t1", "speakerId": "sys:S1", "text": "hello"},
                  {"id": "t2", "speakerId": "sys:S2", "text": "hidden"},
                  {"id": "t3", "speakerId": "sys:S2", "text": "there"},
                  {"id": "t4", "speakerId": "mic:you", "text": "mine"}]}}
    text, speakers, _ = call_track_text(reply)
    expect("only visible call turns, in order", text == "hello there")
    expect("call speakers counted", speakers == {"sys:S1", "sys:S2"})
    print(f"meeting_uat self-test: {len(failures)} failed")
    return EXIT_PASS if not failures else EXIT_FAIL


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("scenario", nargs="?", choices=["feature", "crash", "latency", "memory"])
    parser.add_argument("--run-dir")
    parser.add_argument("--takes", type=int, default=20)
    parser.add_argument("--minutes", type=float, default=10.0)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.scenario or not args.run_dir or not os.path.isdir(args.run_dir):
        parser.error("a scenario and an existing --run-dir are required")
    made = []
    status, rows = EXIT_SETUP, []
    try:
        this_build_pid()
        print(f"== meeting {args.scenario}")
        if args.scenario == "feature":
            checks = scenario_feature(args.run_dir, made)
        elif args.scenario == "crash":
            checks = scenario_crash(args.run_dir, made)
        elif args.scenario == "latency":
            checks = scenario_latency(args.run_dir, made, args.takes)
        else:
            checks = scenario_memory(args.run_dir, made, args.minutes)
        status, rows = checks.status(), checks.rows
    except Setup as error:
        print(f"SETUP FAILED: {error}")
        rows = [{"setup": str(error)}]
    finally:
        if made:
            try:
                cleanup(made)
            except Setup as error:
                print(f"cleanup could not finish: {error}")
    receipt = os.path.join(args.run_dir, f"meeting-{args.scenario}.json")
    with open(receipt, "w") as f:
        json.dump({"scenario": args.scenario, "exit": status, "rows": rows}, f, indent=1)
    print(f"verdict: {['PASS', 'FAIL', 'COULD NOT TELL', 'SETUP FAILED'][status]} ({receipt})")
    return status


if __name__ == "__main__":
    sys.exit(main())
