#!/usr/bin/env python3
"""Generate the #2184 noise-robustness fixtures.

Builds two deterministic 16 kHz mono WAV files from the already-committed
`scripts/freeze-suite/clips/normal-speech.wav`:

  fixture-noisy-cabin.wav  reproduces the production failure (VAD retains 8.2%)
  fixture-noisy-mild.wav   negative control (VAD retains 100%, unchanged by the fix)

The noise bed is seeded white noise, FFT-shaped to the MEASURED band profile of
the founder's 18:05 aeroplane take (issue #2184). Seed is fixed so the bytes are
reproducible; regenerating must produce an identical file or the fixture has
drifted and the test that depends on it is no longer the test that was reviewed.

Usage:  python3 <this> <path/to/normal-speech.wav> <output-dir>
"""
import sys
import wave

import numpy as np

SR = 16000
SEED = 20260818
# (low Hz, high Hz, fraction of total noise energy) — measured, do not retune
# without re-measuring against a real recording and saying so on the issue.
BANDS = [(20, 80, 0.419), (80, 150, 0.273), (150, 300, 0.240),
         (300, 1000, 0.067), (1000, 8000, 0.001)]
VARIANTS = [("cabin", 0.27), ("mild", 0.08)]


def read_wav(path):
    with wave.open(path) as w:
        assert w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2, \
            f"expected 16 kHz mono int16, got {w.getframerate()} Hz {w.getnchannels()}ch"
        raw = w.readframes(w.getnframes())
    # float64 throughout: complex64/complex128 promotion differs between an
    # in-place and an out-of-place spectrum multiply, which moved 96 of 100224
    # samples by 1 LSB between two implementations of this same recipe.
    return np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0


def shaped_bed(n):
    rng = np.random.default_rng(SEED)
    spectrum = np.fft.rfft(rng.standard_normal(n).astype(np.float64))
    freqs = np.fft.rfftfreq(n, 1 / SR)
    shape = np.zeros_like(freqs)
    for lo, hi, frac in BANDS:
        band = (freqs >= lo) & (freqs < hi)
        if band.sum():
            shape[band] = np.sqrt(frac / band.sum())
    bed = np.fft.irfft(spectrum * shape, n).astype(np.float64)
    return bed / np.sqrt(np.mean(bed ** 2))


def main(speech_path, out_dir):
    speech = read_wav(speech_path)
    bed = shaped_bed(len(speech))
    for name, target_rms in VARIANTS:
        mix = speech + bed * target_rms
        peak = np.max(np.abs(mix))
        if peak > 0.999:            # soft ceiling: emulate a hot mic, not hard clipping
            mix = mix / peak * 0.999
        out = f"{out_dir}/fixture-noisy-{name}.wav"
        with wave.open(out, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes((mix * 32767).astype(np.int16).tobytes())
        print(f"{name}: rms={np.sqrt(np.mean(mix ** 2)):.4f} peak={np.max(np.abs(mix)):.3f} -> {out}")

    print("NOTE: the committed WAV is the authority. This generator records how it\n"
          "      was made; it is provenance, not a build step the test depends on.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
