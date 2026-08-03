#!/usr/bin/env python3
"""Play corpus WAVs aloud into a THIRD-PARTY dictation app and capture what it pastes.

Why this exists (#1272, 2026-08-02). Our Type B buckets encode an opinion about what
good polish looks like. When a bucket scores badly the question "is our model wrong, or
is our rubric wrong?" cannot be answered from inside our own harness. Running the same
audio through a shipping competitor answers it: if the market leader makes the same call
we graded a failure, the rubric is the thing to fix.

It is deliberately NOT a wispr_eyes.py addition. wispr_eyes drives EnviousWispr and reads
verdicts from our app log (tools-and-apps.md RULE: uat-verdicts-from-app-log); this drives
an app we do not own, which has no log we can read, so the capture path is different.
Keystroke synthesis is reused from simulate_input.py rather than re-implemented.

Usage:
    # Wispr Flow open, its record key set to fn, a TextEdit window open and focused
    python3 scripts/eval/wispr_flow_bench.py \
        --wav-dir scripts/eval/runs/typeb-parakeet-2026-08-01/wav \
        --ids LF- --out /tmp/wf_results.jsonl

Method notes that are load-bearing:
  * Capture is a direct accessibility read of the TextEdit buffer. Saving to disk was
    tried first and failed: Sublime's unregistered-license modal fired on save and
    silently swallowed every later keystroke, which looked exactly like the dictation
    app refusing to transcribe.
  * The buffer is cleared between cases via an accessibility write, not Cmd+A/Delete.
    Dictation apps read the text around the cursor for context, so leaving earlier
    outputs above would change what the app produces and invalidate the comparison.
  * No synthetic keystrokes are sent apart from the record key. A posted key event
    inherits ambient modifier state, so a lingering fn turns Return into fn+Return:
    macOS beeps and inserts nothing.
  * Audio reaches the app acoustically, through the speakers and the microphone. That
    is a harder input than the pristine WAV our own runs consume, so check the reported
    word-overlap before reading anything into a competitor's mistakes.
"""
import argparse, hashlib, json, os, subprocess, sys, threading, time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "Tests/RuntimeUAT"))
import simulate_input as si  # noqa: E402

from ApplicationServices import (  # noqa: E402
    AXUIElementCreateApplication, AXUIElementCopyAttributeValue,
    AXUIElementSetAttributeValue, kAXFocusedUIElementAttribute, kAXValueAttribute)


def duration(path):
    """True duration via afinfo. WAV headers written by our TTS step carry bogus
    frame counts, so the wave module reports ~89000 seconds for a 3 second clip."""
    out = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "estimated duration" in line:
            return float(line.split(":")[1].strip().split()[0])
    raise RuntimeError(f"afinfo gave no duration for {path}")


def wav_sha(path):
    """Identity of the audio a result came from.

    Resume matches on case ID, and a refreshed corpus reuses IDs while changing
    the audio behind them, so an ID alone would keep a result produced from a
    different recording.
    """
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def _focused_element(app="TextEdit"):
    p = subprocess.run(["pgrep", "-n", "-x", app], capture_output=True, text=True)
    pid = int(p.stdout.strip() or 0)
    if not pid:
        raise RuntimeError(f"{app} is not running")
    err, foc = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                             kAXFocusedUIElementAttribute, None)
    if err:
        raise RuntimeError(f"no focused element in {app} (AX err {err})")
    return foc


def read_buffer(app="TextEdit"):
    """Raises rather than returning '' when the editor is unreachable, so a broken
    instrument can never be mistaken for the app declining to dictate."""
    err, val = AXUIElementCopyAttributeValue(_focused_element(app), kAXValueAttribute, None)
    if err:
        raise RuntimeError(f"cannot read {app} value (AX err {err})")
    return val or ""


def clear_buffer(app="TextEdit"):
    err = AXUIElementSetAttributeValue(_focused_element(app), kAXValueAttribute, "")
    if err:
        raise RuntimeError(f"cannot clear {app} buffer (AX err {err})")


def dictate(case_id, wav_dir, key="fn", app="TextEdit", settle=2.0, timeout=30.0):
    path = os.path.join(wav_dir, f"{case_id}.wav")
    dur = duration(path)
    subprocess.run(["osascript", "-e", f'tell application "{app}" to activate'],
                   capture_output=True)
    time.sleep(0.4)
    clear_buffer(app)
    time.sleep(0.2)
    before = read_buffer(app)

    player = threading.Thread(
        target=lambda: (time.sleep(0.35), subprocess.run(["afplay", path], capture_output=True)))
    player.start()
    si.hold_key(key, duration=dur + settle)
    player.join()

    # Signal-based wait: poll until the buffer grows and then settles. Never a fixed sleep.
    deadline, text, last_change = time.time() + timeout, before, None
    while time.time() < deadline:
        time.sleep(0.5)
        now = read_buffer(app)
        if now != text:
            text, last_change = now, time.time()
        elif last_change and time.time() - last_change > 1.5:
            break
    delta = text[len(before):] if text.startswith(before) else text
    return {"id": case_id, "audio_s": round(dur, 2), "wav_sha": wav_sha(path),
            "output": delta.strip(), "no_paste": last_change is None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav-dir", required=True)
    ap.add_argument("--ids", required=True,
                    help="id prefix to run, e.g. 'LF-' for the list_format bucket")
    ap.add_argument("--out", required=True)
    ap.add_argument("--key", default="fn", help="the competitor's record key")
    ap.add_argument("--app", default="TextEdit", help="paste target, must be AX-readable")
    args = ap.parse_args()

    ids = sorted((f[:-4] for f in os.listdir(args.wav_dir)
                  if f.startswith(args.ids) and f.endswith(".wav")),
                 key=lambda x: (x.split("-")[0], int(x.split("-")[1])))
    done = {}
    if os.path.exists(args.out):
        with open(args.out) as f:
            for l in f:
                if l.strip():
                    r = json.loads(l)
                    # A failed capture is not a result. The abort path appends
                    # no_paste rows before stopping, so treating them as done
                    # would make a resumed run skip precisely the cases that
                    # failed and report a full sweep it never took.
                    if r.get("no_paste") or not r.get("output"):
                        continue
                    done[r["id"]] = r.get("wav_sha")
    # Skip only when the stored result came from THIS audio. A row written before
    # wav_sha existed has None and is redone, which costs one run and cannot
    # report a result from a recording that no longer exists.
    todo = [c for c in ids
            if done.get(c) != wav_sha(os.path.join(args.wav_dir, f"{c}.wav"))]
    print(f"{len(done)} already done, {len(todo)} to run", flush=True)

    empties = 0
    with open(args.out, "a") as f:
        for i, cid in enumerate(todo, 1):
            r = dictate(cid, args.wav_dir, key=args.key, app=args.app)
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
            f.flush()
            print(f"[{i}/{len(todo)}] {cid} -> {r['output'][:70]!r}", flush=True)
            # Fail loud. A long run of empties means the instrument broke, not that the
            # competitor declined to answer a hundred times in a row.
            empties = empties + 1 if not r["output"] else 0
            if empties >= 3:
                print("ABORT: 3 consecutive empty results, instrument is broken", flush=True)
                return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
