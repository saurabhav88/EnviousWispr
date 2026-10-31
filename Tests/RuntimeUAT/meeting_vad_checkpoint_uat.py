#!/usr/bin/env python3
"""#4254 responsiveness checkpoint: actions DURING a meeting Whisper pass's speech detection.

    python3 Tests/RuntimeUAT/meeting_vad_checkpoint_uat.py --run-dir <dir> \
        --meeting <id> [--meeting <id> ...] [--delete-meeting <test meeting id>]
    python3 Tests/RuntimeUAT/meeting_vad_checkpoint_uat.py --self-test

Run with Bash `run_in_background: true`, holding the shared dev-app lock, with ONE debug
instance of THIS worktree's build running and Debug Mode on. Reuses `meeting_uat.py`'s door,
identity, Checks, crash-report and folder helpers.

Founder decision 2026-10-31: saved meetings (his and earlier test meetings) may be transcribed
again for this check; no new fake meeting is recorded. Transcribing again replaces a meeting's
transcript. Delete runs ONLY on `--delete-meeting`, a meeting the operator names as a test
meeting; it is never chosen automatically.

Each pass is `meeting retry <id> --engine whisper` (the endpoint defaults to Parakeet). Its
detection is bracketed by the app's own counts-only lines `whisper_meeting_vad_start token=T`
and `whisper_meeting_vad outcome=... token=T` (second-resolution timestamps). An action counts
as DURING detection only when it was DISPATCHED at least `MARGIN` seconds after the start
line's second and at least `MARGIN` seconds before the outcome line's second (correlated event
timestamps; a long meeting's detection lasts tens of seconds). Quit has no outcome line: it
counts when dispatched `MARGIN` s after the start line and the app exits with that token's
outcome never logged.

Dictation start responsiveness is the app's own `PTT-to-recording: total=<ms>` line (press to
recording started), matched to the take started after dispatch, separately from transcription.
Baselines: the same measure with no meeting pass, per engine.

Exit 0 PASS, 1 FAIL, 2 COULD NOT TELL, 3 SETUP FAILED. Receipt
<run dir>/meeting-vad-checkpoint.json.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import meeting_uat as m  # noqa: E402

LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
MARGIN = 1.0
STAMP = re.compile(r"^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d)\]")
START = re.compile(r"whisper_meeting_vad_start token=(\d+)")
OUTCOME = re.compile(r"whisper_meeting_vad outcome=(\S+) token=(\d+)")
READY = re.compile(r"PTT-to-recording: total=(\d+)ms")


def stamp(line):
    match = STAMP.match(line)
    return datetime.datetime.fromisoformat(match.group(1)).timestamp() if match else None


def detection_window(text, token=None):
    """(token, start epoch, outcome epoch or None, outcome) of the first detection in `text`
    (or of `token`). Start and outcome are read from the SAME text, so an outcome beside its
    start in one read is never skipped."""
    start = outcome_at = outcome = None
    for line in text.splitlines():
        found = START.search(line)
        if found and start is None and (token is None or found.group(1) == token):
            token, start = found.group(1), stamp(line)
            continue
        done = OUTCOME.search(line)
        if done and start is not None and done.group(2) == token:
            outcome_at, outcome = stamp(line), done.group(1)
            break
    return token, start, outcome_at, outcome


def during(dispatched, start, outcome_at, quit_case=False):
    """True, False, or None when the window is not known."""
    if start is None:
        return None
    if quit_case:
        return outcome_at is None and dispatched >= start + MARGIN
    if outcome_at is None:
        return None
    return start + MARGIN <= dispatched <= outcome_at - MARGIN


def ready_ms(text):
    """The first press-to-recording milliseconds in `text`, or None."""
    found = READY.search(text)
    return int(found.group(1)) if found else None


def log_size():
    return os.path.getsize(LOG)


def log_since(offset):
    with open(LOG, "rb") as f:
        f.seek(offset)
        return f.read().decode("utf-8", "replace")


def wait_log(offset, predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        text = log_since(offset)
        if predicate(text):
            return text
        time.sleep(0.05)  # deadline-fallback: the app's log is the only signal
    return log_since(offset)


def dictation(engine_label):
    """(press-to-recording ms or None, problem or None, dispatch epoch)."""
    offset = log_size()
    dispatched = time.time()
    status, reply = m.door("dictation", "start")
    if status != 0 or not reply.get("ok"):
        return None, f"start refused: {json.dumps(reply)[:200]}", dispatched
    receipt = json.dumps(reply["result"]["receipt"])
    text = wait_log(offset, lambda t: READY.search(t) is not None, 20)
    m.door("dictation", "stop", "--receipt", receipt)
    m.door("dictation", "wait", "--receipt", receipt, timeout=120)
    ms = ready_ms(text)
    return ms, None if ms is not None else f"no PTT-to-recording line ({engine_label})", dispatched


def switch(name):
    import wispr_eyes as w
    dispatched = time.time()
    t0 = time.monotonic()
    w.switch_backend(name, wait=180)
    return dispatched, round((time.monotonic() - t0) * 1000)


def state(meeting_id):
    return m.meeting_get(meeting_id)["meeting"]["state"]


def wait_ready(meeting_id, seconds=3600):
    return m.wait_for("ready", lambda: state(meeting_id) == "ready", seconds, 2.0)


def pass_window(meeting_id, offset, seconds=600):
    """Starts a Whisper pass and returns (token, start) once its detection start is logged."""
    m.door_ok("meeting", "retry", meeting_id, "--engine", "whisper")
    text = wait_log(offset, lambda t: START.search(t) is not None, seconds)
    token, start, _, _ = detection_window(text)
    return token, start


def finish_window(offset, token, seconds=1800):
    text = wait_log(offset, lambda t: detection_window(t, token)[2] is not None, seconds)
    return detection_window(text, token)


def open_window(start):
    while time.time() < start + MARGIN + 1:
        time.sleep(0.05)  # deadline-fallback: wait out the log's whole-second timestamps


def run(args):
    c = m.Checks()
    receipt = {}
    rows = {}
    saved = {}
    status = None
    try:
        m.this_build_pid()
        saved = {"selectedBackend": m.door_ok("settings", "get", "selectedBackend")["value"]}
        meetings = args.meeting
        for meeting_id in meetings + ([args.delete_meeting] if args.delete_meeting else []):
            record = m.meeting_get(meeting_id)["meeting"]
            if not record.get("audioKept") or record.get("state") != "ready":
                raise m.Setup(f"meeting {meeting_id} has no audio or is not ready")
        baseline = {}
        for engine in ("parakeet", "whisper"):
            switch(engine)
            values = [dictation(engine)[0] for _ in range(5)]
            baseline[engine] = values
            c.check(f"baseline {engine}: 5 press-to-recording readings",
                    all(v is not None for v in values), json.dumps(values))
        rows["baseline"] = baseline

        def action_pass(label, meeting_id, action):
            offset = log_size()
            token, start = pass_window(meeting_id, offset)
            if token is None:
                c.cannot_tell(label, "no detection start line")
                return None
            open_window(start)
            result = action()
            _, start2, outcome_at, outcome = finish_window(offset, token)
            inside = during(result["dispatched"], start2, outcome_at)
            row = {"label": label, "meeting": meeting_id, "token": token, "start": start2,
                   "outcomeAt": outcome_at, "outcome": outcome, **result, "during": inside}
            print(json.dumps(row))
            rows.setdefault("passes", []).append(row)
            if inside is None:
                c.cannot_tell(f"{label} during detection", "window not observed")
            else:
                c.check(f"{label} dispatched during detection", inside, json.dumps(row))
            c.check(f"{label} detection succeeded", outcome == "vad_ok", outcome or "none")
            wait_ready(meeting_id)
            return row

        primary = meetings[0]
        for engine in ("parakeet", "whisper"):
            switch(engine)
            for i in range(3):
                def take(engine=engine):
                    ms, problem, dispatched = dictation(engine)
                    return {"dispatched": dispatched, "pressToRecordingMs": ms, "problem": problem}
                row = action_pass(f"dictation-{engine}-{i}", meetings[i % len(meetings)], take)
                if row is not None:
                    c.check(f"dictation-{engine}-{i} press-to-recording read",
                            row.get("pressToRecordingMs") is not None, str(row.get("problem")))
        switch("parakeet")
        for target in ("whisper", "parakeet"):
            def flip(target=target):
                dispatched, ms = switch(target)
                return {"dispatched": dispatched, "switchMs": ms}
            action_pass(f"switch-to-{target}", primary, flip)
        pid = m.this_build_pid()
        samples = []

        def sample():
            dispatched = time.time()
            end = time.monotonic() + 1800
            while time.monotonic() < end and state(primary) != "ready":
                value = m.footprint_bytes(pid)
                if value:
                    samples.append(value)
                time.sleep(1)  # deadline-fallback: 1 s sampling period
            return {"dispatched": dispatched, "samples": len(samples),
                    "sampledResidencyPeakMB": round(max(samples) / 1048576) if samples else None}
        action_pass("sampled-residency", primary, sample)
        c.check("sampled residency has samples", bool(samples), str(len(samples)))
        # Quit during detection.
        before = m.crash_reports()
        offset = log_size()
        token, start = pass_window(primary, offset)
        if token is None:
            c.cannot_tell("quit during detection", "no detection start line")
        else:
            open_window(start)
            import AppKit
            pid_now = m.this_build_pid()
            app = AppKit.NSRunningApplication.runningApplicationWithProcessIdentifier_(pid_now)
            if app is None or not (app.executableURL().path() or "").startswith(m.DEV_APP + "/"):
                raise m.Setup(f"pid {pid_now} is not this worktree's dev app")
            dispatched = time.time()
            if not app.terminate():
                raise m.Setup("the quit request was not sent")
            gone = m.wait_for("exit", lambda: not any(p == pid_now for p, _ in m.dev_pids()), 60, 0.2)
            result = {"dispatched": dispatched, "exited": bool(gone),
                      "exitSeconds": round(time.time() - dispatched, 2)}
            _, start2, outcome_at, _ = detection_window(log_since(offset), token)
            rows["quit"] = {**result, "token": token, "start": start2, "outcomeAt": outcome_at}
            print(json.dumps(rows["quit"]))
            c.check("quit dispatched during detection (no outcome before exit)",
                    bool(during(dispatched, start2, outcome_at, quit_case=True)), json.dumps(rows["quit"]))
            c.check("the app exits after Quit", result["exited"], json.dumps(result))
            time.sleep(5)  # deadline-fallback: ReportCrash writes within seconds of an exit
            new = sorted(m.crash_reports() - before)
            c.check("no crash report after Quit", not new, json.dumps(new))
            subprocess.run(["open", m.DEV_APP], check=True)
            if not m.wait_for("relaunch", m.dev_pids, 60, 1.0):
                raise m.Setup("the dev app did not relaunch")
            m.this_build_pid()  # exactly this worktree's build again before any change
            if not m.wait_for("door", lambda: m.door("meeting", "status")[0] == 0, 60, 1.0):
                raise m.Setup("the relaunched app's door did not open")
            m.wait_for("recovered", lambda: state(primary) in ("ready", "failed"), 3600, 3.0)
            c.check("the meeting is ready again after relaunch", state(primary) == "ready", state(primary))
        # Delete last, only on the named test meeting.
        if args.delete_meeting:
            folder = m.meeting_folder(args.delete_meeting)
            if folder is None:
                raise m.Setup("the test meeting's folder is not one exact path")
            offset = log_size()
            token, start = pass_window(args.delete_meeting, offset)
            if token is None:
                c.cannot_tell("delete during detection", "no detection start line")
            else:
                open_window(start)
                dispatched = time.time()
                st, reply = m.door("meeting", "delete", args.delete_meeting)
                _, start2, outcome_at, _ = detection_window(log_since(offset), token)
                # A deletion may end the pass before any outcome line: dispatch after the start
                # with no outcome before the dispatch counts as during.
                inside = start2 is not None and dispatched >= start2 + MARGIN and (
                    outcome_at is None or dispatched <= outcome_at - MARGIN)
                rows["delete"] = {"dispatched": dispatched, "token": token, "start": start2,
                                  "outcomeAt": outcome_at, "reply": st == 0 and bool(reply.get("ok"))}
                print(json.dumps(rows["delete"]))
                c.check("delete dispatched during detection", inside, json.dumps(rows["delete"]))
                c.check("the delete reply succeeded", rows["delete"]["reply"])
                c.check("the deleted meeting's row is gone",
                        m.door("meeting", "get", args.delete_meeting)[0] != 0)
                c.check("the deleted meeting's folder is gone", not os.path.exists(folder), folder)
        else:
            c.cannot_tell("delete during detection", "no --delete-meeting named: not run")
    except m.Setup as error:
        c.rows.append({"setup": str(error)})
        status = m.EXIT_SETUP
    except Exception as error:  # a harness defect is never an app result
        c.cannot_tell("the run", f"harness error {type(error).__name__}: {error}")
    finally:
        for key, value in saved.items():
            try:
                switch(value)
            except Exception as error:
                c.rows.append({"restoreFailed": key, "error": str(error)})
                status = m.EXIT_SETUP
    final = c.status() if status is None else status
    receipt.update({"exit": final, "checks": c.rows, "detail": rows})
    with open(os.path.join(args.run_dir, "meeting-vad-checkpoint.json"), "w") as f:
        json.dump(receipt, f, indent=1, default=str)
    print(f"verdict exit={final}")
    return final


def self_test():
    """Offline controls of the window, overlap and reading parsers. Returns failures."""
    s = "[2026-10-31T09:00:00-04:00] [INFO] [T] "
    e = "[2026-10-31T09:00:30-04:00] [INFO] [T] "
    t0 = datetime.datetime.fromisoformat("2026-10-31T09:00:00-04:00").timestamp()
    cases = []
    one = s + "whisper_meeting_vad_start token=7 route=x\n" + e + "whisper_meeting_vad outcome=vad_ok token=7 route=x\n"
    cases.append(("start and outcome in one read", detection_window(one) == ("7", t0, t0 + 30, "vad_ok")))
    cases.append(("missing marker", detection_window("nothing here\n") == (None, None, None, None)))
    other = s + "whisper_meeting_vad_start token=7 route=x\n" + e + "whisper_meeting_vad outcome=vad_ok token=8 route=x\n"
    cases.append(("another token's outcome is not this one's", detection_window(other)[2] is None))
    cases.append(("dispatch inside the window", during(t0 + 10, t0, t0 + 30) is True))
    cases.append(("dispatch too close to the start", during(t0 + 0.5, t0, t0 + 30) is False))
    cases.append(("dispatch after the outcome", during(t0 + 31, t0, t0 + 30) is False))
    cases.append(("window not observed", during(t0 + 10, t0, None) is None))
    cases.append(("quit with no outcome", during(t0 + 5, t0, None, quit_case=True) is True))
    cases.append(("quit after an outcome", during(t0 + 5, t0, t0 + 3, quit_case=True) is False))
    cases.append(("readiness read", ready_ms("x PTT-to-recording: total=45ms preWarm=41ms") == 45))
    cases.append(("readiness missing", ready_ms("no line") is None))
    c = m.Checks()
    c.cannot_tell("x", "y")
    cases.append(("a could-not-tell row is not PASS", c.status() != 0))
    f = m.Checks()
    f.check("x", False)
    cases.append(("a failed check is FAIL", f.status() == 1))
    failures = [name for name, ok in cases if not ok]
    for name, ok in cases:
        print(("ok    " if ok else "FAIL  ") + name)
    print(f"{len(cases)} controls, {len(failures)} failed")
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir")
    parser.add_argument("--meeting", action="append", default=[])
    parser.add_argument("--delete-meeting")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        sys.exit(1 if self_test() else 0)
    if not args.run_dir or not args.meeting:
        parser.error("--run-dir and at least one --meeting are required")
    os.makedirs(args.run_dir, exist_ok=True)
    sys.exit(run(args))


if __name__ == "__main__":
    main()
