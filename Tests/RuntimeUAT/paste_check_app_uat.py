#!/usr/bin/env python3
"""Does a dictation land in one named app, and what does the paste check say there? (#4047)

    python3 Tests/RuntimeUAT/paste_check_app_uat.py --app <bundle id> [--takes N] [--source saved|tts]
        [--seed S] [--clear none|ctrl-u] [--wait SECONDS]

Put the app's text field (or terminal prompt) in front first; the script never stages a field.
Every take is a silent push-to-talk dictation through the audio rig (BlackHole in and out, the
app's microphone pinned, everything restored at the end). One row per take: the paste route, the
`PASTE_LANDING` verdict and whether the row is VALID: exactly one paste cascade into the named app
and exactly one landing line. Anything else (a panel took the focus, extra recordings started) is
INVALID and never evidence. Whether the words really landed is the caller's screenshot.

`--source saved` (default) replays the founder's own saved dictations
(`~/Library/Application Support/EnviousWispr/dictation-audio/*/raw.wav`, completed, 2 to 8 s,
some speech above -30 dBFS). The archive is recorded at the mic's own low level, so each clip is
loudness-normalised into a temporary folder that is deleted at the end; nothing leaves the Mac.
`--source tts` speaks a fixed sentence instead.

`--clear ctrl-u` empties a shell prompt after each take (terminals); `none` (default) leaves the
text for the caller to remove. Run `--takes 1` first as a smoke test.

Exit 0 when every take was valid, 1 when any was invalid (including a failed take setup check),
2 when the setup failed or the clipboard could not be restored.
"""
import argparse
import array
import glob
import json
import os
import random
import subprocess
import sys
import tempfile
import time
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import last_dictation_uat as u  # noqa: E402
import learn_from_edits_apps_uat as apps  # noqa: E402
import paste_landing_uat as p  # noqa: E402
import take_gate as tg  # noqa: E402
import wispr_eyes as w  # noqa: E402
from audio_rig import AppTarget, AudioRig, _wait_frontmost  # noqa: E402

ARCHIVE = os.path.expanduser("~/Library/Application Support/EnviousWispr/dictation-audio")
SENTENCE = "Send the draft to Maya tomorrow morning."


def saved_clips(seed):
    """Completed saved dictations of 2-8 s with some speech above -30 dBFS, shuffled by `seed`."""
    clips = []
    for meta in glob.glob(os.path.join(ARCHIVE, "*", "meta.json")):
        try:
            with open(meta) as fh:
                info = json.load(fh)
        except (OSError, ValueError):
            continue
        wav = os.path.join(os.path.dirname(meta), "raw.wav")
        if info.get("outcome") != "completed" or not 2000 <= info.get("durationMs", 0) <= 8000:
            continue
        try:
            with wave.open(wav) as fh:
                if fh.getsampwidth() != 2:
                    continue
                samples = array.array("h", fh.readframes(fh.getnframes()))
        except (OSError, wave.Error):
            continue
        if samples and max(abs(x) for x in samples) >= 1000:
            clips.append(wav)
    clips.sort()
    random.Random(seed).shuffle(clips)
    return clips


def normalised(clip, folder, n):
    """The clip at speech level (the archive is recorded at the mic's own low level)."""
    out = os.path.join(folder, f"take-{n}.wav")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", clip, "-af", "loudnorm=I=-18:TP=-2",
                    "-ar", "48000", out], check=True)
    return out


class NoiseFloor:
    """A -80 dBFS noise floor on BlackHole for the whole run. Between takes BlackHole otherwise
    carries exact digital zeros, the dead-air detector retires the warm source, and the next take
    ends `zero_signal` (measured 2026-10-24: take 2 onwards, once takes ran back to back; the old
    100 s stall had hidden it). Recipe: code-tooling.md FACT: a-specific-input-CHANNEL-is-drivable-
    with-a-loopback-device."""

    def __init__(self, folder):
        self.path = os.path.join(folder, "noise-floor.wav")
        self.proc = None

    def __enter__(self):
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i",
                        "anoisesrc=color=white:amplitude=0.0001:sample_rate=48000:duration=3600",
                        self.path], check=True)
        # Output is BlackHole inside the rig, so nothing is audible.
        self.proc = subprocess.Popen(["afplay", self.path], stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        time.sleep(0.5)  # settle: afplay opens the device; no ack
        return self

    def __exit__(self, *_):
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="bundle id of the frontmost target app")
    parser.add_argument("--takes", type=int, default=1)
    parser.add_argument("--source", choices=["saved", "tts"], default="saved")
    parser.add_argument("--seed", type=int, default=4047)
    parser.add_argument("--clear", choices=["none", "ctrl-u"], default="none")
    parser.add_argument("--wait", type=float, default=3.0, help="seconds after key release (pipeline)")
    args = parser.parse_args()
    if args.takes < 1:
        parser.error("--takes must be at least 1")
    clips = saved_clips(args.seed) if args.source == "saved" else []
    if args.source == "saved" and len(clips) < args.takes:
        print(f"SETUP: only {len(clips)} usable saved dictations for {args.takes} takes")
        return 2
    w._INPUT_WARN = False
    w.connect()
    try:
        snapshot = u.pasteboard_snapshot()
    except u.Aborted as e:
        print(f"SETUP: {e}")
        return 2
    rows = []
    restored = False
    try:
        with tempfile.TemporaryDirectory(prefix="ew-paste-check-") as folder, \
                AudioRig(target=AppTarget(args.app)) as rig, NoiseFloor(folder):
            for n in range(1, args.takes + 1):
                audio = normalised(clips[n - 1], folder, n) if args.source == "saved" else None
                rig.target.activate()
                if not _wait_frontmost(args.app):
                    raise tg.SetupFailed("paste-target", f"{args.app} did not come to the front "
                                         f"(front is {tg.frontmost_bundle()!r})")
                start = time.monotonic()
                base = u.log_size()
                checks_before = len(u.results)
                lines, cascades = p.take(args.app, base, bundle=args.app, route=rig.route,
                                         sentence=SENTENCE if audio is None else "(saved dictation)",
                                         audio=audio, wait=args.wait)
                mine = [c for c in cascades if c[1].strip() == args.app]
                # take() records its own setup checks (exactly one recording, virtual capture)
                # without raising: any failure among them makes the row INVALID too.
                failed = [r for r in u.results[checks_before:] if r[1] in ("FAIL", "ABORT")]
                valid = len(cascades) == 1 and len(mine) == 1 and len(lines) == 1 and not failed
                tier = mine[0][0] if mine else "-"
                verdict = f"{lines[0][1]}/{lines[0][2]}" if len(lines) == 1 else "-"
                rows.append((n, valid, tier, verdict, time.monotonic() - start))
                print(f"ROW {n} {'VALID' if valid else 'INVALID'} tier={tier} verdict={verdict} "
                      f"cascades={len(cascades)} landing_lines={len(lines)} failed_checks={len(failed)} "
                      f"secs={rows[-1][4]:.0f}",
                      flush=True)
                if args.clear == "ctrl-u":
                    rig.target.activate()
                    apps.press("u", args.app, ctrl=True)
                    time.sleep(0.3)  # settle: the shell redraws the emptied prompt; no ack
    except tg.SetupFailed as e:
        print(f"SETUP: {e}")
        return 2
    finally:
        restored = bool(u.pasteboard_restore(snapshot))
        print(f"clipboard restored: {restored}")
    valid = [r for r in rows if r[1]]
    counts = {}
    for r in valid:
        counts[r[3]] = counts.get(r[3], 0) + 1
    print(f"SUMMARY {len(rows)} takes, {len(valid)} valid; verdicts {counts or '{}'}")
    if not restored:
        print("SETUP: the clipboard was not restored; check it by hand")
        return 2
    return 0 if len(valid) == len(rows) == args.takes else 1


if __name__ == "__main__":
    sys.exit(main())
