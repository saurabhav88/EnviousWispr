#!/usr/bin/env python3
"""Regenerates the #4254 representative-voice fixtures (plan §16.5).

Two macOS system voices (Samantha, Daniel; no real person's voice) read literal scripts.
Everything is 16 kHz mono PCM16, the pipeline's own rate. Silence is a fixed-seed white
noise floor at -66 dBFS, never exact zeros. Speech levels are set and then measured on the
isolated speech stems (RMS over the stem's active samples, |x| > 1e-4) before mixing; the
measured values go into manifest.json with each file's sha256.

The "music" bed is synthetic: a repeating four-chord progression of summed sine tones with a
4 Hz amplitude pulse, plus pink noise. It stands in for background music; it is not recorded
music.

Usage: python3 generate-fixtures.py   (writes *.wav and manifest.json beside this file)
"""
import hashlib
import json
import os
import subprocess
import tempfile
import wave

import numpy as np

RATE = 16_000
HERE = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(4254)


def say(voice, text, work, name):
    aiff = os.path.join(work, name + ".aiff")
    wav = os.path.join(work, name + ".wav")
    subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav], check=True)
    with wave.open(wav) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
        x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768
    # Trim the synthesizer's own leading/trailing silence so placement is exact.
    active = np.flatnonzero(np.abs(x) > 1e-3)
    return x[active[0]:active[-1] + 1]


def rms_db(x):
    a = x[np.abs(x) > 1e-4]
    return 20 * np.log10(np.sqrt(np.mean(a ** 2)))


def at_level(x, db):
    return x * (10 ** ((db - rms_db(x)) / 20))


def floor(n):
    # -66 dBFS RMS white noise.
    return rng.normal(0, 10 ** (-66 / 20), n)


def secs(s):
    return int(round(s * RATE))


def place(track, stem, start_s):
    i = secs(start_s)
    track[i:i + len(stem)] += stem
    return {"startMs": round(1000 * i / RATE), "endMs": round(1000 * (i + len(stem)) / RATE)}


def bed(n):
    t = np.arange(n) / RATE
    chords = [(220.0, 277.18, 329.63), (196.0, 246.94, 293.66), (174.61, 220.0, 261.63), (196.0, 246.94, 329.63)]
    out = np.zeros(n)
    seg = secs(1.5)
    for k in range(0, n, seg):
        f = chords[(k // seg) % 4]
        tt = t[k:k + seg]
        out[k:k + seg] = sum(np.sin(2 * np.pi * fr * tt) for fr in f)
    out *= 0.6 + 0.4 * np.abs(np.sin(2 * np.pi * 2 * t))  # 4 Hz pulse
    white = rng.normal(0, 1, n)
    pink = np.fft.irfft(np.fft.rfft(white) / np.sqrt(np.maximum(np.fft.rfftfreq(n, 1 / RATE), 1)), n)
    return at_level(out, -30) + at_level(pink, -34)


def write(name, x):
    path = os.path.join(HERE, name + ".wav")
    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def main():
    cases = []
    with tempfile.TemporaryDirectory() as work:
        S, D = "Samantha", "Daniel"

        # 1. A quiet voice (-30 dBFS) beside a loud one (-20 dBFS).
        t1 = "The quarterly numbers came in higher than we expected this time."
        t2 = "Can you send me the full report by Friday?"
        t3 = "Sure, I will send it this afternoon."
        l1, q, l2 = at_level(say(D, t1, work, "l1"), -20), at_level(say(S, t2, work, "q"), -30), at_level(say(D, t3, work, "l2"), -20)
        n = secs(1.0) + len(l1) + secs(1.0) + len(q) + secs(1.0) + len(l2) + secs(2.0)
        x = floor(n)
        a = place(x, l1, 1.0)
        b = place(x, q, a["endMs"] / 1000 + 1.0)
        c = place(x, l2, b["endMs"] / 1000 + 1.0)
        cases.append({"id": "quiet-beside-loud", "reference": f"{t1} {t2} {t3}", "voices": [
            {"voice": D, "text": t1, "levelDb": round(rms_db(l1), 2), **a},
            {"voice": S, "text": t2, "levelDb": round(rms_db(q), 2), **b},
            {"voice": D, "text": t3, "levelDb": round(rms_db(l2), 2), **c}], "x": x})

        # 2. A soft onset and a soft ending (600 ms linear fades on the speech itself).
        t = "Let me start with a quick summary of where the project stands today."
        s = at_level(say(S, t, work, "soft"), -22)
        ramp = np.linspace(0, 1, secs(0.6))
        s[:len(ramp)] *= ramp
        s[-len(ramp):] *= ramp[::-1]
        x = floor(secs(2.0) + len(s) + secs(2.0))
        a = place(x, s, 2.0)
        cases.append({"id": "soft-onset-and-ending", "reference": t, "voices": [
            {"voice": S, "text": t, "levelDb": round(rms_db(s), 2), "fadeMs": 600, **a}], "x": x})

        # 3. A brief "Yes." and "No." between silences.
        y, no = at_level(say(S, "Yes.", work, "yes"), -22), at_level(say(D, "No.", work, "no"), -22)
        x = floor(secs(3.0) + len(y) + secs(4.0) + len(no) + secs(4.0))
        a = place(x, y, 3.0)
        b = place(x, no, a["endMs"] / 1000 + 4.0)
        cases.append({"id": "yes-no-between-silences", "reference": "Yes. No.", "voices": [
            {"voice": S, "text": "Yes.", "levelDb": round(rms_db(y), 2), **a},
            {"voice": D, "text": "No.", "levelDb": round(rms_db(no), 2), **b}], "x": x})

        # 4. Two voices overlapping (the second starts 2 s before the first ends).
        ta = "I think we should finish the design review before we talk about the budget."
        tb = "Right, and the budget depends on how many people we hire next month."
        va, vb = at_level(say(S, ta, work, "oa"), -22), at_level(say(D, tb, work, "ob"), -22)
        start_b = 1.0 + len(va) / RATE - 2.0
        x = floor(secs(start_b) + len(vb) + secs(2.0))
        a = place(x, va, 1.0)
        b = place(x, vb, start_b)
        cases.append({"id": "two-voices-overlapping", "reference": None, "voices": [
            {"voice": S, "text": ta, "levelDb": round(rms_db(va), 2), **a},
            {"voice": D, "text": tb, "levelDb": round(rms_db(vb), 2), **b}], "x": x})

        # 5. Speech over the music-and-noise bed.
        t = "We should move the launch to the second week of March."
        s = at_level(say(S, t, work, "mus"), -22)
        n = secs(2.0) + len(s) + secs(2.0)
        x = floor(n) + bed(n)
        a = place(x, s, 2.0)
        cases.append({"id": "speech-over-music-and-noise", "reference": t, "voices": [
            {"voice": S, "text": t, "levelDb": round(rms_db(s), 2), **a}],
            "bedDb": round(rms_db(bed(n)), 2), "x": x})

        # 6. Music and noise with no speech: must give no words.
        n = secs(12.0)
        x = floor(n) + bed(n)
        cases.append({"id": "music-and-noise-only", "reference": "", "voices": [], "x": x})

    manifest = []
    for c in cases:
        x = c.pop("x")
        assert np.max(np.abs(x)) < 1.0, c["id"]
        c["file"] = c["id"] + ".wav"
        c["seconds"] = round(len(x) / RATE, 3)
        c["sha256"] = write(c["id"], x)
        manifest.append(c)
    # The non-English case reuses the committed language-lock clip and its literal script.
    ru = os.path.join(HERE, "..", "language-lock", "lock-ru.wav")
    clips = json.load(open(os.path.join(HERE, "..", "language-lock", "lock-clips.json")))
    manifest.append({"id": "non-english-ru", "file": "../language-lock/lock-ru.wav", "language": "ru",
                     "reference": clips["ru"]["text"], "voices": [{"voice": clips["ru"]["voice"], "text": clips["ru"]["text"]}],
                     "sha256": hashlib.sha256(open(ru, "rb").read()).hexdigest()})
    with open(os.path.join(HERE, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    main()
