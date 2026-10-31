#!/usr/bin/env python3
"""#4254 responsiveness checkpoint: actions DURING a meeting Whisper pass's speech detection.

    python3 Tests/RuntimeUAT/meeting_vad_checkpoint_uat.py --run-dir <dir> \
        --meeting <id> [--meeting <id> ...] [--delete-meeting <test meeting id>]
    python3 Tests/RuntimeUAT/meeting_vad_checkpoint_uat.py --self-test

Run with Bash `run_in_background: true`, holding the shared dev-app lock, with ONE debug
instance of THIS worktree's build running and Debug Mode on. Reuses `meeting_uat.py`'s door,
identity, Checks, crash-report and folder helpers, and `paste_check_app_uat.NoiseFloor`.

Founder decision 2026-10-31: saved meetings (his and earlier test meetings) may be transcribed
again for this check; no new fake meeting is recorded. Transcribing again replaces a meeting's
transcript. Delete runs ONLY on `--delete-meeting`, a meeting the operator names as a test
meeting; it is never chosen automatically.

Evidence, all from the DEBUG build's own lines, one clock (`CLOCK_UPTIME_RAW`, nanoseconds,
read here with `time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)`):
- `whisper_meeting_vad_start token=T ... uptime_raw_ns=` and `whisper_meeting_vad outcome=...
  token=T ... uptime_raw_ns=`: a pass's detection, stamped at the events.
- `whisper_meeting_vad_active request=K id=I tokens=... uptime_raw_ns=`: the detections running
  when the app RECEIVED the request with client id I (dictation.start, meeting.delete, the
  selectedBackend write) or Quit (`id=none`, may never be written before exit). An action is
  DURING detection only when its witness lists the pass's token. No witness: COULD NOT TELL.
- `RECORDING_READY take=X uptime_raw_ns=`: the take went live. Readiness = that minus this
  script's clock reading just before the start request, per take id from the door's receipt.
A clock control checks a witness's reading lies between this script's readings before the
request and after its reply.

Each pass is `meeting retry <id> --engine whisper` (the endpoint defaults to Parakeet). Exit 0
PASS, 1 FAIL, 2 COULD NOT TELL, 3 SETUP FAILED. Receipt <run dir>/meeting-vad-checkpoint.json.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import meeting_uat as m  # noqa: E402

LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
START = re.compile(r"whisper_meeting_vad_start token=(\d+) .*uptime_raw_ns=(\d+)")
OUTCOME = re.compile(r"whisper_meeting_vad outcome=(\S+) token=(\d+) .*uptime_raw_ns=(\d+)")
WITNESS = re.compile(r"whisper_meeting_vad_active request=(\S+) id=(\S+) tokens=(\S+) uptime_raw_ns=(\d+)")
READY = re.compile(r"RECORDING_READY take=(\S+) uptime_raw_ns=(\d+)")


def now_ns():
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)


def first_start(text):
    """(token, start ns) of the first detection start in `text`, else (None, None)."""
    found = START.search(text)
    return (found.group(1), int(found.group(2))) if found else (None, None)


def outcome_of(text, token):
    """(outcome, ns) of `token`'s outcome line in `text`, else (None, None)."""
    for found in OUTCOME.finditer(text):
        if found.group(2) == token:
            return found.group(1), int(found.group(3))
    return None, None


def witness(text, request, request_id=None):
    """(tokens list, ns) of the first witness for `request` (and `request_id`), else None."""
    for found in WITNESS.finditer(text):
        if found.group(1) == request and (request_id is None or found.group(2) == request_id):
            tokens = [] if found.group(3) == "none" else found.group(3).split(",")
            return tokens, int(found.group(4))
    return None


def ready_ns(text, take):
    for found in READY.finditer(text):
        if found.group(1) == take:
            return int(found.group(2))
    return None


def during(witnessed, token):
    """True, False, or None (no witness: could not tell)."""
    if witnessed is None:
        return None
    return token in witnessed[0]


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


def dictation():
    """dict: request id, take, readiness ms (or None), clock control, problem."""
    offset = log_size()
    before = now_ns()
    status, reply = m.door("dictation", "start")
    after = now_ns()
    if status != 0 or not reply.get("ok"):
        return {"problem": f"start refused: {json.dumps(reply)[:200]}", "offset": offset}
    receipt = reply["result"]["receipt"]
    take = receipt.get("takeID")
    text = wait_log(offset, lambda t: ready_ns(t, take) is not None and witness(t, "dictation.start", reply.get("id")) is not None, 20)
    m.door("dictation", "stop", "--receipt", json.dumps(receipt))
    m.door("dictation", "wait", "--receipt", json.dumps(receipt), timeout=120)
    ready = ready_ns(text, take)
    seen = witness(text, "dictation.start", reply.get("id"))
    return {"id": reply.get("id"), "take": take, "offset": offset, "text": text,
            "readyMs": round((ready - before) / 1e6, 1) if ready else None,
            "clockOk": seen is not None and before <= seen[1] <= after,
            "witness": seen, "problem": None if ready else "no RECORDING_READY for the take"}


def switch(name):
    """Writes selectedBackend through the door (witnessed) and waits for the switch."""
    import wispr_eyes as w
    offset = log_size()
    t0 = time.monotonic()
    status, reply = m.door("settings", "set", "selectedBackend", json.dumps(name))
    if status != 0 or not reply.get("ok"):
        raise m.Setup(f"engine switch refused: {reply}")
    w.switch_backend(name, wait=180)
    return {"id": reply.get("id"), "offset": offset, "switchMs": round((time.monotonic() - t0) * 1000)}


def state(meeting_id):
    return m.meeting_get(meeting_id)["meeting"]["state"]


def wait_ready(meeting_id, seconds=3600):
    return m.wait_for("ready", lambda: state(meeting_id) == "ready", seconds, 2.0)


def start_pass(meeting_id, seconds=600):
    """Starts a Whisper pass; (token, start ns, log offset) once its detection start is logged."""
    offset = log_size()
    m.door_ok("meeting", "retry", meeting_id, "--engine", "whisper")
    text = wait_log(offset, lambda t: START.search(t) is not None, seconds)
    token, start = first_start(text)
    return token, start, offset


def run(args):
    import audio_rig
    from paste_check_app_uat import NoiseFloor
    c = m.Checks()
    detail = {}
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
        work = tempfile.mkdtemp(prefix="vad-checkpoint-", dir=args.run_dir)
        with audio_rig.AudioRig(), NoiseFloor(work):
            baseline = {}
            for engine in ("parakeet", "whisper"):
                switch(engine)
                takes = [dictation() for _ in range(5)]
                baseline[engine] = [t.get("readyMs") for t in takes]
                c.check(f"baseline {engine}: 5 take-matched readiness readings",
                        all(t.get("readyMs") is not None for t in takes), json.dumps(baseline[engine]))
                c.check(f"baseline {engine}: clock control", all(t.get("clockOk") for t in takes))
            detail["baselineReadyMs"] = baseline
            passes = detail.setdefault("passes", [])

            def judge(label, meeting_id, token, start, offset, request, request_id, extra):
                text = wait_log(offset, lambda t: outcome_of(t, token)[0] is not None, 1800)
                outcome, end = outcome_of(text, token)
                seen = witness(text, request, request_id)
                inside = during(seen, token)
                row = {"label": label, "meeting": meeting_id, "token": token, "startNs": start,
                       "outcome": outcome, "endNs": end, "witness": seen, "during": inside, **extra}
                passes.append(row)
                print(json.dumps(row, default=str))
                if inside is None:
                    c.cannot_tell(f"{label} during detection", "no request witness")
                else:
                    c.check(f"{label} received during detection", inside, json.dumps(row, default=str))
                c.check(f"{label} detection succeeded", outcome == "vad_ok", outcome or "none")
                wait_ready(meeting_id)

            for engine in ("parakeet", "whisper"):
                switch(engine)
                for i in range(3):
                    meeting_id = meetings[i % len(meetings)]
                    token, start, offset = start_pass(meeting_id)
                    if token is None:
                        c.cannot_tell(f"dictation-{engine}-{i}", "no detection start line")
                        continue
                    take = dictation()
                    c.check(f"dictation-{engine}-{i} take-matched readiness read",
                            take.get("readyMs") is not None, str(take.get("problem")))
                    judge(f"dictation-{engine}-{i}", meeting_id, token, start, offset, "dictation.start",
                          take.get("id"), {"readyMs": take.get("readyMs"), "clockOk": take.get("clockOk")})
            primary = meetings[0]
            switch("parakeet")
            for target in ("whisper", "parakeet"):
                token, start, offset = start_pass(primary)
                if token is None:
                    c.cannot_tell(f"switch-to-{target}", "no detection start line")
                    continue
                result = switch(target)
                judge(f"switch-to-{target}", primary, token, start, offset, "engine_switch",
                      result["id"], {"switchMs": result["switchMs"]})
            # Sampled residency across one pass.
            pid = m.this_build_pid()
            samples = []
            token, start, offset = start_pass(primary)
            end = time.monotonic() + 1800
            while time.monotonic() < end and state(primary) != "ready":
                value = m.footprint_bytes(pid)
                if value:
                    samples.append(value)
                time.sleep(1)  # deadline-fallback: 1 s sampling period
            detail["sampledResidency"] = {"peakMB": round(max(samples) / 1048576) if samples else None,
                                          "samples": len(samples), "clock": "footprint, 1 s"}
            c.check("sampled residency has samples", bool(samples), str(len(samples)))
            # Quit during detection.
            before = m.crash_reports()
            token, start, offset = start_pass(primary)
            if token is None:
                c.cannot_tell("quit during detection", "no detection start line")
            else:
                import AppKit
                pid_now = m.this_build_pid()
                app = AppKit.NSRunningApplication.runningApplicationWithProcessIdentifier_(pid_now)
                if app is None or not (app.executableURL().path() or "").startswith(m.DEV_APP + "/"):
                    raise m.Setup(f"pid {pid_now} is not this worktree's dev app")
                sent = now_ns()
                if not app.terminate():
                    raise m.Setup("the quit request was not sent")
                gone = m.wait_for("exit", lambda: not any(p == pid_now for p, _ in m.dev_pids()), 60, 0.2)
                text = log_since(offset)
                seen = witness(text, "quit")
                detail["quit"] = {"token": token, "startNs": start, "sentNs": sent, "witness": seen,
                                  "outcome": outcome_of(text, token)[0], "exited": bool(gone)}
                print(json.dumps(detail["quit"], default=str))
                inside = during(seen, token)
                if inside is None:
                    c.cannot_tell("quit received during detection", "no quit witness written before exit")
                else:
                    c.check("quit received during detection", inside, json.dumps(detail["quit"], default=str))
                c.check("the app exits after Quit", bool(gone))
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
                token, start, offset = start_pass(args.delete_meeting)
                if token is None:
                    c.cannot_tell("delete during detection", "no detection start line")
                else:
                    st, reply = m.door("meeting", "delete", args.delete_meeting)
                    text = wait_log(offset, lambda t: witness(t, "meeting.delete", reply.get("id")) is not None, 20)
                    seen = witness(text, "meeting.delete", reply.get("id"))
                    detail["delete"] = {"token": token, "witness": seen, "reply": st == 0 and bool(reply.get("ok"))}
                    print(json.dumps(detail["delete"], default=str))
                    inside = during(seen, token)
                    if inside is None:
                        c.cannot_tell("delete received during detection", "no delete witness")
                    else:
                        c.check("delete received during detection", inside)
                    c.check("the delete reply succeeded", detail["delete"]["reply"])
                    c.check("the deleted meeting's row is gone", m.door("meeting", "get", args.delete_meeting)[0] != 0)
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
    with open(os.path.join(args.run_dir, "meeting-vad-checkpoint.json"), "w") as f:
        json.dump({"exit": final, "checks": c.rows, "detail": detail}, f, indent=1, default=str)
    print(f"verdict exit={final}")
    return final


def self_test():
    """Offline controls of the parsers, the overlap rule and the verdict mapping."""
    cases = []
    one = ("x whisper_meeting_vad_start token=7 route=r run_samples=1 uptime_raw_ns=100\n"
           "x whisper_meeting_vad outcome=vad_ok token=7 route=r detector=d run_samples=1 group_samples=1 groups=1 uptime_raw_ns=900\n")
    cases.append(("start and outcome in one read", first_start(one) == ("7", 100) and outcome_of(one, "7") == ("vad_ok", 900)))
    cases.append(("missing marker", first_start("nothing\n") == (None, None)))
    cases.append(("another token's outcome is not this one's", outcome_of(one, "8") == (None, None)))
    w = ("x whisper_meeting_vad_active request=dictation.start id=A tokens=7,11 uptime_raw_ns=500\n"
         "x whisper_meeting_vad_active request=dictation.start id=B tokens=none uptime_raw_ns=600\n")
    cases.append(("witness matched by request id", witness(w, "dictation.start", "A") == (["7", "11"], 500)))
    cases.append(("another request's witness is not this one's", witness(w, "dictation.start", "C") is None))
    cases.append(("token listed: during", during(witness(w, "dictation.start", "A"), "7") is True))
    cases.append(("no detection running: not during", during(witness(w, "dictation.start", "B"), "7") is False))
    cases.append(("no witness: could not tell", during(None, "7") is None))
    q = "x whisper_meeting_vad_active request=quit id=none tokens=7 uptime_raw_ns=700\n"
    cases.append(("quit witness read", during(witness(q, "quit"), "7") is True))
    cases.append(("missing quit witness: could not tell", during(witness("", "quit"), "7") is None))
    r = "x RECORDING_READY take=T1 uptime_raw_ns=1500\nx RECORDING_READY take=T2 uptime_raw_ns=1600\n"
    cases.append(("readiness matched by take", ready_ns(r, "T2") == 1600))
    cases.append(("readiness of another take is not this one's", ready_ns(r, "T3") is None))
    delayed = ""  # the ready line not written yet: no reading, never a guess
    cases.append(("delayed log: no readiness yet", ready_ns(delayed, "T1") is None))
    c = m.Checks()
    c.cannot_tell("x", "y")
    cases.append(("a could-not-tell row is not PASS", c.status() != 0))
    f = m.Checks()
    f.check("x", False)
    cases.append(("a failed check is FAIL", f.status() == 1))
    cases.append(("the clock is CLOCK_UPTIME_RAW", now_ns() > 0))
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
